import Foundation
import PadCore

/// One timer and paired writer. Managed activation never falls back to standalone publication.
@MainActor final class ApplicationSessionCheckpoints {
  private let session: SessionCoordinator
  private let recovery: RecoveryCoordinator
  private let managed: ManagedCheckpointSources?
  private let legacy: LegacyCheckpointSources?
  private let onRetry: (() -> Void)?
  private let delay: @MainActor (CheckpointDelay) async throws -> Void
  private let owner = UUID()
  private var activation: ManagedPublisherActivation?
  private var activationDrained = false
  private var activationError: Error?
  private var transitioning = false
  private var quitDrained = false
  private var externalPauses: [CheckpointPauseToken] = []
  private lazy var scheduler = makeScheduler()
  private(set) var phase: ApplicationPublisherPhase

  init(
    session: SessionCoordinator, recovery: RecoveryCoordinator,
    managed: ManagedCheckpointSources,
    delay: @escaping @MainActor (CheckpointDelay) async throws -> Void = {
      try await Task.sleep(nanoseconds: $0 == .debounce ? 750_000_000 : 15_000_000_000)
    }
  ) {
    self.session = session
    self.recovery = recovery
    self.managed = managed
    self.legacy = nil
    self.onRetry = nil
    self.delay = delay
    self.phase = .restoring
  }

  init(
    session: SessionCoordinator, recovery: RecoveryCoordinator, legacy: LegacyCheckpointSources,
    onRetry: (() -> Void)?
  ) {
    self.session = session
    self.recovery = recovery
    self.managed = nil
    self.legacy = legacy
    self.onRetry = onRetry
    self.delay = {
      try await Task.sleep(nanoseconds: $0 == .debounce ? 750_000_000 : 15_000_000_000)
    }
    self.phase = .legacy
  }

  var lastAcknowledgedGeneration: UInt64 { scheduler.lastAcknowledgedGeneration }
  var lastError: Error? { activationError ?? scheduler.lastError }
  var hasPendingChanges: Bool { scheduler.hasPendingChanges }

  func startAfterRestoration() {
    if managed == nil { scheduler.startAfterRestoration() }
    renderStatus()
  }
  func requestCheckpoint() {
    scheduler.requestCheckpoint()
    renderStatus()
  }
  func pauseAndDrain() async {
    await scheduler.pauseAndDrain()
    renderStatus()
  }
  func resumeAfterVeto() {
    if managed != nil, phase != .managed {
      cancelPreparedQuit()
    } else {
      scheduler.resumeAfterVeto()
      renderStatus()
    }
  }

  func beginManagedActivation() throws -> ManagedPublisherActivation {
    guard !transitioning, phase == .restoring, activation == nil else {
      throw ApplicationCheckpointError.invalidPhase
    }
    let value = ManagedPublisherActivation(
      owner: owner, request: UUID(), pause: try scheduler.acquirePause())
    activation = value
    phase = .activating(value.request)
    renderStatus()
    return value
  }
  private func requireActivation(_ value: ManagedPublisherActivation) throws {
    guard value.owner == owner, activation == value,
      phase == .activating(value.request) || phase == .failedActivation(value.request)
    else { throw ApplicationCheckpointError.invalidActivation }
  }
  func drainManagedActivation(_ value: ManagedPublisherActivation) async throws {
    guard !transitioning else { throw ApplicationCheckpointError.invalidPhase }
    try requireActivation(value)
    try await scheduler.drainPause(value.pause)
    try requireActivation(value)
    activationDrained = true
  }
  func finishManagedActivation(_ value: ManagedPublisherActivation) throws {
    guard !transitioning else { throw ApplicationCheckpointError.invalidPhase }
    try requireActivation(value)
    guard activationDrained else { throw CheckpointSchedulerError.pauseNotDrained }
    guard externalPauses.isEmpty else { throw ApplicationCheckpointError.unsettled }
    transitioning = true
    do {
      let expected = phase
      _ = try readyWindows(expected: expected)
      // Validated recovery buffers may become usable under preserved metadata failure.
      // Publication still calls captureSession and cannot overwrite that metadata.
      guard session.restorationComplete else { throw ApplicationCheckpointError.unsettled }
      try requireActivation(value)
      phase = .managed
      activation = nil
      activationError = nil
      try scheduler.releasePause(value.pause)
      scheduler.startAfterRestoration()
      transitioning = false
    } catch {
      transitioning = false
      throw error
    }
    renderStatus()
  }
  func failManagedActivation(_ value: ManagedPublisherActivation, error: Error) throws {
    guard !transitioning else { throw ApplicationCheckpointError.invalidPhase }
    try requireActivation(value)
    phase = .failedActivation(value.request)
    activationError = error
    renderStatus()
  }

