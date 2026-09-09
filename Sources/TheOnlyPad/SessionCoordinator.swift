import Foundation
import PadCore

struct SessionImportClaim: Sendable {
  fileprivate let owner: UUID
  fileprivate let revision: UUID
  fileprivate let entry: UnresolvedSessionEntry
  var documentID: UUID { entry.metadata.id }
  var windowID: UUID { entry.windowID }
}

/// Recovery-only startup provenance. Never permits session publication or a file-backed import.
struct SessionRecoveryImportClaim: Sendable {
  fileprivate let base: SessionImportClaim
  let snapshot: RecoverySnapshot
  var documentID: UUID { base.documentID }
  var windowID: UUID { base.windowID }
}

enum SessionImportError: Error, LocalizedError {
  case invalidClaim, cleanupPending
  var errorDescription: String? {
    switch self {
    case .invalidClaim:
      return "The saved session record changed. Refresh the recovery list and try again."
    case .cleanupPending:
      return
        "Recovery cleanup is still pending. Retry importing this record after cleanup completes."
    }
  }
}

struct SessionCapacitySnapshot: Equatable, Sendable {
  let sessionRevision: UUID
  let windowIDs: Set<UUID>
  let documentIDs: Set<UUID>
}

struct PreparedSessionTab: Sendable {
  let seed: NativeDocumentSeed?
  let metadata: SessionTab
  let decoded: DecodedDocument
  let originalBytes: Data?
  let url: URL?
  let viewState: RestoredViewState
  let resolvedPresentation: RestoredPresentationState?
  let utf16Count: Int
}
struct PreparedSessionWindow: Sendable {
  let id: UUID
  let tabs: [PreparedSessionTab]
  let selectedTabID: UUID?
}

struct SessionStartupBudget {
  private var units = 0
  private var estimatedBytes = 0
  mutating func admit(utf16Count: Int, originalByteCount: Int) throws {
    guard utf16Count >= 0, originalByteCount >= 0,
      utf16Count <= 100_000_000 - units,
      originalByteCount <= 400_000_000 - estimatedBytes,
      utf16Count <= (400_000_000 - estimatedBytes - originalByteCount) / 2
    else {
      throw NSError(
        domain: "TheOnlyPad.Session", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Startup restoration exceeds 100 million UTF-16 units or its 400 MB retained text/byte estimate. This record remains unresolved; retry it after closing other documents."
        ])
    }
    units += utf16Count
    estimatedBytes += originalByteCount + utf16Count * 2
  }
}

