import Foundation
import PadCore

private struct Cancellation: DiskActionCancellation {
  let body: @Sendable () -> Void
  func cancel() { body() }
}
@MainActor final class ControlledClient: DiskActionClient {
  var inlineError: FileActionError?
  var reads: [UUID: @Sendable (UUID, Result<ExternalFileActionSnapshot, FileActionError>) -> Void] =
    [:]
  var validations: [UUID: @Sendable (UUID, Result<Void, FileActionError>) -> Void] = [:]
  var latestRead: UUID?
  var latestValidation: UUID?
  func read(
    requestID: UUID, input: DocumentDiskActionInput,
    receive: @escaping @Sendable (UUID, Result<ExternalFileActionSnapshot, FileActionError>) -> Void
  ) -> any DiskActionCancellation {
    latestRead = requestID
    reads[requestID] = receive
    if let inlineError { receive(requestID, .failure(inlineError)) }
    return Cancellation { receive(requestID, .failure(.cancelled)) }
  }
  func revalidate(
    requestID: UUID, snapshot: ExternalFileActionSnapshot,
    receive: @escaping @Sendable (UUID, Result<Void, FileActionError>) -> Void
  ) -> any DiskActionCancellation {
    latestValidation = requestID
    validations[requestID] = receive
    return Cancellation { receive(requestID, .failure(.cancelled)) }
  }
}
@MainActor final class ControlledPreparer: DiskSelectionPreparer {
  var reservation: UUID?
  var running = false
  var completion: (@MainActor (Result<[UUID: NSRange], Error>) -> Void)?
  func reserve() -> UUID? {
    guard reservation == nil else { return nil }
    let id = UUID()
    reservation = id
    return id
  }
  func release(_ id: UUID) { if reservation == id && !running { reservation = nil } }
  func prepare(
    _ id: UUID, text: String, selections: [UUID: NSRange],
    receive: @escaping @MainActor (Result<[UUID: NSRange], Error>) -> Void
  ) {
    guard reservation == id else { preconditionFailure("Unowned preparation") }
    running = true
    completion = receive
  }
  func complete(_ result: Result<[UUID: NSRange], Error>) {
    running = false
    reservation = nil
    let callback = completion
    completion = nil
    callback?(result)
  }
}
@MainActor final class Owner {
  var operation: UUID?
  var closed = false
  var authority = true
  var refuseBegin = false
  var finishes: [UUID] = []
  var errors = 0
  var applications: [DecodedDocument] = []
  var appliedSelections: [[UUID: NSRange]] = []
  var confirmations = 0
  var confirmation: () -> Bool = { true }
  var afterApply: () -> Void = {}
  var afterFinish: () -> Void = {}
  var afterReport: () -> Void = {}
  var currentHook: () -> Void = {}
  var beginHook: () -> Void = {}
  var callbacks: DocumentDiskActionCallbacks {
    DocumentDiskActionCallbacks(
      beginOperation: { [self] in
        guard !refuseBegin else { return nil }
        let value = UUID()
        operation = value
        beginHook()
        return value
      },
      isCurrent: { [self] id in
        let valid = !closed && authority && operation == id
        currentHook()
        return valid
      },
      confirmDiscard: { [self] _ in
        confirmations += 1
        return confirmation()
      },
      apply: { [self] snapshot, selections, _ in
        applications.append(snapshot.document)
        appliedSelections.append(selections)
        afterApply()
      },
      finish: { [self] id in
        finishes.append(id)
        if operation == id { operation = nil }
        afterFinish()
      },
      reportError: { [self] _ in
        errors += 1
        afterReport()
      })
  }
}
@main struct DiskActionCoordinatorHarness {
  @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
  @MainActor static func main() async throws {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("synthetic.txt")
    let bytes = Data("exact synthetic e\u{301} 😀\r\n".utf8)
    try bytes.write(to: file)
    let observation = try await Task.detached {
      try ExternalFileProbe().observe(
        file, expected: Data(), boundIdentity: nil, forceContents: true, previous: nil,
        isCancelled: { false })
    }.value
    let snapshot = try await Task.detached {
      try ExternalFileActionReader().read(
        file, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    }.value
    let id = UUID()
    func input(_ action: DocumentDiskAction = .reload, discard: Bool = false)
      -> DocumentDiskActionInput
    {
      DocumentDiskActionInput(
        documentID: id, url: file, observation: observation, savedEncoding: .utf8, action: action,
        requiresDiscard: discard)
    }
    var checks = 0
    func check(_ value: Bool, _ description: String) {
      if !value {
        print("FAIL: \(description)")
        exit(1)
      }
      checks += 1
    }
    let application = ApplicationFileMonitoring()
    defer { application.stop() }
    let client = ControlledClient()
    let owner = Owner()
    let coordinator = DocumentDiskActionCoordinator(application: application, client: client)
    check(coordinator.start(input(), callbacks: owner.callbacks), "first captured action admitted")
    let operation = owner.operation!
    let request = client.latestRead!
    check(
      !coordinator.start(input(), callbacks: Owner().callbacks),
      "same coordinator refuses second action")
    let other = DocumentDiskActionCoordinator(application: application, client: client)
    check(
      !other.start(input(.copy), callbacks: Owner().callbacks),
      "process lease refuses another coordinator")
    client.reads[request]?(request, .success(snapshot))
    await settle()
    check(
      owner.applications.isEmpty && client.latestValidation != nil,
      "clean reload revalidates before applying")
    let validation = client.latestValidation!
    client.validations[validation]?(validation, .success(()))
    await settle()
    check(
      owner.applications.first?.text.utf16.elementsEqual(snapshot.document.text.utf16) == true,
      "validated reload applies exact Unicode snapshot")
    check(
      owner.finishes == [operation] && coordinator.activeTransactionID == nil,
      "successful reload finishes its operation once")
    let closed = Owner()
    check(coordinator.start(input(.copy), callbacks: closed.callbacks), "copy admitted")
    let closedRequest = client.latestRead!
    let closedOperation = closed.operation!
    closed.closed = true
    client.reads[closedRequest]?(closedRequest, .failure(.readFailed))
    await settle()
    check(
      closed.errors == 0 && closed.applications.isEmpty && closed.finishes == [closedOperation],
      "closed completion finishes only owned operation without UI")
    let stale = Owner()
    check(coordinator.start(input(.copy), callbacks: stale.callbacks), "stale source test admitted")
    let staleRequest = client.latestRead!
    let staleOperation = stale.operation!
    let newerOperation = UUID()
    stale.operation = newerOperation
    client.reads[staleRequest]?(staleRequest, .success(snapshot))
    await settle()
    check(
      stale.operation == newerOperation && stale.finishes == [staleOperation]
        && stale.applications.isEmpty, "late result cannot apply or unfreeze newer operation")
    let cancelled = Owner()
    check(
      coordinator.start(input(.copy), callbacks: cancelled.callbacks),
      "cancellation action admitted")
    let cancelledRequest = client.latestRead!
    let cancelledOperation = cancelled.operation!
    application.suspend()
    await settle()
    client.reads[cancelledRequest]?(cancelledRequest, .success(snapshot))
    await settle()
    check(
      cancelled.finishes == [cancelledOperation] && cancelled.errors == 0
        && cancelled.applications.isEmpty, "process quit cancellation rejects late read silently")
    application.resume()
    let confirm = Owner()
    confirm.confirmation = {
      confirm.authority = false
      return true
    }
    check(
      coordinator.start(input(discard: true), callbacks: confirm.callbacks),
      "discard transaction admitted")
    let confirmRequest = client.latestRead!
    let previousValidation = client.latestValidation
    client.reads[confirmRequest]?(confirmRequest, .success(snapshot))
    await settle()
    check(
      confirm.confirmations == 1 && confirm.applications.isEmpty
        && client.latestValidation == previousValidation,
      "confirmation authority change prevents revalidation and adoption")
    let refusal = Owner()
    refusal.confirmation = { false }
    check(
      coordinator.start(input(discard: true), callbacks: refusal.callbacks),
      "discard refusal admitted")
    let refusalRequest = client.latestRead!
    client.reads[refusalRequest]?(refusalRequest, .success(snapshot))
    await settle()
    check(
      refusal.errors == 0 && refusal.applications.isEmpty && refusal.finishes.count == 1,
      "discard cancellation finishes silently")
    let failed = Owner()
    check(
      coordinator.start(input(), callbacks: failed.callbacks),
      "revalidate error transaction admitted")
    let failedRead = client.latestRead!
    client.reads[failedRead]?(failedRead, .success(snapshot))
    await settle()
    let failedValidation = client.latestValidation!
    client.validations[failedValidation]?(failedValidation, .failure(.observationChanged))
    await settle()
    check(
      failed.errors == 1 && failed.applications.isEmpty && failed.finishes.count == 1,
      "revalidation failure reports current owner without adoption")
    let inline = Owner()
    client.inlineError = .capacity
    check(
      coordinator.start(input(), callbacks: inline.callbacks),
      "inline service refusal still follows admitted transaction")
    await settle()
    check(
      inline.errors == 1 && inline.finishes.count == 1 && coordinator.activeTransactionID == nil,
      "inline callback sees preinstalled request and releases lease")
    client.inlineError = nil
    let noOperation = Owner()
    noOperation.refuseBegin = true
    check(
      !coordinator.start(input(), callbacks: noOperation.callbacks),
      "operation refusal returns actionable nonadmission")
    check(
      noOperation.finishes.isEmpty && noOperation.errors == 0,
      "no fabricated operation finish on refusal")
    let reportClosed = Owner()
    var reportSawOperation = false
    reportClosed.afterReport = {
      reportSawOperation = reportClosed.operation != nil
      reportClosed.closed = true
    }
    check(
      coordinator.start(input(), callbacks: reportClosed.callbacks),
      "report closes error owner test admitted")
    let reportClosedRead = client.latestRead!
    client.reads[reportClosedRead]?(reportClosedRead, .failure(.readFailed))
    await settle()
    check(
      reportClosed.errors == 1 && reportSawOperation && reportClosed.finishes.count == 1
        && reportClosed.operation == nil,
      "error reports while own operation lives then finishes after reporter closes")
    let beginCancelled = Owner()
    beginCancelled.beginHook = { application.suspend() }
    let readsBeforeCancelledBegin = client.reads.count
    check(
      !coordinator.start(input(), callbacks: beginCancelled.callbacks),
      "reentrant begin cancellation refuses transaction")
    check(
      beginCancelled.finishes.count == 1 && client.reads.count == readsBeforeCancelledBegin,
      "cancelled begin finishes returned own operation without reading")
    application.resume()
    let replacement = Owner()
    let reentrantConfirm = Owner()
    reentrantConfirm.confirmation = {
      coordinator.cancel()
      return coordinator.start(input(.copy), callbacks: replacement.callbacks)
    }
    check(
      coordinator.start(input(discard: true), callbacks: reentrantConfirm.callbacks),
      "reentrant confirmation admitted")
    let reentrantRequest = client.latestRead!
    client.reads[reentrantRequest]?(reentrantRequest, .success(snapshot))
    await settle()
    check(
      reentrantConfirm.finishes.count == 1 && reentrantConfirm.applications.isEmpty
        && replacement.operation != nil, "confirmation replacement preserves newer transaction")
    let replacementRequest = client.latestRead!
    client.reads[reentrantRequest]?(reentrantRequest, .failure(.readFailed))
    await settle()
    check(
      replacement.operation != nil && replacement.errors == 0,
      "duplicate old callback cannot affect replacement")
    client.reads[replacementRequest]?(replacementRequest, .success(snapshot))
    await settle()
    check(
      replacement.applications.count == 1 && replacement.finishes.count == 1,
      "replacement completes independently")
    let afterApplyOwner = Owner()
    let applying = Owner()
    applying.afterApply = {
      coordinator.cancel()
      _ = coordinator.start(input(.copy), callbacks: afterApplyOwner.callbacks)
    }
    check(
      coordinator.start(input(.copy), callbacks: applying.callbacks), "reentrant apply admitted")
    let applyingRead = client.latestRead!
    client.reads[applyingRead]?(applyingRead, .success(snapshot))
    await settle()
    check(
      applying.finishes.count == 1 && afterApplyOwner.operation != nil
        && coordinator.activeTransactionID != nil, "old apply cleanup cannot retire new transaction"
    )
    coordinator.cancel()
    await settle()
    check(
      afterApplyOwner.finishes.count == 1 && afterApplyOwner.errors == 0,
      "replacement cancellation remains exact and silent")
    let afterReportOwner = Owner()
    let reporting = Owner()
    reporting.afterReport = {
      _ = coordinator.start(input(.copy), callbacks: afterReportOwner.callbacks)
    }
    check(
      coordinator.start(input(.copy), callbacks: reporting.callbacks), "reentrant reporter admitted"
    )
    let reportingRead = client.latestRead!
    client.reads[reportingRead]?(reportingRead, .failure(.readFailed))
    await settle()
    check(
      reporting.finishes.count == 1 && reporting.errors == 1 && afterReportOwner.operation != nil,
      "deferred finish cannot clear reporter replacement")
    coordinator.cancel()
    await settle()
    weak var released: DocumentDiskActionCoordinator?
    do {
      let temporary = DocumentDiskActionCoordinator(application: application, client: client)
      released = temporary
      _ = temporary.start(input(.copy), callbacks: Owner().callbacks)
      temporary.cancel()
    }
    await settle()
    check(released == nil, "explicit cancellation releases coordinator without process lease cycle")
    let pane = UUID()
    let paneInput = DocumentDiskActionInput(
      documentID: id, url: file, observation: observation, savedEncoding: .utf8,
      action: .reload, requiresDiscard: false, selections: [pane: NSRange(location: 100, length: 0)]
    )
    let preparer = ControlledPreparer()
    let preparingOwner = Owner()
    let preparing = DocumentDiskActionCoordinator(
      application: application, client: client, preparer: preparer)
    check(
      preparing.start(paneInput, callbacks: preparingOwner.callbacks),
      "pane preparation action admitted")
    let preparingRead = client.latestRead!
    let validationBeforePrep = client.latestValidation
    client.reads[preparingRead]?(preparingRead, .success(snapshot))
    await settle()
    check(
      preparer.running && client.latestValidation == validationBeforePrep,
      "CPU preparation precedes final disk revalidation")
    application.suspend()
    application.resume()
    let nextPreparedOwner = Owner()
    let nextPrepared = DocumentDiskActionCoordinator(
      application: application, client: client, preparer: preparer)
    check(
      !nextPrepared.start(paneInput, callbacks: nextPreparedOwner.callbacks),
      "running canceled preparation retains process-wide permit across quit veto")
    check(
      nextPreparedOwner.operation == nil && preparingOwner.finishes.count == 1,
      "prep capacity refusal does not begin newer operation")
    preparer.complete(
      .success([pane: NSRange(location: snapshot.document.text.utf16.count, length: 0)]))
    await settle()
    check(
      preparingOwner.applications.isEmpty && preparer.reservation == nil,
      "independent completion releases canceled prep without adoption")
    check(
      nextPrepared.start(paneInput, callbacks: nextPreparedOwner.callbacks),
      "completed canceled prep permits new transaction")
    let nextRead = client.latestRead!
    client.reads[nextRead]?(nextRead, .success(snapshot))
    await settle()
    let preparedRange = NSRange(location: snapshot.document.text.utf16.count, length: 0)
    preparer.complete(.success([pane: preparedRange]))
    await settle()
    let preparedValidation = client.latestValidation!
    client.validations[preparedValidation]?(preparedValidation, .success(()))
    await settle()
    check(
      nextPreparedOwner.appliedSelections == [[pane: preparedRange]],
      "apply receives prepared pane ranges")
    let predicateSuspends = Owner()
    predicateSuspends.currentHook = {
      if coordinator.activeTransactionID == nil { application.suspend() }
    }
    check(
      coordinator.start(input(), callbacks: predicateSuspends.callbacks),
      "terminal predicate suspend test admitted")
    let predicateRead = client.latestRead!
    client.reads[predicateRead]?(predicateRead, .failure(.readFailed))
    await settle()
    check(
      application.isSuspended && predicateSuspends.errors == 0
        && predicateSuspends.finishes.count == 1,
      "terminal predicate reentry cannot report after application suspension")
    application.resume()
    let predicateReplacement = Owner()
    let predicateStarts = Owner()
    predicateStarts.currentHook = {
      if coordinator.activeTransactionID == nil {
        _ = coordinator.start(input(.copy), callbacks: predicateReplacement.callbacks)
      }
    }
    check(
      coordinator.start(input(), callbacks: predicateStarts.callbacks),
      "terminal predicate replacement test admitted")
    let predicateStartsRead = client.latestRead!
    client.reads[predicateStartsRead]?(predicateStartsRead, .failure(.readFailed))
    await settle()
    check(
      predicateStarts.errors == 0 && predicateStarts.finishes.count == 1
        && predicateReplacement.operation != nil,
      "terminal predicate replacement suppresses obsolete report and preserves new operation")
    coordinator.cancel()
    await settle()
    let immediateReplacement = Owner()
    let predicateRestarts = Owner()
    predicateRestarts.currentHook = {
      if coordinator.activeTransactionID == nil {
        _ = coordinator.start(input(.copy), callbacks: immediateReplacement.callbacks)
        coordinator.cancel()
      }
    }
    check(
      coordinator.start(input(), callbacks: predicateRestarts.callbacks),
      "terminal predicate completed replacement admitted")
    let restartsRead = client.latestRead!
    client.reads[restartsRead]?(restartsRead, .failure(.readFailed))
    await settle()
    check(
      predicateRestarts.errors == 0 && predicateRestarts.finishes.count == 1
        && immediateReplacement.finishes.count == 1,
      "completed replacement still invalidates prior terminal report")
    // Real production service, genuine read and exact revalidation after confirmation.
    let realOwner = Owner()
    let real = DocumentDiskActionCoordinator(application: application)
    check(real.start(input(.copy), callbacks: realOwner.callbacks), "real queued copy admitted")
    let deadline = Date().addingTimeInterval(8)
    while real.activeTransactionID != nil && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    check(
      realOwner.applications.first?.text.utf16.elementsEqual(snapshot.document.text.utf16) == true
        && realOwner.errors == 0, "real queued copy applies exact snapshot")
    let emoji = (snapshot.document.text as NSString).range(of: "😀")
    let eofPane = UUID()
    let clampingInput = DocumentDiskActionInput(
      documentID: id, url: file, observation: observation, savedEncoding: .utf8,
      action: .reload, requiresDiscard: false,
      selections: [
        pane: NSRange(location: emoji.location + 1, length: 0),
        eofPane: NSRange(location: 100, length: 0),
      ])
    let clampOwner = Owner()
    check(
      real.start(clampingInput, callbacks: clampOwner.callbacks), "real CPU pane clamping admitted")
    let clampDeadline = Date().addingTimeInterval(8)
    while real.activeTransactionID != nil && Date() < clampDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    check(
      clampOwner.appliedSelections.first == [
        pane: NSRange(location: emoji.location, length: 0),
        eofPane: NSRange(location: snapshot.document.text.utf16.count, length: 0),
      ], "real off-main clamping preserves scalar boundaries and EOF")
    let excessive = DocumentDiskActionInput(
      documentID: id, url: file, observation: observation, savedEncoding: .utf8,
      action: .reload, requiresDiscard: false,
      selections: [
        UUID(): NSRange(location: 0, length: 0), UUID(): NSRange(location: 0, length: 0),
        UUID(): NSRange(location: 0, length: 0),
      ])
    check(
      !real.start(excessive, callbacks: Owner().callbacks), "more than two captured panes refused")
    let diskChange = Owner()
    diskChange.confirmation = {
      try! Data("replacement during confirmation".utf8).write(to: file, options: .atomic)
      return true
    }
    check(
      real.start(input(discard: true), callbacks: diskChange.callbacks),
      "real confirm-time disk mutation admitted")
    let changeDeadline = Date().addingTimeInterval(8)
    while real.activeTransactionID != nil && Date() < changeDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    check(
      diskChange.confirmations == 1 && diskChange.errors == 1 && diskChange.applications.isEmpty
        && diskChange.finishes.count == 1, "real second disk change refuses reload")
    let diskBytes = try Data(contentsOf: file)
    check(
      diskBytes == Data("replacement during confirmation".utf8),
      "coordinator never writes original file")
    print(
      "PASS \(checks) disk-action coordinator assertions, controlled callbacks plus real queued service; no GUI"
    )
  }
}
