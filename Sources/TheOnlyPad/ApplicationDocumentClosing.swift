import Foundation
import PadCore

/// Process-owned orchestration. Only the recovery actor creates publication receipts.
/// Native admission and the single managed publisher must be wired before UI adoption.
@MainActor final class ApplicationDocumentClosing {
  private enum Resume {
    case newItem, repair, retire, projectClosed
    case projectRetained(DocumentClosingResult)
    case finish(DocumentClosingResult)
  }
  private final class Transaction {
    let handle: any WorkspaceDocumentHandle
    let request: DocumentCloseRequest
    var ticket: DocumentCloseTicket?
    var lease: RecoveryCloseLease?
    var deletion: RecoveryCloseReceipt?
    var attempt: DocumentRecoveryAttempt?
    var repair: RecoveryRepairReceipt?
    var failure: Error?
    init(handle: any WorkspaceDocumentHandle, request: DocumentCloseRequest) {
      self.handle = handle
      self.request = request
    }
  }
  private final class Batch {
    let id = DocumentClosingID(rawValue: UUID())
    let ids: [UUID]
    let sourceWindowID: UUID
    var endpointAvailable = true
    var index = 0
    var closed: [UUID] = []
    var transaction: Transaction?
    var pause: CheckpointPauseToken?
    var drained = false
    var cancelled = false
    var inFlight = false
    var stage = DocumentClosingStage.confirming
    var error: Error?
    var resume = Resume.newItem
    var task: Task<DocumentClosingResult, Never>?
    init(ids: [UUID], sourceWindowID: UUID) {
      self.ids = ids
      self.sourceWindowID = sourceWindowID
    }
  }
  private let registry: ApplicationDocuments
  private let recovery: RecoveryCoordinator
  private let publication: DocumentClosingPublication
  private let native: DocumentClosingNative
  private var active: Batch?
  private var last: (DocumentClosingStatus, DocumentClosingResult)?
  var onChange: (() -> Void)?