/// Owns unresolved metadata. Async readers do not create or change editor windows.
@MainActor final class SessionCoordinator {
  private let importOwner = UUID()
  /// Provenance only: callers must revalidate after native/registry callbacks, not treat this as a reservation.
  func claimImport(_ entry: UnresolvedSessionEntry) throws -> SessionImportClaim {
    try requireImportAdmission()
    guard let current = unresolved.first(where: { Self.sameImportEntry($0, entry) }) else {
      throw SessionImportError.invalidClaim
    }
    return SessionImportClaim(owner: importOwner, revision: capacityRevision, entry: current)
  }
  func validateImport(_ claim: SessionImportClaim) throws {
    try requireImportAdmission()
    guard claim.owner == importOwner, claim.revision == capacityRevision,
      unresolved.contains(where: { Self.sameImportEntry($0, claim.entry) })
    else { throw SessionImportError.invalidClaim }
  }
  func resolveImport(_ claim: SessionImportClaim) throws {
    try validateImport(claim)
    // Transfer unresolved ownership before the array observer can expose the completed transition.
    // This never removes recovery from disk; the live document's publisher now owns that decision.
    recoveryByID[claim.documentID] = nil
    recoveryIDs.remove(claim.documentID)
    unresolved.removeAll { $0.metadata.id == claim.documentID }
  }
  func claimRecoveryImport(_ entry: UnresolvedSessionEntry) throws -> SessionRecoveryImportClaim {
    try requireRecoveryImportAdmission()
    guard entry.hasRecovery,
      let current = unresolved.first(where: { Self.sameImportEntry($0, entry) }),
      let snapshot = recoveryByID[entry.metadata.id], snapshot.id == entry.metadata.id
    else { throw SessionImportError.invalidClaim }
    return SessionRecoveryImportClaim(
      base: SessionImportClaim(owner: importOwner, revision: capacityRevision, entry: current),
      snapshot: snapshot)
  }
  func validateRecoveryImport(_ claim: SessionRecoveryImportClaim) throws {
    try requireRecoveryImportAdmission()
    let base = claim.base
    guard base.owner == importOwner, base.revision == capacityRevision, base.entry.hasRecovery,
      unresolved.contains(where: { Self.sameImportEntry($0, base.entry) }),
      recoveryByID[base.documentID] != nil, claim.snapshot.id == base.documentID
    else { throw SessionImportError.invalidClaim }
    // Retained snapshots are immutable after restoration; any membership change rotates revision.
    // No full-text comparison or disk access is needed at this MainActor provenance boundary.
  }
  func resolveRecoveryImport(_ claim: SessionRecoveryImportClaim) throws {
    try validateRecoveryImport(claim)
    recoveryByID[claim.documentID] = nil
    recoveryIDs.remove(claim.documentID)
    unresolved.removeAll { $0.metadata.id == claim.documentID }
  }
  /// Reconciliation only: the caller must already retain the exact imported handle/assignment.
  /// Permit a new membership revision, never a different coordinator or semantic source record.
  func renewImportClaim(_ claim: SessionImportClaim) throws -> SessionImportClaim {
    guard claim.owner == importOwner else { throw SessionImportError.invalidClaim }
    return try claimImport(claim.entry)
  }
  func renewImportClaim(_ claim: SessionRecoveryImportClaim) throws -> SessionRecoveryImportClaim {
    guard claim.base.owner == importOwner else { throw SessionImportError.invalidClaim }
    return try claimRecoveryImport(claim.base.entry)
  }
  /// Pre-factory admission only; the intake owner must separately revalidate callback/registry state.
  func preflightImport(_ claim: SessionImportClaim, liveWindows: [UUID: Set<UUID>]) throws
    -> SessionCapacitySnapshot
  {
    try validateImport(claim)
    return try importCapacity(entry: claim.entry, liveWindows: liveWindows)
  }
  func preflightImport(_ claim: SessionRecoveryImportClaim, liveWindows: [UUID: Set<UUID>]) throws
    -> SessionCapacitySnapshot
  {
    try validateRecoveryImport(claim)
    return try importCapacity(entry: claim.base.entry, liveWindows: liveWindows)
  }
  private func importCapacity(entry: UnresolvedSessionEntry, liveWindows: [UUID: Set<UUID>]) throws
    -> SessionCapacitySnapshot
  {
    guard liveWindows.count <= 32 else { throw SessionStoreError.limit }
    var liveIDs = Set<UUID>()
    for ids in liveWindows.values {
      guard ids.count <= 128, liveIDs.isDisjoint(with: ids) else {
        throw SessionRestorationError.duplicateID
      }
      liveIDs.formUnion(ids)
      guard liveIDs.count <= 128 else { throw SessionStoreError.limit }
    }
    guard !liveIDs.contains(entry.metadata.id) else { throw SessionRestorationError.duplicateID }
    let reservedWindows = Set(unresolved.map(\.windowID))
    let reservedIDs = Set(unresolved.map { $0.metadata.id })
    let beforeWindows = Set(liveWindows.keys).union(reservedWindows)
    let beforeIDs = liveIDs.union(reservedIDs)
    guard beforeWindows.isDisjoint(with: beforeIDs) else {
      throw SessionRestorationError.duplicateID
    }
    // Restore to the original reserved window only. A new destination is a separate transfer.
    var candidate = liveWindows
    candidate[entry.windowID, default: []].insert(entry.metadata.id)
    let candidateIDs = liveIDs.union([entry.metadata.id])
    guard candidate.count <= 32, candidateIDs.count <= 128 else { throw SessionStoreError.limit }
    let remaining = unresolved.filter { $0.metadata.id != entry.metadata.id }
    let afterWindows = Set(candidate.keys).union(remaining.map(\.windowID))
    let afterIDs = candidateIDs.union(remaining.map { $0.metadata.id })
    guard afterWindows == beforeWindows, afterIDs == beforeIDs else {
      throw SessionImportError.invalidClaim
    }
    // The union may exceed persistence limits; never hide excess unresolved records or issue a receipt.
    return SessionCapacitySnapshot(
      sessionRevision: capacityRevision, windowIDs: afterWindows, documentIDs: afterIDs)
  }
  private func requireRecoveryImportAdmission() throws {
    guard restorationComplete else { throw SessionImportError.invalidClaim }
    guard removals.isEmpty else { throw SessionImportError.cleanupPending }
    // Validated recovery may be exposed as scratch content despite corrupt session metadata.
    // preservationError is deliberately retained: captureSession/persist still refuse all writes.
  }
  private func requireImportAdmission() throws {
    try requireRestoredSession()
    guard removals.isEmpty else { throw SessionImportError.cleanupPending }
  }
  private static func sameImportEntry(
    _ first: UnresolvedSessionEntry, _ second: UnresolvedSessionEntry
  )
    -> Bool
  {
    guard first.windowID == second.windowID, first.metadata == second.metadata,
      first.hasRecovery == second.hasRecovery
    else { return false }
    switch (first.metadata.originalPath, second.metadata.originalPath) {
    case (nil, nil): return true
    case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
    default: return false
    }
  }
  private(set) var capacityRevision = UUID()
  func transferCapacity(liveWindows: [UUID: Set<UUID>]) throws -> SessionCapacitySnapshot {
    try requireRestoredSession()
    guard removals.isEmpty else {
      throw Self.error(
        "Recovery cleanup is pending. Retry the document move after cleanup completes.")
    }
    var windows = Set(liveWindows.keys)
    var documents = Set(liveWindows.values.flatMap { $0 })
    for entry in unresolved {
      windows.insert(entry.windowID)
      documents.insert(entry.metadata.id)
    }
    return SessionCapacitySnapshot(
      sessionRevision: capacityRevision, windowIDs: windows, documentIDs: documents)
  }

