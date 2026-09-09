import Foundation
import PadCore

enum CheckpointDelay: Equatable, Sendable { case debounce, retry }
enum CheckpointSchedulerError: Error {
  case notStarted, invalidReceipt, generationExhausted, invalidPause, pauseNotDrained,
    closeInProgress,
    finalInProgress
}

struct CheckpointPauseToken: Hashable, Sendable {
  fileprivate let owner: UUID
  fileprivate let id: UUID
}

/// Application-owned scheduler. Captures are synchronous MainActor values; commit owns I/O.
/// This object deliberately knows nothing about AppKit, live documents, or unresolved records.
@MainActor final class SessionCheckpointCoordinator {
  enum Phase: Equatable { case stopped, idle, waiting, preparing, writing, paused, failed }
  private(set) var phase: Phase = .stopped
  private(set) var lastAcknowledgedGeneration: UInt64 = 0
  private(set) var lastError: Error?
  /// Observe status only; callbacks must not request another checkpoint.
  var onStateChanged: @MainActor () -> Void = {}
  private let prepareCapture: @MainActor () async throws -> Void
  private let capture: @MainActor (UInt64) throws -> SessionCheckpointCapture
  private let commit: @MainActor (SessionCheckpointCapture) async throws -> SessionCheckpointReceipt
  private let delay: @MainActor (CheckpointDelay) async throws -> Void
  private let now: @MainActor () -> Double
  private var requestedGeneration: UInt64 = 0
  private var attemptedGeneration: UInt64 = 0
  private var started = false
  private var legacyPaused = false
  private let pauseOwner = UUID()
  private var pauseLeases: [UUID: Bool] = [:]
  private var paused: Bool { legacyPaused || !pauseLeases.isEmpty }
  private var worker: Task<Void, Never>?
  private var finalTask: Task<SessionCheckpointReceipt, Error>?
  var isFinalizing: Bool { finalTask != nil }
  var hasPendingChanges: Bool { requestedGeneration > lastAcknowledgedGeneration }

  init(
    capture: @escaping @MainActor (UInt64) throws -> SessionCheckpointCapture,
    commit:
      @escaping @MainActor (SessionCheckpointCapture) async throws -> SessionCheckpointReceipt,
    prepareCapture: @escaping @MainActor () async throws -> Void = {},
    delay: @escaping @MainActor (CheckpointDelay) async throws -> Void = { kind in
      try await Task.sleep(nanoseconds: kind == .debounce ? 750_000_000 : 15_000_000_000)
    },
    now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.prepareCapture = prepareCapture
    self.capture = capture
    self.commit = commit
    self.delay = delay
    self.now = now
  }

  func requestCheckpoint() {
    guard advanceGeneration() else { return }
    launchIfNeeded()
  }
  func startAfterRestoration() {
    guard !started else { return }
    started = true
    phase = paused ? .paused : .idle
    if requestedGeneration == 0 { requestCheckpoint() } else { launchIfNeeded() }
  }
  /// Acquire before registering a close transaction or suspending. Tokens are explicit ownership;
  /// cancellation of a waiter never releases another operation's pause.
  func acquirePause() throws -> CheckpointPauseToken {
    guard finalTask == nil else { throw CheckpointSchedulerError.finalInProgress }
    let token = CheckpointPauseToken(owner: pauseOwner, id: UUID())
    pauseLeases[token.id] = false
    if phase == .waiting { worker?.cancel() }
    if worker == nil { phase = .paused }
    return token
  }

  func drainPause(_ token: CheckpointPauseToken) async throws {
    try validatePause(token)
    await worker?.value
    try validatePause(token)
    pauseLeases[token.id] = true
    phase = .paused
  }

  func releasePause(_ token: CheckpointPauseToken) throws {
    try validatePause(token)
    guard pauseLeases[token.id] == true else { throw CheckpointSchedulerError.pauseNotDrained }
    pauseLeases.removeValue(forKey: token.id)
    guard !paused else { return }
    phase = started ? .idle : .stopped
    requestCheckpoint()
  }

  private func validatePause(_ token: CheckpointPauseToken) throws {
    guard token.owner == pauseOwner, pauseLeases[token.id] != nil else {
      throw CheckpointSchedulerError.invalidPause
    }
  }

  func pauseAndDrain() async {
    await pauseOrdinaryAndDrain()
    if let finalTask { _ = try? await finalTask.value }
    phase = .paused
  }
  private func pauseOrdinaryAndDrain() async {
    legacyPaused = true
    if phase == .waiting { worker?.cancel() }
    await worker?.value
  }
  func resumeAfterVeto() {
    guard finalTask == nil else { return }
    legacyPaused = false
    phase = paused ? .paused : (started ? .idle : .stopped)
    requestCheckpoint()  // Resume even when there is no subsequent user edit.
  }

