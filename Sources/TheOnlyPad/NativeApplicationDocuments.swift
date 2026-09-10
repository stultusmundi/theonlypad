import AppKit
import PadCore

enum NativeWorkspaceError: Error { case notReady, staleEndpoint, retainedImport, quitVetoed }

/// Process owner. The registry owns models; endpoint records own their current native presentation.
@MainActor final class NativeApplicationDocuments {
  private final class Endpoint {
    let id = UUID()
    let assignment: DocumentAssignment
    var controller: EditorWindowController?
    init(_ assignment: DocumentAssignment) { self.assignment = assignment }
  }
  let registry: ApplicationDocuments
  private let session: SessionCoordinator
  private let recovery: RecoveryCoordinator
  private let monitoring: ApplicationFileMonitoring
  private let bindings: NativeDocumentEndpointBindings
  private let onWindowCreated: (EditorWindowController) -> Void
  private let onError: (Error) -> Void
  private let openLargeFile: (LaunchRequest) async throws -> Void
  private var endpoints: [UUID: Endpoint] = [:]
  private var activation: ManagedPublisherActivation?
  private var startupTask: Task<Void, Error>?
  private var pending: [(UUID, NativeDocumentSeed)] = []
  private var retainedStartup: DocumentIntakeID?
  private var startupInFlight = false
  private var startupScratch: UUID?
  private var admissionRefreshPending = false
  private var ready = false
  private var quitting = false
  private var preparingHistory = false
  var windows: [EditorWindowController] {
    (try? registry.captureWindows())?.compactMap { endpoints[$0.id]?.controller } ?? []
  }

  private lazy var checkpoints: ApplicationSessionCheckpoints = ApplicationSessionCheckpoints(
    session: session, recovery: recovery,
    managed: .init(
      registry: registry, requireIntakeSettled: { try self.intake.requireSettled() },
      requireCloseSettled: { try self.closing.requireSettled() },
      validateProjection: { values in
        for value in values {
          let endpoint = try self.endpoint(windowID: value.id)
          try endpoint.controller!.validateRegistryProjection(
            value,
            revision: self.registry.workspaceRevision, endpointID: endpoint.id)
        }
      },
      captureWindow: { value in
        try self.endpoint(windowID: value.id).controller!.captureManagedSessionCheckpoint(
          expected: value)
      },
      preflightResources: { values in
        var budget = SessionStartupBudget()
        for value in values {
          for id in value.groups.flatMap(\.documentIDs) {
            guard let model = self.registry.handle(id: id) as? EditorDocument else {
              throw DocumentIntakeError.staleModel
            }
            try budget.admit(
              utf16Count: model.storage.length, originalByteCount: model.originalBytes?.count ?? 0)
          }
          try self.endpoint(windowID: value.id).controller!.validateManagedResources(
            expected: value)
        }
      },
      renderStatus: { message, retry in
        for window in self.windows {
          window.updateSessionCheckpointStatus(message: message, retry: retry)
        }
      }))
  private lazy var intake: NativeDocumentIntakeController = NativeDocumentIntakeController(
    registry: registry, session: session, recovery: recovery,
    publication: .init(
      acquirePause: {
        if let activation = self.activation {
          return try self.checkpoints.acquireActivationPause(activation)
        }
        return try self.checkpoints.acquirePause()
      }, drainPause: { try await self.checkpoints.drainPause($0) },
      releasePause: { try self.checkpoints.releasePause($0) },
      requestCheckpoint: { self.checkpoints.requestCheckpoint() }),
    destinations: .init(
      requireAdmission: {
        guard self.activation != nil || self.ready else { throw NativeWorkspaceError.notReady }
        try self.closing.requireSettled()
      }, validate: { try self.validate(endpointID: $0, assignment: $1) },
      exists: { id in self.endpoints.values.contains { $0.id == id && $0.controller != nil } },
      resolveSelection: { id, assignment, selection in
        try self.validate(endpointID: id, assignment: assignment)
        switch selection {
        case .select: return true
        case .preserve: return false
        case .selectIfStillSelected(let documentID, let generation):
          return self.registry.window(id: assignment.windowID)?.groups.first?.selectedDocumentID
            == documentID
            && self.registry.handle(id: documentID)?.ownershipGeneration == generation
        }
      }, drainLegacyWrites: { try await self.drainLegacy() },
      project: { id, assignment in
        try self.validate(endpointID: id, assignment: assignment)
        try self.project(windowID: assignment.windowID)
      }))
  private lazy var closing: NativeApplicationCloseCoordinator = NativeApplicationCloseCoordinator(
    registry: registry, recovery: recovery,
    publication: .init(
      requireApplicationAdmission: {
        try self.requireUserAdmission()
        try self.intake.requireSettled()
      },
      acquirePause: { try self.checkpoints.acquirePause() },
      drainPause: { try await self.checkpoints.drainPause($0) },
      releasePause: { try self.checkpoints.releasePause($0) },
      requestCheckpoint: { self.checkpoints.requestCheckpoint() }),
    endpoint: { windowID in
      guard let value = self.endpoints[windowID], let controller = value.controller else {
        return nil
      }
      return (value.id, controller)
    }, reportError: { self.onError($0) })

