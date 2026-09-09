import Foundation
import PadCore

private enum CaptureFixtureError: Error { case cleanup }
@main struct SessionMetadataCaptureHarness {
  @MainActor static func until(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    preconditionFailure("metadata capture boundary not reached")
  }
  @MainActor static func main() async throws {
    let live = SessionTab()
    let missing = SessionTab()
    let original = SessionWindow(tabs: [missing, live], selectedTabID: missing.id)
    var saved: [EditorSession] = []
    var cleanup: CheckedContinuation<Void, Error>?
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [original], recentPaths: ["/synthetic/older.txt"]) },
      claimRecovery: {
        .init(
          snapshots: [.init(id: missing.id, text: "unresolved", encoding: .utf8, hasBOM: false)],
          quarantinedCount: 0)
      },
      saveSession: { saved.append($0) },
      removeRecovery: { _ in try await withCheckedThrowingContinuation { cleanup = $0 } })
    do {
      _ = try coordinator.captureSession(windows: [])
      preconditionFailure("startup capture accepted")
    } catch {}
    await coordinator.restore { _ in [missing.id: "synthetic import failure"] }
    // Both remain unresolved: the live fixture is explicitly resolved before its native counterpart is supplied.
    let liveEntry = coordinator.unresolved.first { $0.metadata.id == live.id }!
    coordinator.resolved(liveEntry)
    try coordinator.recordRecentOpen(URL(fileURLWithPath: "/synthetic/new.txt"))
    let liveWindow = SessionWindow(id: original.id, tabs: [live], selectedTabID: live.id)
    let before = try coordinator.captureSession(windows: [liveWindow])
    precondition(before.windows[0].tabs.map(\.id) == [missing.id, live.id])
    precondition(before.recentPaths == ["/synthetic/new.txt", "/synthetic/older.txt"])
    let entry = coordinator.unresolved.first!
    let removal = Task { try await coordinator.remove(entry) }
    await until { cleanup != nil }
    do {
      _ = try coordinator.captureSession(windows: [liveWindow])
      preconditionFailure("pending cleanup capture accepted")
    } catch {}
    var drained = false
    let drain = Task {
      try await coordinator.drainPendingRemovals()
      drained = true
    }
    await Task.yield()
    precondition(!drained)
    cleanup!.resume(throwing: CaptureFixtureError.cleanup)
    do {
      try await removal.value
      preconditionFailure("cleanup failure hidden")
    } catch CaptureFixtureError.cleanup {}
    do {
      try await drain.value
      preconditionFailure("drain failure hidden")
    } catch CaptureFixtureError.cleanup {}
    precondition(coordinator.unresolved.map { $0.metadata.id } == [missing.id])
    cleanup = nil
    let retry = Task { try await coordinator.remove(entry) }
    await until { cleanup != nil }
    let retriedDrain = Task { try await coordinator.drainPendingRemovals() }
    cleanup!.resume()
    try await retry.value
    try await retriedDrain.value
    let after = try coordinator.captureSession(windows: [liveWindow])
    precondition(after.windows[0].tabs == [live])
    try await coordinator.persist(windows: [liveWindow])
    precondition(saved == [after], "legacy persist must use the same merged capture")
    let queuedA = SessionTab()
    let queuedB = SessionTab()
    let queuedWindow = SessionWindow(tabs: [queuedA, queuedB], selectedTabID: queuedA.id)
    var queuedCleanup: [UUID: CheckedContinuation<Void, Error>] = [:]
    let queued = SessionCoordinator(
      loadSession: { EditorSession(windows: [queuedWindow]) },
      claimRecovery: {
        .init(
          snapshots: [queuedA, queuedB].map {
            RecoverySnapshot(id: $0.id, text: "preserved", encoding: .utf8, hasBOM: false)
          }, quarantinedCount: 0)
      },
      removeRecovery: { id in try await withCheckedThrowingContinuation { queuedCleanup[id] = $0 } }
    )
    await queued.restore { _ in [queuedA.id: "unresolved", queuedB.id: "unresolved"] }
    let entryA = queued.unresolved.first { $0.metadata.id == queuedA.id }!
    let entryB = queued.unresolved.first { $0.metadata.id == queuedB.id }!
    let removeA = Task { try await queued.remove(entryA) }
    await until { queuedCleanup[queuedA.id] != nil }
    var queuedDrained = false
    let queuedDrain = Task {
      try await queued.drainPendingRemovals()
      queuedDrained = true
    }
    await Task.yield()
    let removeB = Task { try await queued.remove(entryB) }
    await until { queuedCleanup[queuedB.id] != nil }
    queuedCleanup[queuedA.id]!.resume()
    try await removeA.value
    precondition(!queuedDrained, "drain must include removal added during its first await")
    do {
      _ = try queued.captureSession(windows: [])
      preconditionFailure("second pending removal ignored")
    } catch {}
    queuedCleanup[queuedB.id]!.resume()
    try await queuedDrain.value
    precondition(queued.unresolved.isEmpty, "drain must apply metadata mutation before returning")
    try await removeB.value
    let emptied = try queued.captureSession(windows: [])
    precondition(emptied.windows.isEmpty)

    for failure in [SessionStoreError.corrupt, .unsupportedVersion(99)] {
      let blocked = SessionCoordinator(
        loadSession: { throw failure },
        claimRecovery: { .init(snapshots: [], quarantinedCount: 0) },
        saveSession: { _ in preconditionFailure("preservation guard bypassed") })
      await blocked.restore { _ in [:] }
      do {
        _ = try blocked.captureSession(windows: [])
        preconditionFailure("preservation capture accepted")
      } catch {}
    }
    print(
      "PASS metadata capture: startup/preservation guards, unresolved/history merge, cleanup barriers and legacy persist"
    )
  }
}
