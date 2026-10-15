// SPDX-License-Identifier: MIT
import Foundation
import PadCore

enum NativeLanguageCatalogLifetime { case active, invalidated }
struct NativeLanguageCatalogPublication {
  let id: UUID
  let requestID: UUID
  let catalog: LanguageCatalogSnapshot
}
struct NativeLanguageCatalogFailure {
  let requestID: UUID
  let underlyingError: any Error
}
struct NativeLanguageCatalogState {
  let lifetime: NativeLanguageCatalogLifetime
  let activeRequestID: UUID?
  let lastSettledRequestID: UUID?
  let current: NativeLanguageCatalogPublication?
  let failure: NativeLanguageCatalogFailure?
}
enum NativeLanguageCatalogAdmission {
  case started(requestID: UUID)
  case busy(activeRequestID: UUID)
  case invalidated
  case quitPrepared(quitID: UUID)
}

/// Serializes genuine Store operations and retains unresolved intent independently of display.
@MainActor final class NativeLanguageCatalogOwner {
  private struct Confirmation {
    let receipt: LoadedLanguageCatalog
    let publicationID: UUID
    let requestID: UUID
  }
  private enum WriteIntent: Sendable {
    case apply(NativeLanguageCatalogDraft, LanguageCatalogSnapshot, LoadedLanguageCatalog, UUID)
    case repair(NativeLanguageCatalogDraft, CustomLanguageRepairInspection, UUID, UUID?)

    var kind: CatalogAttemptKind {
      switch self {
      case .apply: return .apply
      case .repair: return .repair
      }
    }
  }
  private struct Attempt: Sendable {
    let id: UUID
    let intent: WriteIntent
  }
  private enum PendingResult {
    case uncertain(CustomLanguagePublicationUncertain)
    case readback(CustomLanguageReadbackUnconfirmed)
  }
  private enum Unresolved {
    case failed(Attempt, any Error)
    case pending(Attempt, UUID, PendingResult)

    var attempt: Attempt {
      switch self {
      case .failed(let a, _), .pending(let a, _, _): return a
      }
    }
  }
  private enum Operation: Sendable {
    case load
    case inspect
    case write(Attempt, CatalogOperationKind)
    case verify(Attempt, CustomLanguagePublicationUncertain)
    case retry(Attempt, CustomLanguagePublicationUncertain)
    case discard(Attempt)

    var kind: CatalogOperationKind {
      switch self {
      case .load: return .load
      case .inspect: return .inspect
      case .write(_, let kind): return kind
      case .verify: return .verify
      case .retry: return .retry
      case .discard: return .discardAndReload
      }
    }
    var attempt: Attempt? {
      switch self {
      case .load, .inspect: return nil
      case .write(let a, _), .verify(let a, _), .retry(let a, _), .discard(let a): return a
      }
    }
    var isLoad: Bool {
      if case .load = self { return true }
      return false
    }
  }
  private enum Product: Sendable {
    case loaded(LoadedLanguageCatalog)
    case inspected(LanguageCatalogInspection)
    case validated
  }
  private struct Worker {
    let id: UUID
    let operation: Operation
    var phase: CatalogOperationPhase
    var producer: Task<Product, Error>?
    var settlement: Task<Void, Never>?
  }
  private struct Inspection {
    let id: UUID
    let token: CustomLanguageRepairInspection
  }
  private enum LateResult {
    case notLaunched
    case completed(Result<Product, Error>)
  }
  private struct Custody {
    let operationID: UUID
    let operation: Operation
    let result: LateResult
    let summary: CatalogLateOutcomeKind
  }

  private let read: @Sendable () throws -> LoadedLanguageCatalog
  private let services: NativeLanguageCatalogServices?
  private var lifetime = NativeLanguageCatalogLifetime.active
  private var lastSettledRequestID: UUID?
  private var confirmed: Confirmation?
  private var writeReceipt: Confirmation?
  private var failure: NativeLanguageCatalogFailure?
  private var worker: Worker?
  private var observer: (@MainActor (NativeLanguageCatalogState) -> Void)?
  private var inspection: Inspection?
  private var inspectedResult: LanguageCatalogInspection?
  private var inspectionSnapshot = CatalogInspectionSnapshot.notInspected
  private var unresolved: Unresolved?
  private var lastOutcome: CatalogOperationOutcome?
  private var preparedQuitID: UUID?
  private var custody: Custody?