  private lazy var externalOpens: NativeApplicationOpenCoordinator = .init(
    ports: .init(
      chooseDestination: { _ in
        guard self.ready else { throw NativeWorkspaceError.notReady }
        try self.intake.requireSettled()
        try self.closing.requireSettled()
        let chosen = self.windows.first { $0.window === NSApp.keyWindow } ?? self.windows.first
        let value =
          try chosen.map { try self.endpoint(windowID: $0.sessionMetadata.id) }
          ?? self.createEndpoint()
        return .init(endpointID: value.id, assignment: value.assignment)
      },
      requireDestination: { destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
      },
      existing: { request, destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        guard let window = self.registry.window(id: destination.assignment.windowID) else {
          throw NativeWorkspaceError.staleEndpoint
        }
        guard
          let id = window.groups.flatMap(\.documentIDs).first(where: {
            (self.registry.handle(id: $0) as? EditorDocument)?.url?.standardizedFileURL
              == request.url.standardizedFileURL
          })
        else { return nil }
        try self.selectOwnedDocument(id, destination: destination)
        return id
      },
      submit: { seed, destination in
        try self.intake.submit(
          .init(
            endpointID: destination.endpointID, assignment: destination.assignment,
            seed: seed, provenance: .fresh, selection: .select,
            requireDestinationCurrent: {
              try self.validate(
                endpointID: destination.endpointID, assignment: destination.assignment)
            }))
      }, wait: { try await self.intake.wait(for: $0) },
      retrySame: { id, destination in
        guard self.intake.status?.id == id, self.intake.status?.stage == .failed else {
          throw DocumentIntakeError.expired
        }
        if self.endpoints[destination.assignment.windowID] == nil {
          try self.recreateEndpoint(windowID: destination.assignment.windowID)
        }
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        try self.intake.retry(id)
        return .init(endpointID: value.id, assignment: value.assignment)
      },
      reconcileDestination: { documentID, destination in
        guard self.registry.handle(id: documentID) != nil else {
          throw NativeApplicationOpenError.documentClosed
        }
        guard self.registry.assignment(of: documentID) == destination.assignment else {
          throw DocumentIntakeError.staleDestination
        }
        if self.endpoints[destination.assignment.windowID] == nil {
          try self.recreateEndpoint(windowID: destination.assignment.windowID)
        }
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        let reconciled = NativeApplicationOpenDestination(
          endpointID: value.id, assignment: value.assignment)
        try self.selectOwnedDocument(documentID, destination: reconciled)
        return reconciled
      },
      navigate: { documentID, destination, line, column in
        guard self.registry.handle(id: documentID) != nil else {
          throw NativeApplicationOpenError.documentClosed
        }
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        try await value.controller!.navigateManaged(
          documentID: documentID, endpointID: value.id, line: line, column: column)
        guard let model = self.registry.handle(id: documentID) as? EditorDocument else {
          throw DocumentIntakeError.staleModel
        }
        if let url = model.url { value.controller!.onOpenedURL?(url) }
      },
      largeFile: { request, destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        try await self.openLargeFile(request)
      }, reportError: { self.onError($0.error) }))

