import Foundation
import PadCore

/// Serial owner of recovery I/O. Revisions reject reordered writes; tombstones
/// permanently reject writes captured before a document was explicitly closed.
actor RecoveryCoordinator {
  struct Startup: Sendable {
    var snapshots: [RecoverySnapshot]
    var quarantinedCount: Int
  }
  static let shared = RecoveryCoordinator(directory: defaultDirectory())
  private let directory: URL
  private var store: RecoveryStore?
  private var startupClaimed = false
  private var revisions: [UUID: UInt64] = [:]
  private var closed: Set<UUID> = []

  init(directory: URL) { self.directory = directory }

  nonisolated private static func defaultDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
      .appendingPathComponent("Recovery", isDirectory: true)
  }

  private func storage() throws -> RecoveryStore {
    if let store { return store }
    let value = try RecoveryStore(directory: directory)
    store = value
    return value
  }

  func claimStartup() throws -> Startup {
    guard !startupClaimed else { return Startup(snapshots: [], quarantinedCount: 0) }
    let snapshots = try storage().loadAll()
    let corrupt = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "corrupt" }.count
    startupClaimed = true
    return Startup(snapshots: snapshots, quarantinedCount: corrupt)
  }

  func persist(_ snapshot: RecoverySnapshot, revision: UInt64) throws {
    guard !closed.contains(snapshot.id), revision >= revisions[snapshot.id, default: 0] else {
      return
    }
    try storage().save(snapshot)
    revisions[snapshot.id] = revision
  }

  func clear(id: UUID, revision: UInt64) throws {
    guard !closed.contains(id), revision >= revisions[id, default: 0] else { return }
    try storage().remove(id: id)
    revisions[id] = revision
  }

  func close(id: UUID) throws {
    closed.insert(id)
    try storage().remove(id: id)
  }
}
