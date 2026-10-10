import Foundation
import PadCore
import SearchExecution

struct DocumentSearchCredential: Equatable {
  let windowID: UUID
  let endpointID: UUID
  let documentID: UUID
  let paneID: UUID
  let ownershipGeneration: UUID
  let editRevision: UInt64
  let inputUTF16: Int

  init(
    windowID: UUID, endpointID: UUID, documentID: UUID, paneID: UUID,
    ownershipGeneration: UUID, editRevision: UInt64, inputUTF16: Int
  ) throws {
    // The wire maximum is module-internal; use its real public validation boundary.
    do {
      _ = try SearchWireLimits(
        maxTextUTF16: inputUTF16, maxOutputUTF16: 0,
        maxMatches: 0, cooperativeMilliseconds: 0)
    } catch {
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
    self.windowID = windowID
    self.endpointID = endpointID
    self.documentID = documentID
    self.paneID = paneID
    self.ownershipGeneration = ownershipGeneration
    self.editRevision = editRevision
    self.inputUTF16 = inputUTF16
  }
}

struct ApplicationSearchWindowID: Hashable {
  private let ownerNonce: UUID
  private let registrationNonce: UUID
  private let windowID: UUID
  private let endpointID: UUID

  fileprivate init(ownerNonce: UUID, registrationNonce: UUID, windowID: UUID, endpointID: UUID) {
    self.ownerNonce = ownerNonce
    self.registrationNonce = registrationNonce
    self.windowID = windowID
    self.endpointID = endpointID
  }
}

struct ApplicationDocumentSearchRequestID: Hashable {
  private let ownerNonce: UUID
  private let nonce: UUID

  fileprivate init(ownerNonce: UUID, nonce: UUID) {
    self.ownerNonce = ownerNonce
    self.nonce = nonce
  }
}

struct ApplicationDocumentSearchResultID: Hashable {
  private let ownerNonce: UUID
  private let nonce: UUID

  fileprivate init(ownerNonce: UUID, nonce: UUID) {
    self.ownerNonce = ownerNonce
    self.nonce = nonce
  }
}

struct ApplicationSearchQuitID: Equatable {
  private let ownerNonce: UUID
  private let nonce: UUID

  fileprivate init(ownerNonce: UUID, nonce: UUID) {
    self.ownerNonce = ownerNonce
    self.nonce = nonce
  }
}

struct ApplicationSearchJoinID: Equatable {
  private let ownerNonce: UUID
  private let nonce: UUID

  fileprivate init(ownerNonce: UUID, nonce: UUID) {
    self.ownerNonce = ownerNonce
    self.nonce = nonce
  }
}

struct DocumentSearchSummary: Equatable {
  let matchCount: Int
  let hasReplacement: Bool
}

enum ApplicationDocumentSearchFailure: Error, Equatable {
  case windowCapacity, duplicateWindow, staleWindow, documentSlotOccupied
  case sourceUnavailable, staleSource, closed, preparingQuit, terminal, cancelled
  case admission(SearchAdmissionFailure)
}

enum ApplicationDocumentSearchDelivery: Equatable {
  case completed(
    request: ApplicationDocumentSearchRequestID, result: ApplicationDocumentSearchResultID,
    summary: DocumentSearchSummary)
  case failed(
    request: ApplicationDocumentSearchRequestID, failure: ApplicationDocumentSearchFailure)
}

enum ApplicationSearchPhase: Equatable {
  case open
  case prepared(ApplicationSearchQuitID)
  case terminal
}

enum ApplicationSearchTerminalRefusal: Equatable {
  case staleQuit, staleJoin, notPrepared, synchronousCallbackActive
}

enum ApplicationSearchTerminalAdmission: Equatable {
  case callerRefused(ApplicationSearchTerminalRefusal)
  case admitted(ApplicationSearchJoinID)
}

enum ApplicationSearchTerminalResult: Equatable {
  case callerRefused(ApplicationSearchTerminalRefusal)
  case observed(SearchAdmissionJoinedShutdownResult)
}

@MainActor
protocol ApplicationSearchBackend: AnyObject {
  func register() -> SearchConsumerID
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID
  func cancel(_ id: SearchJobID)
  func unregister(_ consumer: SearchConsumerID)
  func release(_ id: SearchResultLeaseID)
  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult
}

@MainActor
final class SearchAdmissionApplicationBackend: ApplicationSearchBackend {
  private let service: SearchAdmissionService<DocumentSearchCredential>

