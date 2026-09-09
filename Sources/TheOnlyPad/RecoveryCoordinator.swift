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
  private let limits: RecoveryLimits
  private var capacityKnown = false
  private var startupReport: RecoveryLoadReport?
  private var snapshotUnits: [UUID: Int] = [:]
  private var revisions: [UUID: UInt64] = [:]
  private var closed: Set<UUID> = []

  init(directory: URL, limits: RecoveryLimits = RecoveryLimits()) {
    self.directory = directory
    self.limits = limits
  }

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
    let value = try RecoveryStore(directory: directory, limits: limits)
    store = value
    return value
  }

  func claimStartup() throws -> Startup {
    guard !startupClaimed else { return Startup(snapshots: [], quarantinedCount: 0) }
    try initializeCapacity()
    let report = startupReport!
    startupReport = nil
    startupClaimed = true
    return Startup(snapshots: report.snapshots, quarantinedCount: report.quarantinedCount)
  }

  func persist(_ snapshot: RecoverySnapshot, revision: UInt64) throws {
    guard !closed.contains(snapshot.id), revision >= revisions[snapshot.id, default: 0] else {
      return
    }
    try initializeCapacity()
    let count = snapshot.text.utf16.count
    let others = snapshotUnits.reduce(0) { $0 + ($1.key == snapshot.id ? 0 : $1.value) }
    guard count <= limits.maximumRestoredUTF16 - others,
      snapshotUnits[snapshot.id] != nil || snapshotUnits.count < limits.maximumSnapshots
    else {
      throw RecoveryError.resourceLimit
    }
    try storage().save(snapshot)
    snapshotUnits[snapshot.id] = count
    if !startupClaimed, let report = startupReport {
      startupReport = RecoveryLoadReport(
        snapshots: report.snapshots.filter { $0.id != snapshot.id } + [snapshot],
        quarantinedCount: report.quarantinedCount)
    }
    revisions[snapshot.id] = revision
  }

  /// Order a bounded set of latest revisions so cleanup and shrinking snapshots release quota
  /// before growth. Unrelated cleanup still completes when a write fails.
  func persistBatch(_ batch: [(UUID, UInt64, RecoverySnapshot?)]) throws {
    guard batch.count <= 4_096 else { throw RecoveryError.resourceLimit }
    var chosen: [UUID: (revision: UInt64, snapshot: RecoverySnapshot?, order: Int)] = [:]
    var inputError: Error?
    for (index, item) in batch.enumerated() {
      let (id, revision, snapshot) = item
      guard snapshot == nil || snapshot?.id == id else {
        inputError = inputError ?? RecoveryError.invalidSnapshot
        continue
      }
      guard !closed.contains(id), revision >= revisions[id, default: 0] else { continue }
      if let previous = chosen[id], previous.revision > revision { continue }
      chosen[id] = (revision, snapshot, index)
    }
    let ordered = chosen.sorted { $0.value.order < $1.value.order }
    var cleanupError: Error?
    for item in ordered where item.value.snapshot == nil {
      do { try clear(id: item.key, revision: item.value.revision) } catch {
        cleanupError = cleanupError ?? error
      }
    }
    let writes = ordered.filter { $0.value.snapshot != nil }
    if !writes.isEmpty {
      // Initialization follows cleanup so pending removals can make an old directory fit again.
      try initializeCapacity()
      let sorted = writes.sorted {
        let leftShrinks = $0.value.snapshot!.text.utf16.count <= snapshotUnits[$0.key, default: 0]
        let rightShrinks = $1.value.snapshot!.text.utf16.count <= snapshotUnits[$1.key, default: 0]
        if leftShrinks != rightShrinks { return leftShrinks }
        return $0.value.order < $1.value.order
      }
      var failures: [(snapshot: RecoverySnapshot, revision: UInt64, error: Error)] = []
      var progress = false
      for item in sorted {
        do {
          try persist(item.value.snapshot!, revision: item.value.revision)
          progress = true
        } catch { failures.append((item.value.snapshot!, item.value.revision, error)) }
      }
      // Text size and escaped JSON size can move in opposite directions. Retry quota failures
      // once after other writes have released space, without an unbounded retry loop.
      var unresolved: Error?
      for failure in failures {
        if progress, failure.error as? RecoveryError == .resourceLimit {
          do { try persist(failure.snapshot, revision: failure.revision) } catch {
            unresolved = unresolved ?? error
          }
        } else {
          unresolved = unresolved ?? failure.error
        }
      }
      if let error = inputError ?? cleanupError ?? unresolved { throw error }
    } else if let error = inputError ?? cleanupError {
      throw error
    }
  }

  func clear(id: UUID, revision: UInt64) throws {
    guard !closed.contains(id), revision >= revisions[id, default: 0] else { return }
    try storage().remove(id: id)
    removedFromCapacity(id)
    revisions[id] = revision
  }

  func close(id: UUID) throws {
    closed.insert(id)
    try storage().remove(id: id)
    removedFromCapacity(id)
  }
  private func initializeCapacity() throws {
    guard !capacityKnown else { return }
    let report = try storage().loadReport()
    snapshotUnits = Dictionary(
      uniqueKeysWithValues: report.snapshots.map { ($0.id, $0.text.utf16.count) })
    startupReport = report
    capacityKnown = true
  }
  private func removedFromCapacity(_ id: UUID) {
    snapshotUnits.removeValue(forKey: id)
    if !startupClaimed, let report = startupReport {
      startupReport = RecoveryLoadReport(
        snapshots: report.snapshots.filter { $0.id != id },
        quarantinedCount: report.quarantinedCount)
    }
  }
}
