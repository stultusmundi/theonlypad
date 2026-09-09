import Foundation
import PadCore

private enum SessionChangeFixtureError: Error { case cleanup }
@main struct SessionChangeHarness {
  @MainActor static func main() async throws {
    let missing = SessionTab()
    let original = SessionWindow(tabs: [missing], selectedTabID: missing.id)
    var cleanupFails = true
    var notifications = 0
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [original]) },
      claimRecovery: {
        .init(
          snapshots: [.init(id: missing.id, text: "preserved", encoding: .utf8, hasBOM: false)],
          quarantinedCount: 0)
      },
      removeRecovery: { _ in if cleanupFails { throw SessionChangeFixtureError.cleanup } })
    coordinator.onSessionChange = { notifications += 1 }
    await coordinator.restore { _ in [missing.id: "synthetic import failure"] }
    precondition(notifications > 0, "restoration mutations must notify")
    var previous = notifications
    _ = try coordinator.captureSession(windows: [])
    try await coordinator.drainPendingRemovals()
    precondition(notifications == previous, "pure capture and empty drain must not notify")
    let first = URL(fileURLWithPath: "/synthetic/first.txt")
    let second = URL(fileURLWithPath: "/synthetic/second.txt")
    try coordinator.recordRecentOpen(first)
    precondition(notifications > previous && coordinator.recentPaths == [first.path])
    previous = notifications
    try coordinator.recordRecentOpen(first)
    coordinator.removeRecent("/synthetic/not-present.txt")
    precondition(notifications == previous, "no-op recent mutations must not notify")
    try coordinator.recordRecentOpen(second)
    previous = notifications
    try coordinator.recordRecentOpen(first)
    precondition(notifications > previous && coordinator.recentPaths == [first.path, second.path])
    previous = notifications
    coordinator.removeRecent(first.path)
    precondition(notifications > previous && coordinator.recentPaths == [second.path])
    previous = notifications
    coordinator.clearRecent()
    precondition(notifications > previous && coordinator.recentPaths.isEmpty)
    previous = notifications
    coordinator.clearRecent()
    precondition(notifications == previous)
    let entry = coordinator.unresolved.first!
    let beforeFailure = try coordinator.captureSession(windows: [])
    do {
      try await coordinator.remove(entry)
      preconditionFailure("cleanup failure hidden")
    } catch SessionChangeFixtureError.cleanup {}
    let afterFailure = try coordinator.captureSession(windows: [])
    precondition(beforeFailure == afterFailure && coordinator.unresolved.count == 1)
    precondition(
      notifications == previous, "error prose alone does not change persisted session metadata")
    cleanupFails = false
    try await coordinator.remove(entry)
    precondition(notifications > previous && coordinator.unresolved.isEmpty)
    previous = notifications
    try await coordinator.drainPendingRemovals()
    coordinator.resolved(entry)
    _ = try coordinator.captureSession(windows: [])
    precondition(notifications == previous)
    let repairing = SessionCoordinator(
      loadSession: { EditorSession(windows: [original]) },
      claimRecovery: { .init(snapshots: [], quarantinedCount: 0) })
    await repairing.restore { _ in [:] }
    var repairNotified = false
    repairing.onSessionChange = { repairNotified = true }
    repairing.resolved(repairing.unresolved.first!)
    precondition(repairNotified && repairing.unresolved.isEmpty)
    print(
      "PASS session change notifications: actual history/restoration/repair changes, pure capture and failed-cleanup preservation"
    )
  }
}
