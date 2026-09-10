import Foundation

/// Process transfer owner. Implemented against behavioral tests before native composition.
@MainActor final class ApplicationDocumentTransfer {
  private enum Resume { case move, rollback, settleMoved, settleRestored, cleanup }
  private final class Transaction {
    let id = ApplicationDocumentTransferID(rawValue: UUID())
    let request: DocumentTransferRequest
    var lease: DocumentTransferLease?
    var pause: CheckpointPauseToken?
    var receipt: (any ApplicationDocumentTransferReceipt)?
    var task: Task<ApplicationDocumentTransferResult, Never>?
    var result: ApplicationDocumentTransferResult?
    var outcome: ApplicationDocumentTransferResult?
    var failure: Error?
    var resume = Resume.move
    var inFlight = false
    var drained = false
    var monitorSuspended = false
    var monitorFinished = false
    init(_ request: DocumentTransferRequest) { self.request = request }
  }
  private let registry: ApplicationDocuments
  private let publication: ApplicationDocumentTransferPublication
  private let native: ApplicationDocumentTransferNative
  private var active: Transaction?
  private var last: (ApplicationDocumentTransferID, ApplicationDocumentTransferResult)?
  init(
    registry: ApplicationDocuments, publication: ApplicationDocumentTransferPublication,
    native: ApplicationDocumentTransferNative
  ) {
    self.registry = registry
    self.publication = publication
    self.native = native
  }
  func start(_ request: DocumentTransferRequest) throws -> ApplicationDocumentTransferID {
    guard active == nil else { throw ApplicationDocumentTransferError.busy }
    let transaction = Transaction(request)
    active = transaction
    do { try publication.requireAdmission() } catch {
      active = nil
      throw error
    }
    launch(transaction)
    return transaction.id
  }
  func wait(for id: ApplicationDocumentTransferID) async throws -> ApplicationDocumentTransferResult
  {
    if let value = active, value.id == id, let task = value.task { return await task.value }
    if let last, last.0 == id { return last.1 }
    throw ApplicationDocumentTransferError.expired
  }
  func retryLayout(_ id: ApplicationDocumentTransferID) throws {
    guard let value = active, value.id == id else { throw ApplicationDocumentTransferError.expired }
    guard !value.inFlight else { throw ApplicationDocumentTransferError.busy }
    launch(value)
  }
  private func launch(_ value: Transaction) {
    value.inFlight = true
    value.task = Task { await self.execute(value) }
  }
  var allowsNativeAdmission: Bool {
    guard let value = active else { return true }
    return value.lease == nil && value.pause == nil && value.outcome != nil
  }
  func requireSettled() throws {
    guard active == nil else { throw ApplicationDocumentTransferError.pendingLayout }
  }
  private func execute(_ value: Transaction) async -> ApplicationDocumentTransferResult {
    defer { value.inFlight = false }
    while true {
      do {
        switch value.resume {
        case .move: try await move(value)
        case .rollback: try rollback(value)
        case .settleMoved: try settle(value, moved: true)
        case .settleRestored: try settle(value, moved: false)
        case .cleanup: return try await cleanup(value)
        }
      } catch {
        if value.failure == nil { value.failure = error }
        if let lease = value.lease { try? registry.retainTransferFailure(lease, error: error) }
        if value.resume == .move {
          value.resume = .rollback
          continue
        }
        let result = ApplicationDocumentTransferResult.retained(error)
        value.result = result
        return result
      }
    }
  }
  private func move(_ value: Transaction) async throws {
    let lease = try registry.reserveTransfer(value.request)
    value.lease = lease
    let pause = try publication.acquirePause()
    value.pause = pause
    try await publication.drainPause(pause)
    value.drained = true
    let original = try registry.validateTransferSnapshot(lease)
    let receipt = try native.capture(original)
    value.receipt = receipt
    try native.validate(original, receipt)
    value.monitorSuspended = true  // Native phase may change before a throwing callback.
    try native.suspendMonitor(original, receipt)
    try registry.stageTransfer(lease)
    var snapshot = try registry.validateTransferSnapshot(lease)
    try native.projectSource(snapshot, receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.projectTarget(snapshot, receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.validate(snapshot, receipt)
    try native.attachMonitor(snapshot, receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.validate(snapshot, receipt)
    try native.finishMonitor(snapshot, receipt)
    value.monitorFinished = true
    value.resume = .settleMoved
  }

  private func rollback(_ value: Transaction) throws {
    let failure = value.failure ?? ApplicationDocumentTransferError.pendingLayout
    guard let lease = value.lease else {
      value.outcome = .restored(failure)
      value.resume = .cleanup
      return
    }
    let diagnostic = try registry.transferSnapshot(lease)
    guard !diagnostic.requiresReconciliation else {
      throw ApplicationDocumentTransferError.pendingLayout
    }
    if !diagnostic.effectsStarted {
      if let receipt = value.receipt, value.monitorSuspended {
        let snapshot = try registry.validateTransferSnapshot(lease)
        try native.suspendMonitor(snapshot, receipt)
        try native.attachMonitor(snapshot, receipt)
        try native.finishMonitor(snapshot, receipt)
        value.monitorFinished = true
      }
      try registry.cancelUnstagedTransfer(lease)
      value.lease = nil
      value.outcome = .restored(failure)
      value.resume = .cleanup
      return
    }
    guard let receipt = value.receipt, !value.monitorFinished else {
      throw ApplicationDocumentTransferError.pendingLayout
    }
    var snapshot = try registry.validateTransferSnapshot(lease)
    if snapshot.phase == .staged || snapshot.phase == .rotated {
      try native.suspendMonitor(snapshot, receipt)
      try registry.restoreTransferAssignment(lease)
      snapshot = try registry.validateTransferSnapshot(lease)
    } else if snapshot.phase == .restored {
      // A previous rollback may have attached successfully before finish refused.
      // Retire that attachment explicitly before repeating either endpoint projection.
      try native.suspendMonitor(snapshot, receipt)
    }
    guard snapshot.phase == .restored else { throw ApplicationDocumentTransferError.pendingLayout }
    // Attempt both restorations; one endpoint failure cannot prevent the other's repair.
    var projectionFailure: Error?
    do { try native.projectSource(snapshot, receipt) } catch { projectionFailure = error }
    do {
      snapshot = try registry.validateTransferSnapshot(lease)
      try native.projectTarget(snapshot, receipt)
    } catch { if projectionFailure == nil { projectionFailure = error } }
    if let projectionFailure { throw projectionFailure }
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.validate(snapshot, receipt)
    try native.attachMonitor(snapshot, receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.finishMonitor(snapshot, receipt)
    value.monitorFinished = true
    value.resume = .settleRestored
  }
  private func settle(_ value: Transaction, moved: Bool) throws {
    guard let lease = value.lease else { throw ApplicationDocumentTransferError.pendingLayout }
    let result: ApplicationDocumentTransferResult =
      moved
      ? .moved : .restored(value.failure ?? ApplicationDocumentTransferError.pendingLayout)
    let willNotify = {
      value.outcome = result
      value.lease = nil
      value.resume = .cleanup
    }
    if moved {
      try registry.completeTransfer(lease, willNotify: willNotify)
    } else {
      try registry.settleRestoredTransfer(lease, willNotify: willNotify)
    }
  }

  private func cleanup(_ value: Transaction) async throws -> ApplicationDocumentTransferResult {
    guard let result = value.outcome else { throw ApplicationDocumentTransferError.pendingLayout }
    if let pause = value.pause {
      if !value.drained {
        try await publication.drainPause(pause)
        value.drained = true
      }
      try publication.releasePause(pause)
      value.pause = nil
    }
    if let receipt = value.receipt { try native.refreshAdmission(receipt) }
    value.result = result
    last = (value.id, result)
    active = nil
    publication.requestCheckpoint()
    // No cleanup after callbacks: a new transaction may already own active.
    return result
  }
}