  init(store: CustomLanguageStore) {
    let services = NativeLanguageCatalogServices(
      read: { try store.load() }, inspect: { try store.inspect() },
      save: { try store.save($0, expected: $1) },
      repair: { try store.repair(definitions: $0, overrides: $1, matching: $2) },
      validatePending: { try store.validatePendingPublication($0) },
      retryPending: { try store.retryPendingPublication($0) })
    self.services = services
    read = services.read
  }
  init(read: @escaping @Sendable () throws -> LoadedLanguageCatalog) {
    self.read = read
    services = nil
  }
  init(services: NativeLanguageCatalogServices) {
    self.services = services
    read = services.read
  }

  var state: NativeLanguageCatalogState {
    let current = confirmed.map {
      NativeLanguageCatalogPublication(
        id: $0.publicationID, requestID: $0.requestID, catalog: $0.receipt.snapshot)
    }
    return NativeLanguageCatalogState(
      lifetime: lifetime, activeRequestID: active ? worker?.id : nil,
      lastSettledRequestID: lastSettledRequestID, current: current, failure: failure)
  }
  var onChange: (@MainActor (NativeLanguageCatalogState) -> Void)? {
    get { observer }
    set {
      guard case .active = lifetime else { return }
      observer = newValue
    }
  }

  func requestLoad() -> NativeLanguageCatalogAdmission {
    guard case .active = lifetime else { return .invalidated }
    if let worker { return .busy(activeRequestID: worker.id) }
    if let preparedQuitID { return .quitPrepared(quitID: preparedQuitID) }
    switch start(.load) {
    case .started(let id): return .started(requestID: id)
    case .refused: return .invalidated
    }
  }

  func invalidate() {
    lifetime = .invalidated
    observer = nil
    confirmed = nil
    writeReceipt = nil
    failure = nil
    lastSettledRequestID = nil
    preparedQuitID = nil
    // The operation owns any original token/receipt. No public follow-on authority survives.
    inspection = nil
    inspectedResult = nil
    inspectionSnapshot = .notInspected
    if let active = worker {
      if active.producer == nil {
        if !active.operation.isLoad {
          custody = Custody(
            operationID: active.id, operation: active.operation,
            result: .notLaunched, summary: .notLaunched)
        }
        worker = nil
      } else {
        worker?.phase = .settlingAfterInvalidation
      }
    }
    // Exact unresolved intent/evidence and launched handles remain until actual completion.
  }

  func invalidateAndWait() async {
    let settlement = worker?.settlement
    invalidate()
    if let settlement { await settlement.value }
  }

  private func start(_ operation: Operation) -> NativeLanguageCatalogMutationAdmission {
    // Capture only the exact services/immutable inputs, with no Store call during admission.
    let work: @Sendable () throws -> Product
    switch operation {
    case .load, .discard:
      let load = read
      work = { .loaded(try load()) }
    case .inspect:
      guard let service = services else { return .refused(.servicesUnavailable) }
      work = { .inspected(try service.inspect()) }
    case .write(let attempt, _):
      guard let service = services else { return .refused(.servicesUnavailable) }
      work = {
        switch attempt.intent {
        case .apply(_, let candidate, let receipt, _):
          return Product.loaded(try service.save(candidate, receipt))
        case .repair(let draft, let token, _, _):
          return Product.loaded(try service.repair(draft.definitions, draft.overrides, token))
        }
      }
    case .verify(_, let pending):
      guard let service = services else { return .refused(.servicesUnavailable) }
      work = {
        try service.validatePending(pending)
        return Product.validated
      }
    case .retry(_, let pending):
      guard let service = services else { return .refused(.servicesUnavailable) }
      work = { .loaded(try service.retryPending(pending)) }
    }
    let id = UUID()
    worker = Worker(id: id, operation: operation, phase: .admitting)
    notify()
    guard case .active = lifetime, worker?.id == id, preparedQuitID == nil else {
      return .refused(.invalidatedDuringAdmission)
    }
    let producer = Task.detached(priority: .utility) { [work] in try work() }
    let settlement = Task<Void, Never> { @MainActor [weak self, producer] in
      let result = await producer.result
      // The owner is not strongly held across a possibly stalled synchronous Store call.
      guard let self else { return }
      self.settle(result, id: id)
    }
    // Admission never suspends: the handles are installed before settlement can execute.
    worker?.phase = .running
    worker?.producer = producer
    worker?.settlement = settlement
    return .started(operationID: id)
  }

