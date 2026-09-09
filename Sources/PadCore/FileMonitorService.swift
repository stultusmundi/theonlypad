import Darwin
import Dispatch
import Foundation

public struct FileMonitorSnapshot: Sendable {
  public let currentToken: FileObservationToken?
  public let cancelled: Bool
  public let documentID: UUID
  public let epoch: UInt64
  public let baselineRevision: UInt64
  public let boundIdentity: FileTargetIdentity?
}
public enum FileMonitorError: Error { case capacity, duplicateDocument, invalidRequest, stopped }
public enum FileCheckError: Error, Equatable {
  case cancelled, capacity, failed, invalidRequest, stopped
}
private final class ShutdownState: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
}
private enum ManualValue {
  case observation(DiskObservation)
  case snapshot(ExternalFileActionSnapshot)
  case validated
}
private final class ManualToken: @unchecked Sendable {
  private let lock = NSLock()
  private let shutdown: ShutdownState
  private var admitted = false
  private var cancelled = false
  private var completed = false
  private var callback: ((Result<ManualValue, FileActionError>) -> Void)?
  private var onCompletion: (() -> Void)?
  fileprivate init(
    shutdown: ShutdownState, callback: @escaping (Result<ManualValue, FileActionError>) -> Void,
    onCompletion: @escaping () -> Void
  ) {
    self.shutdown = shutdown
    self.callback = callback
    self.onCompletion = onCompletion
  }
  fileprivate func markAdmitted() {
    lock.lock()
    admitted = true
    lock.unlock()
  }
  fileprivate var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled || shutdown.isStopped
  }
  fileprivate func invalidate() {
    lock.lock()
    if !completed { cancelled = true }
    lock.unlock()
  }
  fileprivate func complete(_ result: Result<ManualValue, FileActionError>) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let delivered: Result<ManualValue, FileActionError> =
      cancelled || (admitted && shutdown.isStopped) ? .failure(.cancelled) : result
    let callback = self.callback
    self.callback = nil
    let completion = onCompletion
    onCompletion = nil
    lock.unlock()
    callback?(delivered)
    completion?()
  }
  public func cancel() {
    invalidate()
    complete(.failure(.cancelled))
  }
}
public final class FileCheckToken: @unchecked Sendable {
  fileprivate let token: ManualToken
  fileprivate init(_ token: ManualToken) { self.token = token }
  public func cancel() { token.cancel() }
}
public final class FileMonitorRegistration: @unchecked Sendable {
  private let lock = NSLock()
  private let shutdown: ShutdownState
  private let documentID: UUID
  private var epoch: UInt64
  private var baselineRevision: UInt64
  private var boundIdentity: FileTargetIdentity?
  fileprivate init(
    shutdown: ShutdownState, documentID: UUID, epoch: UInt64, baselineRevision: UInt64,
    boundIdentity: FileTargetIdentity?
  ) {
    self.shutdown = shutdown
    self.documentID = documentID
    self.epoch = epoch
    self.baselineRevision = baselineRevision
    self.boundIdentity = boundIdentity
  }
  private var token: FileObservationToken?
  private var cancelled = false
  private var cancellation: (() -> Void)?
  public var snapshot: FileMonitorSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return FileMonitorSnapshot(
      currentToken: token, cancelled: cancelled || shutdown.isStopped, documentID: documentID,
      epoch: epoch, baselineRevision: baselineRevision, boundIdentity: boundIdentity)
  }
  fileprivate func issue(_ token: FileObservationToken?) {
    lock.lock()
    defer { lock.unlock() }
    self.token = token
  }
  fileprivate func installCancellation(_ body: @escaping () -> Void) {
    lock.lock()
    cancellation = body
    lock.unlock()
  }
  fileprivate func replaceCancellationIfActive(
    epoch: UInt64, baselineRevision: UInt64, _ body: @escaping () -> Void
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled && !shutdown.isStopped else { return false }
    token = nil
    self.epoch = epoch
    self.baselineRevision = baselineRevision
    boundIdentity = nil
    cancellation = body
    return true
  }
  fileprivate func accepts(_ token: FileObservationToken) -> Bool {
    let state = snapshot
    return !state.cancelled && state.currentToken == token
  }
  fileprivate func bind(_ identity: FileTargetIdentity?, for issued: FileObservationToken) {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled && !shutdown.isStopped, token == issued else { return }
    if boundIdentity == nil { boundIdentity = identity }
  }
  public func cancelAndSnapshot() -> FileMonitorSnapshot {
    lock.lock()
    cancelled = true
    let result = FileMonitorSnapshot(
      currentToken: token, cancelled: true, documentID: documentID,
      epoch: epoch, baselineRevision: baselineRevision, boundIdentity: boundIdentity)
    let body = cancellation
    cancellation = nil
    lock.unlock()
    body?()
    return result
  }
  public func cancel() { _ = cancelAndSnapshot() }
}
public enum FileActionError: Error, Equatable, Sendable {
  case cancelled, capacity, invalidRequest, stopped, observationChanged, decoding, notDownloaded,
    policy, readFailed
}
public final class FileActionToken: @unchecked Sendable {
  fileprivate let token: ManualToken
  fileprivate init(_ token: ManualToken) { self.token = token }
  public func cancel() { token.cancel() }
}
public final class FileMonitorService: @unchecked Sendable {
  private let core: MonitorCore
  public init() { core = MonitorCore(hooks: MonitorHooks()) }
  init(hooks: MonitorHooks) { core = MonitorCore(hooks: hooks) }
  public func register(
    documentID: UUID, url: URL, baseline: Data, baselineRevision: UInt64,
    boundIdentity: FileTargetIdentity? = nil,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> FileMonitorRegistration {
    try core.register(
      documentID: documentID, url: url, baseline: baseline,
      baselineRevision: baselineRevision, boundIdentity: boundIdentity, receive: receive)
  }
  public func readOnce(
    requestID: UUID, url: URL, matching: DiskObservation, fallbackEncoding: DocumentEncoding,
    receive: @escaping @Sendable (UUID, Result<ExternalFileActionSnapshot, FileActionError>) -> Void
  ) -> FileActionToken {
    FileActionToken(
      core.enqueue(
        requestID: requestID, url: url, operation: .read(url, matching, fallbackEncoding)
      ) { result in
        switch result {
        case .success(.snapshot(let snapshot)): receive(requestID, .success(snapshot))
        case .success: receive(requestID, .failure(.readFailed))
        case .failure(let error): receive(requestID, .failure(error))
        }
      })
  }
  public func revalidateOnce(
    requestID: UUID, snapshot: ExternalFileActionSnapshot,
    receive: @escaping @Sendable (UUID, Result<Void, FileActionError>) -> Void
  ) -> FileActionToken {
    FileActionToken(
      core.enqueue(requestID: requestID, url: nil, operation: .revalidate(snapshot)) { result in
        switch result {
        case .success(.validated): receive(requestID, .success(()))
        case .success: receive(requestID, .failure(.readFailed))
        case .failure(let error): receive(requestID, .failure(error))
        }
      })
  }
  public func requestCheck(documentID: UUID, forceContents: Bool = true) {
    core.queue.async { [core] in
      guard let entry = core.entries[documentID] else { return }
      core.request(documentID, epoch: entry.epoch)
    }
  }
  public func rebind(documentID: UUID, url: URL, baseline: Data, baselineRevision: UInt64) throws {
    try core.rebind(
      documentID: documentID, url: url, baseline: baseline, revision: baselineRevision)
  }
  public func suspendDelivery() { core.delivery.advance(enabled: false) }
  public func resumeAndReconcile() {
    core.delivery.advance(enabled: true)
    core.queue.async { [core] in
      for entry in core.entries.values {
        entry.queued = true
        entry.due = 0
        entry.firstEvent = nil
      }
      core.pump()
    }
  }
  public func checkOnce(
    requestID: UUID, documentID: UUID, url: URL, baseline: Data,
    baselineRevision: UInt64, boundIdentity: FileTargetIdentity? = nil,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, FileCheckError>) -> Void
  ) -> FileCheckToken {
    core.checkOnce(
      requestID: requestID, documentID: documentID, url: url,
      baseline: baseline, revision: baselineRevision, boundIdentity: boundIdentity, receive: receive
    )
  }
  func noteEventForTesting(documentID: UUID) {
    core.queue.sync {
      guard let entry = core.entries[documentID] else { return }
      core.noteEvent(documentID, epoch: entry.epoch)
    }
  }
  func tickForTesting() { core.queue.sync { core.tick() } }
  var diagnostics: MonitorDiagnostics {
    core.queue.sync {
      MonitorDiagnostics(
        workers: core.workers,
        watchReservations: core.watchReservations, peakReservations: core.peakReservations,
        pendingManualCallbacks: core.pendingManualCallbacks,
        pendingCallbacks: core.pendingCallbacks,
        identities: core.entries.compactMapValues { $0.pair?.identity })
    }
  }
  public func stop() { core.stop() }
  deinit { core.stop() }
}