  init(service: SearchAdmissionService<DocumentSearchCredential>) { self.service = service }

  func register() -> SearchConsumerID { service.register() }

  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    try service.submit(
      consumer: consumer, descriptor: descriptor, capture: capture, completion: completion)
  }

  func cancel(_ id: SearchJobID) { service.cancel(id) }
  func unregister(_ consumer: SearchConsumerID) { service.unregister(consumer) }
  func release(_ id: SearchResultLeaseID) { service.release(id) }

  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    service.withResult(id, body)
  }

  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    await service.shutdownJoined()
  }
}

@MainActor
final class ApplicationDocumentSearchConsumer {
  private let owner: ApplicationSearchOwner
  private let window: ApplicationSearchWindowID
  private var source: (any ApplicationDocumentSearchSource)?
  private var onDelivery: (@MainActor (ApplicationDocumentSearchDelivery) -> Void)?
  private var closed = false

  fileprivate init(
    owner: ApplicationSearchOwner, window: ApplicationSearchWindowID,
    source: any ApplicationDocumentSearchSource,
    onDelivery: @escaping @MainActor (ApplicationDocumentSearchDelivery) -> Void
  ) {
    self.owner = owner
    self.window = window
    self.source = source
    self.onDelivery = onDelivery
  }

  func start(
    query: SearchQuery, operation: SearchExecutionOperation, scope: NSRange?,
    limits: SearchWireLimits
  )
    throws -> ApplicationDocumentSearchRequestID
  {
    guard !closed else { throw ApplicationDocumentSearchFailure.closed }
    return try owner.startDocument(
      self, query: query, operation: operation, scope: scope, limits: limits)
  }

  func cancel() {
    guard !closed else { return }
    owner.cancelDocument(self)
  }

  func close() {
    guard !closed else { return }
    closed = true
    onDelivery = nil
    source = nil
    owner.closeDocument(self)
  }

  func summary(for result: ApplicationDocumentSearchResultID) -> DocumentSearchSummary? {
    guard !closed else { return nil }
    return owner.summaryDocument(self, result: result)
  }

  func navigate(result: ApplicationDocumentSearchResultID, matchIndex: Int) -> Bool {
    guard !closed else { return false }
    return owner.navigateDocument(self, result: result, matchIndex: matchIndex)
  }

  func replaceAll(result: ApplicationDocumentSearchResultID) -> Bool {
    guard !closed else { return false }
    return owner.replaceDocument(self, result: result)
  }

  fileprivate func receive(_ delivery: ApplicationDocumentSearchDelivery) {
    guard !closed, let onDelivery else { return }
    onDelivery(delivery)
  }
}

@MainActor
final class ApplicationSearchOwner {
  private final class WindowRecord {
    let ticket: ApplicationSearchWindowID
    let windowID: UUID
    let endpointID: UUID
    var document: DocumentRecord?
    // A reserved role only; this slice never registers a folder consumer.
    let folder: SearchConsumerID? = nil
    var detaching = false

    init(ticket: ApplicationSearchWindowID, windowID: UUID, endpointID: UUID) {
      self.ticket = ticket
      self.windowID = windowID
      self.endpointID = endpointID
    }
  }

  private final class DocumentRecord {
    weak var window: WindowRecord?
    let identity: ObjectIdentifier
    weak var consumer: ApplicationDocumentSearchConsumer?
    weak var source: (any ApplicationDocumentSearchSource)?
    var registration: SearchConsumerID?
    var epoch = UUID()
    var request: RequestRecord?
    var result: ResultRecord?
    var retired = false

    init(
      window: WindowRecord, consumer: ApplicationDocumentSearchConsumer,
      source: any ApplicationDocumentSearchSource
    ) {
      self.window = window
      identity = ObjectIdentifier(consumer)
      self.consumer = consumer
      self.source = source
    }
  }

  private final class RequestRecord {
    let id: ApplicationDocumentSearchRequestID
    let epoch: UUID
    let credential: DocumentSearchCredential
    var job: SearchJobID?

    init(id: ApplicationDocumentSearchRequestID, epoch: UUID, credential: DocumentSearchCredential)
    {
      self.id = id
      self.epoch = epoch
      self.credential = credential
    }
  }

  private struct ResultRecord {
    let id: ApplicationDocumentSearchResultID
    let lease: SearchResultLeaseID
    let credential: DocumentSearchCredential
    let request: ApplicationDocumentSearchRequestID
    let epoch: UUID
  }

