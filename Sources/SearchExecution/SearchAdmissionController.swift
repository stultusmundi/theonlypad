import Foundation
import PadCore

typealias SearchAdmissionPreparing = @Sendable (String, Int, Int, NSRange?) async -> Bool

enum SearchAdmissionPreparation {
  static func validate(text: String, estimate: Int, captured: Int, scope: NSRange?) async -> Bool {
    await Task.detached {
      guard estimate >= 0, estimate <= searchWireGlobalMaximumUTF16,
        captured >= 0, captured <= estimate
      else { return false }
      let bound = estimate.addingReportingOverflow(1)
      guard !bound.overflow else { return false }
      let count = text.utf16.prefix(bound.partialValue).count
      guard count == captured else { return false }
      if let scope {
        guard scope.location >= 0, scope.length >= 0, scope.location <= count,
          scope.length <= count - scope.location
        else { return false }
      }
      return true
    }.value
  }
}

enum SearchAdmissionEvent: Equatable {
  case workerExited(SearchJobID)
}

@MainActor package final class SearchAdmissionController<Context> {
  private final class Job {
    let id: SearchJobID
    let consumer: SearchConsumerID
    let descriptor: SearchAdmissionDescriptor
    var capture: (@MainActor () throws -> SearchAdmissionCapture<Context>)?
    var completion: (@MainActor (SearchAdmissionDelivery) -> Void)?
    var cancelled = false
    var reservation: SearchAdmissionReservation?
    var captured: SearchAdmissionCapture<Context>?
    var failure: SearchAdmissionFailure?
    var handle: SearchParentWireHandle?
    var attemptedSubmit = false
    var readyForSettlement = false
    var cancelIssued = false
    var provisional: (Context, String, SearchExecutionOutput)?

    init(
      id: SearchJobID, consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
      capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
      completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
    ) {
      self.id = id
      self.consumer = consumer
      self.descriptor = descriptor
      self.capture = capture
      self.completion = completion
    }
  }

  private final class Lease {
    let id: SearchResultLeaseID
    let consumer: SearchConsumerID
    let job: SearchJobID
    var payload: (Context, String, SearchExecutionOutput)?
    var valid = true
    var borrowers = 0

    init(
      id: SearchResultLeaseID, consumer: SearchConsumerID, job: SearchJobID,
      payload: (Context, String, SearchExecutionOutput)
    ) {
      self.id = id
      self.consumer = consumer
      self.job = job
      self.payload = payload
    }
  }

  private var leases: [SearchResultLeaseID: Lease] = [:]
  private var consumerLease: [SearchConsumerID: SearchResultLeaseID] = [:]

  private let driver: any SearchParentWireDriving
  private let accounting: any SearchAdmissionAccounting
  private let retry: any SearchAdmissionRetryScheduler
  private let prepare: SearchAdmissionPreparing
  private let observe: (@MainActor (SearchAdmissionEvent) -> Void)?
  private var terminalCommand: Task<SearchParentWireShutdown, Never>?
  private var terminalCommandFinished = false
  private var driverSettlement: SearchParentWireSettlement = .pending
  private var queryTerminalEligible = false
  private var worker: Task<Void, Never>?
  private var cancellation: Task<Void, Never>?
  private var ledger: SearchAdmissionLedger
  private var consumers: Set<SearchConsumerID> = []
  private var jobs: [SearchJobID: Job] = [:]
  private var queue: [SearchJobID] = []
  private var active: SearchJobID?
  private var lastHandle: SearchParentWireHandle?
  private var queryID: UUID?
  private var queryTask: Task<Void, Never>?
  private var retryID: UUID?
  private var retryToken: (any SearchAdmissionRetryToken)?
  private var schedulingRetry = false
  private var retryFiredInline = false
  private var admissionClosed = false

  package convenience init(
    driver: any SearchParentWireDriving, accounting: any SearchAdmissionAccounting,
    retry: any SearchAdmissionRetryScheduler
  ) throws {
    try self.init(
      driver: driver, accounting: accounting, retry: retry,
      prepare: {
        await SearchAdmissionPreparation.validate(text: $0, estimate: $1, captured: $2, scope: $3)
      })
  }

  init(
    driver: any SearchParentWireDriving, accounting: any SearchAdmissionAccounting,
    retry: any SearchAdmissionRetryScheduler, prepare: @escaping SearchAdmissionPreparing,
    observe: (@MainActor (SearchAdmissionEvent) -> Void)? = nil
  ) throws {
    self.driver = driver
    self.accounting = accounting
    self.retry = retry
    self.prepare = prepare
    self.observe = observe
    ledger = try SearchAdmissionLedger(
      activeLimit: accounting.activeLimit, retainedLimit: accounting.retainedLimit,
      resident: accounting.resident)
  }

  var accountingSnapshot: SearchAdmissionLedgerSnapshot { ledger.snapshot }

  /// Terminal only. The command receipt is historical; settlement excludes launcher quarantine.
  package func shutdown() async -> SearchAdmissionShutdown {
    if terminalCommand == nil {
      beginShutdown()
      let driver = driver
      terminalCommand = Task { await driver.shutdown() }
    }
    let receipt = await terminalCommand!.value
    terminalCommandFinished = true
    await inspectShutdownOnce()
    return SearchAdmissionShutdown(
      driver: receipt, driverSettlement: driverSettlement,
      retainedActiveJobs: jobs.count, retainedLeases: leases.count)
  }

  private func beginShutdown() {
    admissionClosed = true
    driverSettlement = .pending
    for job in jobs.values { job.completion = nil }
    consumers.removeAll()
    let queued = queue
    queue.removeAll()
    for id in queued { jobs.removeValue(forKey: id) }
    if let active, let job = jobs[active] {
      job.cancelled = true
      cancelDriver(job)
    }
    for id in Array(leases.keys) { release(id) }
    cancelRetry()
  }

  private func inspectShutdownOnce() async {
    cancelRetry()
    if let queryTask {
      let eligible = queryTerminalEligible
      await queryTask.value
      if eligible { return }
    }
    if queryTask == nil { startInspection() }
    await queryTask?.value
  }

  private func cancelRetry() {
    retryID = nil
    let token = retryToken
    retryToken = nil
    token?.cancel()
  }

  package func release(_ id: SearchResultLeaseID) {
    guard let lease = leases[id], lease.valid else { return }
    lease.valid = false
    if consumerLease[lease.consumer] == id { consumerLease.removeValue(forKey: lease.consumer) }
    if lease.borrowers == 0 { destroyLease(lease) }
  }

  package func withResult(
    _ id: SearchResultLeaseID, _ body: (Context, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    guard let lease = leases[id], lease.valid else { return false }
    let increment = lease.borrowers.addingReportingOverflow(1)
    guard !increment.overflow else { return false }
    lease.borrowers = increment.partialValue
    invokeBorrow(lease, body)
    lease.borrowers -= 1
    if !lease.valid && lease.borrowers == 0 { destroyLease(lease) }
    return true
  }

  private func invokeBorrow(
    _ lease: Lease, _ body: (Context, String, SearchExecutionOutput) -> Void
  ) {
    guard let payload = lease.payload else { return }
    body(payload.0, payload.1, payload.2)
  }

  private func destroyLease(_ lease: Lease) {
    lease.payload = nil
    leases.removeValue(forKey: lease.id)
    ledger.release(lease.id)
  }

  package func register() -> SearchConsumerID {
    let id = SearchConsumerID()
    if !admissionClosed { consumers.insert(id) }
    return id
  }

  package func cancel(_ id: SearchJobID) {
    guard let job = jobs[id] else {
      if let lease = leases.values.first(where: { $0.job == id && $0.valid }) { release(lease.id) }
      return
    }
    if let lease = consumerLease[job.consumer] { release(lease) }
    job.cancelled = true
    job.completion = nil
    if active != id {
      jobs.removeValue(forKey: id)
      queue.removeAll { $0 == id }
    } else {
      cancelDriver(job)
    }
  }

  package func unregister(_ consumer: SearchConsumerID) {
    consumers.remove(consumer)
    if let lease = consumerLease[consumer] { release(lease) }
    let removed = jobs.values.filter { $0.consumer == consumer }.map(\.id)
    for id in removed { cancel(id) }
  }

  package func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    guard !admissionClosed else { throw SearchAdmissionFailure.shutdown }
    guard consumers.contains(consumer) else { throw SearchAdmissionFailure.unknownConsumer }
    guard !jobs.values.contains(where: { $0.consumer == consumer }) else {
      throw SearchAdmissionFailure.consumerBusy
    }
    guard jobs.count < 8 else { throw SearchAdmissionFailure.queueFull }
    let id = SearchJobID()
    jobs[id] = Job(
      id: id, consumer: consumer, descriptor: descriptor, capture: capture, completion: completion)
    queue.append(id)
    pump()
    return id
  }

  private func pump() {
    guard !admissionClosed || terminalCommandFinished, queryID == nil, retryID == nil else {
      return
    }
    if let active {
      guard jobs[active]?.readyForSettlement == true, worker == nil, cancellation == nil else {
        return
      }
    } else if queue.isEmpty {
      guard terminalCommandFinished, driverSettlement == .pending else { return }
    }
    startInspection()
  }

  private func startInspection() {
    guard queryID == nil else { return }
    let id = UUID()
    queryID = id
    queryTerminalEligible = terminalCommandFinished
    let eligible = queryTerminalEligible
    let driver = driver
    let handle = lastHandle
    queryTask = Task { [weak self] in
      let result: Result<SearchParentWireSettlement, SearchAdmissionFailure>
      do { result = .success(try await driver.settlement(after: handle)) } catch let error
        as SearchParentWireDriverError
      { result = .failure(.driver(error)) } catch { result = .failure(.internalFailure) }
      self?.inspected(result, id: id, handle: handle, terminalEligible: eligible)
    }
  }

  private func inspected(
    _ result: Result<SearchParentWireSettlement, SearchAdmissionFailure>, id: UUID,
    handle: SearchParentWireHandle?, terminalEligible: Bool
  ) {
    guard queryID == id else { return }
    queryID = nil
    queryTask = nil
    guard handle == lastHandle else {
      driverSettlement = .pending
      scheduleRetry()
      return
    }
    if terminalCommand != nil && (!terminalEligible || !terminalCommandFinished) {
      driverSettlement = .pending
      return
    }
    switch result {
    case .failure(let failure):
      driverSettlement = .pending
      failClosed(failure)
    case .success(.pending):
      driverSettlement = .pending
      scheduleRetry()
    case .success(.settled(let closed)):
      if terminalCommandFinished && !closed {
        driverSettlement = .pending
        scheduleRetry()
        return
      }
      driverSettlement = .settled(admissionClosed: closed)
      if closed {
        admissionClosed = true
        if let active, let job = jobs[active], job.readyForSettlement,
          worker == nil, cancellation == nil
        {
          discardProvisional(job)
          finishCapture(job, failure: .shutdown)
        }
        failClosed(.shutdown)
      } else if let active, let job = jobs[active] {
        if job.cancelled {
          discardProvisional(job)
          finishCapture(job, failure: .cancelled)
        } else if let failure = job.failure {
          finishCapture(job, failure: failure)
        } else {
          publish(job)
        }
      } else {
        captureNext()
      }
    }
  }

  private func scheduleRetry() {
    guard !admissionClosed || terminalCommandFinished, retryID == nil,
      active != nil || !queue.isEmpty || terminalCommandFinished
    else { return }
    let id = UUID()
    retryID = id
    schedulingRetry = true
    retryFiredInline = false
    let token = retry.schedule { [weak self] in
      guard let self, self.retryID == id else { return }
      if self.schedulingRetry {
        self.retryFiredInline = true
        return
      }
      self.retryID = nil
      self.retryToken = nil
      self.pump()
    }
    schedulingRetry = false
    if retryFiredInline {
      retryID = nil
      token.cancel()
      failClosed(.internalFailure)
    } else {
      retryToken = token
    }
  }

  private func failClosed(_ failure: SearchAdmissionFailure) {
    admissionClosed = true
    retryID = nil
    retryToken?.cancel()
    retryToken = nil
    if let active, let job = jobs[active] {
      let completion = job.completion
      job.completion = nil
      completion?(.failed(failure))
    }
    let queued = queue.compactMap { jobs.removeValue(forKey: $0) }
    queue.removeAll()
    for job in queued {
      let completion = job.completion
      job.completion = nil
      job.capture = nil
      completion?(.failed(failure))
    }
  }

  private func captureNext() {
    guard active == nil, !admissionClosed, !queue.isEmpty else { return }
    let id = queue.removeFirst()
    guard let job = jobs[id] else {
      pump()
      return
    }
    active = id
    do {
      let charge = try accounting.charge(for: job.descriptor)
      guard active == id, jobs[id] === job, !job.cancelled,
        consumers.contains(job.consumer), !admissionClosed
      else {
        finishCapture(job, failure: .cancelled)
        return
      }
      job.reservation = try ledger.reserve(charge)
    } catch {
      finishCapture(job, failure: .resultBudget)
      return
    }
    invokeCapture(job)
    // Arbitrary capture Error and callback-local source aliases have left their scope.
    if job.cancelled || job.failure != nil {
      job.captured = nil
      finishCapture(job, failure: job.failure ?? .cancelled)
    } else {
      worker = Task { [weak self] in
        await self?.prepareAndSubmit(id)
        self?.preparationScopeExited(id)
      }
    }
  }

  private func invokeCapture(_ job: Job) {
    guard let capture = job.capture else {
      job.failure = .captureRefused
      return
    }
    job.capture = nil
    do {
      let captured = try capture()
      if !job.cancelled { job.captured = captured }
    } catch {
      job.failure = .captureRefused
    }
  }

  private func prepareAndSubmit(_ id: SearchJobID) async {
    guard let job = jobs[id], let captured = job.captured else { return }
    job.captured = nil
    let descriptor = job.descriptor
    let valid = await prepare(
      captured.text, descriptor.estimatedInputUTF16, captured.inputUTF16, descriptor.scope)
    guard !job.cancelled else {
      job.failure = .cancelled
      return
    }
    guard valid else {
      job.failure = .sourceChanged
      return
    }
    do {
      let request = try SearchParentWireJob(
        requestID: UUID(), query: descriptor.query, operation: descriptor.operation,
        text: captured.text, inputUTF16: captured.inputUTF16, scope: descriptor.scope,
        limits: descriptor.limits)
      job.attemptedSubmit = true
      let handle = try await driver.submit(request)
      job.handle = handle
      lastHandle = handle
      driverSettlement = .pending
      if let lease = consumerLease[job.consumer] { release(lease) }
      if job.cancelled { cancelDriver(job) }
      let outcome = try await driver.wait(for: handle)
      switch outcome {
      case .completed(_, let source, let output):
        if !job.cancelled { job.provisional = (captured.context, source, output) }
      case .semanticFailure(_, let error): job.failure = .semantic(error)
      case .failed(_, let failure): job.failure = .child(failure)
      }
    } catch let error as SearchParentWireDriverError {
      job.failure = .driver(error)
    } catch {
      job.failure = .internalFailure
    }
  }

  private func preparationScopeExited(_ id: SearchJobID) {
    guard active == id, let job = jobs[id] else { return }
    worker = nil
    if !job.attemptedSubmit {
      finishCapture(job, failure: job.failure ?? .internalFailure)
    } else {
      job.readyForSettlement = true
      pump()
    }
    observe?(.workerExited(id))
  }

  private func cancelDriver(_ job: Job) {
    guard let handle = job.handle, !job.cancelIssued else { return }
    job.cancelIssued = true
    let id = job.id
    let driver = driver
    cancellation = Task { [weak self] in
      // This task owns only the exact handle. It never cancels the sole wait observer.
      _ = try? await driver.cancel(handle)
      self?.cancellationExited(id)
    }
  }

  private func cancellationExited(_ id: SearchJobID) {
    guard active == id else { return }
    cancellation = nil
    pump()
  }

  private func installLease(_ job: Job) throws -> SearchResultLeaseID {
    guard let reservation = job.reservation, let payload = job.provisional else {
      throw SearchAdmissionFailure.internalFailure
    }
    let id = SearchResultLeaseID()
    let lease = Lease(id: id, consumer: job.consumer, job: job.id, payload: payload)
    try ledger.retain(reservation, as: id)
    job.reservation = nil
    leases[id] = lease
    consumerLease[job.consumer] = id
    job.provisional = nil
    return id
  }

  private func publish(_ job: Job) {
    do {
      let lease = try installLease(job)
      // The transfer helper's tuple aliases are gone before any reentrant delivery.
      active = nil
      jobs.removeValue(forKey: job.id)
      let completion = job.completion
      job.completion = nil
      completion?(.completed(lease))
      pump()
    } catch {
      failClosed(.internalFailure)
    }
  }

  private func discardProvisional(_ job: Job) {
    job.provisional = nil
  }

  private func finishCapture(_ job: Job, failure: SearchAdmissionFailure) {
    guard active == job.id else { return }
    if let reservation = job.reservation {
      ledger.abandon(reservation)
      job.reservation = nil
    }
    active = nil
    jobs.removeValue(forKey: job.id)
    let completion = job.cancelled ? nil : job.completion
    job.completion = nil
    job.capture = nil
    completion?(.failed(failure))
    pump()
  }
}