  var onSessionChange: (() -> Void)?
  // Post-startup public operations only change membership or error prose. A future semantic
  // metadata update must also rotate capacityRevision, including for an A→B→A update sequence.
  private(set) var unresolved: [UnresolvedSessionEntry] = [] {
    willSet {
      if unresolved.map({ [$0.windowID, $0.metadata.id] })
        != newValue.map({ [$0.windowID, $0.metadata.id] })
      {
        capacityRevision = UUID()
      }
    }
    didSet {
      // Error prose is panel state, not persisted metadata.
      let unchanged =
        oldValue.count == unresolved.count
        && zip(oldValue, unresolved).allSatisfy {
          $0.windowID == $1.windowID && $0.metadata == $1.metadata
        }
      if !unchanged { onSessionChange?() }
    }
  }
  private(set) var warnings: [String] = []
  private(set) var startupErrors: [String] = []
  private(set) var restorationComplete = false {
    willSet { if newValue != restorationComplete { capacityRevision = UUID() } }
    didSet { if oldValue != restorationComplete { onSessionChange?() } }
  }
  private var preservationError: Error? {
    willSet { capacityRevision = UUID() }
  }
  private var originalWindows: [SessionWindow] = [] {
    didSet { if oldValue != originalWindows { onSessionChange?() } }
  }
  private(set) var recentPaths: [String] = [] {
    didSet {
      let unchanged =
        oldValue.count == recentPaths.count
        && zip(oldValue, recentPaths).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
      if !unchanged { onSessionChange?() }
    }
  }
  private var generation = 0
  private var started = false {
    willSet { if newValue != started { capacityRevision = UUID() } }
  }
  private var recoveryIDs = Set<UUID>()
  private var recoveryByID: [UUID: RecoverySnapshot] = [:]
  private struct PendingRemoval {
    let token = UUID()
    let task: Task<Void, Error>
  }
  private var removals: [UUID: PendingRemoval] = [:] {
    willSet { capacityRevision = UUID() }
  }
  private let removeRecovery: @MainActor (UUID) async throws -> Void
  private let loadSession: @MainActor () async throws -> EditorSession?
  private let claimRecovery: @MainActor () async throws -> RecoveryCoordinator.Startup
  private let saveSession: @MainActor (EditorSession) async throws -> Void
  private let readFile: @MainActor (SessionTab, URL) async throws -> SessionResolvedFile

