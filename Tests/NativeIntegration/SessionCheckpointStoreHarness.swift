import Foundation
import PadCore

private func check(_ condition: Bool) { precondition(condition) }
private func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
  semaphore.wait(timeout: .now() + seconds)
}

private final class WriterProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCalls = 0
  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCalls
  }
  func called() {
    lock.lock()
    storedCalls += 1
    lock.unlock()
  }
}
@main struct SessionCheckpointStoreHarness {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func snapshot(_ id: UUID, _ text: String) -> RecoverySnapshot {
      RecoverySnapshot(id: id, text: text, encoding: .utf8, hasBOM: false)
    }
    func capture(_ generation: UInt64, _ items: [RecoveryCheckpointItem])
      -> SessionCheckpointCapture
    {
      let tabs = items.map {
        SessionTab(id: $0.id, originalPath: $0.snapshot == nil ? "/synthetic/clean.txt" : nil)
      }
      return SessionCheckpointCapture(
        generation: generation, liveTabIDs: Set(items.map(\.id)), recovery: items,
        session: EditorSession(windows: [SessionWindow(tabs: tabs, selectedTabID: tabs.first?.id)]))
    }
    let folder = root.appendingPathComponent("normal")
    let session = SessionStore(directory: root.appendingPathComponent("session"))
    let probe = WriterProbe()
    let owner = RecoveryCoordinator(
      directory: folder,
      saveCheckpointSession: { value in
        // The real recovery store must already contain every scratch tab at publication.
        let saved = try RecoveryStore(directory: folder).loadAll()
        for tab in value.windows.flatMap(\.tabs) where tab.originalPath == nil {
          precondition(saved.contains { $0.id == tab.id })
        }
        probe.called()
        try session.save(value)
      })
    let id = UUID()
    try await owner.persist(snapshot(id, "newer"), revision: 2)
    do {
      _ = try await owner.commitSessionCheckpoint(
        capture(1, [.init(id: id, revision: 1, snapshot: snapshot(id, "old"))]))
      preconditionFailure("stale recovery must not acknowledge metadata")
    } catch CheckpointFailure.superseded {}
    precondition(probe.calls == 0)
    do {
      _ = try await owner.commitSessionCheckpoint(
        capture(1, [.init(id: id, revision: 2, snapshot: snapshot(id, "same revision changed"))]))
      preconditionFailure("equal revision cannot prove immutable content through legacy APIs")
    } catch CheckpointFailure.superseded {}
    do {
      let malformed = capture(
        1, [.init(id: id, revision: 3, snapshot: snapshot(UUID(), "wrong id"))])
      _ = try await owner.commitSessionCheckpoint(malformed)
      preconditionFailure("mismatched recovery identity cannot enter a checkpoint")
    } catch RecoveryError.invalidSnapshot {}
    do {
      let duplicate = RecoveryCheckpointItem(
        id: id, revision: 3, snapshot: snapshot(id, "duplicate"))
      _ = try await owner.commitSessionCheckpoint(capture(1, [duplicate, duplicate]))
      preconditionFailure("duplicate checkpoint recovery identities must be rejected")
    } catch RecoveryError.invalidSnapshot {}
    let liveScratch = SessionTab(id: id)
    let scratchSession = EditorSession(windows: [
      SessionWindow(tabs: [liveScratch], selectedTabID: id)
    ])
    for items: [RecoveryCheckpointItem] in [[], [.init(id: id, revision: 3, snapshot: nil)]] {
      do {
        _ = try await owner.commitSessionCheckpoint(
          SessionCheckpointCapture(
            generation: 1, liveTabIDs: [id], recovery: items, session: scratchSession))
        preconditionFailure("live scratch must have a nonnil recovery item")
      } catch RecoveryError.invalidSnapshot {}
      check(try RecoveryStore(directory: folder).loadAll().first?.text == "newer")
      precondition(probe.calls == 0, "invalid admission must not invoke the session writer")
    }
    do {
      _ = try await owner.commitSessionCheckpoint(
        SessionCheckpointCapture(
          generation: 1, liveTabIDs: [], recovery: [.init(id: id, revision: 3, snapshot: nil)],
          session: scratchSession))
      preconditionFailure("an unresolved-only tab cannot receive an unrequested clear")
    } catch RecoveryError.invalidSnapshot {}
    check(try RecoveryStore(directory: folder).loadAll().first?.text == "newer")
    precondition(probe.calls == 0)
    let unresolvedStore = SessionStore(directory: root.appendingPathComponent("unresolved-session"))
    let unresolvedOwner = RecoveryCoordinator(
      directory: root.appendingPathComponent("unresolved-recovery"),
      saveCheckpointSession: { try unresolvedStore.save($0) })
    let unresolvedReceipt = try await unresolvedOwner.commitSessionCheckpoint(
      SessionCheckpointCapture(
        generation: 1, liveTabIDs: [], recovery: [], session: scratchSession))
    precondition(unresolvedReceipt.recoveryRevisions.isEmpty)
    check(try unresolvedStore.load() == scratchSession)
    let successful = capture(
      2, [.init(id: id, revision: 3, snapshot: snapshot(id, "acknowledged 👩🏽‍💻\r\n"))])
    let receipt = try await owner.commitSessionCheckpoint(successful)
    precondition(receipt.generation == 2 && receipt.recoveryRevisions == [id: 3])
    check(try session.load() == successful.session)
    precondition(probe.calls == 1)
    do {
      _ = try await owner.commitSessionCheckpoint(
        capture(1, [.init(id: id, revision: 4, snapshot: snapshot(id, "late generation"))]))
      preconditionFailure("old generation must not overtake a published generation")
    } catch CheckpointFailure.superseded {}
    let cleared = try await owner.commitSessionCheckpoint(
      capture(3, [.init(id: id, revision: 4, snapshot: nil)]))
    precondition(cleared.recoveryRevisions == [id: 4])
    check(try RecoveryStore(directory: folder).loadAll().isEmpty)
    try await owner.close(id: id)
    do {
      _ = try await owner.commitSessionCheckpoint(
        capture(4, [.init(id: id, revision: 5, snapshot: snapshot(id, "closed"))]))
      preconditionFailure("closed snapshot cannot publish metadata")
    } catch CheckpointFailure.closedDocument {}
    precondition(probe.calls == 2)

