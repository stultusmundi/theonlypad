import Foundation
import PadCore

@MainActor final class DocumentDiskActionCoordinator {
  private final class Transaction {
    let id = UUID()
    let generation: UUID
    let input: DocumentDiskActionInput
    let callbacks: DocumentDiskActionCallbacks
    var lease: ApplicationFileMonitoring.ActionLease?
    var operation: UUID?
    var request: UUID?
    var token: (any DiskActionCancellation)?
    var snapshot: ExternalFileActionSnapshot?
    var preparationPermit: UUID?
    var selections: [UUID: NSRange] = [:]
    init(generation: UUID, input: DocumentDiskActionInput, callbacks: DocumentDiskActionCallbacks) {
      self.generation = generation
      self.input = input
      self.callbacks = callbacks
    }
  }
  private let application: ApplicationFileMonitoring
  private let client: any DiskActionClient
  private let preparer: any DiskSelectionPreparer
  private var active: Transaction?
  private var lastAdmittedTransactionID: UUID?
  var activeTransactionID: UUID? { active?.id }
  init(
    application: ApplicationFileMonitoring, client: (any DiskActionClient)? = nil,
    preparer: (any DiskSelectionPreparer)? = nil
  ) {
    self.application = application
    self.client = client ?? NativeDiskActionClient(service: application.service)
    self.preparer = preparer ?? NativeDiskSelectionPreparer.shared
  }
  @discardableResult func start(
    _ input: DocumentDiskActionInput, callbacks: DocumentDiskActionCallbacks
  ) -> Bool {
    guard active == nil, !application.isSuspended, !application.isStopped,
      input.selections.count <= 2
    else { return false }
    let transaction = Transaction(
      generation: application.deliveryGeneration, input: input, callbacks: callbacks)
    if !input.selections.isEmpty {
      guard let permit = preparer.reserve() else { return false }
      transaction.preparationPermit = permit
    }
    active = transaction
    let transactionID = transaction.id
    guard
      let lease = application.beginAction(
        documentID: input.documentID,
        cancel: { [weak self] in
          self?.cancel(transactionID: transactionID)
        })
    else {
      if active === transaction {
        active = nil
        if let permit = transaction.preparationPermit { preparer.release(permit) }
      }
      return false
    }
    transaction.lease = lease
    lastAdmittedTransactionID = transaction.id
    guard let operation = callbacks.beginOperation() else {
      finish(transaction)
      return false
    }
    guard active === transaction else {
      // A reentrant begin callback cancelled before it returned its owned operation.
      callbacks.finish(operation)
      return false
    }
    transaction.operation = operation
    guard isCurrent(transaction) else {
      finish(transaction)
      return false
    }
    read(transaction)
    return true
  }
  private func isCurrent(_ transaction: Transaction) -> Bool {
    guard active === transaction, !application.isSuspended, !application.isStopped,
      application.deliveryGeneration == transaction.generation,
      let operation = transaction.operation
    else { return false }
    let valid = transaction.callbacks.isCurrent(operation)
    return valid && active === transaction && !application.isSuspended && !application.isStopped
      && application.deliveryGeneration == transaction.generation
  }
  private func read(_ transaction: Transaction) {
    let requestID = UUID()
    transaction.request = requestID
    let transactionID = transaction.id
    let token = client.read(requestID: requestID, input: transaction.input) {
      [weak self] id, result in
      Task { @MainActor [weak self] in
        guard let self, let current = self.active, current.id == transactionID,
          current.request == requestID, id == requestID
        else { return }
        current.token = nil
        current.request = nil
        guard self.isCurrent(current) else {
          self.finish(current)
          return
        }
        switch result {
        case .failure(let error): self.finish(current, error: error)
        case .success(let snapshot):
          current.snapshot = snapshot
          if current.input.action == .copy {
            self.prepare(current)
            return
          }
          if current.input.requiresDiscard {
            let confirmed = current.callbacks.confirmDiscard(snapshot)
            guard self.isCurrent(current) else {
              self.finish(current)
              return
            }
            guard confirmed else {
              self.finish(current)
              return
            }
          }
          self.prepare(current)
        }
      }
    }
    if active === transaction && transaction.request == requestID {
      transaction.token = token
    } else {
      token.cancel()
    }
  }
  private func prepare(_ transaction: Transaction) {
    guard isCurrent(transaction), let snapshot = transaction.snapshot else {
      finish(transaction)
      return
    }
    guard let permit = transaction.preparationPermit else {
      prepared(transaction)
      return
    }
    let requestID = UUID()
    transaction.request = requestID
    let transactionID = transaction.id
    preparer.prepare(permit, text: snapshot.document.text, selections: transaction.input.selections)
    { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, let current = self.active, current.id == transactionID,
          current.request == requestID
        else { return }
        current.request = nil
        current.preparationPermit = nil
        guard self.isCurrent(current) else {
          self.finish(current)
          return
        }
        switch result {
        case .failure(let error): self.finish(current, error: error)
        case .success(let selections):
          current.selections = selections
          self.prepared(current)
        }
      }
    }
  }
  private func prepared(_ transaction: Transaction) {
    if transaction.input.action == .copy { apply(transaction) } else { revalidate(transaction) }
  }
  private func revalidate(_ transaction: Transaction) {
    guard isCurrent(transaction), let snapshot = transaction.snapshot else {
      finish(transaction)
      return
    }
    let requestID = UUID()
    transaction.request = requestID
    let transactionID = transaction.id
    let token = client.revalidate(requestID: requestID, snapshot: snapshot) {
      [weak self] id, result in
      Task { @MainActor [weak self] in
        guard let self, let current = self.active, current.id == transactionID,
          current.request == requestID, id == requestID
        else { return }
        current.token = nil
        current.request = nil
        guard self.isCurrent(current) else {
          self.finish(current)
          return
        }
        switch result {
        case .failure(let error): self.finish(current, error: error)
        case .success: self.apply(current)
        }
      }
    }
    if active === transaction && transaction.request == requestID {
      transaction.token = token
    } else {
      token.cancel()
    }
  }
  private func apply(_ transaction: Transaction) {
    guard isCurrent(transaction), let operation = transaction.operation,
      let snapshot = transaction.snapshot
    else {
      finish(transaction)
      return
    }
    do {
      try transaction.callbacks.apply(snapshot, transaction.selections, operation)
      finish(transaction)
    } catch { finish(transaction, error: error) }
  }
  private func finish(_ transaction: Transaction, error: Error? = nil) {
    guard active === transaction else { return }
    let mayReport = error != nil && isCurrent(transaction)
    // Reentrant owner predicates may already have retired this transaction.
    guard active === transaction else { return }
    active = nil
    transaction.snapshot = nil
    transaction.request = nil
    let token = transaction.token
    transaction.token = nil
    token?.cancel()
    if let permit = transaction.preparationPermit {
      preparer.release(permit)
      transaction.preparationPermit = nil
    }
    if let lease = transaction.lease {
      _ = application.finishAction(lease)
      transaction.lease = nil
    }
    guard let operation = transaction.operation else { return }
    transaction.operation = nil
    defer { transaction.callbacks.finish(operation) }
    if let error, (error as? FileActionError) != .cancelled,
      mayReport, !application.isStopped, !application.isSuspended,
      application.deliveryGeneration == transaction.generation,
      transaction.callbacks.isCurrent(operation)
    {
      // The final owner predicate is external code and can synchronously reenter.
      guard !application.isStopped, !application.isSuspended,
        application.deliveryGeneration == transaction.generation,
        active == nil, lastAdmittedTransactionID == transaction.id
      else { return }
      transaction.callbacks.reportError(error)
    }
  }
  func cancel(transactionID: UUID) {
    guard let current = active, current.id == transactionID else { return }
    finish(current)
  }
  func cancel() {
    guard let current = active else { return }
    finish(current)
  }
}
