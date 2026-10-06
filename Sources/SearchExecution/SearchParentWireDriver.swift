import Foundation
import PadCore

enum SearchParentDriverEvent: Sendable, Equatable {
  case admitted(UUID)
  case ticketStored(UUID, SearchWireIdentity)
  case sourceOwnerReleased(UUID)
  case coordinatorScopeExited(UUID)
  case resultDelivered(UUID)
  case observerInstalled(UUID)
  case terminalAccepted(UUID)
  case expectFinished(UUID)
  case producerExited(UUID)
  case consumerExited(UUID)
  case lifecycleDecided(UUID, SearchChildOutcome)
  case cancellationStarted(UUID)
  case connectionAvailable(UUID, UUID)
  case idleRetirementRequested(UUID, Bool)
  case readSequenceExhausted(UUID)
  case idleReadReserved(UUID)
  case readHeld(UUID, Int)
  case sessionReleased(UUID)
}

package final class SearchParentWireDriver: SearchParentWireDriving {
  private let state: SearchParentDriverState
  init(
    lifecycle: SearchChildLifecycle,
    accumulatorFactory: @escaping SearchParentWireResponseAccumulatorFactory,
    maximumWireBytesPerChild: UInt64,
    observe: (@Sendable (SearchParentDriverEvent) -> Void)? = nil
  ) throws {
    guard maximumWireBytesPerChild > 0 else { throw SearchParentWireDriverError.invalidJob }
    state = SearchParentDriverState(
      lifecycle: lifecycle, factory: accumulatorFactory,
      maximumBytes: maximumWireBytesPerChild, observe: observe)
  }
  deinit {
    let state = state
    Task { await state.abandon() }
  }
  package func settlement(after handle: SearchParentWireHandle?) async throws
    -> SearchParentWireSettlement
  {
    try await state.settlement(after: handle)
  }
  package func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle {
    try await state.submit(job)
  }
  package func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome {
    let registration = SearchParentDriverRegistration()
    let state = state
    return try await withTaskCancellationHandler {
      try await state.wait(handle, registration: registration)
    } onCancel: {
      registration.cancel()
      Task { await state.detach(handle, registration: registration) }
    }
  }
  package func cancel(_ handle: SearchParentWireHandle) async throws {
    try await state.cancel(handle)
  }
  package func discard(_ handle: SearchParentWireHandle) async throws {
    try await state.discard(handle)
  }
  /// One terminal owner joins logical parent scopes and the existing lane stop.
  /// Ownership admission does not certify external result or allocator release.
  package func shutdownJoined(after handle: SearchParentWireHandle?) async
    -> SearchParentJoinedShutdownResult
  {
    await state.shutdownJoined(after: handle)
  }
  package func shutdown() async -> SearchParentWireShutdown { await state.shutdown() }
}

private final class SearchParentDriverRegistration: @unchecked Sendable {
  private let lock = NSLock()
  private enum State { case pending, cancelled, delivered }
  private var state = State.pending
  func cancel() {
    lock.lock()
    if case .pending = state { state = .cancelled }
    lock.unlock()
  }
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard case .pending = state else { return false }
    state = .delivered
    return true
  }
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    if case .cancelled = state { return true }
    return false
  }
}

private final class SearchParentDriverSource: Sendable {
  let text: String
  let nonce: UUID
  let observe: (@Sendable (SearchParentDriverEvent) -> Void)?
  init(_ text: String, nonce: UUID, observe: (@Sendable (SearchParentDriverEvent) -> Void)?) {
    self.text = text
    self.nonce = nonce
    self.observe = observe
  }
  deinit { observe?(.sourceOwnerReleased(nonce)) }
}

/// One cancellation command waits here. This cell never owns source or connection state.
private actor SearchParentTicketReady {
  private var resolved = false
  private var ticket: SearchChildTicket?
  private var waiter: CheckedContinuation<SearchChildTicket?, Never>?
  func resolve(_ value: SearchChildTicket?) {
    guard !resolved else { return }
    resolved = true
    ticket = value
    let old = waiter
    waiter = nil
    old?.resume(returning: value)
  }
  func value() async -> SearchChildTicket? {
    if resolved { return ticket }
    return await withCheckedContinuation { waiter = $0 }
  }
}

/// Its reference may cross a suspended helper; the payload is taken only once by the lane.
private final class SearchParentReadPayload: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Data?
  init(_ bytes: Data) { self.bytes = bytes }
  func take() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let result = bytes else { throw SearchWireError.invalidPhase }
    bytes = nil
    return result
  }
}

