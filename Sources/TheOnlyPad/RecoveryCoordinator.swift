import Foundation
import PadCore

struct RecoveryCheckpointItem: Sendable {
  let id: UUID
  let revision: UInt64
  let snapshot: RecoverySnapshot?
  let authority: RecoveryWriteAuthority?
  init(
    id: UUID, revision: UInt64, snapshot: RecoverySnapshot?,
    authority: RecoveryWriteAuthority? = nil
  ) {
    self.id = id
    self.revision = revision
    self.snapshot = snapshot
    self.authority = authority
  }
}
struct SessionCheckpointCapture: Sendable {
  let generation: UInt64
  let liveTabIDs: Set<UUID>
  let recovery: [RecoveryCheckpointItem]
  let session: EditorSession
}
struct SessionCheckpointReceipt: Sendable {
  let generation: UInt64
  let recoveryRevisions: [UUID: UInt64]
  let recoveryAuthorities: [UUID: RecoveryWriteAuthority]
  init(
    generation: UInt64, recoveryRevisions: [UUID: UInt64],
    recoveryAuthorities: [UUID: RecoveryWriteAuthority] = [:]
  ) {
    self.generation = generation
    self.recoveryRevisions = recoveryRevisions
    self.recoveryAuthorities = recoveryAuthorities
  }
}
enum CheckpointFailure: Error, Equatable {
  case superseded, closedDocument, publicationUncertain
}

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
  private let saveCheckpointSession: @Sendable (EditorSession) throws -> Void
  private var checkpointGeneration: UInt64 = 0
  private let readCheckpointSession: @Sendable () throws -> EditorSession?
  private var uncertainSession: EditorSession?
  private let removeRecovery: @Sendable (RecoveryStore, UUID) throws -> RecoveryRemovalReceipt
  private let saveRecovery: @Sendable (RecoveryStore, RecoverySnapshot) throws -> Void
  private var uncertainPublication: (snapshot: RecoverySnapshot, evidence: FilePublicationEvidence)?
  private var capacityKnown = false
  private var startupReport: RecoveryLoadReport?
  private var snapshotUnits: [UUID: Int] = [:]
  private var revisions: [UUID: UInt64] = [:]
  private var closed: Set<UUID> = []

  init(
    directory: URL, limits: RecoveryLimits = RecoveryLimits(),
    removeRecovery: @escaping @Sendable (RecoveryStore, UUID) throws -> RecoveryRemovalReceipt = {
      try $0.removeChecked(id: $1)
    },
    saveRecovery: @escaping @Sendable (RecoveryStore, RecoverySnapshot) throws -> Void = {
      try $0.save($1)
    },
    saveCheckpointSession: @escaping @Sendable (EditorSession) throws -> Void = {
      try SessionStore().save($0)
    },
    readCheckpointSession: @escaping @Sendable () throws -> EditorSession? = {
      try SessionStore().load()
    }
  ) {
    self.directory = directory
    self.limits = limits
    self.saveRecovery = saveRecovery
    self.removeRecovery = removeRecovery
    self.saveCheckpointSession = saveCheckpointSession
    self.readCheckpointSession = readCheckpointSession
  }

  private let coordinatorID = UUID()
  private enum ManagedPhase {
    case open
    case prepared(RecoveryCloseLease)
    case finalized(RecoveryCloseReceipt)
    case retired(RecoveryCloseReceipt)
  }
  private struct Managed {
    var authority: RecoveryWriteAuthority
    var phase: ManagedPhase
  }
  private var managed: [UUID: Managed] = [:]
  private var removalUncertainties: [UUID: RecoveryRemovalEvidence] = [:]
  private var repairPublished = Set<UUID>()
  private var confirmedRemovals: [UUID: RecoveryRemovalReceipt] = [:]

  func preflightRepair(authority: RecoveryWriteAuthority, snapshot: RecoverySnapshot) throws {
    guard let owner = managed[authority.documentID], owner.authority == authority,
      case .open = owner.phase, snapshot.id == authority.documentID
    else {
      throw RecoveryAuthorityError.invalidAuthority
    }
    guard uncertainSession == nil, uncertainPublication == nil, removalUncertainties.isEmpty else {
      throw RecoveryAuthorityError.uncertainty
    }
    let store = try storage()
    try store.preflightSave(snapshot)
    let report = try store.loadReport(quarantineInvalid: false)
    let others = report.snapshots.reduce(0) {
      $0 + ($1.id == snapshot.id ? 0 : $1.text.utf16.count)
    }
    guard snapshot.text.utf16.count <= limits.maximumRestoredUTF16 - others,
      report.snapshots.contains(where: { $0.id == snapshot.id })
        || report.snapshots.count < limits.maximumSnapshots
    else {
      throw RecoveryError.resourceLimit
    }
  }
  func adoptManagedDocument(id: UUID) throws -> RecoveryAdoptionReceipt {
    guard managed[id] == nil else { throw RecoveryAuthorityError.alreadyManaged }
    guard !closed.contains(id) else { throw RecoveryAuthorityError.closed }
    guard uncertainSession == nil, uncertainPublication == nil, removalUncertainties.isEmpty else {
      throw RecoveryAuthorityError.uncertainty
    }
    let authority = RecoveryWriteAuthority(
      coordinatorID: coordinatorID, documentID: id, epoch: UUID())
    managed[id] = Managed(authority: authority, phase: .open)
    revisions[id] = 0
    return RecoveryAdoptionReceipt(authority: authority, nextRevision: 1)
  }
  private func validateAuthorized(_ items: [AuthorizedRecoveryItem]) throws {
    guard items.count <= 4096 else { throw RecoveryError.resourceLimit }
    var ids = Set<UUID>()
    for item in items {
      let id = item.authority.documentID
      guard ids.insert(id).inserted, item.snapshot == nil || item.snapshot?.id == id else {
        throw RecoveryError.invalidSnapshot
      }
      guard let owner = managed[id], owner.authority == item.authority,
        case .open = owner.phase
      else { throw RecoveryAuthorityError.invalidAuthority }
      guard item.revision > revisions[id, default: 0] else {
        throw RecoveryAuthorityError.staleRevision
      }
    }
  }
  func persistAuthorized(_ item: AuthorizedRecoveryItem) throws {
    try persistAuthorizedBatch([item])
  }
  func persistAuthorizedBatch(_ items: [AuthorizedRecoveryItem]) throws {
    try validateAuthorized(items)
    try persistBatchImpl(items.map { ($0.authority.documentID, $0.revision, $0.snapshot) })
  }
  func prepareClose(
    authority: RecoveryWriteAuthority, minimumRevision: UInt64, registryTicketID: UUID
  ) throws -> RecoveryCloseLease {
    guard let owner = managed[authority.documentID], owner.authority == authority,
      case .open = owner.phase
    else { throw RecoveryAuthorityError.invalidAuthority }
    guard minimumRevision >= revisions[authority.documentID, default: 0] else {
      throw RecoveryAuthorityError.staleRevision
    }
    guard uncertainSession == nil, uncertainPublication == nil, removalUncertainties.isEmpty else {
      throw RecoveryAuthorityError.uncertainty
    }
    let lease = RecoveryCloseLease(
      authority: authority, transactionID: UUID(), registryTicketID: registryTicketID)
    managed[authority.documentID]?.phase = .prepared(lease)
    revisions[authority.documentID] = minimumRevision
    return lease
  }
  private func requireLease(_ lease: RecoveryCloseLease) throws {
    guard let owner = managed[lease.authority.documentID], owner.authority == lease.authority else {
      throw RecoveryAuthorityError.invalidLease
    }
    switch owner.phase {
    case .prepared(let current) where current == lease: return
    case .finalized(let receipt) where receipt.lease == lease: return
    default: throw RecoveryAuthorityError.invalidLease
    }
  }
  func finalizeClose(_ lease: RecoveryCloseLease) throws -> RecoveryCloseReceipt {
    try requireLease(lease)
    guard uncertainPublication == nil, uncertainSession == nil else {
      throw RecoveryAuthorityError.uncertainty
    }
    let id = lease.authority.documentID
    if case .finalized(let receipt) = managed[id]!.phase { return receipt }
    do {
      let removal: RecoveryRemovalReceipt
      if let evidence = removalUncertainties[id] {
        removal = try storage().finishCheckedRemoval(evidence)
      } else {
        removal = try removeRecovery(storage(), id)
      }
      removalUncertainties[id] = nil
      confirmedRemovals[id] = removal
      repairPublished.remove(id)
      removedFromCapacity(id)
      let receipt = RecoveryCloseReceipt(lease: lease, deletionID: UUID())
      managed[id]?.phase = .finalized(receipt)
      return receipt
    } catch {
      if case RecoveryRemovalError.uncertain(let evidence) = error {
        removalUncertainties[id] = evidence
      }
      capacityKnown = false
      startupReport = nil
      throw error
    }
  }
  func retireClose(_ receipt: RecoveryCloseReceipt) throws {
    let id = receipt.lease.authority.documentID
    guard let owner = managed[id], owner.authority == receipt.lease.authority else {
      throw RecoveryAuthorityError.invalidLease
    }
    switch owner.phase {
    case .finalized(let expected) where expected == receipt:
      managed[id]?.phase = .retired(receipt)
      confirmedRemovals[id] = nil
      closed.insert(id)
    case .retired(let expected) where expected == receipt: return
    default: throw RecoveryAuthorityError.invalidLease
    }
  }
  func restoreAfterClose(
    _ lease: RecoveryCloseLease, attemptID: UUID, mutationGeneration: UUID,
    snapshot: RecoverySnapshot
  ) throws -> RecoveryRepairReceipt {
    try requireLease(lease)
    let id = lease.authority.documentID
    guard snapshot.id == id else { throw RecoveryError.invalidSnapshot }
    // A repair attempt invalidates the old deletion receipt before any possible publication.
    managed[id]?.phase = .prepared(lease)
    if let evidence = removalUncertainties[id] {
      confirmedRemovals[id] = try storage().finishCheckedRemoval(evidence)
      removalUncertainties[id] = nil
      removedFromCapacity(id)
      capacityKnown = false
    }
    // A prior attempted repair may now be the canonical file. Validate that exact publication
    // and its original parent before dropping the old absence requirement; still save afresh.
    let removal = confirmedRemovals[id]
    if let removal { try storage().validateRepairParent(removal) }
    try initializeCapacity()
    let count = snapshot.text.utf16.count
    let others = snapshotUnits.reduce(0) { $0 + ($1.key == id ? 0 : $1.value) }
    guard count <= limits.maximumRestoredUTF16 - others,
      snapshotUnits[id] != nil || snapshotUnits.count < limits.maximumSnapshots
    else {
      throw RecoveryError.resourceLimit
    }
    do {
      if let removal = confirmedRemovals[id], !repairPublished.contains(id) {
        // Recheck exact parent and absence immediately before the new atomic publication.
        _ = try storage().finishCheckedRemoval(removal.evidence)
      }
      try saveRecovery(storage(), snapshot)
      // Keep transaction-local publication progress even if a later acceptance check fails.
      repairPublished.insert(id)
      if let removal { try storage().validateRepairParent(removal) }
    } catch {
      if case FileStoreError.publicationUncertain(let evidence) = error {
        uncertainPublication = (snapshot, evidence)
      }
      capacityKnown = false
      startupReport = nil
      throw error
    }
    let authority = RecoveryWriteAuthority(
      coordinatorID: coordinatorID, documentID: id, epoch: UUID())
    managed[id] = Managed(authority: authority, phase: .open)
    revisions[id] = 1
    snapshotUnits[id] = count
    confirmedRemovals[id] = nil
    repairPublished.remove(id)
    if !startupClaimed {
      startupReport = nil
      capacityKnown = false
    }
    return RecoveryRepairReceipt(
      lease: lease, attemptID: attemptID, mutationGeneration: mutationGeneration,
      publicationID: UUID(), authority: authority, nextRevision: 2)
  }
  func commitAuthorizedSessionCheckpoint(_ capture: SessionCheckpointCapture) throws
    -> SessionCheckpointReceipt
  {
    let items = try capture.recovery.map { item -> AuthorizedRecoveryItem in
      guard let authority = item.authority, authority.documentID == item.id else {
        throw RecoveryAuthorityError.authorityRequired
      }
      return AuthorizedRecoveryItem(
        authority: authority, revision: item.revision, snapshot: item.snapshot)
    }
    try validateAuthorized(items)
    return try commitCheckpoint(capture, authorized: true)
  }

  /// Serial publication boundary: no suspension is permitted between admission and receipt.
  /// Recovery files and Session.json remain separate filesystem publications, not a transaction.
  func commitSessionCheckpoint(_ capture: SessionCheckpointCapture) throws
    -> SessionCheckpointReceipt
  {
    guard capture.recovery.allSatisfy({ managed[$0.id] == nil && $0.authority == nil }) else {
      throw RecoveryAuthorityError.authorityRequired
    }
    return try commitCheckpoint(capture, authorized: false)
  }
  private func commitCheckpoint(_ capture: SessionCheckpointCapture, authorized: Bool) throws
    -> SessionCheckpointReceipt
  {
    guard uncertainSession == nil else { throw CheckpointFailure.publicationUncertain }
    guard capture.generation > checkpointGeneration else { throw CheckpointFailure.superseded }
    guard capture.recovery.count <= 128 else { throw RecoveryError.resourceLimit }
    let tabs = capture.session.windows.flatMap(\.tabs)
    let tabIDs = Set(tabs.map(\.id))
    guard tabIDs.count == tabs.count, capture.liveTabIDs.isSubset(of: tabIDs),
      Set(capture.recovery.map(\.id)) == capture.liveTabIDs,
      capture.recovery.count == capture.liveTabIDs.count
    else { throw RecoveryError.invalidSnapshot }
    let scratchIDs = Set(tabs.filter { $0.originalPath == nil }.map(\.id))
    var admitted: [UUID: UInt64] = [:]
    for item in capture.recovery {
      guard admitted[item.id] == nil, tabIDs.contains(item.id),
        item.snapshot == nil || item.snapshot?.id == item.id,
        !scratchIDs.contains(item.id) || item.snapshot != nil
      else { throw RecoveryError.invalidSnapshot }
      guard !closed.contains(item.id) else { throw CheckpointFailure.closedDocument }
      // Legacy persist accepts equal revisions with different contents. Checkpoints therefore
      // require a fresh capture revision rather than infer identity from an equal number.
      guard item.revision > revisions[item.id, default: 0] else {
        throw CheckpointFailure.superseded
      }
      admitted[item.id] = item.revision
    }
    // Reserve attempted generations too: a failed directory sync may follow publication.
    // Retrying requires a newly captured generation and fresh document revisions.
    checkpointGeneration = capture.generation
    try persistBatchImpl(capture.recovery.map { ($0.id, $0.revision, $0.snapshot) })
    for item in capture.recovery {
      guard !closed.contains(item.id), revisions[item.id] == item.revision else {
        throw CheckpointFailure.superseded
      }
    }
    do {
      try saveCheckpointSession(capture.session)
    } catch SessionStoreError.committedButNotSynced {
      uncertainSession = capture.session
      throw SessionStoreError.committedButNotSynced
    }
    return SessionCheckpointReceipt(
      generation: capture.generation, recoveryRevisions: admitted,
      recoveryAuthorities: authorized
        ? Dictionary(uniqueKeysWithValues: capture.recovery.map { ($0.id, $0.authority!) }) : [:])
  }

  /// Readback validates observed publication; it does not retroactively acknowledge durability.
  /// A new capture and successful save are still required for a checkpoint receipt.
  func validateUncertainCheckpoint() throws {
    guard let expected = uncertainSession else { return }
    guard let actual = try readCheckpointSession(), actual == expected else {
      throw CheckpointFailure.publicationUncertain
    }
    let expectedPaths =
      expected.windows.flatMap { $0.tabs.compactMap(\.originalPath) } + expected.recentPaths
    let actualPaths =
      actual.windows.flatMap { $0.tabs.compactMap(\.originalPath) } + actual.recentPaths
    guard zip(expectedPaths, actualPaths).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
      throw CheckpointFailure.publicationUncertain
    }
    uncertainSession = nil
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
    guard managed[snapshot.id] == nil else { throw RecoveryAuthorityError.authorityRequired }
    try persistImpl(snapshot, revision: revision)
  }
  private func persistImpl(_ snapshot: RecoverySnapshot, revision: UInt64) throws {
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
    do {
      try saveRecovery(storage(), snapshot)
    } catch FileStoreError.publicationUncertain(let evidence) {
      // Publication may already contain this newer revision. Reserve admission order without
      // calling the write successful; no later write may trust the old capacity cache.
      revisions[snapshot.id] = max(revision, revisions[snapshot.id, default: 0])
      uncertainPublication = (snapshot, evidence)
      capacityKnown = false
      startupReport = nil
      throw FileStoreError.publicationUncertain(evidence)
    }
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
    guard batch.allSatisfy({ managed[$0.0] == nil }) else {
      throw RecoveryAuthorityError.authorityRequired
    }
    try persistBatchImpl(batch)
  }
  private func persistBatchImpl(_ batch: [(UUID, UInt64, RecoverySnapshot?)]) throws {
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
      do { try clearImpl(id: item.key, revision: item.value.revision) } catch {
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
          try persistImpl(item.value.snapshot!, revision: item.value.revision)
          progress = true
        } catch { failures.append((item.value.snapshot!, item.value.revision, error)) }
      }
      // Text size and escaped JSON size can move in opposite directions. Retry quota failures
      // once after other writes have released space, without an unbounded retry loop.
      var unresolved: Error?
      for failure in failures {
        if progress, failure.error as? RecoveryError == .resourceLimit {
          do { try persistImpl(failure.snapshot, revision: failure.revision) } catch {
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
    guard managed[id] == nil else { throw RecoveryAuthorityError.authorityRequired }
    try clearImpl(id: id, revision: revision)
  }
  private func clearImpl(id: UUID, revision: UInt64) throws {
    guard !closed.contains(id), revision >= revisions[id, default: 0] else { return }
    if managed[id] != nil {
      do {
        if let evidence = removalUncertainties[id] {
          _ = try storage().finishCheckedRemoval(evidence)
        } else {
          _ = try removeRecovery(storage(), id)
        }
        removalUncertainties[id] = nil
      } catch {
        revisions[id] = revision
        if case RecoveryRemovalError.uncertain(let evidence) = error {
          removalUncertainties[id] = evidence
        }
        capacityKnown = false
        startupReport = nil
        throw error
      }
    } else {
      try storage().remove(id: id)
    }
    removedFromCapacity(id)
    revisions[id] = revision
  }

  func close(id: UUID) throws {
    guard managed[id] == nil else { throw RecoveryAuthorityError.authorityRequired }
    closed.insert(id)
    try storage().remove(id: id)
    removedFromCapacity(id)
  }
  private func initializeCapacity() throws {
    guard removalUncertainties.isEmpty else { throw RecoveryAuthorityError.uncertainty }
    guard !capacityKnown else { return }
    if let pending = uncertainPublication {
      try storage().validatePublication(pending.evidence, snapshot: pending.snapshot)
      // Any caller can validate this global uncertainty. Preserve the close transaction's
      // publication progress before clearing global evidence, without issuing a repair receipt.
      if case .prepared = managed[pending.snapshot.id]?.phase {
        repairPublished.insert(pending.snapshot.id)
      }
    }
    let report = try storage().loadReport()
    snapshotUnits = Dictionary(
      uniqueKeysWithValues: report.snapshots.map { ($0.id, $0.text.utf16.count) })
    startupReport = startupClaimed ? nil : report
    capacityKnown = true
    uncertainPublication = nil
  }
  private func removedFromCapacity(_ id: UUID) {
    // Called only after successful removal. Failed cleanup must retain the admission block.
    if uncertainPublication?.snapshot.id == id {
      uncertainPublication = nil
      capacityKnown = false
      startupReport = nil
    }
    snapshotUnits.removeValue(forKey: id)
    if !startupClaimed, let report = startupReport {
      startupReport = RecoveryLoadReport(
        snapshots: report.snapshots.filter { $0.id != id },
        quarantinedCount: report.quarantinedCount)
    }
  }
}
