import Foundation

/// Process transfer owner. Implemented against behavioral tests before native composition.
@MainActor final class ApplicationDocumentTransfer {
  private enum Resume { case move, rollback, settleMoved, settleRestored, cleanup }
  private final class Transaction {
    let id = ApplicationDocumentTransferID(rawValue: UUID())
    let request: DocumentTransferRequest
    var lease: DocumentTransferLease?
    var originalReservedLease: DocumentTransferLease?
    var macroSuspension: MacroTransferSuspension?
    var macroBindingFinished = false
    var pause: CheckpointPauseToken?
    var receipt: (any ApplicationDocumentTransferReceipt)?
    var task: Task<ApplicationDocumentTransferResult, Never>?
    var result: ApplicationDocumentTransferResult?
    var outcome: ApplicationDocumentTransferResult?
    var terminal: ApplicationDocumentTransferTerminalReceipt?
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
  private var last:
    (
      ApplicationDocumentTransferID, ApplicationDocumentTransferResult,
      ApplicationDocumentTransferTerminalReceipt
    )?
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
  func terminalReceipt(for id: ApplicationDocumentTransferID) throws
    -> ApplicationDocumentTransferTerminalReceipt
  {
    if let value = active, value.id == id, let terminal = value.terminal { return terminal }
    if let last, last.0 == id { return last.2 }
    throw ApplicationDocumentTransferError.expired
  }
  func retryLayout(_ id: ApplicationDocumentTransferID) throws {
    guard let value = active, value.id == id else { throw ApplicationDocumentTransferError.expired }
    guard !value.inFlight else { throw ApplicationDocumentTransferError.busy }
    launch(value)
  }
  /// Exact idle transaction status for endpoint repair before retry. Not projection authority.
  func retryLease(for id: ApplicationDocumentTransferID) throws -> DocumentTransferLease? {
    guard let value = active, value.id == id else { throw ApplicationDocumentTransferError.expired }
    guard !value.inFlight else { throw ApplicationDocumentTransferError.busy }
    return value.lease
  }
  private func launch(_ value: Transaction) {
    value.inFlight = true
    value.task = Task { await self.execute(value) }
  }
  var hasUnsettledTransactions: Bool { active != nil }
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
    value.originalReservedLease = lease
    let reserved = try registry.validateTransferSnapshot(lease)
    value.macroSuspension = try native.suspendMacroBinding(reserved)
    guard value.macroSuspension?.lease == lease,
      value.macroSuspension?.documentID == value.request.documentID
    else {
      throw ApplicationDocumentTransferError.pendingLayout
    }
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
      value.terminal = .init(
        request: value.request, workspaceRevision: value.request.workspaceRevision, moved: false)
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
        try projectEndpoints(try registry.validateTransferSnapshot(lease), receipt: receipt)
        try native.validate(try registry.validateTransferSnapshot(lease), receipt)
        try native.attachMonitor(try registry.validateTransferSnapshot(lease), receipt)
        try native.finishMonitor(try registry.validateTransferSnapshot(lease), receipt)
        value.monitorFinished = true
      }
      try registry.cancelUnstagedTransfer(lease)
      value.lease = nil
      value.outcome = .restored(failure)
      value.terminal = .init(
        request: value.request, workspaceRevision: value.request.workspaceRevision, moved: false)
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
    try projectEndpoints(snapshot, receipt: receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.validate(snapshot, receipt)
    try native.attachMonitor(snapshot, receipt)
    snapshot = try registry.validateTransferSnapshot(lease)
    try native.finishMonitor(snapshot, receipt)
    value.monitorFinished = true
    value.resume = .settleRestored
  }
  private func projectEndpoints(
    _ snapshot: DocumentTransferSnapshot, receipt: any ApplicationDocumentTransferReceipt
  ) throws {
    // Repair both presentations, even when cancellation occurred before ownership rotation.
    var failure: Error?
    do { try native.projectSource(snapshot, receipt) } catch { failure = error }
    do {
      let current = try registry.validateTransferSnapshot(snapshot.lease)
      try native.projectTarget(current, receipt)
    } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }
  private func settle(_ value: Transaction, moved: Bool) throws {
    guard let lease = value.lease else { throw ApplicationDocumentTransferError.pendingLayout }
    let result: ApplicationDocumentTransferResult =
      moved
      ? .moved : .restored(value.failure ?? ApplicationDocumentTransferError.pendingLayout)
    let willNotify = {
      value.terminal = .init(
        request: value.request, workspaceRevision: self.registry.workspaceRevision, moved: moved)
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
    guard let result = value.outcome, let terminal = value.terminal else {
      throw ApplicationDocumentTransferError.pendingLayout
    }
    if let pause = value.pause {
      if !value.drained {
        try await publication.drainPause(pause)
        value.drained = true
      }
      try publication.releasePause(pause)
      value.pause = nil
    }
    if let receipt = value.receipt { try native.refreshAdmission(receipt) }
    if let token = value.macroSuspension, !value.macroBindingFinished {
      guard value.originalReservedLease == token.lease, terminal.request == value.request,
        token.documentID == value.request.documentID, value.lease == nil, value.pause == nil
      else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      try native.finishMacroBinding(token, terminal, value.receipt)
      // Process owns this flag. Successful service cannot callback/throw after commit.
      value.macroBindingFinished = true
    }
    if let token = value.macroSuspension {
      guard value.macroBindingFinished, value.originalReservedLease == token.lease,
        terminal.request == value.request, token.documentID == value.request.documentID,
        value.lease == nil, value.pause == nil
      else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      // Separate callback-bearing phase. A refusal retains cleanup and the
      // consumed flag; retry must never call the atomic suspension finish again.
      try native.completeApprovedViewRouting(token, terminal, value.receipt)
    }
    value.result = result
    last = (value.id, result, terminal)
    active = nil
    publication.requestCheckpoint()
    // No cleanup after callbacks: a new transaction may already own active.
    return result
  }
}