private actor SearchParentDriverState {
  private final class Operation {
    let handle: SearchParentWireHandle
    var source: SearchParentDriverSource?
    let query: SearchQuery
    let kind: SearchExecutionOperation
    let inputUTF16: Int
    let scope: NSRange?
    let limits: SearchWireLimits
    let ready = SearchParentTicketReady()
    var ticket: SearchChildTicket?
    var decision: SearchChildOutcome?
    var provisional: SearchParentProvisionalTerminal?
    var terminalReady = false
    var terminalReadSequence: UInt64 = 0
    var staged: SearchParentWireOutcome?
    var cancelTask: Task<Void, Never>?
    var observerTask: Task<Void, Never>?
    var coordinator: Task<Void, Never>?
    init(_ job: SearchParentWireJob, observe: (@Sendable (SearchParentDriverEvent) -> Void)?) {
      handle = SearchParentWireHandle(nonce: UUID(), requestID: job.requestID)
      source = SearchParentDriverSource(job.text, nonce: handle.nonce, observe: observe)
      query = job.query
      kind = job.operation
      inputUTF16 = job.inputUTF16
      scope = job.scope
      limits = job.limits
    }
  }
  private final class Session {
    let generation: UUID
    let epoch: UInt64
    let connection: any SearchChildConnection
    let codec: SearchParentWireCodecSession
    var counter: SearchParentWireByteCounter
    var writerEpoch: UInt64 = 0
    var readSequence: UInt64 = 0
    var readReservation: UUID?
    var handshake = false
    var enabled = false
    var retiring = false
    var readTask: Task<Void, Never>?
    var readState = ReadState.available
    var progress: SearchParentCodecProgress?
    init(
      generation: UUID, epoch: UInt64, connection: any SearchChildConnection,
      codec: SearchParentWireCodecSession, maximumBytes: UInt64
    ) throws {
      self.generation = generation
      self.epoch = epoch
      self.connection = connection
      self.codec = codec
      counter = try SearchParentWireByteCounter(
        generation: generation, sessionEpoch: epoch,
        maximumWireBytes: maximumBytes)
    }
  }
  private enum ReadState {
    case available
    case reading(UInt64)
    case staging(UInt64, SearchParentReadPayload)
    case held(UInt64, SearchParentReadPayload)
    case failed(UInt64, SearchChildChannelObservation?)
    case consuming(UInt64)
    case stopping
  }
  private enum ReadAction {
    case read(UInt64)
    case consume(UInt64)
    case stop, exhausted
  }
  private struct Waiter {
    let registration: SearchParentDriverRegistration
    let continuation: CheckedContinuation<SearchParentWireOutcome, Error>
  }
  let lifecycle: SearchChildLifecycle
  let factory: SearchParentWireResponseAccumulatorFactory
  let maximumBytes: UInt64
  let observe: (@Sendable (SearchParentDriverEvent) -> Void)?
  let lane = SearchParentCodecLane()
  private var operation: Operation?
  private var lastAdmittedHandle: SearchParentWireHandle?
  private var receipt: (SearchParentWireHandle, SearchParentWireOutcome)?
  private var waiter: Waiter?
  private var session: Session?
  private var epoch: UInt64 = 0
  private var laneOwner: UUID?
  private var laneBusy: Bool { laneOwner != nil }
  private var bridge: SearchParentWireUploadBridge?
  private var coordinatorWake: CheckedContinuation<Void, Never>?
  private var readWake: CheckedContinuation<ReadAction, Never>?
  private var shuttingDown = false
  private var abandoned = false
  private final class JoinedOwner {
    let id = UUID()
    let key: SearchParentWireHandle?
    let admittedHandle: SearchParentWireHandle?
    let ownership: SearchParentJoinedOwnership
    var task: Task<Void, Never>?
    var completion: SearchParentJoinedShutdownCompletion?
    init(
      key: SearchParentWireHandle?, admittedHandle: SearchParentWireHandle?,
      ownership: SearchParentJoinedOwnership
    ) {
      self.key = key
      self.admittedHandle = admittedHandle
      self.ownership = ownership
    }
  }
  private enum TerminalMode {
    case unused, legacyStarted
    case joinedStarted(JoinedOwner)
  }
  private var terminalMode = TerminalMode.unused
  /// Sole retained owner registers here; payload/coordinator waits remain separate.
  private var joinedWake: CheckedContinuation<Void, Never>?

  init(
    lifecycle: SearchChildLifecycle, factory: @escaping SearchParentWireResponseAccumulatorFactory,
    maximumBytes: UInt64, observe: (@Sendable (SearchParentDriverEvent) -> Void)?
  ) {
    self.lifecycle = lifecycle
    self.factory = factory
    self.maximumBytes = maximumBytes
    self.observe = observe
  }
  func submit(_ job: SearchParentWireJob) throws -> SearchParentWireHandle {
    guard !shuttingDown else { throw SearchParentWireDriverError.shutDown }
    guard operation == nil, waiter == nil else { throw SearchParentWireDriverError.busy }
    if let receipt {
      if case .completed = receipt.1 { throw SearchParentWireDriverError.busy }
    }
    guard session?.retiring != true else { throw SearchParentWireDriverError.busy }
    receipt = nil
    let op = Operation(job, observe: observe)
    operation = op
    lastAdmittedHandle = op.handle
    session?.enabled = false
    observe?(.admitted(op.handle.nonce))
    let nonce = op.handle.nonce
    op.coordinator = Task.detached { [self] in
      await driveAndStage(nonce)
      await coordinatorExited(nonce)
    }
    return op.handle
  }
  /// Bounded advisory observation for the sole admission owner. It neither reserves
  /// a future submit nor certifies launcher pre-adoption quarantine was released.
  func settlement(after handle: SearchParentWireHandle?) async throws -> SearchParentWireSettlement
  {
    guard handle == lastAdmittedHandle else { throw SearchParentWireDriverError.staleHandle }
    guard requestScopesSettled else { return .pending }
    let inspectedEpoch = session?.epoch
    let child = await lifecycle.admissionInspection()
    // An admission or session transition can occur while the control lane is queried.
    guard handle == lastAdmittedHandle else { throw SearchParentWireDriverError.staleHandle }
    guard requestScopesSettled, inspectedEpoch == session?.epoch else { return .pending }
    switch child {
    case .unsettled:
      return .pending
    case .absent(let closed):
      guard session == nil else { return .pending }
      return .settled(admissionClosed: shuttingDown || closed)
    case .healthy(let generation):
      guard !shuttingDown, let current = session,
        current.generation == generation, current.handshake, current.enabled,
        !current.retiring, current.progress == nil
      else { return .pending }
      switch current.readState {
      case .available, .reading:
        // The healthy idle reader owns bounded resident transport, not request data.
        return .settled(admissionClosed: false)
      default:
        return .pending
      }
    }
  }

  private var requestScopesSettled: Bool {
    operation == nil && waiter == nil && receipt == nil && bridge == nil && !laneBusy
  }

  func wait(_ handle: SearchParentWireHandle, registration: SearchParentDriverRegistration)
    async throws -> SearchParentWireOutcome
  {
    if abandoned, case .joinedStarted = terminalMode {
      throw SearchParentWireDriverError.shutDown
    }
    guard operation?.handle == handle || receipt?.0 == handle else {
      throw SearchParentWireDriverError.staleHandle
    }
    guard waiter == nil else { throw SearchParentWireDriverError.observerBusy }
    return try await withCheckedThrowingContinuation { continuation in
      if registration.cancelled {
        continuation.resume(throwing: CancellationError())
        return
      }
      waiter = Waiter(registration: registration, continuation: continuation)
      observe?(.observerInstalled(handle.nonce))
      publish()
    }
  }
  func detach(_ handle: SearchParentWireHandle, registration: SearchParentDriverRegistration) {
    guard operation?.handle == handle || receipt?.0 == handle,
      let old = waiter, old.registration === registration, registration.cancelled
    else { return }
    waiter = nil
    old.continuation.resume(throwing: CancellationError())
  }
  func discard(_ handle: SearchParentWireHandle) throws {
    guard operation?.handle == handle || receipt?.0 == handle else {
      throw SearchParentWireDriverError.staleHandle
    }
    guard waiter == nil else { throw SearchParentWireDriverError.observerBusy }
    guard receipt?.0 == handle else { throw SearchParentWireDriverError.notSettled }
    receipt = nil
  }
  func cancel(_ handle: SearchParentWireHandle) async throws {
    guard let op = operation, op.handle == handle else {
      if receipt?.0 == handle { return }
      throw SearchParentWireDriverError.staleHandle
    }
    bridge?.close(.child(.cancelled))
    if op.cancelTask == nil {
      let ready = op.ready
      let lifecycle = lifecycle
      op.cancelTask = Task {
        if let ticket = await ready.value() { try? await lifecycle.cancel(ticket) }
      }
      observe?(.cancellationStarted(handle.nonce))
    }
    await op.cancelTask?.value
  }
  private func publish() {
    guard let result = receipt, let old = waiter else { return }
    waiter = nil
    guard old.registration.claim() else {
      old.continuation.resume(throwing: CancellationError())
      return
    }
    receipt = nil
    observe?(.resultDelivered(result.0.nonce))
    old.continuation.resume(returning: result.1)
  }
  private func pulse() {
    wakeCoordinator()
    if let reader = readWake, let action = chooseReadAction() {
      readWake = nil
      reader.resume(returning: action)
    }
  }
  private func wakeCoordinator() {
    let old = coordinatorWake
    coordinatorWake = nil
    old?.resume()
  }
  private func changed() async { await withCheckedContinuation { coordinatorWake = $0 } }
  private func token(_ session: Session, operationID: UUID = UUID()) throws
    -> SearchParentCodecToken
  {
    try SearchParentCodecToken(
      generation: session.generation, sessionEpoch: session.epoch, operationID: operationID)
  }
  /// Synchronous admission avoids retaining a source-bearing closure in an async frame.
  private func beginLane<T>(
    token: SearchParentCodecToken, reserved: Bool = false,
    body: @escaping @Sendable () throws -> T
  ) throws -> SearchParentCodecWork<T> {
    if reserved {
      guard laneOwner == token.operationID else { throw SearchParentCodecLaneError.busy }
    } else {
      guard laneOwner == nil else { throw SearchParentCodecLaneError.busy }
      laneOwner = token.operationID
    }
    do { return try lane.submit(token: token, body) } catch {
      finishLane(token.operationID)
      throw error
    }
  }
  private func finishLane(_ owner: UUID) {
    guard laneOwner == owner else { return }
    laneOwner = nil
    wakeJoinedIfReady()
  }
  /// The receipt has no source-bearing body. Only its matching admission credit is released.
  private func completeLane<T>(_ work: SearchParentCodecWork<T>, token: SearchParentCodecToken)
    async throws -> T
  {
    defer { finishLane(token.operationID) }
    return try await work.value()
  }
  private func reserveReader(_ current: Session) {
    let owner = UUID()
    laneOwner = owner
    current.readReservation = owner
  }
  private func finishReader(_ current: Session) {
    if let owner = current.readReservation { finishLane(owner) }
    current.readReservation = nil
  }
  private func driveAndStage(_ nonce: UUID) async {
    guard let op = operation, op.handle.nonce == nonce, let source = op.source else { return }
    do {
      let ticket = try await lifecycle.begin(requestID: op.handle.requestID)
      op.ticket = ticket
      await op.ready.resolve(ticket)
      observe?(.ticketStored(nonce, ticket.identity))
      let lifecycle = lifecycle
      op.observerTask = Task.detached { [self] in
        let result: SearchChildOutcome
        do { result = try await lifecycle.wait(for: ticket) } catch {
          result = .failed((error as? SearchChildFailure) ?? .protocolFailure)
        }
        await decided(nonce, result)
      }
      if let cancellation = op.cancelTask { await cancellation.value }
      try checkDecision(op)
      let connection = try await lifecycle.connection(for: ticket)
      observe?(.connectionAvailable(nonce, ticket.identity.generation))
      try checkDecision(op)
      if let previous = session, previous.generation != ticket.identity.generation {
        previous.retiring = true
        pulse()
        while session != nil { await changed() }
      }
      if session == nil {
        guard epoch < UInt64.max else { throw SearchChildFailure.protocolFailure }
        epoch += 1
        let token = try SearchParentCodecToken(
          generation: ticket.identity.generation,
          sessionEpoch: epoch, operationID: UUID())
        let factory = factory
        let work = try beginLane(token: token) {
          try SearchParentWireCodecSession(token: token, factory: factory)
        }
        let codec = try await completeLane(work, token: token)
        let created = try Session(
          generation: ticket.identity.generation, epoch: epoch,
          connection: connection, codec: codec, maximumBytes: maximumBytes)
        session = created
        let key = created.epoch
        created.readTask = Task.detached { [self] in await readLoop(key, connection: connection) }
        try await upload(created, op: op, source: nil)
        created.enabled = true
        pulse()
        while !created.handshake && op.decision == nil { await changed() }
        try checkDecision(op)
      }
      guard let current = session, current.generation == ticket.identity.generation,
        current.handshake, !current.retiring
      else { throw SearchChildFailure.protocolFailure }
      current.enabled = false
      while laneBusy { await changed() }
      try checkDecision(op)
      try await upload(current, op: op, source: source)
      try checkDecision(op)
      let token = try token(current)
      let codec = current.codec
      let expected = try beginLane(token: token) {
        try codec.expect(token: token, identity: ticket.identity)
      }
      try await completeLane(expected, token: token)
      observe?(.expectFinished(nonce))
      current.enabled = true
      pulse()
      while op.decision == nil || (op.provisional != nil && !op.terminalReady) { await changed() }
      if case .completed(let terminal) = op.decision, let provisional = op.provisional,
        provisional.identity == ticket.identity, provisional.terminal == terminal
      {
        switch terminal {
        case .success:
          guard let output = provisional.output else { throw SearchChildFailure.protocolFailure }
          op.staged = .completed(identity: ticket.identity, source: source.text, output: output)
        case .failure(let error):
          op.staged = .semanticFailure(identity: ticket.identity, error: error)
        }
        op.provisional = nil
        // Arm idle read before handing the result to an observer.
        current.enabled = true
        pulse()
        // A retained read action must own the next sequence before publication or retirement.
        // This is not a kernel/read-source admission acknowledgment.
        while session === current && !current.retiring
          && current.readSequence <= op.terminalReadSequence
        {
          await changed()
        }
        while session === current && readHelperStaged(current) { await changed() }
        if current.counter.retirementRequired {
          current.retiring = true
          let accepted = await lifecycle.requestIdleRetirement(generation: current.generation)
          observe?(.idleRetirementRequested(current.generation, accepted))
        }
      } else {
        throw failure(op.decision)
      }
    } catch {
      op.provisional = nil
      if let ticket = op.ticket {
        if op.decision == nil {
          // Explicit command intent has already closed the bridge. Its retained authority
          // command, not the resulting sink rejection, decides the lifecycle outcome.
          if op.cancelTask == nil && !shuttingDown {
            await reject(error, generation: ticket.identity.generation)
          }
          while op.decision == nil { await changed() }
        }
        session?.retiring = true
        bridge?.close(.child(failure(op.decision)))
        pulse()
        while session != nil { await changed() }
        op.staged = .failed(identity: ticket.identity, failure: failure(op.decision))
      } else {
        await op.ready.resolve(nil)
        // A begin refusal has not invalidated the old idle reader.
        session?.enabled = true
        pulse()
        op.staged = .failed(
          identity: nil, failure: (error as? SearchChildFailure) ?? .protocolFailure)
      }
    }
    op.source = nil
    // Test-only frozen instrumentation may hold this exact source-bearing scope.
    withExtendedLifetime(source) {}
  }
  private func coordinatorExited(_ nonce: UUID) {
    guard let op = operation, op.handle.nonce == nonce, let result = op.staged else { return }
    op.coordinator = nil
    op.observerTask = nil
    op.staged = nil
    receipt = (op.handle, result)
    operation = nil
    observe?(.coordinatorScopeExited(nonce))
    if abandoned {
      // An observer installed before joined abandonment keeps its one claim.
      if case .joinedStarted = terminalMode { publish() }
      receipt = nil
    } else {
      publish()
    }
    stopLaneIfReady()
    wakeJoinedIfReady()
  }
  private func decided(_ nonce: UUID, _ result: SearchChildOutcome) {
    guard let op = operation, op.handle.nonce == nonce, op.decision == nil else { return }
    op.decision = result
    observe?(.lifecycleDecided(nonce, result))
    if case .failed(let failure) = result {
      op.provisional = nil
      bridge?.close(.child(failure))
      session?.retiring = true
    }
    pulse()
  }
  private func checkDecision(_ op: Operation) throws {
    if case .failed(let failure) = op.decision { throw failure }
    if shuttingDown { throw SearchChildFailure.shutDown }
  }
  private func failure(_ outcome: SearchChildOutcome?) -> SearchChildFailure {
    if case .failed(let failure) = outcome { return failure }
    return .protocolFailure
  }
  private func reject(_ error: Error, generation: UUID) async {
    if let child = error as? SearchChildFailure, case .channelFailure(let code) = child, code > 0 {
      await lifecycle.rejectedChannel(.failure(code), generation: generation)
    } else if let wire = error as? SearchParentWireFailure,
      case .child(.channelFailure(let code)) = wire, code > 0
    {
      await lifecycle.rejectedChannel(.failure(code), generation: generation)
    } else {
      await lifecycle.rejectedProtocol(generation: generation)
    }
  }
  private func upload(_ current: Session, op: Operation, source: SearchParentDriverSource?)
    async throws
  {
    guard current.writerEpoch < UInt64.max else { throw SearchChildFailure.protocolFailure }
    current.writerEpoch += 1
    let identity = try SearchParentWriterIdentity(
      generation: current.generation,
      requestID: source == nil ? nil : op.handle.requestID, writerEpoch: current.writerEpoch)
    let upload = SearchParentWireUploadBridge(identity: identity)
    bridge = upload
    let connection = current.connection
    let epoch = current.epoch
    let nonce = op.handle.nonce
    let consumer = Task.detached(priority: nil) { [self] in
      do {
        try await upload.consume { [self] bytes in
          do {
            try await connection.write(bytes)
            await wrote(bytes.count, epoch: epoch)
          } catch {
            // Store concrete transport failure before emit can observe sink rejection.
            let compact: SearchParentWireFailure
            if let child = error as? SearchChildFailure {
              compact = .child(child)
            } else {
              compact = .writeFailure
            }
            upload.close(compact)
            throw compact
          }
        }
      } catch {}
      await consumerExited(nonce)
    }
    let token = try token(current)
    let codec = current.codec
    var producerError: Error?
    do {
      if let source {
        guard let ticket = op.ticket else { throw SearchChildFailure.protocolFailure }
        let request = try SearchWireRequest(
          identity: ticket.identity, query: op.query, operation: op.kind,
          inputUTF16: op.inputUTF16, scope: op.scope, limits: op.limits)
        let work = try beginLane(token: token) {
          try codec.writeRequest(token: token, request: request, text: source.text, bridge: upload)
        }
        _ = try await completeLane(work, token: token)
      } else {
        let work = try beginLane(token: token) {
          try codec.writeHello(token: token, bridge: upload)
        }
        try await completeLane(work, token: token)
      }
      upload.producerExited(.success(()))
    } catch {
      producerError = error
      upload.producerExited(.failure(error))
    }
    observe?(.producerExited(nonce))
    await consumer.value
    bridge = nil
    pulse()
    wakeJoinedIfReady()
    guard upload.snapshot.settled else { throw SearchChildFailure.protocolFailure }
    if let error = upload.snapshot.firstError { throw error }
    if let producerError { throw producerError }
  }
  private func consumerExited(_ nonce: UUID) { observe?(.consumerExited(nonce)) }
  private func wrote(_ count: Int, epoch: UInt64) {
    guard let current = session, current.epoch == epoch else { return }
    try? current.counter.record(count, generation: current.generation, sessionEpoch: epoch)
  }
  private func readHelperStaged(_ current: Session) -> Bool {
    switch current.readState {
    case .staging, .failed: return true
    default: return false
    }
  }
  private func chooseReadAction() -> ReadAction? {
    guard let current = session, !laneBusy else { return nil }
    switch current.readState {
    case .available:
      if current.retiring {
        current.readState = .stopping
        reserveReader(current)
        return .stop
      }
      guard current.readSequence < UInt64.max else {
        current.retiring = true
        current.readState = .stopping
        reserveReader(current)
        observe?(.readSequenceExhausted(current.generation))
        return .exhausted
      }
      current.readSequence += 1
      current.readState = .reading(current.readSequence)
      if operation == nil || operation?.terminalReady == true {
        observe?(.idleReadReserved(current.generation))
      }
      wakeCoordinator()
      return .read(current.readSequence)
    case .held(let sequence, _):
      if current.retiring {
        current.readState = .stopping
        reserveReader(current)
        return .stop
      }
      guard current.enabled else { return nil }
      reserveReader(current)
      return .consume(sequence)
    default: return nil
    }
  }
  private func nextReadAction(_ epoch: UInt64) async -> ReadAction {
    guard session?.epoch == epoch else { return .stop }
    if let action = chooseReadAction() { return action }
    return await withCheckedContinuation { readWake = $0 }
  }
  private func readLoop(_ epoch: UInt64, connection: any SearchChildConnection) async {
    while true {
      let action = await nextReadAction(epoch)
      switch action {
      case .read(let sequence):
        await readAndStage(epoch, sequence: sequence, connection: connection)
        await readScopeExited(epoch, sequence: sequence)
      case .consume(let sequence):
        await consumeAndStage(epoch, sequence: sequence)
        await consumeScopeExited(epoch, sequence: sequence)
      case .stop, .exhausted:
        if case .exhausted = action, let current = session, current.epoch == epoch {
          await lifecycle.rejectedProtocol(generation: current.generation)
        }
        await discardSession(epoch)
        readOwnerExited(epoch)
        return
      }
    }
  }
  private func readAndStage(
    _ epoch: UInt64, sequence: UInt64, connection: any SearchChildConnection
  ) async {
    do {
      let bytes = try await connection.read(maxBytes: searchWireMaximumFramePayload)
      guard let current = session, current.epoch == epoch,
        case .reading(sequence) = current.readState
      else { return }
      if bytes.isEmpty {
        current.readState = .failed(sequence, .endOfFile)
      } else if bytes.count > searchWireMaximumFramePayload {
        current.readState = .failed(sequence, nil)
      } else {
        try current.counter.record(bytes.count, generation: current.generation, sessionEpoch: epoch)
        current.readState = .staging(sequence, SearchParentReadPayload(bytes))
        observe?(.readHeld(current.generation, bytes.count))
      }
    } catch {
      guard let current = session, current.epoch == epoch else { return }
      if let child = error as? SearchChildFailure, case .channelFailure(let code) = child, code > 0
      {
        current.readState = .failed(sequence, .failure(code))
      } else {
        current.readState = .failed(sequence, nil)
      }
    }
  }
  private func readScopeExited(_ epoch: UInt64, sequence: UInt64) async {
    guard let current = session, current.epoch == epoch else { return }
    switch current.readState {
    case .staging(sequence, let payload): current.readState = .held(sequence, payload)
    case .failed(sequence, let observation):
      current.readState = .available
      current.retiring = true
      // Commit the truthful observation before waking an upload into sink rejection.
      if let observation {
        await lifecycle.rejectedChannel(observation, generation: current.generation)
      } else {
        await lifecycle.rejectedProtocol(generation: current.generation)
      }
      let cause: SearchChildFailure
      switch observation {
      case .endOfFile: cause = current.handshake ? .unexpectedExit : .handshakeFailure
      case .failure(let code): cause = .channelFailure(code)
      case nil: cause = .protocolFailure
      }
      bridge?.close(.child(cause))
    default: break
    }
    pulse()
  }
  private func consumeAndStage(_ epoch: UInt64, sequence: UInt64) async {
    guard let current = session, current.epoch == epoch,
      case .held(sequence, let payload) = current.readState
    else { return }
    current.readState = .consuming(sequence)
    do {
      guard let reservation = current.readReservation else { throw SearchWireError.invalidPhase }
      let token = try token(current, operationID: reservation)
      let codec = current.codec
      let work = try beginLane(token: token, reserved: true) {
        try codec.consume(token: token, bytes: payload.take())
      }
      current.progress = try await work.value()
    } catch {
      current.retiring = true
      await reject(error, generation: current.generation)
    }
  }
  private func consumeScopeExited(_ epoch: UInt64, sequence: UInt64) async {
    guard let current = session, current.epoch == epoch else { return }
    finishReader(current)
    current.readState = .available
    let progress = current.progress
    current.progress = nil
    switch progress {
    case .hello(let generation):
      do {
        try await lifecycle.acceptedHandshake(generation: generation)
        current.handshake = true
      } catch { current.retiring = true }
      current.enabled = false
    case .terminal(let provisional):
      current.enabled = false
      if let op = operation, let ticket = op.ticket, ticket.identity == provisional.identity {
        if case .failed = op.decision {
          current.retiring = true
          op.terminalReady = true
          pulse()
          return
        }
        op.terminalReadSequence = sequence
        op.provisional = provisional
        do {
          try await lifecycle.acceptedTerminal(provisional.terminal, ticket: ticket)
          observe?(.terminalAccepted(op.handle.nonce))
        } catch {}
        op.terminalReady = true
        current.enabled = true
      } else {
        current.retiring = true
        await lifecycle.rejectedProtocol(generation: current.generation)
      }
    case .needMore, nil: break
    }
    pulse()
  }
  private func discardSession(_ epoch: UInt64) async {
    guard let current = session, current.epoch == epoch else { return }
    do {
      guard let reservation = current.readReservation else { throw SearchWireError.invalidPhase }
      let token = try token(current, operationID: reservation)
      let codec = current.codec
      let work = try beginLane(token: token, reserved: true) { try codec.discard(token: token) }
      try await work.value()
    } catch {}
  }
  private func readOwnerExited(_ epoch: UInt64) {
    guard let current = session, current.epoch == epoch else { return }
    current.readTask = nil
    finishReader(current)
    session = nil
    observe?(.sessionReleased(current.generation))
    pulse()
    stopLaneIfReady()
    wakeJoinedIfReady()
  }
  func shutdown() async -> SearchParentWireShutdown {
    if case .joinedStarted(let owner) = terminalMode {
      return await join(owner).shutdown
    }
    if case .unused = terminalMode { terminalMode = .legacyStarted }
    shuttingDown = true
    bridge?.close(.child(.shutDown))
    session?.retiring = true
    pulse()
    let child = await lifecycle.shutdown()
    stopLaneIfReady()
    let settled = operation == nil && session == nil && !laneBusy && bridge == nil
    return SearchParentWireShutdown(
      child: child, parentLaneSettled: settled,
      retainedParentLanes: settled ? 0 : 1)
  }
  func abandon() async {
    abandoned = true
    if case .joinedStarted(let owner) = terminalMode {
      publish()
      receipt = nil
      _ = await join(owner)
    } else {
      receipt = nil
      if case .unused = terminalMode { terminalMode = .legacyStarted }
      _ = await shutdown()
    }
  }

  func shutdownJoined(after handle: SearchParentWireHandle?) async
    -> SearchParentJoinedShutdownResult
  {
    switch terminalMode {
    case .legacyStarted:
      return .callerRefused(.legacyModeSelected)
    case .joinedStarted(let owner):
      guard handle == owner.key else { return .callerRefused(.differentJoinOwner) }
      return .completed(await join(owner))
    case .unused:
      let owner = JoinedOwner(
        key: handle, admittedHandle: lastAdmittedHandle, ownership: joinedOwnership(handle))
      terminalMode = .joinedStarted(owner)
      // Close actual admission synchronously, before task creation or any await.
      shuttingDown = true
      bridge?.close(.child(.shutDown))
      session?.retiring = true
      pulse()
      wakeJoinedIfReady()
      let ownerID = owner.id
      owner.task = Task.detached { [self] in await runJoined(ownerID) }
      return .completed(await join(owner))
    }
  }

  private func joinedOwnership(_ handle: SearchParentWireHandle?) -> SearchParentJoinedOwnership {
    if abandoned { return .refused(.abandoned) }
    if handle != lastAdmittedHandle { return .refused(.staleHandle) }
    if waiter != nil { return .refused(.observerPresent) }
    if operation != nil { return .refused(.requestActive) }
    if receipt != nil { return .refused(.receiptUnconsumed) }
    return .admitted
  }

  private var joinedMechanicalReady: Bool {
    operation == nil && session == nil && laneOwner == nil && bridge == nil
  }
  private func wakeJoinedIfReady() {
    guard joinedMechanicalReady else { return }
    let old = joinedWake
    joinedWake = nil
    old?.resume()
  }
  private func waitForJoinedMechanical() async {
    while !joinedMechanicalReady {
      await withCheckedContinuation { continuation in
        // Predicate and registration share this actor turn: no lost transition.
        if joinedMechanicalReady {
          continuation.resume()
        } else {
          precondition(joinedWake == nil, "Only the retained terminal owner may wait")
          joinedWake = continuation
        }
      }
    }
  }
  private func join(_ owner: JoinedOwner) async -> SearchParentJoinedShutdownCompletion {
    if let completed = owner.completion { return completed }
    guard let task = owner.task else { preconditionFailure("Terminal owner not installed") }
    // Caller cancellation never forwards to the retained detached owner.
    await task.value
    guard let completed = owner.completion else {
      preconditionFailure("Terminal owner returned without its committed completion")
    }
    return completed
  }
  private func runJoined(_ ownerID: UUID) async {
    guard case .joinedStarted(let owner) = terminalMode, owner.id == ownerID else {
      preconditionFailure("Terminal owner changed")
    }
    let originalChild = await lifecycle.shutdown()
    wakeJoinedIfReady()
    await waitForJoinedMechanical()
    lane.requestStop()
    let laneStop: SearchParentJoinedLaneStop
    do {
      try await lane.waitForStop()
      laneStop = .acknowledged
    } catch {
      laneStop = .failed
    }
    guard case .joinedStarted(let current) = terminalMode, current === owner,
      owner.admittedHandle == lastAdmittedHandle
    else { preconditionFailure("Terminal owner changed while joining") }
    let settled = joinedMechanicalReady && laneStop == .acknowledged
    // Commit the first combined receipt; original pending child is never upgraded.
    owner.completion = SearchParentJoinedShutdownCompletion(
      shutdown: SearchParentWireShutdown(
        child: originalChild, parentLaneSettled: settled,
        retainedParentLanes: settled ? 0 : 1),
      ownership: owner.ownership, laneStop: laneStop)
  }
  private func stopLaneIfReady() {
    if shuttingDown && operation == nil && session == nil && !laneBusy { lane.requestStop() }
  }
}
