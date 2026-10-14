// SPDX-License-Identifier: MIT
import Foundation
import PadCore
import XCTest

@testable import DocumentSearchSessionComponent
@testable import SearchExecution

@MainActor
final class DocumentSearchSessionTests: XCTestCase {
  func testAttachAndQueuedStartNeverCaptureText() throws {
    let f = try SessionFixture()
    XCTAssertEqual(f.backend.registered.count, 1)
    try f.start()
    XCTAssertEqual(f.session.state, .searching)
    XCTAssertEqual(f.backend.submissions.count, 1)
    XCTAssertEqual(f.source.captures, 0)
    if let descriptor = f.backend.submissions.first?.descriptor {
      XCTAssertEqual(descriptor.query.pattern, "x")
      XCTAssertEqual(descriptor.estimatedInputUTF16, 4)
      XCTAssertNil(descriptor.scope)
    }
  }

  func testSynchronousCompletionBuffersUntilReturnedRequestAdoption() throws {
    let f = try SessionFixture()
    f.backend.onSubmit = { index in
      do { _ = try f.complete(index) } catch { XCTFail("Fixture completion: \(error)") }
      XCTAssertFalse(f.log.values.contains(.results(matchCount: 2, selectedIndex: nil)))
    }
    try f.start()
    XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: nil))
    XCTAssertEqual(f.log.values, [.searching, .results(matchCount: 2, selectedIndex: nil)])
    XCTAssertEqual(f.backend.cancelled.count, 0)
    XCTAssertEqual(f.source.selections, [])
  }

  func testSynchronousFailureCannotOverrideThrownSubmission() throws {
    let f = try SessionFixture()
    f.backend.onSubmit = { index in f.backend.deliver(index, .failed(.queueFull)) }
    XCTAssertThrowsError(try f.start()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .cancelled)
    }
    XCTAssertEqual(f.session.state, .failed(.cancelled))
    XCTAssertEqual(f.backend.cancelled.count, 1)
    XCTAssertFalse(f.log.values.contains(.failed(.admission(.queueFull))))
  }

  func testRejectedStartPublishesTypedFailureWithoutCapture() throws {
    let f = try SessionFixture()
    f.backend.failure = .resultBudget
    XCTAssertThrowsError(try f.start()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .admission(.resultBudget))
    }
    XCTAssertEqual(f.session.state, .failed(.admission(.resultBudget)))
    XCTAssertEqual(f.source.captures, 0)
    XCTAssertEqual(f.backend.submissions.count, 0)
  }

  func testLateCompletionCannotReplaceNewSearchAndReleasesExactLease() throws {
    let f = try SessionFixture()
    try f.start()
    let captured = try f.backend.capture(0)
    try f.start()
    let late = f.backend.install(captured, matches: f.ranges, replacement: nil)
    f.backend.deliver(0, .completed(late))
    XCTAssertEqual(f.session.state, .searching)
    XCTAssertEqual(f.backend.released, [late])
    _ = try f.complete(1)
    XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: nil))
  }

  func testNavigationWrapsBothDirectionsAndNeverCopiesResults() throws {
    let f = try SessionFixture()
    try f.start()
    _ = try f.complete(0)
    XCTAssertTrue(f.session.previous())
    XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: 1))
    XCTAssertTrue(f.session.next())
    XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: 0))
    XCTAssertTrue(f.session.next())
    XCTAssertTrue(f.session.next())
    XCTAssertEqual(f.source.selections, [f.ranges[1], f.ranges[0], f.ranges[1], f.ranges[0]])
    XCTAssertEqual(f.backend.borrowDepth, 0)
  }

  func testEmptyReplacementResultNeverRequestsApprovalOrNavigation() throws {
    let f = try SessionFixture()
    try f.start(replacing: true)
    _ = try f.complete(0, matches: [], replacement: "😀xx")
    XCTAssertEqual(f.session.state, .results(matchCount: 0, selectedIndex: nil))
    XCTAssertFalse(f.session.next())
    XCTAssertFalse(f.session.previous())
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertEqual(f.backend.borrowDepth, 0)
  }

  func testApprovalIsHeldWithoutBorrowAndAppliesOnce() throws {
    let f = try SessionFixture()
    try f.start(replacing: true)
    let lease = try f.complete(0, replacement: "😀yy")
    let token = try f.token()
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertEqual(f.backend.borrowDepth, 0)
    XCTAssertTrue(f.session.resolveApproval(token, approved: true))
    XCTAssertEqual(f.source.replacements, 1)
    XCTAssertEqual(f.session.state, .replaced(matchCount: 2))
    XCTAssertEqual(f.backend.released, [lease])
    XCTAssertFalse(f.session.resolveApproval(token, approved: true))
    XCTAssertEqual(f.source.replacements, 1)
  }

  func testDeniedApprovalConsumesTokenAndReleasesLease() throws {
    let f = try SessionFixture()
    try f.start(replacing: true)
    let lease = try f.complete(0, replacement: "😀yy")
    let token = try f.token()
    XCTAssertFalse(f.session.resolveApproval(token, approved: false))
    XCTAssertEqual(f.session.state, .idle)
    XCTAssertEqual(f.backend.released, [lease])
    XCTAssertFalse(f.session.resolveApproval(token, approved: true))
    XCTAssertEqual(f.source.replacements, 0)
  }

  func testLateApprovalAfterNewStartCannotTouchNewResult() throws {
    let f = try SessionFixture()
    try f.start(replacing: true)
    let firstLease = try f.complete(0, replacement: "😀yy")
    let first = try f.token()
    try f.start(replacing: true)
    _ = try f.complete(1, replacement: "😀zz")
    let second = try f.token()
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(f.session.resolveApproval(first, approved: true))
    XCTAssertEqual(f.session.state, .awaitingApproval(token: second, matchCount: 2))
    XCTAssertEqual(f.backend.released, [firstLease])
    XCTAssertTrue(f.session.resolveApproval(second, approved: true))
    XCTAssertEqual(f.source.replacements, 1)
  }

  func testApprovalRevalidatesIndependentCredentialAndCompositionChanges() throws {
    for row in ["revisionABA", "endpoint", "ownership", "pane", "composition"] {
      let f = try SessionFixture()
      try f.start(replacing: true)
      let lease = try f.complete(0, replacement: "😀yy")
      let token = try f.token()
      try f.source.change(row)
      XCTAssertFalse(f.session.resolveApproval(token, approved: true), row)
      XCTAssertEqual(f.session.state, .failed(.staleSource), row)
      XCTAssertEqual(f.source.replacements, 0, row)
      XCTAssertEqual(f.backend.released, [lease], row)
    }
  }

  func testMissingLeaseNavigationFailsClosed() throws {
    let f = try SessionFixture()
    try f.start()
    let lease = try f.complete(0)
    f.backend.payloads.removeValue(forKey: lease)
    XCTAssertFalse(f.session.next())
    XCTAssertEqual(f.session.state, .failed(.staleSource))
    XCTAssertEqual(f.source.selections, [])
    XCTAssertFalse(f.session.previous())
  }

  func testNavigationCallbackReentrantCancelCannotRepublishResults() throws {
    let f = try SessionFixture()
    try f.start()
    let lease = try f.complete(0)
    f.source.onSelect = { f.session.cancel() }
    XCTAssertFalse(f.session.next())
    XCTAssertEqual(f.session.state, .idle)
    XCTAssertEqual(f.backend.released, [lease])
    XCTAssertFalse(f.session.next())
  }

  func testSearchingCallbackReentrantClosePreventsSubmission() throws {
    let f = try SessionFixture()
    f.log.action = { value in if value == .searching { f.session.close() } }
    XCTAssertThrowsError(try f.start()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .closed)
    }
    XCTAssertEqual(f.session.state, .closed)
    XCTAssertEqual(f.backend.submissions.count, 0)
    XCTAssertEqual(f.backend.unregistered, f.backend.registered)
  }

  func testApprovalPublicationCanReenterCloseWithoutBorrowOrMutation() throws {
    let f = try SessionFixture()
    var held: DocumentSearchApprovalToken?
    f.log.action = { value in
      if case .awaitingApproval(let token, _) = value {
        held = token
        XCTAssertEqual(f.backend.borrowDepth, 0)
        f.session.close()
      }
    }
    try f.start(replacing: true)
    let lease = try f.complete(0, replacement: "😀yy")
    XCTAssertEqual(f.session.state, .closed)
    XCTAssertEqual(f.backend.released, [lease])
    let token = try XCTUnwrap(held)
    XCTAssertFalse(f.session.resolveApproval(token, approved: true))
    XCTAssertEqual(f.source.replacements, 0)
  }

  func testCancelAndRepeatedCloseRetireOnlyOwnConsumer() throws {
    let f = try SessionFixture()
    let siblingSource = SessionSource()
    let siblingWindow = try f.owner.attachWindow(
      windowID: siblingSource.window, endpointID: siblingSource.endpoint)
    var siblingDeliveries: [ApplicationDocumentSearchDelivery] = []
    let sibling = try f.owner.attachDocument(
      window: siblingWindow, source: siblingSource.adapter,
      onDelivery: { siblingDeliveries.append($0) })
    try f.start(replacing: true)
    let siblingRequest = try sibling.start(
      query: SearchQuery(pattern: "x", mode: .literal, caseSensitive: true, wholeWord: false),
      operation: .replace(template: "y"), scope: nil, limits: f.limits)
    let siblingSubmission = try XCTUnwrap(f.backend.submissions.last)
    let ownRegistration = try f.backend.registeredID(0)
    let siblingRegistration = try f.backend.registeredID(1)
    XCTAssertEqual(siblingSubmission.consumer, siblingRegistration)
    let ownLease = try f.complete(0, replacement: "😀yy")
    let token = try f.token()
    f.session.cancel()
    XCTAssertEqual(f.session.state, .idle)
    XCTAssertEqual(f.backend.released, [ownLease])
    XCTAssertFalse(f.session.resolveApproval(token, approved: true))
    f.session.close()
    f.session.close()
    XCTAssertEqual(f.session.state, .closed)
    XCTAssertEqual(f.backend.unregistered, [ownRegistration])
    XCTAssertThrowsError(try f.start())
    XCTAssertEqual(f.backend.registered.count, 2)
    XCTAssertFalse(f.backend.cancelled.contains(siblingSubmission.job))
    // Pending sibling capture remains usable after the first session's cancel/close.
    let captured = try f.backend.capture(1)
    XCTAssertEqual(captured.context, try siblingSource.credential())
    let siblingLease = f.backend.install(captured, matches: f.ranges, replacement: "😀yy")
    f.backend.deliver(1, .completed(siblingLease))
    guard
      case .completed(let request, let result, let summary) = try XCTUnwrap(siblingDeliveries.last)
    else {
      return XCTFail("Independent sibling request must complete after first session closes")
    }
    XCTAssertEqual(request, siblingRequest)
    XCTAssertEqual(summary, DocumentSearchSummary(matchCount: 2, hasReplacement: true))
    XCTAssertEqual(f.backend.released, [ownLease])
    XCTAssertEqual(f.backend.unregistered, [ownRegistration])
    XCTAssertTrue(sibling.navigate(result: result, matchIndex: 1))
    XCTAssertEqual(siblingSource.selections, [f.ranges[1]])
    XCTAssertTrue(sibling.replaceAll(result: result))
    XCTAssertEqual(siblingSource.replacements, 1)
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertEqual(f.backend.released, [ownLease, siblingLease])
    XCTAssertFalse(f.backend.cancelled.contains(siblingSubmission.job))
    sibling.close()
    XCTAssertEqual(f.backend.unregistered, f.backend.registered)
  }

  func testCancelCalloutNewStartWinsForExactReleaseAndJobCancellation() throws {
    for seam in ["release", "cancel"] {
      let f = try SessionFixture()
      try f.start()
      let oldJob = try f.backend.submission(0).job
      var oldLease: SearchResultLeaseID?
      if seam == "release" { oldLease = try f.complete(0) }
      let callback: @MainActor () -> Void = {
        do { try f.start() } catch { XCTFail("Reentrant new start failed: \(error)") }
      }
      if seam == "release" {
        f.backend.onRelease = { id in
          XCTAssertEqual(id, oldLease)
          callback()
        }
      } else {
        f.backend.onCancel = { id in
          XCTAssertEqual(id, oldJob)
          callback()
        }
      }
      f.session.cancel()
      XCTAssertEqual(f.session.state, .searching, seam)
      XCTAssertEqual(f.backend.submissions.count, 2, seam)
      XCTAssertEqual(f.log.values.last, .searching, seam)
      let newJob = try f.backend.submission(1).job
      XCTAssertFalse(f.backend.cancelled.contains(newJob), seam)
      if let oldLease {
        XCTAssertEqual(f.backend.released, [oldLease])
      } else {
        XCTAssertEqual(f.backend.cancelled, [oldJob])
      }
      _ = try f.complete(1)
      XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: nil), seam)
    }
  }

  func testSubmittedMatchCeilingRejectsResultAndRetiresLease() throws {
    let f = try SessionFixture()
    try f.start(replacing: true)
    // Five tiny ranges exceed the submitted maximum4; no huge fixture allocation.
    let lease = try f.complete(
      0, matches: Array(repeating: f.ranges[0], count: 5), replacement: "😀yy")
    XCTAssertEqual(f.session.state, .failed(.admission(.semantic(.matchLimit))))
    XCTAssertEqual(f.backend.released, [lease])
    XCTAssertEqual(f.source.selections, [])
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertFalse(f.session.next())
    XCTAssertFalse(f.session.previous())
  }

  func testForeignApprovalTokenCannotConsumeOwnApproval() throws {
    let f = try SessionFixture()
    let other = try SessionFixture()
    try f.start(replacing: true)
    let ownLease = try f.complete(0, replacement: "😀yy")
    let ownToken = try f.token()
    try other.start(replacing: true)
    let foreignLease = try other.complete(0, replacement: "😀zz")
    let foreign = try other.token()
    XCTAssertNotEqual(ownToken, foreign)
    XCTAssertFalse(f.session.resolveApproval(foreign, approved: true))
    XCTAssertEqual(f.session.state, .awaitingApproval(token: ownToken, matchCount: 2))
    XCTAssertEqual(other.session.state, .awaitingApproval(token: foreign, matchCount: 2))
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertEqual(f.backend.released, [])
    XCTAssertEqual(other.backend.released, [])
    XCTAssertTrue(f.session.resolveApproval(ownToken, approved: true))
    XCTAssertEqual(f.backend.released, [ownLease])
    XCTAssertTrue(other.session.resolveApproval(foreign, approved: true))
    XCTAssertEqual(other.backend.released, [foreignLease])
  }

  func testApprovalPublicationCanResolveSynchronouslyWithoutOverwritingReplacement() throws {
    let f = try SessionFixture()
    var returned = false
    f.log.action = { value in
      if case .awaitingApproval(let token, _) = value {
        XCTAssertEqual(f.backend.borrowDepth, 0)
        returned = f.session.resolveApproval(token, approved: true)
      }
    }
    try f.start(replacing: true)
    let lease = try f.complete(0, replacement: "😀yy")
    XCTAssertTrue(returned)
    XCTAssertEqual(f.session.state, .replaced(matchCount: 2))
    XCTAssertEqual(f.log.values.last, .replaced(matchCount: 2))
    XCTAssertEqual(f.source.replacements, 1)
    XCTAssertEqual(f.backend.released, [lease])
  }

  // Historical method name retained for roster stability. "Mutation" below is
  // only the scripted replacement counter effect, not source-text/native editing.
  func testReplacementCallbackNewIntentWinsAfterActualMutation() throws {
    for intent in ["start", "cancel", "close"] {
      let f = try SessionFixture()
      try f.start(replacing: true)
      let lease = try f.complete(0, replacement: "😀yy")
      let token = try f.token()
      f.source.onReplace = {
        XCTAssertEqual(f.source.replacements, 1)
        switch intent {
        case "start":
          do { try f.start() } catch { XCTFail("New intent: \(error)") }
        case "cancel": f.session.cancel()
        default: f.session.close()
        }
      }
      XCTAssertFalse(f.session.resolveApproval(token, approved: true), intent)
      let expected: DocumentSearchSessionState =
        intent == "start" ? .searching : intent == "cancel" ? .idle : .closed
      XCTAssertEqual(f.session.state, expected, intent)
      XCTAssertEqual(f.log.values.last, expected, intent)
      XCTAssertEqual(f.source.replacements, 1, intent)
      XCTAssertEqual(f.backend.released, [lease], intent)
      XCTAssertFalse(f.log.values.contains(.replaced(matchCount: 2)), intent)
      XCTAssertFalse(f.session.resolveApproval(token, approved: true), intent)
      if intent == "start" {
        XCTAssertEqual(f.backend.submissions.count, 2)
        _ = try f.complete(1)
        XCTAssertEqual(f.session.state, .results(matchCount: 2, selectedIndex: nil))
      }
    }
  }

}