  private struct RetiredRights {
    let job: SearchJobID?
    let lease: SearchResultLeaseID?
  }

  private struct Observation {
    let nonce: UUID
    let task: Task<SearchAdmissionJoinedShutdownResult, Never>
  }

  private final class TerminalRecord {
    let quit: ApplicationSearchQuitID
    let join: ApplicationSearchJoinID
    var observation: Observation?

    init(quit: ApplicationSearchQuitID, join: ApplicationSearchJoinID) {
      self.quit = quit
      self.join = join
    }
  }

  private let backend: any ApplicationSearchBackend
  private let ownerNonce = UUID()
  private var windows: [UUID: WindowRecord] = [:]
  private var terminal: TerminalRecord?
  private var callbackDepth = 0
  private(set) var phase: ApplicationSearchPhase = .open

  init(backend: any ApplicationSearchBackend) { self.backend = backend }

  func attachWindow(windowID: UUID, endpointID: UUID) throws -> ApplicationSearchWindowID {
    try requireOpen()
    guard windows[windowID] == nil else { throw ApplicationDocumentSearchFailure.duplicateWindow }
    guard windows.count < 32 else { throw ApplicationDocumentSearchFailure.windowCapacity }
    let ticket = ApplicationSearchWindowID(
      ownerNonce: ownerNonce, registrationNonce: UUID(),
      windowID: windowID, endpointID: endpointID)
    windows[windowID] = WindowRecord(ticket: ticket, windowID: windowID, endpointID: endpointID)
    return ticket
  }

  func detachWindow(_ window: ApplicationSearchWindowID) {
    guard let record = windowRecord(window), !record.detaching else { return }
    record.detaching = true
    if let document = record.document {
      if let consumer = document.consumer { consumer.close() } else { retireDocument(document) }
    }
    if windows[record.windowID] === record { windows.removeValue(forKey: record.windowID) }
  }

  func attachDocument(
    window: ApplicationSearchWindowID, source: any ApplicationDocumentSearchSource,
    onDelivery: @escaping @MainActor (ApplicationDocumentSearchDelivery) -> Void
  ) throws -> ApplicationDocumentSearchConsumer {
    try requireOpen()
    guard let record = windowRecord(window), !record.detaching else {
      throw ApplicationDocumentSearchFailure.staleWindow
    }
    guard record.document == nil else {
      throw ApplicationDocumentSearchFailure.documentSlotOccupied
    }
    let consumer = ApplicationDocumentSearchConsumer(
      owner: self, window: window, source: source,
      onDelivery: onDelivery)
    let document = DocumentRecord(window: record, consumer: consumer, source: source)
    // Reserve the role before register can reenter. Adopt its returned ID before cleanup.
    record.document = document
    let registration = callback { backend.register() }
    document.registration = registration
    guard phase == .open, isLive(document), !record.detaching else {
      consumer.close()
      if document.registration != nil {
        document.registration = nil
        callback { backend.unregister(registration) }
      }
      throw ApplicationDocumentSearchFailure.cancelled
    }
    return consumer
  }

  func prepareQuit() throws -> ApplicationSearchQuitID {
    switch phase {
    case .terminal: throw ApplicationDocumentSearchFailure.terminal
    case .prepared(let quit): return quit
    case .open: break
    }
    let quit = ApplicationSearchQuitID(ownerNonce: ownerNonce, nonce: UUID())
    phase = .prepared(quit)
    // At most32 stack-local metadata receipts; all generations/rights are consumed first.
    let rights = windows.values.compactMap { record in
      record.document.map { consumeRequestAndResult($0) }
    }
    for consumed in rights { perform(consumed) }
    return quit
  }

  func resumeAfterVeto(_ quit: ApplicationSearchQuitID) -> Bool {
    guard phase == .prepared(quit) else { return false }
    for record in windows.values { record.document?.epoch = UUID() }
    phase = .open
    return true
  }

  func admitShutdownJoined(after quit: ApplicationSearchQuitID)
    -> ApplicationSearchTerminalAdmission
  {
    guard callbackDepth == 0 else { return .callerRefused(.synchronousCallbackActive) }
    switch phase {
    case .open: return .callerRefused(.notPrepared)
    case .terminal:
      guard let terminal, terminal.quit == quit else { return .callerRefused(.staleQuit) }
      return .admitted(terminal.join)
    case .prepared(let current):
      guard current == quit else { return .callerRefused(.staleQuit) }
    }
    let joined = TerminalRecord(
      quit: quit,
      join: ApplicationSearchJoinID(ownerNonce: ownerNonce, nonce: UUID()))
    terminal = joined
    phase = .terminal
    // Immutable bounded reference snapshot; no dictionary borrow crosses effects.
    let records = Array(windows.values)
    for record in records {
      if let document = record.document {
        if let consumer = document.consumer { consumer.close() } else { retireDocument(document) }
      }
    }
    joined.observation = newObservation()
    return .admitted(joined.join)
  }

