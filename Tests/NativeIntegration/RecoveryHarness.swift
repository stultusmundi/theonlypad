import Foundation
import PadCore

@main struct CoordinatorTest {
  static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let coordinator = RecoveryCoordinator(directory: directory)
    let id = UUID()
    let snapshot = RecoverySnapshot(
      id: id, text: "synthetic recovery 👩🏽‍💻", encoding: .utf8, hasBOM: false)
    try await coordinator.persist(snapshot, revision: 2)
    var old = snapshot
    old.text = "stale"
    try await coordinator.persist(old, revision: 1)
    let first = try await RecoveryCoordinator(directory: directory).claimStartup()
    precondition(first.snapshots == [snapshot], "older updates cannot replace latest content")
    try await coordinator.close(id: id)
    try await coordinator.persist(snapshot, revision: 99)
    let empty = try await RecoveryCoordinator(directory: directory).claimStartup()
    precondition(empty.snapshots.isEmpty, "late snapshot cannot resurrect closed document")
    try Data("invalid".utf8).write(
      to: directory.appendingPathComponent(UUID().uuidString + ".json"))
    let corrupt = try await RecoveryCoordinator(directory: directory).claimStartup()
    precondition(corrupt.quarantinedCount == 1)
    print("PASS recovery ordering, close tombstone, restore, quarantine")
  }
}