  private func settle(_ result: Result<Product, Error>, id: UUID) {
    guard let active = worker, active.id == id else { return }
    worker?.phase = .settling
    guard case .active = lifetime else {
      if !active.operation.isLoad {
        custody = Custody(
          operationID: id, operation: active.operation,
          result: .completed(result), summary: lateSummary(result, operation: active.operation))
      }
      worker = nil
      return
    }
    lastSettledRequestID = id
    switch result {
    case .success(let product):
      failure = nil
      var publicationID: UUID?
      switch product {
      case .loaded(let loaded):
        let value = Confirmation(receipt: loaded, publicationID: UUID(), requestID: id)
        confirmed = value
        writeReceipt = value
        inspection = nil
        inspectedResult = nil
        inspectionSnapshot = .loaded(publicationID: value.publicationID)
        publicationID = value.publicationID
        switch active.operation {
        case .write, .retry, .discard: unresolved = nil
        case .load, .inspect, .verify: break
        }
      case .inspected(let actual):
        inspectedResult = actual
        switch actual {
        case .loaded(let loaded):
          let value = Confirmation(receipt: loaded, publicationID: UUID(), requestID: id)
          confirmed = value
          writeReceipt = value
          inspection = nil
          inspectionSnapshot = .loaded(publicationID: value.publicationID)
          publicationID = value.publicationID
        case .corrupt(let token):
          let tokenID = UUID()
          inspection = Inspection(id: tokenID, token: token)
          inspectionSnapshot = .corrupt(inspectionID: tokenID, summary: .corruptCatalog)
          writeReceipt = nil
        case .unsupported:
          inspection = nil
          inspectionSnapshot = .unsupported(summary: .unsupportedCatalog)
          writeReceipt = nil
        }
      case .validated:
        // Verification is Void: no receipt, generation, pending ID or authority changes.
        break
      }
      lastOutcome = .succeeded(operationID: id, publicationID: publicationID)
    case .failure(let error):
      let summary = failureSummary(error, operation: active.operation)
      failure = NativeLanguageCatalogFailure(requestID: id, underlyingError: error)
      lastOutcome = .failed(operationID: id, summary: summary)
      switch active.operation {
      case .write(let attempt, _):
        retainWriteFailure(error, attempt: attempt, preservePending: false)
      case .retry(let attempt, _):
        retainWriteFailure(error, attempt: attempt, preservePending: true)
      case .inspect: inspectionSnapshot = .failed(summary: summary)
      case .load, .verify, .discard: break
      }
    }
    // Producer has actually completed. Retire before callback; nothing follows delivery.
    worker = nil
    notify()
  }

  private func retainWriteFailure(_ error: any Error, attempt: Attempt, preservePending: Bool) {
    if let actual = error as? CustomLanguagePublicationUncertain {
      unresolved = .pending(attempt, UUID(), .uncertain(actual))
    } else if let actual = error as? CustomLanguageReadbackUnconfirmed {
      unresolved = .pending(attempt, UUID(), .readback(actual))
    } else if !preservePending {
      unresolved = .failed(attempt, error)
    }
  }

  private func lateSummary(_ result: Result<Product, Error>, operation: Operation)
    -> CatalogLateOutcomeKind
  {
    switch operation {
    case .verify:
      switch result {
      case .success: return .validationCompletedWithoutAcknowledgement
      case .failure: return .validationFailedWithoutAcknowledgement
      }
    case .discard: return .discardReloadCompletedWithoutResolution
    case .inspect:
      if case .success = result { return .inspectionCompleted }
    case .load, .write, .retry: break
    }
    switch result {
    case .success: return .succeededReceiptRetainedWithoutPublication
    case .failure(let error):
      if error is CustomLanguagePublicationUncertain { return .publicationUncertain }
      if error is CustomLanguageReadbackUnconfirmed { return .readbackUnconfirmed }
      return .failed
    }
  }

  private func failureSummary(_ error: any Error, operation: Operation) -> CatalogFailureSummary {
    if error is CustomLanguagePublicationUncertain { return .publicationUncertain }
    if error is CustomLanguageReadbackUnconfirmed { return .readbackUnconfirmed }
    if error is LanguageProfileError { return .validation }
    if let actual = error as? CustomLanguageStoreError {
      switch actual {
      case .changed, .receiptMismatch: return .externalChange
      case .invalidCatalog, .tooLarge, .generationExhausted, .revisionExhausted: return .validation
      case .unsafeLocation, .unreadable, .unimplemented: break
      }
    }
    if let actual = error as? FileStoreError, case .externalChange = actual {
      return .externalChange
    }
    switch operation {
    case .write, .retry: return .storeWrite
    case .load, .inspect, .verify, .discard: return .storeRead
    }
  }