  init(
    loadSession: @escaping @MainActor () async throws -> EditorSession? = {
      try await Task.detached { try SessionStore().load() }.value
    },
    claimRecovery: @escaping @MainActor () async throws -> RecoveryCoordinator.Startup = {
      try await SessionCoordinator.claimRecoveryStartup()
    },
    saveSession: @escaping @MainActor (EditorSession) async throws -> Void = { session in
      try await Task.detached { try SessionStore().save(session) }.value
    },
    removeRecovery: @escaping @MainActor (UUID) async throws -> Void = { id in
      try await SessionCoordinator.removeRecoverySnapshot(id)
    },
    readFile: @escaping @MainActor (SessionTab, URL) async throws -> SessionResolvedFile = {
      metadata, url in
      try await Task.detached { try SessionCoordinator.read(metadata, at: url) }.value
    }
  ) {
    self.removeRecovery = removeRecovery
    self.loadSession = loadSession
    self.claimRecovery = claimRecovery
    self.saveSession = saveSession
    self.readFile = readFile
  }

  nonisolated private static func claimRecoveryStartup() async throws -> RecoveryCoordinator.Startup
  {
    try await RecoveryCoordinator.shared.claimStartup()
  }
  func insertionIndex(for entry: UnresolvedSessionEntry, in window: SessionWindow) -> Int {
    guard let original = originalWindows.first(where: { $0.id == entry.windowID }),
      let index = original.tabs.firstIndex(where: { $0.id == entry.metadata.id })
    else { return window.tabs.count }
    let predecessors = Set(original.tabs.prefix(index).map(\.id))
    return window.tabs.lastIndex(where: { predecessors.contains($0.id) }).map { $0 + 1 } ?? 0
  }
  func shouldSelect(_ entry: UnresolvedSessionEntry) -> Bool {
    originalWindows.first(where: { $0.id == entry.windowID })?.selectedTabID == entry.metadata.id
  }

  nonisolated private static func removeRecoverySnapshot(_ id: UUID) async throws {
    try await RecoveryCoordinator.shared.close(id: id)
  }

  func cancelRestoration() {
    capacityRevision = UUID()
    generation += 1
  }