    let partialFolder = root.appendingPathComponent("partial")
    let partialProbe = WriterProbe()
    let limits = RecoveryLimits(
      maximumSnapshotUTF16: 100, maximumEnvelopeBytes: 2048,
      maximumSnapshots: 2, maximumDirectoryEntries: 16, maximumRestoredUTF16: 100)
    let partial = RecoveryCoordinator(
      directory: partialFolder, limits: limits,
      saveCheckpointSession: { _ in partialProbe.called() })
    let a = UUID()
    let b = UUID()
    do {
      _ = try await partial.commitSessionCheckpoint(
        capture(
          1,
          [
            .init(id: a, revision: 1, snapshot: snapshot(a, "survives partial failure")),
            .init(id: b, revision: 1, snapshot: snapshot(b, String(repeating: "x", count: 101))),
          ]))
      preconditionFailure("recovery quota failure cannot acknowledge a checkpoint")
    } catch RecoveryError.resourceLimit {}
    precondition(partialProbe.calls == 0)
    check(try RecoveryStore(directory: partialFolder, limits: limits).loadAll().map(\.id) == [a])

    let failureStore = SessionStore(directory: root.appendingPathComponent("failed-session"))
    let original = EditorSession(windows: [], recentPaths: ["/synthetic/original.txt"])
    try failureStore.save(original)
    let originalSessionBytes = try Data(
      contentsOf: failureStore.directory.appendingPathComponent("Session.json"))
    let failureFolder = root.appendingPathComponent("failed-recovery")
    let failure = RecoveryCoordinator(
      directory: failureFolder,
      saveCheckpointSession: { value in
        try failureStore.save(value, fault: .beforeReplace)
      })
    let failedID = UUID()
    do {
      _ = try await failure.commitSessionCheckpoint(
        capture(1, [.init(id: failedID, revision: 1, snapshot: snapshot(failedID, "recoverable"))]))
      preconditionFailure("session writer failure must not produce a receipt")
    } catch SessionStoreError.ioFailure {}
    check(try failureStore.load() == original)
    check(
      try Data(contentsOf: failureStore.directory.appendingPathComponent("Session.json"))
        == originalSessionBytes)
    check(try RecoveryStore(directory: failureFolder).loadAll().first?.text == "recoverable")