  init(
    session: SessionCoordinator, recovery: RecoveryCoordinator,
    monitoring: ApplicationFileMonitoring,
    onWindowCreated: @escaping (EditorWindowController) -> Void,
    onError: @escaping (Error) -> Void,
    openLargeFile: @escaping (LaunchRequest) async throws -> Void = { _ in
      throw NativeApplicationOpenError.tooLarge
    }
  ) throws {
    self.session = session
    self.recovery = recovery
    self.monitoring = monitoring
    self.onWindowCreated = onWindowCreated
    self.onError = onError
    self.openLargeFile = openLargeFile
    bindings = try NativeDocumentEndpointBindings()
    registry = ApplicationDocuments(
      closeServices: .init(readState: { handle in
        guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
        return try model.captureCloseState()
      }),
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { handle in
          guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
          return .init(
            documentID: model.id, ownershipGeneration: model.ownershipGeneration,
            authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        }))
  }
  private func requireUserAdmission() throws {
    guard ready, !quitting else { throw NativeWorkspaceError.notReady }
  }
  private func endpoint(windowID: UUID) throws -> Endpoint {
    guard let value = endpoints[windowID], value.controller != nil else {
      throw NativeWorkspaceError.staleEndpoint
    }
    return value
  }
  private func validate(endpointID: UUID, assignment: DocumentAssignment) throws {
    let value = try endpoint(windowID: assignment.windowID)
    guard value.id == endpointID, value.assignment == assignment else {
      throw NativeWorkspaceError.staleEndpoint
    }
    try value.controller!.requireEndpointIdentity(endpointID: endpointID, assignment: assignment)
  }
  private func createEndpoint(windowID: UUID = UUID()) throws -> Endpoint {
    guard endpoints[windowID] == nil else { throw NativeWorkspaceError.staleEndpoint }
    let assignment: DocumentAssignment
    if let window = registry.window(id: windowID) {
      guard window.groups.count == 1 else { throw ApplicationCheckpointError.invalidProjection }
      assignment = .init(windowID: windowID, groupID: window.groups[0].id)
    } else {
      let live = Set(try registry.captureWindows().map(\.id))
      let reserved = Set(session.unresolved.map(\.windowID))
      guard live.union(reserved).union([windowID]).count <= 32 else {
        throw SessionStoreError.limit
      }
      assignment = .init(windowID: windowID, groupID: UUID())
      try registry.registerWindow(id: windowID, initialGroupID: assignment.groupID)
    }
    let value = Endpoint(assignment)
    endpoints[windowID] = value
    let current: () throws -> Void = { [weak self, weak value] in
      guard let self, let value, self.endpoints[windowID] === value else {
        throw NativeWorkspaceError.staleEndpoint
      }
    }
    let routing = EditorApplicationRouting(
      endpointID: value.id, assignment: assignment, registry: registry,
      requireEndpointCurrent: current,
      requireUserAdmission: { [weak self] in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.requireUserAdmission()
      },
      submit: { [weak self] submission in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.requireUserAdmission()
        return try self.intake.submit(submission)
      },
      wait: { [weak self] id in
        guard let self else { throw NativeWorkspaceError.notReady }
        return try await self.intake.wait(for: id)
      },
      requestClose: { [weak self] ids in
        guard let self else { throw NativeWorkspaceError.notReady }
        try current()
        guard let window = self.registry.window(id: windowID) else {
          throw NativeWorkspaceError.staleEndpoint
        }
        let ordered = window.groups.flatMap(\.documentIDs).filter { ids.contains($0) }
        guard Set(ordered) == ids else { throw DocumentClosingError.invalidRequest }
        return try self.closing.start(documentIDs: ordered, sourceWindowID: windowID)
      },
      requestReopen: { [weak self] in
        guard let self else { throw NativeWorkspaceError.notReady }
        try current()
        return try await self.reopen(windowID: windowID)
      },
      detachDocumentEndpoint: { [weak self] model in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.bindings.detach(model)
      },
      reattachDocumentEndpoint: { [weak self] model, context, change in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.bindings.reattach(model, liveContext: context, onChange: change)
      },
      endpointClosed: { [weak self, weak value] id in
        guard let self, let value, value.id == id, self.endpoints[windowID] === value else {
          return
        }
        self.endpoints[windowID] = nil
        self.closing.endpointClosed(windowID: windowID)
        if self.registry.window(id: windowID)?.groups.allSatisfy({ $0.documentIDs.isEmpty }) == true
        {
          do {
            try self.registry.unregisterEmptyWindow(
              windowID, expectedRevision: self.registry.workspaceRevision)
            self.checkpoints.requestCheckpoint()
          } catch { self.onError(error) }
        }
      }, requestCheckpoint: { [weak self] in self?.checkpoints.requestCheckpoint() })
    do {
      let controller = try EditorWindowController(
        id: windowID, application: routing, onError: onError)
      value.controller = controller
      controller.configureFileMonitoring(monitoring)
      if registry.window(id: windowID)?.groups.allSatisfy({ $0.documentIDs.isEmpty }) == true {
        try project(windowID: windowID)
      }
      onWindowCreated(controller)
      try current()
      return value
    } catch {
      if endpoints[windowID] === value { endpoints[windowID] = nil }
      throw error
    }
  }
  private func selectOwnedDocument(_ id: UUID, destination: NativeApplicationOpenDestination) throws
  {
    try validate(endpointID: destination.endpointID, assignment: destination.assignment)
    let value = try endpoint(windowID: destination.assignment.windowID)
    guard let model = registry.handle(id: id) as? EditorDocument,
      registry.assignment(of: id) == destination.assignment,
      registry.allows(.select, documentID: id), model.composingPaneID == nil,
      !model.storage.editedMask.contains(.editedCharacters),
      value.controller?.focusedPane?.document.composingPaneID == nil
    else { throw PaneRoutingError.stale }
    try registry.selectDocument(
      id, in: destination.assignment, expectedRevision: registry.workspaceRevision)
    try project(windowID: destination.assignment.windowID)
  }
  private func project(windowID: UUID) throws {
    let value = try endpoint(windowID: windowID)
    guard let expected = registry.window(id: windowID) else {
      throw NativeWorkspaceError.staleEndpoint
    }
    try value.controller!.applyRegistryProjection(
      expected, revision: registry.workspaceRevision, endpointID: value.id)
  }
  private func drainLegacy() async throws {
    try EditorWindowController.assertNoPendingCloses()
    for value in Array(endpoints.values) {
      guard let controller = value.controller else { throw NativeWorkspaceError.staleEndpoint }
      try await controller.drainLegacyRecoveryWrites(endpointID: value.id)
      try validate(endpointID: value.id, assignment: value.assignment)
    }
    try EditorWindowController.assertNoPendingCloses()
  }
  private func refreshAdmission() throws {
    for value in endpoints.values {
      guard let window = registry.window(id: value.assignment.windowID),
        let controller = value.controller
      else {
        throw NativeWorkspaceError.staleEndpoint
      }
      for id in window.groups.flatMap(\.documentIDs) {
        guard let model = registry.handle(id: id) as? EditorDocument else {
          throw DocumentIntakeError.staleModel
        }
        try controller.applyManagedAdmission(to: model, endpointID: value.id)
      }
    }
  }
  func start() async throws {
    if let startupTask { return try await startupTask.value }
    startupInFlight = true
    let task = Task {
      defer { self.startupInFlight = false }
      try await self.restore()
    }
    startupTask = task
    try await task.value
  }
  private func restore() async throws {
    let token = try checkpoints.beginManagedActivation()
    activation = token
    do {
      try await checkpoints.drainManagedActivation(token)
      await session.restore { window in
        var failures: [UUID: String] = [:]
        for tab in window.tabs {
          failures[tab.metadata.id] = "Awaiting managed document import."
          if self.pending.count < 128,
            Set(self.pending.map { $0.0 }).union([window.id]).count <= 32,
            let seed = tab.seed
          {
            self.pending.append((window.id, seed))
          }
        }
        return failures
      }
      try await continueStartup()
    } catch {
      if activation != nil { try checkpoints.failManagedActivation(token, error: error) }
      throw error
    }
  }
  private func continueStartup() async throws {
    guard let token = activation else { throw NativeWorkspaceError.notReady }
    if let id = retainedStartup {
      if let windowID = pending.first?.0, endpoints[windowID] == nil {
        try recreateEndpoint(windowID: windowID)
      }
      try intake.retry(id)
      switch try await intake.wait(for: id) {
      case .imported:
        retainedStartup = nil
        pending.removeFirst()
      case .refused(let error):
        retainedStartup = nil
        throw error
      case .retained(_, let error): throw error
      }
    }
    if pending.isEmpty, try registry.captureWindows().isEmpty {
      let reservedWindows = Set(session.unresolved.map(\.windowID))
      let reservedDocuments = Set(session.unresolved.map { $0.metadata.id })
      if reservedDocuments.count < 128, reservedWindows.count <= 32 {
        let seed = try NativeDocumentSeed.scratch()
        startupScratch = seed.id
        let destination = reservedWindows.count == 32 ? session.unresolved[0].windowID : UUID()
        pending.append((destination, seed))
      } else {
        // Existing unresolved ownership fills the budget; expose its repair UI without adding a record.
        onError(SessionStoreError.limit)
      }
    }
    while let (windowID, seed) = pending.first {
      let value = try endpoints[windowID] ?? createEndpoint(windowID: windowID)
      let provenance: DocumentIntakeProvenance
      var selection = EditorIntakeSelection.select
      var insertionIndex: Int?
      if seed.id == startupScratch {
        provenance = .fresh
      } else {
        guard
          let entry = session.unresolved.first(where: {
            $0.metadata.id == seed.id && $0.windowID == windowID
          })
        else { throw SessionImportError.invalidClaim }
        do { provenance = .session(try session.claimImport(entry)) } catch {
          guard seed.url == nil, seed.originalBytes == nil else { throw error }
          provenance = .recovery(try session.claimRecoveryImport(entry))
        }
        selection = session.shouldSelect(entry) ? .select : .preserve
        insertionIndex = session.insertionIndex(for: entry, in: value.controller!.sessionMetadata)
      }
      let submission = EditorPreparedSubmission(
        endpointID: value.id, assignment: value.assignment,
        seed: seed, provenance: provenance, selection: selection,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        },
        insertionIndex: insertionIndex)
      let id = try intake.submit(submission)
      switch try await intake.wait(for: id) {
      case .imported: pending.removeFirst()
      case .refused(let error):
        onError(error)
        pending.removeFirst()
      case .retained(_, let error):
        retainedStartup = id
        throw error
      }
    }
    try checkpoints.finishManagedActivation(token)
    activation = nil
    ready = true
    session.onSessionChange = { [weak self] in self?.checkpoints.requestCheckpoint() }
    admissionRefreshPending = true
    try refreshAdmission()
    admissionRefreshPending = false
    externalOpens.startupFinished()
  }
  func retryStartup() async throws {
    guard !quitting else { throw NativeWorkspaceError.notReady }
    guard !startupInFlight else { throw DocumentIntakeError.busy }
    if admissionRefreshPending {
      try refreshAdmission()
      admissionRefreshPending = false
      startupTask = Task {}
      externalOpens.startupFinished()
      return
    }
    guard activation != nil else { throw NativeWorkspaceError.notReady }
    startupInFlight = true
    let task = Task {
      defer { self.startupInFlight = false }
      try await self.continueStartup()
    }
    startupTask = task
    try await task.value
  }
  /// Explicitly reconstruct a lost endpoint without replacing its registry-owned models.
  func recreateEndpoint(windowID: UUID) throws {
    guard !quitting, endpoints[windowID] == nil, registry.window(id: windowID) != nil else {
      throw NativeWorkspaceError.staleEndpoint
    }
    let value = try createEndpoint(windowID: windowID)
    if let status = intake.status, status.stage == .failed,
      registry.assignment(of: status.documentID)?.windowID == windowID
    {
      try intake.reconcileDestination(status.id, endpointID: value.id)
    } else {
      try project(windowID: windowID)
    }
  }
  private func reopen(windowID: UUID) async throws -> DocumentIntakeID {
    try requireUserAdmission()
    try intake.requireSettled()
    try closing.requireSettled()
    guard !preparingHistory else { throw DocumentIntakeError.busy }
    let value = try endpoint(windowID: windowID)
    preparingHistory = true
    defer { preparingHistory = false }
    let prepared = try await NativeHistoryPreparation.prepare(
      registry: registry, windowID: windowID)
    try requireUserAdmission()
    try validate(endpointID: value.id, assignment: value.assignment)
    return try intake.submit(
      .init(
        endpointID: value.id, assignment: value.assignment,
        seed: prepared.seed, provenance: .history(prepared.claim), selection: .select,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        }))
  }
  @discardableResult func enqueueExternal(_ requests: [LaunchRequest]) -> OpenRequestAdmission {
    externalOpens.enqueue(requests)
  }
  var pendingExternalOpenCount: Int { externalOpens.pendingCount }
  var externalOpenFailure: OpenRequestFailure? { externalOpens.lastFailure }
  func retryExternalOpen() throws {
    try requireUserAdmission()
    try externalOpens.retryCurrent()
  }

  func retryDocumentIntake() async throws {
    try requireUserAdmission()
    guard let status = intake.status, status.stage == .failed else {
      throw DocumentIntakeError.expired
    }
    guard let assignment = registry.assignment(of: status.documentID) else {
      throw DocumentIntakeError.staleDestination
    }
    if endpoints[assignment.windowID] == nil { try recreateEndpoint(windowID: assignment.windowID) }
    try intake.retry(status.id)
    switch try await intake.wait(for: status.id) {
    case .imported: return
    case .refused(let error), .retained(_, let error): throw error
    }
  }

  var canRetryRecovery: Bool {
    activation != nil || admissionRefreshPending || externalOpens.hasRetainedRequest
      || intake.status?.stage == .failed || closing.status?.stage == .failed
      || checkpoints.lastError != nil
  }
  func retryRecovery() async throws {
    guard !quitting else { throw NativeWorkspaceError.notReady }
    if activation != nil || admissionRefreshPending {
      try await retryStartup()
      return
    }
    if externalOpens.hasRetainedRequest {
      try retryExternalOpen()
      return
    }
    if intake.status?.stage == .failed {
      try await retryDocumentIntake()
      return
    }
    if let status = closing.status, status.stage == .failed {
      for window in try registry.captureWindows() where endpoints[window.id] == nil {
        try recreateEndpoint(windowID: window.id)
      }
      try closing.retry(status.id)
      if case .retained(_, _, let error) = try await closing.wait(for: status.id) { throw error }
      return
    }
    try requireUserAdmission()
    try intake.requireSettled()
    try closing.requireSettled()
    for window in try registry.captureReadyWindows() {
      if endpoints[window.id] == nil {
        try recreateEndpoint(windowID: window.id)
      } else {
        try project(windowID: window.id)
      }
    }
    checkpoints.requestCheckpoint()
  }

  var lastCheckpointError: Error? { checkpoints.lastError }
  func requestCheckpoint() { checkpoints.requestCheckpoint() }

  func createWindow(createDocument: Bool = true) throws -> EditorWindowController {
    try requireUserAdmission()
    try intake.requireSettled()
    try closing.requireSettled()
    if createDocument {
      let live = Set(try registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) })
      guard live.union(session.unresolved.map { $0.metadata.id }).count < 128 else {
        throw SessionStoreError.limit
      }
    }
    let value = try createEndpoint()
    let controller = value.controller!
    if createDocument { controller.newDocument() }
    return controller
  }

  /// The panel supplies a worker-prepared seed; only managed intake resolves its exact claim.
  func acceptSession(_ entry: UnresolvedSessionEntry, file: SessionResolvedFile) async throws {
    try requireUserAdmission()
    try intake.requireSettled()
    guard let seed = file.seed, seed.id == entry.metadata.id else {
      throw DocumentIntakeError.invalidRequest
    }
    let provenance: DocumentIntakeProvenance
    do { provenance = .session(try session.claimImport(entry)) } catch {
      guard seed.url == nil, seed.originalBytes == nil else { throw error }
      provenance = .recovery(try session.claimRecoveryImport(entry))
    }
    let value = try endpoints[entry.windowID] ?? createEndpoint(windowID: entry.windowID)
    let id = try intake.submit(
      .init(
        endpointID: value.id, assignment: value.assignment,
        seed: seed, provenance: provenance,
        selection: session.shouldSelect(entry) ? .select : .preserve,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        },
        insertionIndex: session.insertionIndex(for: entry, in: value.controller!.sessionMetadata)))
    switch try await intake.wait(for: id) {
    case .imported: return
    case .refused(let error), .retained(_, let error): throw error
    }
  }

  func prepareQuit() async throws -> SessionCheckpointReceipt {
    guard !quitting else { throw NativeWorkspaceError.notReady }
    quitting = true
    externalOpens.beginQuit()
    do {
      if let startupTask { try await startupTask.value }
      await externalOpens.drainCurrent()
      guard externalOpens.pendingCount == 0 else { throw OpenRequestQueueError.busy }
      guard !preparingHistory else { throw DocumentIntakeError.busy }
      if let status = intake.status {
        _ = try await intake.wait(for: status.id)
      }
      try intake.requireSettled()
      try closing.requireSettled()
      try await checkpoints.prepareQuit()
      for window in windows {
        guard await window.prepareToQuit(persistRecovery: false) else {
          throw NativeWorkspaceError.quitVetoed
        }
      }
      try await drainLegacy()
      try checkpoints.markNativeQuitPrepared()
      return try await checkpoints.commitFinal()
    } catch {
      cancelPreparedQuit()
      throw error
    }
  }
  func cancelPreparedQuit() {
    quitting = false
    for window in windows { window.cancelPreparedQuit() }
    checkpoints.cancelPreparedQuit()
    externalOpens.resumeAfterVeto()
  }
}