  func restore(importWindow: @MainActor (PreparedSessionWindow) -> [UUID: String]) async {
    guard !started else { return }
    started = true
    let request = generation
    var session: EditorSession?
    do { session = try await loadSession() } catch { preserve(error) }
    guard request == generation else { return }
    var snapshots: [RecoverySnapshot] = []
    do {
      let recovery = try await claimRecovery()
      snapshots = recovery.snapshots
      recoveryIDs = Set(snapshots.map(\.id))
      recoveryByID = Dictionary(
        snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      if recovery.quarantinedCount > 0 {
        warnings.append(
          "\(recovery.quarantinedCount) recovery records could not be restored and remain quarantined."
        )
      }
    } catch { preserve(error) }
    guard request == generation else { return }
    do {
      let plan: SessionRestorationPlan
      do { plan = try SessionRestoration.plan(session: session, recoveries: snapshots) } catch {
        preserve(error)
        // Invalid metadata must not hide otherwise valid recovery buffers.
        plan = try SessionRestoration.plan(session: nil, recoveries: snapshots)
      }
      recentPaths = Self.uniqueRecentPaths(recentPaths + plan.recentPaths)
      originalWindows = plan.windows.map {
        SessionWindow(id: $0.id, tabs: $0.tabs.map(\.metadata), selectedTabID: $0.selectedTabID)
      }
      var budget = SessionStartupBudget()
      for window in plan.windows {
        var prepared: [PreparedSessionTab] = []
        for tab in window.tabs {
          guard request == generation else { return }
          do {
            let value: PreparedSessionTab
            switch tab.source {
            case .missingRecovery:
              throw Self.error(
                "Recovery content for this scratch tab is missing. Locate an existing file or explicitly remove the record."
              )
            case .file(let path, _):
              let file = try await readFile(tab.metadata, URL(fileURLWithPath: path))
              guard let state = file.resolvedViewState,
                file.resolvedPresentation != nil
                  || tab.metadata.presentation == .single(selection: tab.metadata.selection)
              else {
                throw SessionStoreError.invalidMetadata
              }
              value = PreparedSessionTab(
                seed: file.seed, metadata: tab.metadata, decoded: file.decoded,
                originalBytes: file.originalBytes,
                url: file.url, viewState: state, resolvedPresentation: file.resolvedPresentation,
                utf16Count: file.utf16Count)
            case .recovery(let snapshot):
              value = try await Task.detached {
                let seed = try NativeDocumentSeed.restored(
                  tab.metadata,
                  decoded: .init(
                    text: snapshot.text, encoding: snapshot.encoding, hasBOM: snapshot.hasBOM),
                  originalBytes: nil, url: nil)
                guard let presentation = seed.presentation else {
                  throw SessionStoreError.invalidMetadata
                }
                return PreparedSessionTab(
                  seed: seed, metadata: tab.metadata,
                  decoded: .init(text: seed.text, encoding: seed.encoding, hasBOM: seed.hasBOM),
                  originalBytes: nil, url: nil,
                  viewState: presentation.focusedViewState, resolvedPresentation: presentation,
                  utf16Count: seed.textUTF16Count)
              }.value
            }
            guard request == generation else { return }
            try budget.admit(
              utf16Count: value.utf16Count, originalByteCount: value.originalBytes?.count ?? 0)
            prepared.append(value)
            if value.viewState.selectionAdjusted || !value.viewState.invalidBookmarks.isEmpty
              || value.resolvedPresentation?.adjustedPaneIndices.isEmpty == false
            {
              warnings.append(
                "Saved positions for \(tab.metadata.originalPath ?? tab.metadata.id.uuidString) no longer match its text; pane selections were clamped where needed and invalid bookmarks were omitted."
              )
            }
          } catch {
            guard request == generation else { return }
            unresolved.append(
              UnresolvedSessionEntry(
                windowID: window.id, metadata: tab.metadata,
                errorMessage: error.localizedDescription,
                hasRecovery: recoveryIDs.contains(tab.metadata.id)))
          }
        }
        guard request == generation else { return }
        if !prepared.isEmpty {
          let failures = importWindow(
            PreparedSessionWindow(
              id: window.id, tabs: prepared, selectedTabID: window.selectedTabID))
          for tab in prepared where failures[tab.metadata.id] == nil {
            recoveryByID[tab.metadata.id] = nil
          }
          for tab in prepared where failures[tab.metadata.id] != nil {
            unresolved.append(
              UnresolvedSessionEntry(
                windowID: window.id, metadata: tab.metadata,
                errorMessage: failures[tab.metadata.id]!,
                hasRecovery: recoveryIDs.contains(tab.metadata.id)))
          }
        }
      }
      restorationComplete = true
    } catch {
      preserve(error)
      restorationComplete = true
    }
  }

  func retry(_ entry: UnresolvedSessionEntry) async throws -> SessionResolvedFile {
    if let snapshot = recoveryByID[entry.metadata.id] {
      return try await Task.detached {
        let seed = try NativeDocumentSeed.restored(
          entry.metadata,
          decoded: .init(text: snapshot.text, encoding: snapshot.encoding, hasBOM: snapshot.hasBOM),
          originalBytes: nil, url: nil)
        return SessionResolvedFile(seed: seed)
      }.value
    }
    guard let path = entry.metadata.originalPath else {
      throw Self.error(
        "Recovery content is missing. Locate an existing file or explicitly remove this record.")
    }
    return try await readFile(entry.metadata, URL(fileURLWithPath: path))
  }
  func locate(_ entry: UnresolvedSessionEntry, url: URL) async throws -> SessionResolvedFile {
    try await readFile(entry.metadata, url)
  }
  func resolved(_ entry: UnresolvedSessionEntry) {
    unresolved.removeAll { $0.metadata.id == entry.metadata.id }
    recoveryByID[entry.metadata.id] = nil
  }
  func remove(_ entry: UnresolvedSessionEntry) async throws {
    let id = entry.metadata.id
    let operation: PendingRemoval
    if let existing = removals[id] {
      operation = existing
    } else {
      let hasRecovery = recoveryIDs.contains(id)
      let cleanup = removeRecovery
      operation = PendingRemoval(task: Task { if hasRecovery { try await cleanup(id) } })
      removals[id] = operation
    }
    do {
      try await operation.task.value
      finishRemoval(id: id, token: operation.token)
    } catch {
      if removals[id]?.token == operation.token {
        removals[id] = nil
        if let index = unresolved.firstIndex(where: { $0.metadata.id == id }) {
          unresolved[index].errorMessage = error.localizedDescription
        }
      }
      throw error
    }
  }
  private func finishRemoval(id: UUID, token: UUID) {
    guard removals[id]?.token == token else { return }
    unresolved.removeAll { $0.metadata.id == id }
    recoveryIDs.remove(id)
    recoveryByID[id] = nil
    removals[id] = nil
  }
  func drainPendingRemovals() async throws {
    // Re-read after each suspension: newly confirmed removals also precede this barrier.
    while let (id, operation) = removals.first {
      try await operation.task.value
      finishRemoval(id: id, token: operation.token)
    }
  }

  func recordRecentOpen(_ url: URL) throws {
    let path = url.standardizedFileURL.path
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4096,
      !path.utf8.contains(0)
    else { throw SessionStoreError.invalidMetadata }
    recentPaths = Self.uniqueRecentPaths([path] + recentPaths)
  }
  func removeRecent(_ path: String) { recentPaths.removeAll { $0 == path } }
  func clearRecent() { recentPaths.removeAll() }
  private static func uniqueRecentPaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return Array(paths.filter { seen.insert($0).inserted }.prefix(50))
  }

