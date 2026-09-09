import Foundation
import PadCore

@MainActor final class DocumentLocateCoordinator {
  private final class Transaction {
    let id = UUID()
    let generation: UUID
    let input: DocumentLocateInput
    let callbacks: DocumentLocateCallbacks
    var lease: ApplicationFileMonitoring.ActionLease?
    var operation: UUID?
    var request: UUID?
    var handle: (any ManualHandle)?
    var firstMetadata: FileMetadata?
    init(generation: UUID, input: DocumentLocateInput, callbacks: DocumentLocateCallbacks) {
      self.generation = generation
      self.input = input
      self.callbacks = callbacks
    }
  }
  private let application: ApplicationFileMonitoring
  private let client: any MonitorClient
  private var active: Transaction?
  private var lastAdmittedID: UUID?
  var activeTransactionID: UUID? { active?.id }
  init(application: ApplicationFileMonitoring, client: (any MonitorClient)? = nil) {
    self.application = application
    self.client = client ?? application.client
  }
  @discardableResult func start(_ input: DocumentLocateInput, callbacks: DocumentLocateCallbacks)
    -> Bool
  {
    guard active == nil, !application.isSuspended, !application.isStopped,
      input.pendingPublicationID == nil, input.originalBytes.count <= 100_000_000,
      input.originalURL.isFileURL, input.candidateURL.isFileURL
    else { return false }
    let transaction = Transaction(
      generation: application.deliveryGeneration, input: input, callbacks: callbacks)
    active = transaction
    let id = transaction.id
    guard
      let lease = application.beginAction(
        documentID: input.documentID, cancel: { [weak self] in self?.cancel(transactionID: id) })
    else {
      if active === transaction { active = nil }
      return false
    }
    transaction.lease = lease
    lastAdmittedID = transaction.id
    guard let operation = callbacks.beginOperation() else {
      finish(transaction)
      return false
    }
    guard active === transaction else {
      callbacks.finish(operation)
      return false
    }
    transaction.operation = operation
    guard isCurrent(transaction) else {
      finish(transaction)
      return false
    }
    check(transaction, first: true)
    return true
  }
  private func isCurrent(_ transaction: Transaction) -> Bool {
    guard active === transaction, !application.isStopped, !application.isSuspended,
      application.deliveryGeneration == transaction.generation,
      let operation = transaction.operation
    else { return false }
    let valid = transaction.callbacks.isCurrent(operation)
    return valid && active === transaction && !application.isStopped && !application.isSuspended
      && application.deliveryGeneration == transaction.generation
  }
  private func check(_ transaction: Transaction, first: Bool) {
    guard isCurrent(transaction) else {
      finish(transaction)
      return
    }
    let requestID = UUID()
    transaction.request = requestID
    let transactionID = transaction.id
    let handle = client.checkOnce(
      requestID: requestID, id: transaction.input.documentID,
      url: transaction.input.candidateURL, baseline: transaction.input.originalBytes,
      revision: transaction.input.baselineRevision,
      boundIdentity: first ? nil : transaction.firstMetadata?.identity
    ) { [weak self] id, result in
      Task { @MainActor [weak self] in
        guard let self, let current = self.active, current.id == transactionID,
          current.request == requestID, id == requestID
        else { return }
        current.request = nil
        current.handle = nil
        guard self.isCurrent(current) else {
          self.finish(current)
          return
        }
        switch result {
        case .failure(let error): self.finish(current, error: error)
        case .success(let observation):
          guard observation.locationProblem == nil, let metadata = observation.metadata,
            observation.content != .unavailable
          else {
            self.finish(
              current, error: DocumentLocateError.unavailable(observation.locationProblem))
            return
          }
          guard observation.content == .matchesBaseline else {
            self.finish(current, error: DocumentLocateError.differentBytes)
            return
          }
          if first {
            current.firstMetadata = metadata
            self.check(current, first: false)
          } else {
            guard current.firstMetadata == metadata else {
              self.finish(current, error: DocumentLocateError.changedCandidate)
              return
            }
            guard self.isCurrent(current), let operation = current.operation else {
              self.finish(current)
              return
            }
            do {
              try current.callbacks.apply(current.input.candidateURL, metadata.identity, operation)
              self.finish(current)
            } catch { self.finish(current, error: error) }
          }
        }
      }
    }
    if active === transaction && transaction.request == requestID {
      transaction.handle = handle
    } else {
      handle.cancel()
    }
  }
  private func finish(_ transaction: Transaction, error: Error? = nil) {
    guard active === transaction else { return }
    let mayReport = error != nil && isCurrent(transaction)
    guard active === transaction else { return }
    active = nil
    transaction.request = nil
    transaction.firstMetadata = nil
    let handle = transaction.handle
    transaction.handle = nil
    handle?.cancel()
    if let lease = transaction.lease {
      _ = application.finishAction(lease)
      transaction.lease = nil
    }
    guard let operation = transaction.operation else { return }
    transaction.operation = nil
    defer { transaction.callbacks.finish(operation) }
    if let error, (error as? MonitorFailure) != .cancelled, mayReport,
      !application.isStopped, !application.isSuspended,
      application.deliveryGeneration == transaction.generation,
      transaction.callbacks.isCurrent(operation)
    {
      guard !application.isStopped, !application.isSuspended,
        application.deliveryGeneration == transaction.generation,
        active == nil, lastAdmittedID == transaction.id
      else { return }
      transaction.callbacks.reportError(error)
    }
  }
  func cancel() { if let active { finish(active) } }
  func cancel(transactionID: UUID) { if let active, active.id == transactionID { finish(active) } }
}