  /// Startup intake owns an independent hold; it cannot consume the outer activation pause.
  func acquireActivationPause(_ value: ManagedPublisherActivation) throws -> CheckpointPauseToken {
    guard !transitioning else { throw ApplicationCheckpointError.invalidPhase }
    try requireActivation(value)
    let token = try scheduler.acquirePause()
    externalPauses.append(token)
    return token
  }

  func acquirePause() throws -> CheckpointPauseToken {
    guard !transitioning, phase == .managed || phase == .legacy else {
      throw ApplicationCheckpointError.invalidPhase
    }
    let token = try scheduler.acquirePause()
    externalPauses.append(token)
    return token
  }
  func drainPause(_ token: CheckpointPauseToken) async throws {
    guard externalPauses.contains(token) else { throw CheckpointSchedulerError.invalidPause }
    try await scheduler.drainPause(token)
  }
  func releasePause(_ token: CheckpointPauseToken) throws {
    guard !transitioning, externalPauses.contains(token) else {
      throw CheckpointSchedulerError.invalidPause
    }
    try scheduler.releasePause(token)
    externalPauses.removeAll { $0 == token }
    renderStatus()
  }

  func prepareQuit() async throws {
    guard !transitioning, phase == .managed, externalPauses.isEmpty else {
      throw ApplicationCheckpointError.invalidPhase
    }
    let request = UUID()
    phase = .preparingQuit(request)
    quitDrained = false
    do {
      transitioning = true
      _ = try readyWindows(expected: .preparingQuit(request))
      transitioning = false
      await scheduler.pauseAndDrain()
      transitioning = true
      _ = try readyWindows(expected: .preparingQuit(request))
      quitDrained = true
      transitioning = false
    } catch {
      transitioning = false
      // Caller explicitly thaws native state and cancels quit. Never release another owner's pause.
      throw error
    }
  }
  func markNativeQuitPrepared() throws {
    guard !transitioning, quitDrained, case .preparingQuit(let id) = phase else {
      throw ApplicationCheckpointError.invalidPhase
    }
    transitioning = true
    defer { transitioning = false }
    _ = try readyWindows(expected: .preparingQuit(id))
    phase = .finalReady(id)
  }
  func cancelPreparedQuit() {
    guard !transitioning else { return }
    switch phase {
    case .preparingQuit, .finalReady:
      quitDrained = false
      phase = .managed
      scheduler.resumeAfterVeto()
      renderStatus()
    default: return
    }
  }
  func commitFinal() async throws -> SessionCheckpointReceipt {
    if managed == nil { return try await scheduler.commitFinal() }
    guard !transitioning, case .finalReady(let id) = phase else {
      throw ApplicationCheckpointError.invalidPhase
    }
    phase = .finalizing(id)
    defer { if phase == .finalizing(id) { phase = .finalReady(id) } }
    return try await scheduler.commitFinal()
  }

  private func readyWindows(expected: ApplicationPublisherPhase) throws -> [DocumentWindowSnapshot]
  {
    guard let managed, phase == expected else { throw ApplicationCheckpointError.invalidPhase }
    try managed.requireIntakeSettled()
    do {
      try managed.requireCloseSettled()
    } catch {
      if expected == .managed,
        let closeError = error as? DocumentClosingError,
        closeError == .pendingRecovery
      {
        throw CheckpointSchedulerError.closeInProgress
      }
      throw error
    }
    guard phase == expected else { throw ApplicationCheckpointError.invalidPhase }
    let registry = managed.registry
    let revision = registry.workspaceRevision
    let windows = try registry.captureReadyWindows()
    var count = 0
    guard windows.count <= 32 else { throw RecoveryError.resourceLimit }
    for window in windows {
      guard window.groups.count == 1 else { throw ApplicationCheckpointError.invalidProjection }
      for id in window.groups[0].documentIDs {
        count += 1
        guard count <= 128 else { throw RecoveryError.resourceLimit }
        guard registry.adoptionStatus(documentID: id) == .active,
          registry.handle(id: id)?.workspaceKind == .editable
        else { throw ApplicationCheckpointError.unsettled }
      }
    }
    try managed.validateProjection(windows)
    guard phase == expected, registry.workspaceRevision == revision,
      try registry.captureReadyWindows() == windows
    else { throw ApplicationCheckpointError.invalidProjection }
    return windows
  }

