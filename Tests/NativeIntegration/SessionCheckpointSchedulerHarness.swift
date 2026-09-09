import Foundation
import PadCore

@MainActor private final class ManualClock {
  var now = 0.0
  private var waiting: [(UUID, CheckpointDelay, CheckedContinuation<Void, Error>)] = []
  var delays: [CheckpointDelay] { waiting.map { $0.1 } }
  func sleep(_ delay: CheckpointDelay) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        waiting.append((id, delay, continuation))
      }
    } onCancel: {
      Task { @MainActor in
        guard let index = self.waiting.firstIndex(where: { $0.0 == id }) else { return }
        self.waiting.remove(at: index).2.resume(throwing: CancellationError())
      }
    }
  }
  func release() {
    precondition(!waiting.isEmpty)
    let (_, delay, continuation) = waiting.removeFirst()
    now += delay == .debounce ? 0.75 : 15
    continuation.resume()
  }
}
@MainActor private final class CommitGate {
  var captured: [UInt64] = []
  var entered: [UInt64] = []
  private var waiting: [(UInt64, CheckedContinuation<SessionCheckpointReceipt, Error>)] = []
  var active: Int { waiting.count }
  func capture(_ generation: UInt64) -> SessionCheckpointCapture {
    captured.append(generation)
    return SessionCheckpointCapture(
      generation: generation, liveTabIDs: [], recovery: [], session: EditorSession(windows: []))
  }
  func commit(_ capture: SessionCheckpointCapture) async throws -> SessionCheckpointReceipt {
    entered.append(capture.generation)
    return try await withCheckedThrowingContinuation { waiting.append((capture.generation, $0)) }
  }
  func finish(error: Error? = nil) {
    let (generation, continuation) = waiting.removeFirst()
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(returning: .init(generation: generation, recoveryRevisions: [:]))
    }
  }
}
@MainActor private final class PreparationGate {
  private var waiting: [CheckedContinuation<Void, Error>] = []
  var calls = 0
  var active: Int { waiting.count }
  func prepare() async throws {
    calls += 1
    try await withCheckedThrowingContinuation { waiting.append($0) }
  }
  func finish(error: Error? = nil) {
    let continuation = waiting.removeFirst()
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }
}
private enum SyntheticFailure: Error { case write, capture }
@main struct SessionCheckpointSchedulerHarness {
  @MainActor static func until(_ condition: () -> Bool) async {
    for _ in 0..<20_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("scheduler failed to reach its deterministic boundary")
  }
  @MainActor static func main() async throws {
    let clock = ManualClock()
    let gate = CommitGate()
    let scheduler = SessionCheckpointCoordinator(
      capture: gate.capture, commit: gate.commit,
      delay: clock.sleep, now: { clock.now })
    scheduler.requestCheckpoint()
    await Task.yield()
    precondition(gate.captured.isEmpty && clock.delays.isEmpty)
    scheduler.startAfterRestoration()
    await until { clock.delays == [.debounce] }
    clock.release()
    await until { gate.active == 1 }
    for _ in 0..<99 { scheduler.requestCheckpoint() }
    precondition(gate.captured == [1] && gate.active == 1)
    gate.finish()
    await until { gate.entered == [1, 100] }
    precondition(gate.captured == [1, 100] && gate.active == 1)
    gate.finish()
    await until { scheduler.lastAcknowledgedGeneration == 100 }
    precondition(scheduler.lastError == nil)

    scheduler.requestCheckpoint()
    await until { clock.delays == [.debounce] }
    await scheduler.pauseAndDrain()
    await until { clock.delays.isEmpty }
    precondition(gate.captured.count == 2)
    scheduler.requestCheckpoint()
    precondition(gate.captured.count == 2)
    scheduler.resumeAfterVeto()
    await until { clock.delays == [.debounce] }
    clock.release()
    await until { gate.active == 1 }
    gate.finish(error: SyntheticFailure.write)
    await until { scheduler.lastError != nil }
    precondition(clock.delays.isEmpty, "an idle failure must not spin retry tasks")
    scheduler.requestCheckpoint()
    await until { clock.delays == [.retry] }
    precondition(gate.active == 0)
    clock.release()
    await until { gate.active == 1 }
    gate.finish()
    await until { scheduler.lastError == nil }

    scheduler.requestCheckpoint()
    await until { clock.delays == [.debounce] }
    clock.release()
    await until { gate.active == 1 }
    var drained = false
    let pause = Task {
      await scheduler.pauseAndDrain()
      drained = true
    }
    await Task.yield()
    precondition(!drained, "pause must await an admitted publication")
    scheduler.requestCheckpoint()
    gate.finish()
    await pause.value
    precondition(drained && gate.active == 0)
    let countBeforeFinal = gate.captured.count
    let final = Task { try await scheduler.commitFinal() }
    await until { gate.active == 1 }
    precondition(gate.captured.count == countBeforeFinal + 1)
    let finalGeneration = gate.entered.last!
    scheduler.requestCheckpoint()
    gate.finish()
    let receipt = try await final.value
    precondition(receipt.generation == finalGeneration)
    await Task.yield()
    precondition(
      gate.active == 0 && clock.delays.isEmpty, "nothing ordinary may follow final publication")
    scheduler.resumeAfterVeto()
    await until { clock.delays == [.debounce] }
    clock.release()
    await until { gate.active == 1 }
    precondition(gate.entered.last! > finalGeneration)
    gate.finish()
    await scheduler.pauseAndDrain()

    let failedClock = ManualClock()
    let failedGate = CommitGate()
    let failedCapture = SessionCheckpointCoordinator(
      capture: { _ in throw SyntheticFailure.capture },
      commit: failedGate.commit, delay: failedClock.sleep, now: { failedClock.now })
    failedCapture.startAfterRestoration()
    await until { failedClock.delays == [.debounce] }
    failedClock.release()
    await until { failedCapture.lastError != nil }
    precondition(failedGate.entered.isEmpty && failedClock.delays.isEmpty)
    await failedCapture.pauseAndDrain()
    let continuousClock = ManualClock()
    let continuousGate = CommitGate()
    let continuous = SessionCheckpointCoordinator(
      capture: continuousGate.capture, commit: continuousGate.commit,
      delay: continuousClock.sleep, now: { continuousClock.now })
    continuous.startAfterRestoration()
    for _ in 0..<20 {
      await until { continuousClock.delays == [.debounce] }
      continuous.requestCheckpoint()
      continuousClock.release()
    }
    await until { continuousGate.active == 1 }
    precondition(
      continuousClock.now == 15 && continuousGate.captured.count == 1,
      "Continuous notifications must not starve checkpoint capture past the maximum interval")
    continuousGate.finish()
    await continuous.pauseAndDrain()

    let drainClock = ManualClock()
    let drainGate = CommitGate()
    let draining = SessionCheckpointCoordinator(
      capture: drainGate.capture, commit: drainGate.commit,
      delay: drainClock.sleep, now: { drainClock.now })
    draining.startAfterRestoration()
    await until { drainClock.delays == [.debounce] }
    drainClock.release()
    await until { drainGate.active == 1 }
    var callersEntered = 0
    var finalReceipts: [SessionCheckpointReceipt] = []
    let drainA = Task {
      callersEntered += 1
      finalReceipts.append(try await draining.commitFinal())
    }
    let drainB = Task {
      callersEntered += 1
      finalReceipts.append(try await draining.commitFinal())
    }
    await until { callersEntered == 2 }
    draining.resumeAfterVeto()
    draining.requestCheckpoint()
    precondition(drainGate.captured.count == 1)
    drainGate.finish()
    await until { drainGate.entered.count == 2 }
    drainGate.finish()
    await until { finalReceipts.count == 2 || drainGate.entered.count > 2 }
    precondition(
      drainGate.entered.count == 2,
      "Two finals queued behind an ordinary write must share one drain/capture/publication")
    try await drainA.value
    try await drainB.value
    precondition(
      finalReceipts.count == 2 && finalReceipts[0].generation == finalReceipts[1].generation)
    precondition(drainGate.captured.count == 2)

    let invalidClock = ManualClock()
    var invalidCommitContinuation: CheckedContinuation<SessionCheckpointReceipt, Error>?
    var invalidCaptures = 0
    let invalid = SessionCheckpointCoordinator(
      capture: { generation in
        invalidCaptures += 1
        return SessionCheckpointCapture(
          generation: generation, liveTabIDs: [], recovery: [], session: EditorSession(windows: []))
      },
      commit: { value in
        return try await withCheckedThrowingContinuation { invalidCommitContinuation = $0 }
      }, delay: invalidClock.sleep, now: { invalidClock.now })
    invalid.startAfterRestoration()
    await invalid.pauseAndDrain()
    let invalidFinalA = Task { try await invalid.commitFinal() }
    await until { invalidCommitContinuation != nil }
    let invalidFinalB = Task { try await invalid.commitFinal() }
    await Task.yield()
    invalidCommitContinuation!.resume(returning: .init(generation: 999, recoveryRevisions: [:]))
    for task in [invalidFinalA, invalidFinalB] {
      do {
        _ = try await task.value
        preconditionFailure("Every final caller must reject an invalid receipt")
      } catch CheckpointSchedulerError.invalidReceipt {}
    }
    precondition(invalidCaptures == 1 && invalid.lastAcknowledgedGeneration == 0)
    let prepClock = ManualClock()
    let prepGate = PreparationGate()
    let preparedWrites = CommitGate()
    let prepared = SessionCheckpointCoordinator(
      capture: preparedWrites.capture, commit: preparedWrites.commit,
      prepareCapture: prepGate.prepare, delay: prepClock.sleep, now: { prepClock.now })
    var observedPreparationState: [(UInt64, Bool)] = []
    prepared.onStateChanged = { [weak prepared] in
      guard let prepared else { return }
      observedPreparationState.append(
        (prepared.lastAcknowledgedGeneration, prepared.lastError != nil))
    }
    prepared.startAfterRestoration()
    await until { prepClock.delays == [.debounce] }
    prepClock.release()
    await until { prepGate.active == 1 }
    for _ in 0..<99 { prepared.requestCheckpoint() }
    precondition(preparedWrites.captured.isEmpty && prepGate.calls == 1)
    prepGate.finish()
    await until { preparedWrites.active == 1 }
    precondition(
      preparedWrites.captured == [100], "Capture must use latest post-preparation generation")
    preparedWrites.finish()
    await until { prepared.lastAcknowledgedGeneration == 100 }
    precondition(
      observedPreparationState.last?.0 == 100 && observedPreparationState.last?.1 == false)

    prepared.requestCheckpoint()
    await until { prepClock.delays == [.debounce] }
    prepClock.release()
    await until { prepGate.active == 1 }
    var preparationDrained = false
    let prepPause = Task {
      await prepared.pauseAndDrain()
      preparationDrained = true
    }
    await Task.yield()
    precondition(!preparationDrained, "Pause must await active preparation")
    prepGate.finish()
    await prepPause.value
    precondition(preparedWrites.captured == [100], "Pause must prevent capture after preparation")
    prepared.resumeAfterVeto()
    await until { prepClock.delays == [.debounce] }
    prepClock.release()
    await until { prepGate.active == 1 }
    prepGate.finish(error: SyntheticFailure.capture)
    await until { prepared.phase == .failed }
    precondition(
      observedPreparationState.last?.0 == 100 && observedPreparationState.last?.1 == true)
    precondition(preparedWrites.captured == [100] && prepClock.delays.isEmpty)
    for _ in 0..<20 { await Task.yield() }
    precondition(
      prepGate.active == 0 && prepClock.delays.isEmpty,
      "Preparation failure cannot retry without a newer request")
    prepared.requestCheckpoint()
    await until { prepClock.delays == [.retry] }
    prepClock.release()
    await until { prepGate.active == 1 }
    prepGate.finish()
    await until { preparedWrites.active == 1 }
    preparedWrites.finish()
    await until { prepared.lastError == nil }
    precondition(observedPreparationState.last?.1 == false)
    await prepared.pauseAndDrain()

    let beforeFinalPreparations = prepGate.calls
    let finalPreparedA = Task { try await prepared.commitFinal() }
    await until { prepGate.active == 1 }
    let finalPreparedB = Task { try await prepared.commitFinal() }
    await Task.yield()
    precondition(prepGate.calls == beforeFinalPreparations + 1)
    let beforeFinalCaptures = preparedWrites.captured.count
    prepared.requestCheckpoint()
    prepGate.finish()
    await until { preparedWrites.active == 1 }
    precondition(preparedWrites.captured.count == beforeFinalCaptures + 1)
    preparedWrites.finish()
    let preparedReceiptA = try await finalPreparedA.value
    let preparedReceiptB = try await finalPreparedB.value
    precondition(preparedReceiptA.generation == preparedReceiptB.generation)
    precondition(prepGate.calls == beforeFinalPreparations + 1)

    let beforeFailedFinalCaptures = preparedWrites.captured.count
    let failedPreparedA = Task { try await prepared.commitFinal() }
    await until { prepGate.active == 1 }
    let failedPreparedB = Task { try await prepared.commitFinal() }
    await Task.yield()
    prepGate.finish(error: SyntheticFailure.capture)
    for task in [failedPreparedA, failedPreparedB] {
      do {
        _ = try await task.value
        preconditionFailure("All final callers must observe preparation failure")
      } catch SyntheticFailure.capture {}
    }
    precondition(preparedWrites.captured.count == beforeFailedFinalCaptures)
    precondition(observedPreparationState.last?.1 == true)

    print(
      "PASS checkpoint scheduler: startup, coalescing, pause/drain, veto, retry and final ordering")
  }
}