  func observeShutdownJoined(_ join: ApplicationSearchJoinID) async
    -> ApplicationSearchTerminalResult
  {
    guard callbackDepth == 0 else { return .callerRefused(.synchronousCallbackActive) }
    guard let joined = terminal, joined.join == join else { return .callerRefused(.staleJoin) }
    if joined.observation == nil { joined.observation = newObservation() }
    guard let observation = joined.observation else { return .callerRefused(.staleJoin) }
    let value = await observation.task.value
    if terminal === joined, joined.observation?.nonce == observation.nonce {
      joined.observation = nil
    }
    return .observed(value)
  }

  fileprivate func startDocument(
    _ consumer: ApplicationDocumentSearchConsumer, query: SearchQuery,
    operation: SearchExecutionOperation, scope: NSRange?, limits: SearchWireLimits
  ) throws -> ApplicationDocumentSearchRequestID {
    guard let document = documentRecord(consumer) else {
      throw ApplicationDocumentSearchFailure.closed
    }
    try requireOpen()
    let rights = consumeRequestAndResult(document)
    let epoch = document.epoch
    perform(rights)
    guard isOpen(document, epoch: epoch) else { throw ApplicationDocumentSearchFailure.cancelled }
    guard let source = document.source else {
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
    let credential: DocumentSearchCredential
    do { credential = try callback { try source.inspect() } } catch {
      guard isOpen(document, epoch: epoch) else { throw ApplicationDocumentSearchFailure.cancelled }
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
    guard isOpen(document, epoch: epoch) else { throw ApplicationDocumentSearchFailure.cancelled }
    guard credential.windowID == document.window?.windowID,
      credential.endpointID == document.window?.endpointID
    else { throw ApplicationDocumentSearchFailure.staleSource }
    let descriptor: SearchAdmissionDescriptor
    do {
      descriptor = try SearchAdmissionDescriptor(
        query: query, operation: operation,
        estimatedInputUTF16: credential.inputUTF16, scope: scope, limits: limits)
    } catch let failure as SearchAdmissionFailure {
      throw ApplicationDocumentSearchFailure.admission(failure)
    } catch {
      throw ApplicationDocumentSearchFailure.admission(.internalFailure)
    }
    guard let registration = document.registration else {
      throw ApplicationDocumentSearchFailure.closed
    }
    let id = ApplicationDocumentSearchRequestID(ownerNonce: ownerNonce, nonce: UUID())
    document.request = RequestRecord(id: id, epoch: epoch, credential: credential)
    let returned: SearchJobID
    let releaseBackend = backend
    do {
      returned = try callback {
        try backend.submit(
          consumer: registration, descriptor: descriptor,
          capture: { [weak self, weak consumer] in
            guard let self, let consumer else { throw ApplicationDocumentSearchFailure.closed }
            return try self.captureDocument(
              consumer, request: id, epoch: epoch, expected: credential)
          },
          completion: { [weak self, weak consumer, releaseBackend] delivery in
            guard let self else {
              if case .completed(let lease) = delivery { releaseBackend.release(lease) }
              return
            }
            self.deliverDocument(consumer, request: id, epoch: epoch, delivery: delivery)
          })
      }
    } catch let failure as SearchAdmissionFailure {
      if isRequest(document, id: id, epoch: epoch) { document.request = nil }
      throw ApplicationDocumentSearchFailure.admission(failure)
    } catch {
      if isRequest(document, id: id, epoch: epoch) { document.request = nil }
      throw ApplicationDocumentSearchFailure.admission(.internalFailure)
    }
    // A returned job is either adopted by its exact request or consumed immediately.
    if isOpen(document, epoch: epoch), isRequest(document, id: id, epoch: epoch) {
      document.request?.job = returned
      return id
    }
    callback { backend.cancel(returned) }
    throw ApplicationDocumentSearchFailure.cancelled
  }

  fileprivate func cancelDocument(_ consumer: ApplicationDocumentSearchConsumer) {
    guard let document = documentRecord(consumer) else { return }
    perform(consumeRequestAndResult(document))
  }

  fileprivate func closeDocument(_ consumer: ApplicationDocumentSearchConsumer) {
    guard let document = documentRecord(consumer) else { return }
    retireDocument(document)
  }

  fileprivate func summaryDocument(
    _ consumer: ApplicationDocumentSearchConsumer, result: ApplicationDocumentSearchResultID
  ) -> DocumentSearchSummary? {
    guard let document = documentRecord(consumer) else { return nil }
    return borrowResult(document, result: result) { _, _, _, output in
      DocumentSearchSummary(
        matchCount: output.matches.count, hasReplacement: output.replacement != nil)
    }
  }

  fileprivate func navigateDocument(
    _ consumer: ApplicationDocumentSearchConsumer, result: ApplicationDocumentSearchResultID,
    matchIndex: Int
  ) -> Bool {
    guard let document = documentRecord(consumer), matchIndex >= 0 else { return false }
    return borrowResult(document, result: result) { source, credential, text, output in
      guard output.matches.indices.contains(matchIndex) else { return false }
      return callback {
        source.select(expected: credential, source: text, range: output.matches[matchIndex])
      }
    } ?? false
  }

  fileprivate func replaceDocument(
    _ consumer: ApplicationDocumentSearchConsumer, result: ApplicationDocumentSearchResultID
  ) -> Bool {
    guard let document = documentRecord(consumer) else { return false }
    let replaced =
      borrowResult(document, result: result) { source, credential, text, output in
        guard let replacement = output.replacement else { return false }
        return callback {
          source.replace(expected: credential, source: text, replacement: replacement)
        }
      } ?? false
    if replaced { retireResult(document, result: result, rotateEpoch: true) }
    return replaced
  }

  private func captureDocument(
    _ consumer: ApplicationDocumentSearchConsumer, request: ApplicationDocumentSearchRequestID,
    epoch: UUID, expected: DocumentSearchCredential
  ) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    guard let document = documentRecord(consumer), isOpen(document, epoch: epoch),
      isRequest(document, id: request, epoch: epoch)
    else { throw ApplicationDocumentSearchFailure.cancelled }
    guard let source = document.source else {
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
    let current = callback { source.isCurrent(expected: expected) }
    guard isOpen(document, epoch: epoch), isRequest(document, id: request, epoch: epoch) else {
      throw ApplicationDocumentSearchFailure.cancelled
    }
    guard current else { throw ApplicationDocumentSearchFailure.staleSource }
    let captured = try callback { try source.capture(expected: expected) }
    guard isOpen(document, epoch: epoch), isRequest(document, id: request, epoch: epoch) else {
      throw ApplicationDocumentSearchFailure.cancelled
    }
    guard captured.context == expected, captured.inputUTF16 == expected.inputUTF16 else {
      throw ApplicationDocumentSearchFailure.staleSource
    }
    let stillCurrent = callback { source.isCurrent(expected: expected) }
    guard isOpen(document, epoch: epoch), isRequest(document, id: request, epoch: epoch) else {
      throw ApplicationDocumentSearchFailure.cancelled
    }
    guard stillCurrent else { throw ApplicationDocumentSearchFailure.staleSource }
    return captured
  }

  private func deliverDocument(
    _ consumer: ApplicationDocumentSearchConsumer?, request: ApplicationDocumentSearchRequestID,
    epoch: UUID, delivery: SearchAdmissionDelivery
  ) {
    guard let consumer, let document = documentRecord(consumer), isOpen(document, epoch: epoch),
      isRequest(document, id: request, epoch: epoch), let pending = document.request
    else {
      if case .completed(let lease) = delivery { callback { backend.release(lease) } }
      return
    }
    // Completion consumes the pending job before any borrow or UI callback.
    pending.job = nil
    switch delivery {
    case .failed(let failure):
      document.request = nil
      callback { consumer.receive(.failed(request: request, failure: .admission(failure))) }
    case .completed(let lease):
      let result = ApplicationDocumentSearchResultID(ownerNonce: ownerNonce, nonce: UUID())
      document.result = ResultRecord(
        id: result, lease: lease, credential: pending.credential,
        request: request, epoch: epoch)
      let summary: DocumentSearchSummary? = borrowResult(document, result: result) {
        _, _, _, output in
        DocumentSearchSummary(
          matchCount: output.matches.count, hasReplacement: output.replacement != nil)
      }
      if let summary, isOpen(document, epoch: epoch), document.result?.id == result {
        callback {
          consumer.receive(.completed(request: request, result: result, summary: summary))
        }
      } else if isLive(document), phase == .open, document.epoch == epoch {
        // borrowResult retired this stale lease. Notify only this still-current invocation.
        document.request = nil
        callback { consumer.receive(.failed(request: request, failure: .staleSource)) }
      }
    }
  }

  private func borrowResult<Value>(
    _ document: DocumentRecord, result: ApplicationDocumentSearchResultID,
    _ body: (
      any ApplicationDocumentSearchSource, DocumentSearchCredential, String, SearchExecutionOutput
    ) -> Value?
  ) -> Value? {
    guard phase == .open, isLive(document), let held = document.result, held.id == result else {
      return nil
    }
    var value: Value?
    var entered = false
    var stale = false
    let found = callback {
      backend.withResult(held.lease) { credential, text, output in
        entered = true
        guard isResult(document, held), let source = document.source,
          credential == held.credential
        else {
          stale = true
          return
        }
        let current = callback { source.isCurrent(expected: credential) }
        guard isResult(document, held), current else {
          stale = true
          return
        }
        value = body(source, credential, text, output)
        if !isResult(document, held) { value = nil }
      }
    }
    if !found || !entered || stale { retireResult(document, result: result, rotateEpoch: false) }
    guard isResult(document, held) else { return nil }
    return value
  }

  private func retireResult(
    _ document: DocumentRecord, result: ApplicationDocumentSearchResultID, rotateEpoch: Bool
  ) {
    guard let held = document.result, held.id == result else { return }
    document.result = nil
    if document.request?.id == held.request { document.request = nil }
    if rotateEpoch { document.epoch = UUID() }
    callback { backend.release(held.lease) }
  }

  private func consumeRequestAndResult(_ document: DocumentRecord) -> RetiredRights {
    let rights = RetiredRights(job: document.request?.job, lease: document.result?.lease)
    document.request = nil
    document.result = nil
    document.epoch = UUID()
    return rights
  }

  private func perform(_ rights: RetiredRights) {
    if let job = rights.job { callback { backend.cancel(job) } }
    if let lease = rights.lease { callback { backend.release(lease) } }
  }

  private func retireDocument(_ document: DocumentRecord) {
    guard !document.retired else { return }
    document.retired = true
    let rights = consumeRequestAndResult(document)
    let registration = document.registration
    document.registration = nil
    document.source = nil
    if let window = document.window, window.document === document { window.document = nil }
    perform(rights)
    if let registration { callback { backend.unregister(registration) } }
  }

  private func requireOpen() throws {
    switch phase {
    case .open: return
    case .prepared: throw ApplicationDocumentSearchFailure.preparingQuit
    case .terminal: throw ApplicationDocumentSearchFailure.terminal
    }
  }

  private func windowRecord(_ ticket: ApplicationSearchWindowID) -> WindowRecord? {
    windows.values.first { $0.ticket == ticket }
  }

  private func documentRecord(_ consumer: ApplicationDocumentSearchConsumer) -> DocumentRecord? {
    let identity = ObjectIdentifier(consumer)
    for window in windows.values {
      if let document = window.document, !document.retired,
        document.identity == identity, document.consumer === consumer
      {
        return document
      }
    }
    return nil
  }

  private func isLive(_ document: DocumentRecord) -> Bool {
    guard let window = document.window else { return false }
    return !document.retired && windows[window.windowID] === window
      && window.document === document && document.consumer != nil
  }

  private func isOpen(_ document: DocumentRecord, epoch: UUID) -> Bool {
    phase == .open && isLive(document) && document.window?.detaching == false
      && document.epoch == epoch
  }

  private func isRequest(
    _ document: DocumentRecord, id: ApplicationDocumentSearchRequestID, epoch: UUID
  ) -> Bool {
    document.request?.id == id && document.request?.epoch == epoch
  }

  private func isResult(_ document: DocumentRecord, _ held: ResultRecord) -> Bool {
    isOpen(document, epoch: held.epoch) && document.result?.id == held.id
  }

  private func callback<Value>(_ action: () throws -> Value) rethrows -> Value {
    callbackDepth += 1
    defer { callbackDepth -= 1 }
    return try action()
  }

  private func newObservation() -> Observation {
    Observation(
      nonce: UUID(),
      task: Task { @MainActor [self] in
        await self.backend.shutdownJoined()
      })
  }
}