private enum SessionFixtureFailure: Error {
  case missingRegistration, missingSubmission, missingApproval
}

@MainActor
private final class SessionStateLog {
  var values: [DocumentSearchSessionState] = []
  var action: (@MainActor (DocumentSearchSessionState) -> Void)?
  func receive(_ value: DocumentSearchSessionState) {
    guard values.count < 64 else {
      XCTFail("State callback bound exceeded")
      return
    }
    values.append(value)
    action?(value)
  }
}

@MainActor
private final class SessionSource {
  var text = "😀xx"
  var revision: UInt64 = 7
  let window = UUID()
  var endpoint = UUID()
  let document = UUID()
  var pane = UUID()
  var ownership = UUID()
  var composition = false
  var captures = 0
  var selections: [NSRange] = []
  var replacements = 0
  var onSelect: (@MainActor () -> Void)?
  var onReplace: (@MainActor () -> Void)?
  func credential() throws -> DocumentSearchCredential {
    try DocumentSearchCredential(
      windowID: window, endpointID: endpoint, documentID: document, paneID: pane,
      ownershipGeneration: ownership, editRevision: revision, inputUTF16: 4)
  }
  var adapter: EditorDocumentSearchSource {
    EditorDocumentSearchSource(
      inspect: { [self] in
        guard !composition else { throw ApplicationDocumentSearchFailure.sourceUnavailable }
        return try credential()
      },
      capture: { [self] expected in
        guard !composition, try credential() == expected else {
          throw ApplicationDocumentSearchFailure.staleSource
        }
        captures += 1
        return SearchAdmissionCapture(text: text, inputUTF16: 4, context: expected)
      },
      isCurrent: { [self] expected in !composition && (try? credential()) == expected },
      select: { [self] expected, original, range in
        let callback = onSelect
        onSelect = nil
        callback?()
        guard !composition, (try? credential()) == expected, text == original else { return false }
        selections.append(range)
        return true
      },
      replace: { [self] expected, original, _ in
        guard !composition, (try? credential()) == expected, text == original else { return false }
        // Counter-only replacement effect seam; source text is not changed.
        replacements += 1
        let callback = onReplace
        onReplace = nil
        callback?()
        return true
      })
  }
  func change(_ row: String) throws {
    switch row {
    case "revisionABA":
      text = "😀zz"
      revision = 8
      text = "😀xx"
      revision = 9
    case "endpoint": endpoint = UUID()
    case "ownership": ownership = UUID()
    case "pane": pane = UUID()
    case "composition": composition = true
    default: XCTFail("Unknown credential control")
    }
  }
}