  func commitFinal() async throws -> SessionCheckpointReceipt {
    guard started else { throw CheckpointSchedulerError.notStarted }
    guard pauseLeases.isEmpty else { throw CheckpointSchedulerError.closeInProgress }
    if let finalTask { return try await finalTask.value }
    // Latch the entire operation before the first suspension, including the ordinary drain.
    // Calling public pauseAndDrain from this task would await this same finalTask.
    legacyPaused = true
    let task = Task { try await self.performFinal() }
    finalTask = task
    defer {
      finalTask = nil
      phase = .paused
    }
    return try await task.value
  }
  private func performFinal() async throws -> SessionCheckpointReceipt {
    await pauseOrdinaryAndDrain()
    do {
      phase = .preparing
      try await prepareCapture()
      guard advanceGeneration() else { throw CheckpointSchedulerError.generationExhausted }
      let generation = requestedGeneration
      attemptedGeneration = generation
      let value = try capture(generation)
      guard value.generation == generation else { throw CheckpointSchedulerError.invalidReceipt }
      phase = .writing
      let receipt = try await commit(value)
      try acknowledge(receipt, for: value)
      return receipt
    } catch {
      lastError = error
      onStateChanged()
      throw error
    }
  }

  private func advanceGeneration() -> Bool {
    guard requestedGeneration < UInt64.max else {
      lastError = CheckpointSchedulerError.generationExhausted
      legacyPaused = true
      onStateChanged()
      return false
    }
    requestedGeneration += 1
    return true
  }
  private func launchIfNeeded() {
    guard started, !paused, worker == nil, finalTask == nil,
      requestedGeneration > attemptedGeneration
    else { return }
    worker = Task { [weak self] in await self?.run() }
  }
  private func run() async {
    defer {
      worker = nil
      phase = paused ? .paused : (lastError == nil ? .idle : .failed)
      launchIfNeeded()
    }
    var needsDelay = true
    let firstRequestTime = now()
    while !paused, !Task.isCancelled, requestedGeneration > attemptedGeneration {
      if needsDelay {
        phase = .waiting
        let beforeWait = requestedGeneration
        do { try await delay(lastError == nil ? .debounce : .retry) } catch {
          if !paused, !Task.isCancelled {
            lastError = error
            attemptedGeneration = requestedGeneration
            onStateChanged()
          }
          return
        }
        guard !paused, !Task.isCancelled else { return }
        // A trailing debounce cannot postpone continuous editing beyond fifteen seconds.
        if lastError == nil, requestedGeneration != beforeWait, now() - firstRequestTime < 15 {
          continue
        }
      }
      phase = .preparing
      do {
        do {
          try await prepareCapture()
        } catch {
          guard !paused, !Task.isCancelled else { return }
          // Preparation failed before a capture existed. Consume the current request so an
          // idle error cannot spin; a later request still takes the normal retry delay.
          attemptedGeneration = requestedGeneration
          throw error
        }
        guard !paused, !Task.isCancelled else { return }
        let generation = requestedGeneration
        attemptedGeneration = generation
        phase = .writing
        let value = try capture(generation)
        guard value.generation == generation else { throw CheckpointSchedulerError.invalidReceipt }
        let receipt = try await commit(value)
        try acknowledge(receipt, for: value)
        needsDelay = false  // Coalesce work requested during publication into one fresh capture.
      } catch {
        lastError = error
        onStateChanged()
        needsDelay = true  // Retry only if a newer request exists, and only after the retry delay.
      }
    }
  }
  private func acknowledge(_ receipt: SessionCheckpointReceipt, for value: SessionCheckpointCapture)
    throws
  {
    var expected: [UUID: UInt64] = [:]
    var authorities: [UUID: RecoveryWriteAuthority] = [:]
    for item in value.recovery {
      guard expected[item.id] == nil else { throw CheckpointSchedulerError.invalidReceipt }
      expected[item.id] = item.revision
      if let authority = item.authority {
        guard authority.documentID == item.id else { throw CheckpointSchedulerError.invalidReceipt }
        authorities[item.id] = authority
      }
    }
    guard receipt.generation == value.generation, receipt.recoveryRevisions == expected,
      receipt.recoveryAuthorities == authorities
    else {
      throw CheckpointSchedulerError.invalidReceipt
    }
    lastAcknowledgedGeneration = receipt.generation
    lastError = nil
    onStateChanged()
  }
}