  init(
    registry: ApplicationDocuments, recovery: RecoveryCoordinator,
    publication: DocumentClosingPublication, native: DocumentClosingNative
  ) {
    self.registry = registry
    self.recovery = recovery
    self.publication = publication
    self.native = native
  }
  var status: DocumentClosingStatus? {
    guard let batch = active else { return last?.0 }
    return snapshot(batch)
  }
  var hasUnsettledTransactions: Bool { active != nil }
  private func snapshot(_ batch: Batch) -> DocumentClosingStatus {
    .init(
      id: batch.id, documentID: batch.transaction?.request.documentID,
      stage: batch.stage, recoveryPaused: batch.pause != nil, error: batch.error)
  }
  func start(documentIDs: [UUID], sourceWindowID: UUID) throws -> DocumentClosingID {
    guard active == nil else { throw DocumentClosingError.busy }
    guard !documentIDs.isEmpty, documentIDs.count <= 128,
      Set(documentIDs).count == documentIDs.count
    else {
      throw DocumentClosingError.invalidRequest
    }
    let batch = Batch(ids: documentIDs, sourceWindowID: sourceWindowID)
    active = batch  // Before any collaborator can synchronously reenter.
    do { try publication.requireApplicationAdmission() } catch {
      active = nil
      throw error
    }
    launch(batch)
    return batch.id
  }
  func wait(for id: DocumentClosingID) async throws -> DocumentClosingResult {
    if let batch = active, batch.id == id, let task = batch.task { return await task.value }
    if let last, last.0.id == id { return last.1 }
    throw DocumentClosingError.expiredResult
  }
  func retry(_ id: DocumentClosingID) throws {
    guard let batch = active, batch.id == id else { throw DocumentClosingError.expiredResult }
    guard !batch.inFlight, batch.stage == .failed else { throw DocumentClosingError.busy }
    launch(batch)
  }
  func cancelBeforeAdmission(_ id: DocumentClosingID) throws {
    guard let batch = active, batch.id == id else { throw DocumentClosingError.expiredResult }
    // A nil ticket is not safe: beginClose installs its lease before returning through onChange.
    guard batch.stage == .confirming, batch.transaction?.ticket == nil else {
      throw DocumentClosingError.cancellationUnavailable
    }
    batch.cancelled = true
  }
  func requireSettledForFinalCheckpoint() throws {
    guard active == nil else { throw DocumentClosingError.pendingRecovery }
  }
  func requireCaptureAdmission() throws { try requireSettledForFinalCheckpoint() }
  func endpointDidClose(windowID: UUID) {
    if active?.sourceWindowID == windowID { active?.endpointAvailable = false }
  }
  private func launch(_ batch: Batch) {
    batch.inFlight = true
    batch.error = nil
    batch.task = Task { await self.execute(batch) }
  }
  private func stage(_ value: DocumentClosingStage, _ batch: Batch) {
    batch.stage = value
    onChange?()
  }
  private func requireOwned(_ transaction: Transaction) throws {
    guard registry.handle(id: transaction.request.documentID) === transaction.handle,
      registry.assignment(of: transaction.request.documentID) == transaction.request.assignment
    else {
      throw DocumentClosingError.ownershipChanged
    }
  }
  private func requireState(_ transaction: Transaction) throws {
    try requireOwned(transaction)
    guard try native.readState(transaction.handle) == transaction.request.state else {
      throw DocumentClosingError.staleState
    }
  }
  private func retained(_ batch: Batch, error: Error) -> DocumentClosingResult {
    .retained(
      closedIDs: batch.closed,
      documentID: batch.transaction?.request.documentID
        ?? batch.ids[min(batch.index, batch.ids.count - 1)],
      error: error)
  }
  private func execute(_ batch: Batch) async -> DocumentClosingResult {
    while true {
      do {
        switch batch.resume {
        case .newItem: try await newItem(batch)
        case .repair: try await repair(batch)
        case .retire: try await retire(batch)
        case .projectClosed:
          stage(.projecting, batch)
          try native.projectRegistry()
          let id = batch.transaction!.request.documentID
          batch.closed.append(id)
          batch.index += 1
          batch.transaction = nil
          batch.resume = .newItem
        case .projectRetained(let result):
          stage(.projecting, batch)
          if let transaction = batch.transaction {
            try requireOwned(transaction)
            try native.applyAdmission(transaction.handle)
          }
          try native.projectRegistry()
          batch.resume = .finish(result)
        case .finish(let result): return try await finish(batch, result: result)
        }
      } catch {
        switch batch.resume {
        case .newItem:
          if let transaction = batch.transaction, let ticket = transaction.ticket {
            transaction.failure = error
            if transaction.lease != nil {
              do {
                _ = try registry.completeClose(ticket, result: .uncertain(error))
                batch.resume = .repair
              } catch { return fail(batch, error: error) }
              return fail(batch, error: error)
            }
            do { _ = try registry.completeClose(ticket, result: .notRemoved(error)) } catch {
              return fail(batch, error: error)
            }
          }
          batch.resume = .projectRetained(retained(batch, error: error))
        case .repair:
          if let transaction = batch.transaction, let attempt = transaction.attempt,
            registry.closeStatus(documentID: attempt.documentID)
              == .repairing(repairID: attempt.repairID, attemptID: attempt.id)
          {
            do { _ = try registry.completeRecoveryRepair(attempt, result: .failure(error)) } catch {
              return fail(batch, error: error)
            }
            transaction.attempt = nil
          }
          return fail(batch, error: error)
        default: return fail(batch, error: error)
        }
      }
    }
  }
  private func fail(_ batch: Batch, error: Error) -> DocumentClosingResult {
    let result = retained(batch, error: error)
    batch.error = error
    batch.stage = .failed
    batch.inFlight = false
    onChange?()  // No cleanup after this callback: it may start the next explicit retry.
    return result
  }
  private func newItem(_ batch: Batch) async throws {
    if batch.cancelled {
      batch.resume = .finish(.cancelled(closedIDs: batch.closed))
      return
    }
    guard batch.index < batch.ids.count else {
      batch.resume = .finish(.completed(closedIDs: batch.closed))
      return
    }
    let id = batch.ids[batch.index]
    guard let handle = registry.handle(id: id), handle.workspaceKind == .editable else {
      throw DocumentClosingError.unsupportedKind
    }
    let request = try registry.requestClose(documentID: id)
    let transaction = Transaction(handle: handle, request: request)
    batch.transaction = transaction
    stage(.confirming, batch)
    guard !batch.cancelled, batch.endpointAvailable else {
      batch.resume = .finish(.cancelled(closedIDs: batch.closed))
      return
    }
    let disposition = try await native.confirm(request, batch.sourceWindowID)
    guard !batch.cancelled, batch.endpointAvailable, let disposition else {
      batch.resume = .finish(.cancelled(closedIDs: batch.closed))
      return
    }
    stage(.acquiring, batch)
    try publication.requireApplicationAdmission()
    if batch.pause == nil { batch.pause = try publication.acquirePause() }
    stage(.admitting, batch)
    transaction.ticket = try registry.beginClose(request, disposition: disposition)
    try native.applyAdmission(handle)
    stage(.draining, batch)
    if !batch.drained {
      try await publication.drainPause(batch.pause!)
      batch.drained = true
    }
    try await native.drainLegacyWrites(handle)
    try requireState(transaction)
    stage(.preflighting, batch)
    let capture = try native.capture(handle)
    guard capture.state == request.state, capture.snapshot.id == id,
      capture.authority.documentID == id
    else { throw DocumentClosingError.staleState }
    try await recovery.preflightRepair(authority: capture.authority, snapshot: capture.snapshot)
    try requireState(transaction)
    stage(.preparing, batch)
    let lease = try await recovery.prepareClose(
      authority: capture.authority,
      minimumRevision: capture.highestIssuedRevision, registryTicketID: transaction.ticket!.id)
    transaction.lease = lease
    try requireState(transaction)
    stage(.deleting, batch)
    let receipt = try await recovery.finalizeClose(lease)
    transaction.deletion = receipt
    guard receipt.lease == lease else { throw DocumentClosingError.staleState }
    stage(.registrySettlement, batch)
    switch try registry.completeClose(transaction.ticket!, result: .removed) {
    case .closed: batch.resume = .retire
    case .recoveryRequired(let error):
      transaction.failure = error ?? DocumentClosingError.staleState
      batch.resume = .repair
      throw transaction.failure!
    case .retained(let error): throw error
    }
  }
  private func retire(_ batch: Batch) async throws {
    let transaction = batch.transaction!
    stage(.retiring, batch)
    try await recovery.retireClose(transaction.deletion!)
    batch.resume = .projectClosed
  }
  private func repair(_ batch: Batch) async throws {
    let transaction = batch.transaction!
    try requireOwned(transaction)
    if let prior = transaction.repair {
      stage(.needsFreshLease, batch)
      let lease = try await recovery.prepareClose(
        authority: prior.authority,
        minimumRevision: prior.nextRevision - 1, registryTicketID: transaction.ticket!.id)
      transaction.lease = lease
      transaction.repair = nil
      transaction.deletion = nil
    }
    stage(.capturingRepair, batch)
    let attempt = try registry.beginRecoveryRepair(documentID: transaction.request.documentID)
    transaction.attempt = attempt
    let capture = try native.capture(transaction.handle)
    guard capture.state == attempt.state, capture.snapshot.id == attempt.documentID else {
      throw DocumentClosingError.staleState
    }
    stage(.repairing, batch)
    let receipt = try await recovery.restoreAfterClose(
      transaction.lease!, attemptID: attempt.id,
      mutationGeneration: attempt.state.mutationGeneration, snapshot: capture.snapshot)
    transaction.repair = receipt  // Actor epoch is already new, even if native acceptance fails.
    guard receipt.lease == transaction.lease, receipt.attemptID == attempt.id,
      receipt.mutationGeneration == attempt.state.mutationGeneration,
      receipt.authority.documentID == attempt.documentID
    else { throw DocumentClosingError.staleState }
    stage(.installingRepair, batch)
    try requireOwned(transaction)
    try native.installRepair(transaction.handle, attempt, receipt)
    let accepted = try registry.completeRecoveryRepair(
      attempt,
      result: .success(
        .init(
          attemptID: attempt.id, repairID: attempt.repairID, documentID: attempt.documentID,
          mutationGeneration: receipt.mutationGeneration, publicationID: receipt.publicationID)))
    transaction.attempt = nil
    guard accepted, registry.closeStatus(documentID: attempt.documentID) == .open else {
      throw DocumentClosingError.staleState
    }
    batch.resume = .projectRetained(
      retained(batch, error: transaction.failure ?? DocumentClosingError.staleState))
  }
  private func finish(_ batch: Batch, result: DocumentClosingResult) async throws
    -> DocumentClosingResult
  {
    if let token = batch.pause {
      if !batch.drained {
        stage(.drainingUnusedPause, batch)
        try await publication.drainPause(token)
        batch.drained = true
      }
      try publication.releasePause(token)
      batch.pause = nil
    }
    batch.stage = .settled
    batch.inFlight = false
    last = (snapshot(batch), result)
    active = nil
    publication.requestCheckpoint()
    onChange?()
    return result
  }
}