@MainActor
private final class SessionBackend: ApplicationSearchBackend {
  struct Submission {
    let consumer: SearchConsumerID
    let descriptor: SearchAdmissionDescriptor
    let job: SearchJobID
    let capture: @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>
    let completion: @MainActor (SearchAdmissionDelivery) -> Void
  }
  struct Payload {
    let captured: SearchAdmissionCapture<DocumentSearchCredential>
    let output: SearchExecutionOutput
  }
  var registered: [SearchConsumerID] = []
  var unregistered: [SearchConsumerID] = []
  var cancelled: [SearchJobID] = []
  var released: [SearchResultLeaseID] = []
  var submissions: [Submission] = []
  var payloads: [SearchResultLeaseID: Payload] = [:]
  var failure: SearchAdmissionFailure?
  var onSubmit: (@MainActor (Int) -> Void)?
  var onCancel: (@MainActor (SearchJobID) -> Void)?
  var onRelease: (@MainActor (SearchResultLeaseID) -> Void)?
  var borrowDepth = 0
  func registeredID(_ index: Int) throws -> SearchConsumerID {
    guard registered.indices.contains(index) else {
      XCTFail("Expected actual owner registration was absent")
      throw SessionFixtureFailure.missingRegistration
    }
    return registered[index]
  }
  func submission(_ index: Int) throws -> Submission {
    guard submissions.indices.contains(index) else {
      XCTFail("Expected actual owner submission was absent")
      throw SessionFixtureFailure.missingSubmission
    }
    return submissions[index]
  }
  func register() -> SearchConsumerID {
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func unregister(_ consumer: SearchConsumerID) {
    XCTAssertFalse(unregistered.contains(consumer))
    unregistered.append(consumer)
  }
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    if let failure { throw failure }
    guard submissions.count < 8 else { throw SessionFixtureFailure.missingSubmission }
    let job = SearchJobID()
    submissions.append(
      Submission(
        consumer: consumer, descriptor: descriptor, job: job, capture: capture,
        completion: completion))
    let callback = onSubmit
    onSubmit = nil
    callback?(submissions.count - 1)
    return job
  }
  func cancel(_ id: SearchJobID) {
    XCTAssertFalse(cancelled.contains(id))
    cancelled.append(id)
    let callback = onCancel
    onCancel = nil
    callback?(id)
  }
  func release(_ id: SearchResultLeaseID) {
    XCTAssertFalse(released.contains(id))
    released.append(id)
    payloads.removeValue(forKey: id)
    let callback = onRelease
    onRelease = nil
    callback?(id)
  }
  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    guard let payload = payloads[id] else { return false }
    XCTAssertEqual(borrowDepth, 0)
    borrowDepth += 1
    body(payload.captured.context, payload.captured.text, payload.output)
    borrowDepth -= 1
    return true
  }
  func capture(_ index: Int) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    guard submissions.indices.contains(index) else {
      XCTFail("Expected actual owner submission was absent")
      throw SessionFixtureFailure.missingSubmission
    }
    return try submissions[index].capture()
  }
  func install(
    _ captured: SearchAdmissionCapture<DocumentSearchCredential>, matches: [NSRange],
    replacement: String?
  ) -> SearchResultLeaseID {
    let id = SearchResultLeaseID()
    payloads[id] = Payload(
      captured: captured, output: SearchExecutionOutput(matches: matches, replacement: replacement))
    return id
  }
  func deliver(_ index: Int, _ value: SearchAdmissionDelivery) {
    guard submissions.indices.contains(index) else {
      XCTFail("Missing submission delivery")
      return
    }
    submissions[index].completion(value)
  }
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    .callerRefused(.unsupportedDriver)
  }
}