    let uncertainStore = SessionStore(directory: root.appendingPathComponent("uncertain-session"))
    let uncertainProbe = WriterProbe()
    let uncertain = RecoveryCoordinator(
      directory: root.appendingPathComponent("uncertain-recovery"),
      saveCheckpointSession: { value in
        uncertainProbe.called()
        try uncertainStore.save(value)
        if uncertainProbe.calls == 1 { throw SessionStoreError.committedButNotSynced }
      }, readCheckpointSession: { try uncertainStore.load() })
    let uncertainCapture = capture(8, [])
    do {
      _ = try await uncertain.commitSessionCheckpoint(uncertainCapture)
      preconditionFailure("uncertain publication must not be called acknowledged")
    } catch SessionStoreError.committedButNotSynced {}
    for generation: UInt64 in [7, 9] {
      do {
        _ = try await uncertain.commitSessionCheckpoint(capture(generation, []))
        preconditionFailure("publication uncertainty must block every retry until checked readback")
      } catch CheckpointFailure.publicationUncertain {}
    }
    precondition(uncertainProbe.calls == 1)
    try uncertainStore.save(EditorSession(windows: [], recentPaths: ["/synthetic/changed.txt"]))
    do {
      try await uncertain.validateUncertainCheckpoint()
      preconditionFailure("mismatched readback must retain the uncertainty block")
    } catch CheckpointFailure.publicationUncertain {}
    try uncertainStore.save(uncertainCapture.session)
    try await uncertain.validateUncertainCheckpoint()
    let afterReadback = try await uncertain.commitSessionCheckpoint(capture(9, []))
    precondition(afterReadback.generation == 9 && uncertainProbe.calls == 2)
    let recoveryUncertainFolder = root.appendingPathComponent("checkpoint-recovery-uncertain")
    let recoveryUncertainProbe = WriterProbe()
    let recoveryUncertain = RecoveryCoordinator(
      directory: recoveryUncertainFolder, limits: limits,
      saveRecovery: { store, value in
        try store.save(value, fault: value.text.utf16.count == 80 ? .directorySync : nil)
      }, saveCheckpointSession: { _ in recoveryUncertainProbe.called() })
    let uncertainRecoveryID = UUID()
    let additionalID = UUID()
    try await recoveryUncertain.persist(snapshot(uncertainRecoveryID, "small"), revision: 1)
    do {
      _ = try await recoveryUncertain.commitSessionCheckpoint(
        capture(
          1,
          [
            .init(
              id: uncertainRecoveryID, revision: 3,
              snapshot: snapshot(uncertainRecoveryID, String(repeating: "a", count: 80)))
          ]))
      preconditionFailure("uncertain recovery publication cannot acknowledge session metadata")
    } catch FileStoreError.publicationUncertain {}
    precondition(recoveryUncertainProbe.calls == 0)
    do {
      _ = try await recoveryUncertain.commitSessionCheckpoint(
        capture(
          2,
          [
            .init(
              id: uncertainRecoveryID, revision: 2, snapshot: snapshot(uncertainRecoveryID, "stale")
            )
          ]))
      preconditionFailure("checkpoint admission must preserve reserved uncertain recovery revision")
    } catch CheckpointFailure.superseded {}
    do {
      _ = try await recoveryUncertain.commitSessionCheckpoint(
        capture(
          2,
          [
            .init(
              id: additionalID, revision: 1,
              snapshot: snapshot(additionalID, String(repeating: "b", count: 50)))
          ]))
      preconditionFailure("checkpoint must refresh uncertain recovery capacity before growth")
    } catch RecoveryError.resourceLimit {}
    precondition(recoveryUncertainProbe.calls == 0)
    let repairedRecoveryReceipt = try await recoveryUncertain.commitSessionCheckpoint(
      capture(
        3,
        [
          .init(
            id: uncertainRecoveryID, revision: 4, snapshot: snapshot(uncertainRecoveryID, "small")),
          .init(
            id: additionalID, revision: 2,
            snapshot: snapshot(additionalID, String(repeating: "b", count: 50))),
        ]))
    precondition(repairedRecoveryReceipt.generation == 3 && recoveryUncertainProbe.calls == 1)

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let attemptedClose = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let orderedFolder = root.appendingPathComponent("ordered-recovery")
    let orderedStore = SessionStore(directory: root.appendingPathComponent("ordered-session"))
    let orderedID = UUID()
    let ordered = RecoveryCoordinator(
      directory: orderedFolder,
      saveCheckpointSession: { value in
        entered.signal()
        precondition(release.wait(timeout: .now() + 5) == .success)
        try orderedStore.save(value)
      })
    let orderedCapture = capture(
      1, [.init(id: orderedID, revision: 1, snapshot: snapshot(orderedID, "ordered"))])
    let commit = Task { try await ordered.commitSessionCheckpoint(orderedCapture) }
    let enteredResult = await Task.detached { wait(entered, seconds: 5) }.value
    precondition(enteredResult == .success)
    let close = Task {
      attemptedClose.signal()
      try await ordered.close(id: orderedID)
      closed.signal()
    }
    let attempted = await Task.detached { wait(attemptedClose, seconds: 5) }.value
    precondition(attempted == .success)
    let duringWriter = await Task.detached { wait(closed, seconds: 0.05) }.value
    precondition(
      duringWriter == .timedOut, "Close cannot interleave the recovery/session publication boundary"
    )
    release.signal()
    _ = try await commit.value
    try await close.value
    check(try RecoveryStore(directory: orderedFolder).loadAll().isEmpty)
    check(try orderedStore.load() == orderedCapture.session)
    print(
      "PASS checkpoint store: stale/closed rejection, receipts, quotas, partial recovery and session failure"
    )
  }
}