  private func notify() {
    let snapshot = state
    let callback = observer
    callback?(snapshot)
  }
}

@MainActor extension NativeLanguageCatalogOwner {
  private var active: Bool {
    if case .active = lifetime { return true }
    return false
  }
  private var available: Bool { active && worker == nil && preparedQuitID == nil }
  private var clear: Bool { available && unresolved == nil }

  private func globalRefusal() -> NativeLanguageCatalogMutationRefusal? {
    guard active else { return .invalidated }
    if let worker { return .busy(activeOperationID: worker.id) }
    if let preparedQuitID { return .quitPrepared(quitID: preparedQuitID) }
    guard services != nil else { return .servicesUnavailable }
    return nil
  }
  private func unresolvedRefusal() -> NativeLanguageCatalogMutationRefusal? {
    switch unresolved {
    case .failed(let attempt, _): return .unresolvedAttempt(attemptID: attempt.id)
    case .pending(_, let id, _): return .unresolvedPending(recoveryID: id)
    case nil: return nil
    }
  }
  private func matches(_ expected: CatalogPublicationExpectation) -> Bool {
    switch expected {
    case .none: return confirmed == nil
    case .current(let id): return confirmed?.publicationID == id
    }
  }
  private func retryable(_ intent: WriteIntent) -> Bool {
    switch intent {
    case .apply(_, _, _, let id): return writeReceipt?.publicationID == id
    case .repair(_, _, let tokenID, let publication):
      return inspection?.id == tokenID && confirmed?.publicationID == publication
    }
  }

  var mutationState: NativeLanguageCatalogMutationState {
    let unresolvedSnapshot: CatalogUnresolvedSnapshot?
    switch unresolved {
    case .failed(let attempt, let error):
      unresolvedSnapshot = .failedAttempt(
        attemptID: attempt.id, kind: attempt.intent.kind,
        summary: failureSummary(error, operation: .write(attempt, .retryFailedAttempt)))
    case .pending(let attempt, let recovery, let result):
      switch result {
      case .uncertain:
        unresolvedSnapshot = .pending(
          attemptID: attempt.id, recoveryID: recovery,
          kind: .publicationUncertain, summary: .publicationUncertain)
      case .readback:
        unresolvedSnapshot = .pending(
          attemptID: attempt.id, recoveryID: recovery,
          kind: .readbackUnconfirmed, summary: .readbackUnconfirmed)
      }
    case nil: unresolvedSnapshot = nil
    }
    var canRetryFailed = false
    var canRecover = false
    if case .failed(let attempt, _) = unresolved { canRetryFailed = retryable(attempt.intent) }
    if case .pending(_, _, .uncertain) = unresolved { canRecover = true }
    let storeReady = available && services != nil
    return NativeLanguageCatalogMutationState(
      activeOperation: worker.map {
        CatalogOperationSnapshot(id: $0.id, kind: $0.operation.kind, phase: $0.phase)
      },
      lastOutcome: lastOutcome,
      lastGoodDisplay: confirmed.map {
        CatalogDisplaySnapshot(publicationID: $0.publicationID, catalog: $0.receipt.snapshot)
      },
      writeReceiptPublicationID: writeReceipt?.publicationID,
      inspection: inspectionSnapshot, unresolved: unresolvedSnapshot,
      preparedQuitID: preparedQuitID,
      invalidationCustody: custody.map {
        CatalogInvalidationCustodySnapshot(
          operationID: $0.operationID,
          attemptID: $0.operation.attempt?.id, outcome: $0.summary)
      },
      canApply: storeReady && unresolved == nil && writeReceipt != nil,
      canInspect: storeReady && unresolved == nil,
      canRepair: storeReady && unresolved == nil && inspection != nil,
      canVerifyPending: storeReady && canRecover, canRetryPending: storeReady && canRecover,
      canRetryFailedAttempt: storeReady && canRetryFailed,
      canDiscardAndReload: storeReady && unresolved != nil, canPrepareQuit: clear)
  }