  func persist(windows: [SessionWindow]) async throws {
    try requireRestoredSession()
    try await drainPendingRemovals()
    try await saveSession(captureSession(windows: windows))
  }
  private func requireRestoredSession() throws {
    guard restorationComplete else {
      throw Self.error(
        "Session restoration has not completed. The previous session remains unchanged.")
    }
    if let preservationError { throw preservationError }
  }
  func captureSession(windows: [SessionWindow]) throws -> EditorSession {
    try requireRestoredSession()
    guard removals.isEmpty else {
      throw Self.error(
        "Recovery cleanup is still pending. Drain pending removals before capturing session metadata."
      )
    }
    var merged: [SessionWindow] = []
    var remaining = windows
    for original in originalWindows {
      let live = remaining.first { $0.id == original.id }
      remaining.removeAll { $0.id == original.id }
      let missing = unresolved.filter { $0.windowID == original.id }
      if live == nil && missing.isEmpty { continue }
      var tabs = live?.tabs ?? []
      for (index, tab) in original.tabs.enumerated()
      where missing.contains(where: { $0.metadata.id == tab.id }) {
        guard !tabs.contains(where: { $0.id == tab.id }) else {
          throw SessionRestorationError.duplicateID
        }
        tabs.insert(tab, at: min(index, tabs.count))
      }
      let preferred = live?.selectedTabID ?? original.selectedTabID
      merged.append(
        SessionWindow(
          id: original.id, tabs: tabs,
          selectedTabID: tabs.contains { $0.id == preferred } ? preferred : tabs.first?.id))
    }
    merged.append(contentsOf: remaining)
    return EditorSession(windows: merged, recentPaths: recentPaths)
  }
  private func preserve(_ error: Error) {
    preservationError = preservationError ?? error
    startupErrors.append(error.localizedDescription)
  }
  nonisolated private static func error(_ message: String) -> NSError {
    NSError(domain: "TheOnlyPad.Session", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  nonisolated static func read(_ metadata: SessionTab, at url: URL) throws -> SessionResolvedFile {
    let reader = try LargeFileReader(url: url)
    guard reader.identity.size <= 100_000_000 else {
      throw error(
        "This session file exceeds 100 MB. Use Open to view it, or locate a smaller file.")
    }
    var bytes = Data()
    bytes.reserveCapacity(Int(reader.identity.size))
    while bytes.count < reader.identity.size {
      try Task.checkCancellation()
      bytes.append(
        try reader.readWindow(
          offset: Int64(bytes.count),
          length: min(LargeFileReader.maximumWindowSize, Int(reader.identity.size) - bytes.count)))
    }
    _ = try reader.readWindow(offset: reader.identity.size, length: 0)
    let seed = try NativeDocumentSeed.restored(metadata, url: url, originalBytes: bytes)
    return SessionResolvedFile(seed: seed)
  }
}