  private func requireCapturePhase() throws {
    switch phase {
    case .managed, .finalizing: return
    default: throw ApplicationCheckpointError.invalidPhase
    }
  }
  private func capture(_ generation: UInt64) throws -> SessionCheckpointCapture {
    guard let managed else {
      let pairs = try legacy!.capture()
      return SessionCheckpointCapture(
        generation: generation, liveTabIDs: Set(pairs.flatMap { $0.liveTabIDs }),
        recovery: pairs.flatMap(\.recovery),
        session: try session.captureSession(windows: pairs.map(\.window)))
    }
    try requireCapturePhase()
    let expected = phase
    let windows = try readyWindows(expected: expected)
    let revision = managed.registry.workspaceRevision
    try managed.preflightResources(windows)
    guard phase == expected, managed.registry.workspaceRevision == revision else {
      throw ApplicationCheckpointError.invalidProjection
    }
    var pairs: [ManagedWindowCheckpointCapture] = []
    for window in windows {
      let pair = try managed.captureWindow(window)
      let group = window.groups[0]
      guard phase == expected, managed.registry.workspaceRevision == revision,
        pair.window.id == window.id, pair.window.tabs.map(\.id) == group.documentIDs,
        pair.window.selectedTabID == group.selectedDocumentID,
        pair.liveTabIDs == Set(group.documentIDs), pair.recovery.count == group.documentIDs.count,
        Set(pair.recovery.map(\.id)) == pair.liveTabIDs,
        pair.window.tabs.allSatisfy({ managed.registry.metadata(id: $0.id)?.pinned == $0.pinned }),
        pair.recovery.allSatisfy({
          $0.authority?.documentID == $0.id && $0.authority?.coordinatorID == recovery.coordinatorID
        })
      else { throw ApplicationCheckpointError.invalidProjection }
      pairs.append(pair)
    }
    guard try readyWindows(expected: expected) == windows,
      managed.registry.workspaceRevision == revision
    else { throw ApplicationCheckpointError.invalidProjection }
    let value = try session.captureSession(windows: pairs.map(\.window))
    return SessionCheckpointCapture(
      generation: generation, liveTabIDs: Set(pairs.flatMap { $0.liveTabIDs }),
      recovery: pairs.flatMap(\.recovery), session: value)
  }

  private func makeScheduler() -> SessionCheckpointCoordinator {
    let recovery = recovery
    let isManaged = managed != nil
    let coordinator = SessionCheckpointCoordinator(
      capture: { [weak self] generation in
        guard let self else { throw CancellationError() }
        return try self.capture(generation)
      },
      commit: { value in
        try await recovery.validateUncertainCheckpoint()
        if isManaged { return try await recovery.commitAuthorizedSessionCheckpoint(value) }
        return try await recovery.commitSessionCheckpoint(value)
      },
      prepareCapture: { [weak self] in
        guard let self else { throw CancellationError() }
        if self.managed != nil {
          try self.requireCapturePhase()
          _ = try self.readyWindows(expected: self.phase)
        } else {
          try await self.legacy!.prepare()
        }
        try await self.session.drainPendingRemovals()
        if self.managed != nil {
          try self.requireCapturePhase()
          _ = try self.readyWindows(expected: self.phase)
        }
      }, delay: delay)
    coordinator.onStateChanged = { [weak self] in self?.renderStatus() }
    return coordinator
  }
  private func renderStatus() {
    let message: String
    let retry: (() -> Void)?
    if let error = lastError {
      message = "Session recovery needs attention: " + error.localizedDescription
      // Intake owns activation recovery; requesting a stopped checkpoint cannot repair it.
      retry =
        activationError == nil
        ? { [weak self] in
          guard let self else { return }
          if let onRetry = self.onRetry { onRetry() } else { self.requestCheckpoint() }
        } : nil
    } else {
      message =
        hasPendingChanges || lastAcknowledgedGeneration == 0
        ? "Session recovery pending" : "Session recovery saved"
      retry = nil
    }
    if let managed {
      managed.renderStatus(message, retry)
    } else {
      legacy?.renderStatus(message, retry)
    }
  }
}