  func requestApply(
    _ draft: NativeLanguageCatalogDraft, expectedPublication: CatalogPublicationExpectation
  ) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() ?? unresolvedRefusal() { return .refused(reason) }
    guard let receipt = writeReceipt else { return .refused(.noWriteReceipt) }
    guard matches(expectedPublication) else { return .refused(.wrongPublication) }
    let candidate: LanguageCatalogSnapshot
    do {
      candidate = try LanguageCatalogSnapshot(
        definitions: draft.definitions,
        overrides: draft.overrides, generation: receipt.receipt.snapshot.generation)
    } catch { return .refused(.invalidDraft) }
    let attempt = Attempt(
      id: UUID(), intent: .apply(draft, candidate, receipt.receipt, receipt.publicationID))
    return start(.write(attempt, .apply))
  }

  func requestInspect(expectedPublication: CatalogPublicationExpectation)
    -> NativeLanguageCatalogMutationAdmission
  {
    if let reason = globalRefusal() ?? unresolvedRefusal() { return .refused(reason) }
    guard matches(expectedPublication) else { return .refused(.wrongPublication) }
    return start(.inspect)
  }

  func requestRepair(
    _ draft: NativeLanguageCatalogDraft, inspection inspectionID: UUID,
    expectedPublication: CatalogPublicationExpectation
  ) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() ?? unresolvedRefusal() { return .refused(reason) }
    guard matches(expectedPublication) else { return .refused(.wrongPublication) }
    guard let token = inspection, token.id == inspectionID else {
      if case .unsupported = inspectionSnapshot { return .refused(.unsupported) }
      return .refused(.wrongInspection)
    }
    let attempt = Attempt(
      id: UUID(), intent: .repair(draft, token.token, token.id, confirmed?.publicationID))
    return start(.write(attempt, .repair))
  }

  func requestVerifyPending(_ recoveryID: UUID) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() { return .refused(reason) }
    guard case .pending(let attempt, let id, let actual) = unresolved, id == recoveryID else {
      return .refused(.wrongRecovery)
    }
    guard case .uncertain(let pending) = actual else { return .refused(.notRetryable) }
    return start(.verify(attempt, pending))
  }

  func requestRetryPending(_ recoveryID: UUID) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() { return .refused(reason) }
    guard case .pending(let attempt, let id, let actual) = unresolved, id == recoveryID else {
      return .refused(.wrongRecovery)
    }
    guard case .uncertain(let pending) = actual else { return .refused(.notRetryable) }
    return start(.retry(attempt, pending))
  }

  func requestRetryFailedAttempt(_ attemptID: UUID) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() { return .refused(reason) }
    guard case .failed(let attempt, _) = unresolved, attempt.id == attemptID else {
      return .refused(.wrongAttempt)
    }
    guard retryable(attempt.intent) else { return .refused(.notRetryableFailedAttempt) }
    return start(.write(attempt, .retryFailedAttempt))
  }

  func requestDiscardAndReload(
    _ unresolvedID: CatalogUnresolvedID,
    confirmation: CatalogRecoveryDecision
  ) -> NativeLanguageCatalogMutationAdmission {
    if let reason = globalRefusal() { return .refused(reason) }
    switch confirmation {
    case .discardAttemptAndReload: break
    }
    guard let unresolved else { return .refused(.noUnresolvedAttempt) }
    switch (unresolvedID, unresolved) {
    case (.attempt(let id), .failed(let attempt, _)) where id == attempt.id:
      return start(.discard(attempt))
    case (.pending(let id), .pending(let attempt, let recovery, _)) where id == recovery:
      return start(.discard(attempt))
    case (.attempt, _): return .refused(.wrongAttempt)
    case (.pending, _): return .refused(.wrongRecovery)
    }
  }

  func prepareQuit() -> CatalogQuitAdmission {
    guard active else { return .refused(.invalidated) }
    if let worker { return .refused(.busy(activeOperationID: worker.id)) }
    if let preparedQuitID { return .refused(.quitPrepared(quitID: preparedQuitID)) }
    if let reason = unresolvedRefusal() { return .refused(reason) }
    let id = UUID()
    preparedQuitID = id
    notify()
    guard active else { return .refused(.invalidated) }
    guard preparedQuitID == id else { return .refused(.reservationWithdrawn) }
    return .prepared(id)
  }

  func cancelPreparedQuit(_ quitID: UUID) -> Bool {
    guard active, preparedQuitID == quitID else { return false }
    preparedQuitID = nil
    notify()
    return true
  }
}
