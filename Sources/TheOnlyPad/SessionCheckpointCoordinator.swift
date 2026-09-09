import Foundation

enum CheckpointDelay: Equatable, Sendable { case debounce, retry }
enum CheckpointSchedulerError: Error { case notStarted, invalidReceipt, generationExhausted }

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
  private var paused = false
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
    phase = .idle
    if requestedGeneration == 0 { requestCheckpoint() } else { launchIfNeeded() }
  }
  func pauseAndDrain() async {
    await pauseOrdinaryAndDrain()
    if let finalTask { _ = try? await finalTask.value }
    phase = .paused
  }
  private func pauseOrdinaryAndDrain() async {
    paused = true
    if phase == .waiting { worker?.cancel() }
    await worker?.value
  }
  func resumeAfterVeto() {
    guard finalTask == nil else { return }
    paused = false
    phase = started ? .idle : .stopped
    requestCheckpoint()  // Resume even when there is no subsequent user edit.
  }

  func commitFinal() async throws -> SessionCheckpointReceipt {
    guard started else { throw CheckpointSchedulerError.notStarted }
    if let finalTask { return try await finalTask.value }
    // Latch the entire operation before the first suspension, including the ordinary drain.
    // Calling public pauseAndDrain from this task would await this same finalTask.
    paused = true
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
      paused = true
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
    for item in value.recovery {
      guard expected[item.id] == nil else { throw CheckpointSchedulerError.invalidReceipt }
      expected[item.id] = item.revision
    }
    guard receipt.generation == value.generation, receipt.recoveryRevisions == expected else {
      throw CheckpointSchedulerError.invalidReceipt
    }
    lastAcknowledgedGeneration = receipt.generation
    lastError = nil
    onStateChanged()
  }
}