private final class DeliveryState: @unchecked Sendable {
  private let lock = NSLock()
  private var generation = UUID()
  private var enabled = true
  var current: UUID? {
    lock.lock()
    defer { lock.unlock() }
    return enabled ? generation : nil
  }
  func advance(enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    generation = UUID()
    lock.unlock()
  }
  func accepts(_ value: UUID?) -> Bool {
    guard let value else { return false }
    return current == value
  }
}
struct MonitorWorkerOutcome {
  let observation: DiskObservation
  fileprivate let prepared: WatchPair?
  func discardPrepared() { for descriptor in prepared?.descriptors ?? [] { close(descriptor) } }
  var preparedDescriptors: [Int32] { prepared?.descriptors ?? [] }
}
private struct DeliveryPayload {
  let token: FileObservationToken
  let observation: DiskObservation
  let generation: UUID?
}
private enum ManualOperation {
  case check(URL, Data, FileTargetIdentity?)
  case read(URL, DiskObservation, DocumentEncoding)
  case revalidate(ExternalFileActionSnapshot)
}
private final class ManualJob {
  let completionID: UUID
  let id: UUID
  let operation: ManualOperation
  let token: ManualToken
  var running = false
  var workFinished = false
  var callbackFinished = false
  var completionQueued = false
  var completionDrained = false
  init(completionID: UUID, id: UUID, operation: ManualOperation, token: ManualToken) {
    self.completionID = completionID
    self.id = id
    self.operation = operation
    self.token = token
  }
}
private final class MonitorEntry {
  let id: UUID
  let url: URL
  let baseline: Data
  let revision: UInt64
  let epoch: UInt64
  let registration: FileMonitorRegistration
  let receive: @Sendable (FileObservationToken, DiskObservation) -> Void
  var pendingDelivery: DeliveryPayload?
  var deliveryScheduled = false
  var waitingForWatchCapacity = false
  var initialRetryAvailable = true
  var sequence: UInt64 = 0
  var running = false
  var queued = true
  var due: TimeInterval = 0
  var firstEvent: TimeInterval?
  var nextReconciliation: TimeInterval = 0
  var pair: WatchPair?
  var boundIdentity: FileTargetIdentity?
  init(
    id: UUID, url: URL, baseline: Data, revision: UInt64, epoch: UInt64,
    registration: FileMonitorRegistration,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) {
    self.id = id
    self.url = url
    self.baseline = baseline
    self.revision = revision
    self.epoch = epoch
    self.registration = registration
    self.receive = receive
  }
}
private final class WatchPair {
  let descriptors: [Int32]
  let identity: FileTargetIdentity
  var sources: [DispatchSourceFileSystemObject] = []
  var remainingCancels = 2
  var borrowers = 0
  var cleanupQueued = false
  init(_ descriptors: [Int32], identity: FileTargetIdentity) {
    self.descriptors = descriptors
    self.identity = identity
  }
}
struct MonitorDiagnostics {
  let workers: Int
  let watchReservations: Int
  let peakReservations: Int
  let pendingManualCallbacks: Int
  let pendingCallbacks: Int
  let identities: [UUID: FileTargetIdentity]
}
enum WatchPreparationStage: CaseIterable, Sendable {
  case resolvingParent, openingParent, openingFile, checkingIdentity
}
struct MonitorHooks: Sendable {
  var readAction:
    @Sendable (URL, DiskObservation, DocumentEncoding, @escaping @Sendable () -> Bool) throws ->
      ExternalFileActionSnapshot = {
        try ExternalFileActionReader().read($0, matching: $1, fallbackEncoding: $2, isCancelled: $3)
      }
  var revalidateAction:
    @Sendable (ExternalFileActionSnapshot, @escaping @Sendable () -> Bool) throws -> Void = {
      try ExternalFileActionReader().revalidate($0, isCancelled: $1)
    }
  var beforeFirstBinding: @Sendable () -> Void = {}
  var afterFirstBinding: @Sendable () -> Void = {}
  var beforeManualDelivery: @Sendable () -> Void = {}
  var openWatchParent: @Sendable (String) -> Int32 = {
    open($0, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  }
  var openWatchFile: @Sendable (Int32, String) -> Int32 = {
    openat($0, $1, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
  }
  var observationGuard: @Sendable (() throws -> DiskObservation) throws -> DiskObservation = {
    try FileMaterializationGuard.perform($0)
  }
  var workerGuard: @Sendable (() throws -> MonitorWorkerOutcome) throws -> MonitorWorkerOutcome = {
    try FileMaterializationGuard.perform(discardOnRestoreFailure: { $0.discardPrepared() }, $0)
  }
  var watchBoundary: @Sendable (WatchPreparationStage) -> Void = { _ in }

  var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

  var beforeRebindInstall: @Sendable () -> Void = {}
  var beforeMovedCandidate: @Sendable () throws -> Void = {}
  var beforeWatchOpen: @Sendable () throws -> Void = {}
  var beforeClose: @Sendable () -> Void = {}

  var beforeDelivery: @Sendable () -> Void = {}
  var probe:
    @Sendable (URL, Data, FileTargetIdentity?, @escaping @Sendable () -> Bool) throws ->
      DiskObservation = { url, baseline, identity, cancelled in
        try ExternalFileProbe().observe(
          url, expected: baseline, boundIdentity: identity,
          forceContents: true, previous: nil, isCancelled: cancelled)
      }
}
private final class MonitorCore: @unchecked Sendable {
  let hooks: MonitorHooks
  let delivery = DeliveryState()
  let shutdown = ShutdownState()
  private var timer: DispatchSourceTimer?
  init(hooks: MonitorHooks) {
    self.hooks = hooks
    let timer = DispatchSource.makeTimerSource(queue: queue)
    self.timer = timer
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.schedule(
      deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
    timer.activate()
  }

  let queue = DispatchQueue(label: "monitor.control")
  let callbackQueue = DispatchQueue(label: "monitor.callbacks")
  let manualCallbackQueue = DispatchQueue(label: "monitor.manual-callbacks")
  var manual: [UUID: ManualJob] = [:]
  var manualOrder: [UUID] = []
  var preferManual = true
  var entries: [UUID: MonitorEntry] = [:]
  var order: [UUID] = []
  var cleanup: [WatchPair] = []
  var workers = 0
  var watchReservations = 0
  var peakReservations = 0
  var pendingCallbacks = 0
  var pendingManualCallbacks = 0
  var nextEpoch: UInt64 = 0
  var stopped = false

  func register(
    documentID: UUID, url: URL, baseline: Data, baselineRevision: UInt64,
    boundIdentity: FileTargetIdentity? = nil,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> FileMonitorRegistration {
    // URL syntax and byte counts only. Resolving/opening paths is worker-owned.
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count < 4096,
      baseline.count <= 100_000_000
    else { throw FileMonitorError.invalidRequest }
    return try queue.sync {
      guard !stopped && !shutdown.isStopped else { throw FileMonitorError.stopped }
      guard entries[documentID] == nil else { throw FileMonitorError.duplicateDocument }
      guard entries.count < 128, nextEpoch < .max else { throw FileMonitorError.capacity }
      nextEpoch += 1
      let registration = FileMonitorRegistration(
        shutdown: shutdown, documentID: documentID, epoch: nextEpoch,
        baselineRevision: baselineRevision, boundIdentity: boundIdentity)
      let entry = MonitorEntry(
        id: documentID, url: url, baseline: baseline,
        revision: baselineRevision, epoch: nextEpoch, registration: registration, receive: receive)
      entry.boundIdentity = boundIdentity
      entry.nextReconciliation = hooks.clock() + 30
      let epoch = entry.epoch
      registration.installCancellation { [weak self] in
        self?.queue.async { [weak self] in self?.remove(documentID, epoch: epoch) }
      }
      entries[documentID] = entry
      order.append(documentID)
      pump()
      return registration
    }
  }
  func checkOnce(
    requestID: UUID, documentID: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, FileCheckError>) -> Void
  ) -> FileCheckToken {
    FileCheckToken(
      enqueue(requestID: requestID, url: url, operation: .check(url, baseline, boundIdentity)) {
        result in
        switch result {
        case .success(.observation(let observation)): receive(requestID, .success(observation))
        case .success: receive(requestID, .failure(.failed))
        case .failure(let error):
          let mapped: FileCheckError
          switch error {
          case .cancelled: mapped = .cancelled
          case .capacity: mapped = .capacity
          case .invalidRequest: mapped = .invalidRequest
          case .stopped: mapped = .stopped
          default: mapped = .failed
          }
          receive(requestID, .failure(mapped))
        }
      })
  }
  func enqueue(
    requestID: UUID, url: URL?, operation: ManualOperation,
    receive: @escaping (Result<ManualValue, FileActionError>) -> Void
  ) -> ManualToken {
    let completionID = UUID()
    let token = ManualToken(
      shutdown: shutdown, callback: receive,
      onCompletion: { [weak self] in
        self?.queue.async { [weak self] in
          guard let self, let job = self.manual[requestID], job.completionID == completionID else {
            return
          }
          job.callbackFinished = true
          self.finishManualIfReady(job)
          self.pump()
        }
      })
    let refusal: FileActionError? = queue.sync {
      guard !stopped && !shutdown.isStopped else { return .stopped }
      if let url {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
          url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count < 4096
        else { return .invalidRequest }
      }
      if case .check(_, let baseline, _) = operation, baseline.count > 100_000_000 {
        return .invalidRequest
      }
      guard manual[requestID] == nil else { return .invalidRequest }
      guard manual.count < 16 else { return .capacity }
      token.markAdmitted()
      let job = ManualJob(
        completionID: completionID, id: requestID, operation: operation, token: token)
      manual[requestID] = job
      manualOrder.append(requestID)
      pump()
      return nil
    }
    if let refusal { token.complete(.failure(refusal)) }
    return token
  }
  func finishManualIfReady(_ job: ManualJob) {
    guard
      job.callbackFinished && (job.workFinished || !job.running)
        && (!job.completionQueued || job.completionDrained)
    else { return }
    manual.removeValue(forKey: job.id)
    manualOrder.removeAll { $0 == job.id }
  }
  func scheduleManualCompletion(_ job: ManualJob, result: Result<ManualValue, FileActionError>) {
    guard !job.completionQueued else { return }
    job.completionQueued = true
    pendingManualCallbacks += 1
    manualCallbackQueue.async { [self] in
      hooks.beforeManualDelivery()
      job.token.complete(result)
      queue.async { [self] in
        pendingManualCallbacks -= 1
        job.completionDrained = true
        finishManualIfReady(job)
        pump()
      }
    }
  }
  func startManual(_ job: ManualJob) {
    job.running = true
    workers += 1
    peakReservations = max(peakReservations, watchReservations + workers * 6)
    DispatchQueue.global(qos: .utility).async { [self] in
      let result: Result<ManualValue, FileActionError>
      do {
        if job.token.isCancelled { throw CancellationError() }
        switch job.operation {
        case .check(let url, let baseline, let identity):
          result = .success(
            .observation(
              try hooks.observationGuard {
                try hooks.probe(url, baseline, identity, { job.token.isCancelled })
              }))
        case .read(let url, let observation, let encoding):
          result = .success(
            .snapshot(try hooks.readAction(url, observation, encoding, { job.token.isCancelled })))
        case .revalidate(let snapshot):
          try hooks.revalidateAction(snapshot, { job.token.isCancelled })
          result = .success(.validated)
        }
      } catch {
        if job.token.isCancelled || error is CancellationError {
          result = .failure(.cancelled)
        } else if case .check = job.operation, isMaterializationRefusal(error) {
          result = .success(.observation(unavailableAfter(error)))
        } else {
          result = .failure(actionError(error))
        }
      }
      queue.async { [self] in
        workers -= 1
        job.workFinished = true
        scheduleManualCompletion(job, result: result)
        finishManualIfReady(job)
        pump()
      }
    }
  }
  func rebind(documentID: UUID, url: URL, baseline: Data, revision: UInt64) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
      url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count < 4096,
      baseline.count <= 100_000_000
    else { throw FileMonitorError.invalidRequest }
    try queue.sync {
      guard !stopped && !shutdown.isStopped else { throw FileMonitorError.stopped }
      guard let old = entries[documentID], !old.registration.snapshot.cancelled,
        nextEpoch < .max
      else { throw FileMonitorError.invalidRequest }
      nextEpoch += 1
      let replacement = MonitorEntry(
        id: documentID, url: url, baseline: baseline,
        revision: revision, epoch: nextEpoch, registration: old.registration, receive: old.receive)
      replacement.nextReconciliation = hooks.clock() + 30
      let epoch = nextEpoch
      hooks.beforeRebindInstall()
      guard
        old.registration.replaceCancellationIfActive(
          epoch: epoch, baselineRevision: revision,
          { [weak self] in
            self?.queue.async { [weak self] in self?.remove(documentID, epoch: epoch) }
          })
      else { throw FileMonitorError.invalidRequest }
      retire(old.pair)
      entries[documentID] = replacement
      pump()
    }
  }
  func stop() {
    // Fence admission synchronously. Already admitted client callbacks cannot be recalled.
    shutdown.stop()
    delivery.advance(enabled: false)
    queue.async { [self] in
      guard !stopped else { return }
      stopped = true
      timer?.cancel()
      timer = nil
      for entry in entries.values {
        entry.registration.cancel()
        retire(entry.pair)
      }
      for job in manual.values {
        job.token.invalidate()
        scheduleManualCompletion(job, result: .failure(.cancelled))
      }
      entries.removeAll()
      order.removeAll()
      pump()
    }
  }
  func remove(_ id: UUID, epoch: UInt64) {
    guard let entry = entries[id], entry.epoch == epoch else { return }
    entries.removeValue(forKey: id)
    order.removeAll { $0 == id }
    retire(entry.pair)
    pump()
  }
  func request(_ id: UUID, epoch: UInt64) {
    guard !stopped, let entry = entries[id], entry.epoch == epoch,
      !entry.registration.snapshot.cancelled
    else { return }
    entry.queued = true
    entry.due = 0
    entry.firstEvent = nil
    pump()
  }
  func noteEvent(_ id: UUID, epoch: UInt64) {
    guard !stopped, let entry = entries[id], entry.epoch == epoch,
      !entry.registration.snapshot.cancelled
    else { return }
    let now = hooks.clock()
    // Do not postpone an already admitted explicit or periodic check.
    if entry.queued && entry.firstEvent == nil && entry.due <= now { return }
    if entry.firstEvent == nil { entry.firstEvent = now }
    entry.queued = true
    entry.due = min(now + 0.25, (entry.firstEvent ?? now) + 2)
    pump()
  }
  func tick() {
    guard !stopped else { return }
    let now = hooks.clock()
    for entry in entries.values where now >= entry.nextReconciliation {
      entry.queued = true
      entry.due = 0
      entry.firstEvent = nil
      entry.nextReconciliation = now + 30
    }
    pump()
  }
  func pump() {
    if watchReservations <= 254 {
      for entry in entries.values where entry.waitingForWatchCapacity {
        entry.waitingForWatchCapacity = false
        entry.queued = true
        entry.due = 0
      }
    }
    while workers < 2 {
      if !cleanup.isEmpty {
        let pair = cleanup.removeFirst()
        workers += 1
        peakReservations = max(peakReservations, watchReservations + workers * 6)
        DispatchQueue.global(qos: .utility).async { [self] in
          hooks.beforeClose()
          for descriptor in pair.descriptors { close(descriptor) }
          queue.async { [self] in
            workers -= 1
            watchReservations -= 2
            pump()
          }
        }
        continue
      }
      guard !stopped && !shutdown.isStopped else { return }
      let index =
        delivery.current == nil
        ? nil
        : order.firstIndex(where: {
          guard let item = entries[$0] else { return false }
          return item.queued && item.due <= hooks.clock() && !item.running
            && !item.registration.snapshot.cancelled
        })
      let pendingManual = manualOrder.compactMap { manual[$0] }.first {
        !$0.running && !$0.token.isCancelled && !$0.callbackFinished
      }
      if let pendingManual, preferManual || index == nil {
        preferManual = false
        startManual(pendingManual)
        continue
      }
      guard let index, let entry = entries[order[index]] else { return }
      preferManual = true
      order.remove(at: index)
      order.append(entry.id)
      entry.queued = false
      entry.due = 0
      entry.firstEvent = nil
      entry.nextReconciliation = hooks.clock() + 30
      entry.running = true
      workers += 1
      guard entry.sequence < .max else {
        workers -= 1
        entry.running = false
        entry.registration.cancel()
        continue
      }
      entry.sequence += 1
      let token = FileObservationToken(
        documentID: entry.id, epoch: entry.epoch,
        baselineRevision: entry.revision, sequence: entry.sequence)
      entry.registration.issue(token)
      let reserved = watchReservations <= 254
      if reserved { watchReservations += 2 }
      peakReservations = max(peakReservations, watchReservations + workers * 6)
      let deliveryGeneration = delivery.current
      let bound = entry.boundIdentity
      let borrowedPair = entry.pair
      borrowedPair?.borrowers += 1
      let watched = borrowedPair?.identity
      DispatchQueue.global(qos: .utility).async { [self] in
        let outcome: MonitorWorkerOutcome
        do {
          outcome = try hooks.workerGuard {
            var result: DiskObservation
            do {
              result = try hooks.probe(
                entry.url, entry.baseline, bound,
                { !entry.registration.accepts(token) })
            } catch let policyError as FileMaterializationError {
              throw policyError
            } catch {
              if isMaterializationRefusal(error) { throw error }
              result = DiskObservation(
                metadata: nil, content: .unavailable,
                locationProblem: .checkDelayed, readOnlyHint: false, movedCandidate: nil)
            }
            if result.locationProblem == .missing, let borrowedPair,
              entry.registration.accepts(token),
              let candidate = try movedCandidate(
                borrowedPair, baseline: entry.baseline, hooks: hooks,
                isCancelled: { !entry.registration.accepts(token) })
            {
              result = DiskObservation(
                metadata: result.metadata, content: result.content,
                locationProblem: result.locationProblem, readOnlyHint: result.readOnlyHint,
                movedCandidate: candidate)
            }
            let prepared: WatchPair?
            if reserved, entry.registration.accepts(token),
              let identity = result.metadata?.identity,
              identity != watched
            {
              do {
                try hooks.beforeWatchOpen()
                prepared = try prepareWatch(entry.url, identity: identity, hooks: hooks)
              } catch let policyError as FileMaterializationError { throw policyError } catch {
                if isMaterializationRefusal(error) { throw error }
                prepared = nil
              }
            } else {
              prepared = nil
            }
            return MonitorWorkerOutcome(observation: result, prepared: prepared)
          }
        } catch {
          outcome = MonitorWorkerOutcome(observation: unavailableAfter(error), prepared: nil)
        }
        hooks.beforeFirstBinding()
        entry.registration.bind(outcome.observation.metadata?.identity, for: token)
        hooks.afterFirstBinding()
        let observed = outcome.observation
        let prepared = outcome.prepared
        queue.async { [self] in
          workers -= 1
          if let borrowedPair {
            borrowedPair.borrowers -= 1
            queueCleanupIfReady(borrowedPair)
          }
          let result = observed
          if reserved && prepared == nil { watchReservations -= 2 }
          guard entries[entry.id] === entry, entry.registration.accepts(token), !stopped else {
            if let prepared { cleanup.append(prepared) }
            pump()
            return
          }
          entry.running = false
          var delivered = result
          let needsWatch =
            result.metadata != nil && result.metadata?.identity != entry.pair?.identity
          if needsWatch && prepared == nil {
            delivered = DiskObservation(
              metadata: result.metadata, content: .unavailable,
              locationProblem: .checkDelayed, readOnlyHint: result.readOnlyHint, movedCandidate: nil
            )
            if !reserved {
              retire(entry.pair)
              entry.pair = nil
              entry.waitingForWatchCapacity = true
            }
          }
          if let prepared {
            retire(entry.pair)
            entry.pair = prepared
            install(prepared, entry: entry)
            // One reconciliation closes the accepted-probe/source-registration gap.
            entry.queued = true
          }
          if entry.boundIdentity == nil { entry.boundIdentity = result.metadata?.identity }
          if entry.pair == nil && entry.initialRetryAvailable
            && (result.locationProblem == .changedDuringRead || result.metadata != nil)
          {
            entry.initialRetryAvailable = false
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
              self?.request(entry.id, epoch: entry.epoch)
            }
          }
          entry.pendingDelivery = DeliveryPayload(
            token: token, observation: delivered,
            generation: deliveryGeneration)
          scheduleDeliveries()
          pump()
        }
      }
    }
  }
  func scheduleDeliveries() {
    for id in order {
      guard pendingCallbacks < 128 else { return }
      guard let entry = entries[id], !entry.deliveryScheduled, entry.pendingDelivery != nil,
        !entry.registration.snapshot.cancelled
      else { continue }
      entry.deliveryScheduled = true
      pendingCallbacks += 1
      callbackQueue.async { [self, weak entry] in
        hooks.beforeDelivery()
        let payload: DeliveryPayload? = queue.sync {
          guard let entry else { return nil }
          let value = entry.pendingDelivery
          entry.pendingDelivery = nil
          return value
        }
        if let entry, let payload, delivery.accepts(payload.generation),
          entry.registration.accepts(payload.token)
        {
          entry.receive(payload.token, payload.observation)
        }
        queue.async { [self, weak entry] in
          entry?.deliveryScheduled = false
          pendingCallbacks -= 1
          scheduleDeliveries()
        }
      }
    }
  }
  func install(_ pair: WatchPair, entry: MonitorEntry) {
    for descriptor in pair.descriptors {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue: queue)
      let id = entry.id
      let epoch = entry.epoch
      source.setEventHandler { [weak self] in self?.noteEvent(id, epoch: epoch) }
      source.setCancelHandler { [self, pair] in
        pair.remainingCancels -= 1
        queueCleanupIfReady(pair)
        pump()
      }
      pair.sources.append(source)
      source.activate()
    }
  }
  func queueCleanupIfReady(_ pair: WatchPair) {
    guard pair.remainingCancels == 0, pair.borrowers == 0, !pair.cleanupQueued else { return }
    pair.cleanupQueued = true
    cleanup.append(pair)
  }
  func retire(_ pair: WatchPair?) {
    guard let pair else { return }
    let sources = pair.sources
    pair.sources.removeAll()
    for source in sources { source.cancel() }
  }
}