@MainActor
private final class SessionFixture {
  let backend = SessionBackend()
  let source = SessionSource()
  let log = SessionStateLog()
  let owner: ApplicationSearchOwner
  let session: DocumentSearchSession
  let ranges = [NSRange(location: 2, length: 1), NSRange(location: 3, length: 1)]
  let limits: SearchWireLimits
  init() throws {
    owner = ApplicationSearchOwner(backend: backend)
    let window = try owner.attachWindow(windowID: source.window, endpointID: source.endpoint)
    let sink = log
    session = try DocumentSearchSession(
      owner: owner, window: window, source: source.adapter, onState: { sink.receive($0) })
    limits = try SearchWireLimits(
      maxTextUTF16: 4, maxOutputUTF16: 4, maxMatches: 4, cooperativeMilliseconds: 100)
  }
  func start(replacing: Bool = false) throws {
    try session.start(
      query: SearchQuery(pattern: "x", mode: .literal, caseSensitive: true, wholeWord: false),
      operation: replacing ? .replace(template: "y") : .find, scope: nil, limits: limits)
  }
  func complete(
    _ index: Int, matches: [NSRange]? = nil, replacement: String? = nil
  ) throws -> SearchResultLeaseID {
    let captured = try backend.capture(index)
    let lease = backend.install(captured, matches: matches ?? ranges, replacement: replacement)
    backend.deliver(index, .completed(lease))
    return lease
  }
  func token() throws -> DocumentSearchApprovalToken {
    guard case .awaitingApproval(let token, let count) = session.state else {
      XCTFail("Expected a held nonmodal approval token")
      throw SessionFixtureFailure.missingApproval
    }
    XCTAssertEqual(count, 2)
    return token
  }
}
