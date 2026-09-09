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
    let nextStartup = try await RecoveryCoordinator(directory: directory).claimStartup()
    precondition(
      nextStartup.quarantinedCount == 0, "historical quarantine is not reported as a new failure")
    let oversized = directory.appendingPathComponent(UUID().uuidString + ".json")
    FileManager.default.createFile(
      atPath: oversized.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: oversized)
    let byteCount = UInt64(RecoveryLimits().maximumEnvelopeBytes) + 1
    try handle.truncate(atOffset: byteCount)
    try handle.close()
    let retrying = RecoveryCoordinator(directory: directory)
    do {
      _ = try await retrying.claimStartup()
      preconditionFailure("oversized recovery must fail before reading")
    } catch RecoveryError.resourceLimit {}
    let preservedSize = try oversized.resourceValues(forKeys: [.fileSizeKey]).fileSize
    precondition(preservedSize == Int(byteCount))
    try FileManager.default.removeItem(at: oversized)
    let retry = try await retrying.claimStartup()
    precondition(retry.snapshots.isEmpty, "a resource failure must not consume the startup claim")
    let tinyDirectory = directory.appendingPathComponent("tiny")
    let limits = RecoveryLimits(
      maximumSnapshotUTF16: 100, maximumEnvelopeBytes: 2_048,
      maximumSnapshots: 2, maximumDirectoryEntries: 16, maximumRestoredUTF16: 100)
    let bounded = RecoveryCoordinator(directory: tinyDirectory, limits: limits)
    var a = RecoverySnapshot(
      id: UUID(), text: String(repeating: "a", count: 60), encoding: .utf8, hasBOM: false)
    let b = RecoverySnapshot(
      id: UUID(), text: String(repeating: "b", count: 60), encoding: .utf8, hasBOM: false)
    try await bounded.persist(a, revision: 1)
    do {
      try await bounded.persist(b, revision: 2)
      preconditionFailure("aggregate save must fail before an unrestorable session is persisted")
    } catch RecoveryError.resourceLimit {}
    a.text = "small"
    try await bounded.persist(a, revision: 2)
    try await bounded.persist(b, revision: 1)
    let c = RecoverySnapshot(id: UUID(), text: "third", encoding: .utf8, hasBOM: false)
    do {
      try await bounded.persist(c, revision: 1)
      preconditionFailure("snapshot-count overflow must fail before saving")
    } catch RecoveryError.resourceLimit {}
    try await bounded.close(id: a.id)
    try await bounded.persist(c, revision: 1)
    let restored = try await RecoveryCoordinator(directory: tinyDirectory, limits: limits)
      .claimStartup()
    precondition(Set(restored.snapshots.map(\.id)) == Set([b.id, c.id]))
    let batchDirectory = directory.appendingPathComponent("batch")
    let batchLimits = RecoveryLimits(
      maximumSnapshotUTF16: 100, maximumEnvelopeBytes: 2_048,
      maximumSnapshots: 4, maximumDirectoryEntries: 16, maximumRestoredUTF16: 100)
    let batchOwner = RecoveryCoordinator(directory: batchDirectory, limits: batchLimits)
    var batchA = RecoverySnapshot(
      id: UUID(), text: String(repeating: "a", count: 60), encoding: .utf8, hasBOM: false)
    var second = RecoverySnapshot(
      id: UUID(), text: String(repeating: "b", count: 40), encoding: .utf8, hasBOM: false)
    try await batchOwner.persist(batchA, revision: 1)
    try await batchOwner.persist(second, revision: 1)
    batchA.text = String(repeating: "a", count: 80)
    second.text = String(repeating: "b", count: 20)
    try await batchOwner.persistBatch([(batchA.id, 2, batchA), (second.id, 2, second)])
    let afterBatch = try RecoveryStore(directory: batchDirectory, limits: batchLimits).loadAll()
    precondition(afterBatch.first { $0.id == batchA.id }?.text.utf16.count == 80)
    precondition(afterBatch.first { $0.id == second.id }?.text.utf16.count == 20)
    let tooBig = RecoverySnapshot(
      id: UUID(), text: String(repeating: "x", count: 101), encoding: .utf8, hasBOM: false)
    do {
      try await batchOwner.persistBatch([(tooBig.id, 1, tooBig), (second.id, 3, nil)])
      preconditionFailure("unresolved overflow must report failure")
    } catch RecoveryError.resourceLimit {}
    let afterCleanup = try RecoveryStore(directory: batchDirectory, limits: batchLimits).loadAll()
    precondition(
      afterCleanup.map(\.id) == [batchA.id], "unrelated cleanup must run despite quota error")
    try await batchOwner.persistBatch([(batchA.id, 5, nil), (batchA.id, 4, batchA)])
    let afterCoalescing = try RecoveryStore(directory: batchDirectory, limits: batchLimits)
      .loadAll()
    precondition(afterCoalescing.isEmpty, "highest revision wins before operation ordering")

    let retryDirectory = directory.appendingPathComponent("batch-retry")
    let initialStore = try RecoveryStore(directory: retryDirectory)
    var escaped = RecoverySnapshot(
      id: UUID(), text: String(repeating: "\u{1}", count: 50), encoding: .utf8, hasBOM: false)
    var plain = RecoverySnapshot(
      id: UUID(), text: String(repeating: "p", count: 50), encoding: .utf8, hasBOM: false)
    try initialStore.save(escaped)
    try initialStore.save(plain)
    let initialFiles = try FileManager.default.contentsOfDirectory(
      at: retryDirectory, includingPropertiesForKeys: [.fileSizeKey])
    let encodedBudget = try initialFiles.reduce(0) {
      try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    }
    let retryLimits = RecoveryLimits(
      maximumSnapshotUTF16: 120, maximumEnvelopeBytes: encodedBudget,
      maximumSnapshots: 4, maximumDirectoryEntries: 16, maximumRestoredUTF16: 120)
    let retryOwner = RecoveryCoordinator(directory: retryDirectory, limits: retryLimits)
    escaped.text = String(repeating: "a", count: 60)
    plain.text = String(repeating: "\u{1}", count: 40)
    try await retryOwner.persistBatch([(plain.id, 2, plain), (escaped.id, 2, escaped)])
    let finalRetry = try RecoveryStore(directory: retryDirectory, limits: retryLimits).loadAll()
    precondition(finalRetry.first { $0.id == plain.id }?.text == plain.text)
    precondition(finalRetry.first { $0.id == escaped.id }?.text == escaped.text)
    print(
      "PASS recovery quotas, batch shrink ordering, cleanup on error, revision coalescing and bounded retry"
    )
  }
}