private enum MonitorFileFailure: Error { case notDownloaded }
private func isMaterializationRefusal(_ error: Error) -> Bool {
  if case MonitorFileFailure.notDownloaded = error { return true }
  if case ExternalFileProbeError.notDownloaded = error { return true }
  let value = error as NSError
  return value.domain == NSPOSIXErrorDomain && value.code == Int(EDEADLK)
}
private func unavailableAfter(_ error: Error) -> DiskObservation {
  DiskObservation(
    metadata: nil, content: .unavailable,
    locationProblem: isMaterializationRefusal(error) ? .notDownloaded : .checkDelayed,
    readOnlyHint: false, movedCandidate: nil)
}
private func currentFileFailure() -> Error {
  errno == EDEADLK
    ? MonitorFileFailure.notDownloaded : NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
private func prepareWatch(_ url: URL, identity: FileTargetIdentity, hooks: MonitorHooks) throws
  -> WatchPair?
{
  hooks.watchBoundary(.resolvingParent)
  let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
  hooks.watchBoundary(.openingParent)
  let directory = hooks.openWatchParent(parent.path)
  guard directory >= 0 else { throw currentFileFailure() }
  var descriptor: Int32 = -1
  var transferred = false
  defer {
    if !transferred {
      if descriptor >= 0 { close(descriptor) }
      close(directory)
    }
  }
  hooks.watchBoundary(.openingFile)
  descriptor = hooks.openWatchFile(directory, url.lastPathComponent)
  guard descriptor >= 0 else { throw currentFileFailure() }
  hooks.watchBoundary(.checkingIdentity)
  var parentInfo = stat()
  var info = stat()
  guard fstat(directory, &parentInfo) == 0, fstat(descriptor, &info) == 0 else {
    throw currentFileFailure()
  }
  guard (info.st_mode & S_IFMT) == S_IFREG,
    UInt64(UInt32(bitPattern: parentInfo.st_dev)) == identity.parentDevice,
    UInt64(parentInfo.st_ino) == identity.parentInode,
    UInt64(UInt32(bitPattern: info.st_dev)) == identity.fileDevice,
    UInt64(info.st_ino) == identity.fileInode
  else { return nil }
  transferred = true
  return WatchPair([descriptor, directory], identity: identity)
}

// Runs only inside one of the two workers, borrowing the original watched FD.
// Candidate remains an untrusted navigation hint; it never rebinds the URL.
private func movedCandidate(
  _ pair: WatchPair, baseline: Data, hooks: MonitorHooks,
  isCancelled: @escaping @Sendable () -> Bool
) throws -> URL? {
  do { try hooks.beforeMovedCandidate() } catch let policyError as FileMaterializationError {
    throw policyError
  } catch {
    if isMaterializationRefusal(error) { throw error }
    return nil
  }
  guard !isCancelled(), let descriptor = pair.descriptors.first else { return nil }
  var before = stat()
  guard fstat(descriptor, &before) == 0 else {
    if errno == EDEADLK { throw MonitorFileFailure.notDownloaded }
    return nil
  }
  guard before.st_nlink == 1, before.st_mode & S_IFMT == S_IFREG else { return nil }
  var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
  guard buffer.withUnsafeMutableBytes({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else {
    if errno == EDEADLK { throw MonitorFileFailure.notDownloaded }
    return nil
  }
  guard let end = buffer.firstIndex(of: 0), end > 0,
    let path = String(bytes: buffer[..<end], encoding: .utf8), path.hasPrefix("/")
  else { return nil }
  let candidate = URL(fileURLWithPath: path)
  let observation: DiskObservation
  do { observation = try hooks.probe(candidate, baseline, nil, isCancelled) } catch let policyError
    as FileMaterializationError
  { throw policyError } catch {
    if isMaterializationRefusal(error) { throw error }
    return nil
  }
  if observation.locationProblem == .notDownloaded { throw MonitorFileFailure.notDownloaded }
  guard observation.locationProblem == nil, let metadata = observation.metadata,
    metadata.identity.fileDevice == pair.identity.fileDevice,
    metadata.identity.fileInode == pair.identity.fileInode, !isCancelled()
  else { return nil }
  var after = stat()
  guard fstat(descriptor, &after) == 0 else {
    if errno == EDEADLK { throw MonitorFileFailure.notDownloaded }
    return nil
  }
  guard after.st_nlink == 1,
    UInt64(UInt32(bitPattern: after.st_dev)) == metadata.identity.fileDevice,
    UInt64(after.st_ino) == metadata.identity.fileInode,
    Int64(after.st_size) == metadata.byteCount,
    UInt32(after.st_mode) == metadata.mode, after.st_flags == metadata.flags,
    Int64(after.st_mtimespec.tv_sec) == metadata.modificationSeconds,
    Int64(after.st_mtimespec.tv_nsec) == metadata.modificationNanoseconds,
    Int64(after.st_ctimespec.tv_sec) == metadata.changeSeconds,
    Int64(after.st_ctimespec.tv_nsec) == metadata.changeNanoseconds
  else { return nil }
  return candidate
}

private func actionError(_ error: Error) -> FileActionError {
  if error is FileMaterializationError { return .policy }
  if isMaterializationRefusal(error) { return .notDownloaded }
  if error is DocumentCodecError || error is ExternalDocumentDecodingError { return .decoding }
  if let probe = error as? ExternalFileProbeError, case .observationChanged = probe {
    return .observationChanged
  }
  return .readFailed
}
