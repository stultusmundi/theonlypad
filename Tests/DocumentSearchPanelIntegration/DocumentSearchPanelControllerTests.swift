// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import PadCore
import XCTest

@testable import DocumentSearchPanelComponent
@testable import SearchExecution

@MainActor final class DocumentSearchPanelControllerTests: XCTestCase {
  func testAlreadyCreatedSourceAttachesOnceWithoutInspectionOrCapture() throws {
    let f = try PanelFixture()
    defer { f.finish() }
    XCTAssertEqual(f.backend.registered.count, 1)
    XCTAssertEqual(f.source.inspections, f.inspectionsBeforePanel)
    XCTAssertEqual(f.source.captures, f.capturesBeforePanel)
    XCTAssertEqual(f.backend.submissions.count, 0)
    XCTAssertFalse(try XCTUnwrap(f.panel.window).isVisible)
    XCTAssertEqual(f.panel.testOnlyRenderedState, .idle)
    XCTAssertEqual(f.panel.testOnlySessionState, .idle)
    XCTAssertTrue(f.controls.approvalRow.isHidden)
    XCTAssertFalse(f.controls.next.isEnabled)
    XCTAssertFalse(f.controls.previous.isEnabled)
    XCTAssertFalse(f.controls.approve.isEnabled)
    XCTAssertFalse(f.controls.reject.isEnabled)
    XCTAssertTrue(f.controls.find.isEnabled)
    XCTAssertTrue(f.controls.replace.isEnabled)
    XCTAssertEqual(f.controls.status.stringValue, "Idle")
    // Later duplicate/first-panel oracles are unentered on missing attachment.
    guard f.attached() else { return }
    XCTAssertThrowsError(
      try DocumentSearchPanelController(owner: f.owner, window: f.ticket, source: f.source)
    ) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .documentSlotOccupied)
    }
    XCTAssertEqual(f.backend.registered.count, 1)
    XCTAssertEqual(f.backend.unregistered, [])
    XCTAssertFalse(f.panel.testOnlyLogicallyClosed)
    guard let first = f.start(replacing: false) else { return }
    _ = try f.complete(first)
    f.assertResults(count: 2, selected: nil)
  }

  func testFindRendersCountAndOnlyExplicitNavigationBorrowsResults() throws {
    let f = try PanelFixture()
    defer { f.finish() }
    guard let index = f.start(replacing: false) else { return }
    let request = try f.backend.submission(index)
    XCTAssertEqual(request.descriptor.query.pattern, "x")
    if case .literal = request.descriptor.query.mode {
    } else {
      XCTFail("Find must snapshot literal mode")
    }
    XCTAssertTrue(request.descriptor.query.caseSensitive)
    XCTAssertFalse(request.descriptor.query.wholeWord)
    XCTAssertEqual(request.descriptor.operation, .find)
    XCTAssertNil(request.descriptor.scope)
    XCTAssertEqual(request.descriptor.limits.maxTextUTF16, 100_000_000)
    XCTAssertEqual(request.descriptor.limits.maxOutputUTF16, 100_000_000)
    XCTAssertEqual(request.descriptor.limits.maxMatches, 100_000)
    XCTAssertEqual(request.descriptor.limits.cooperativeMilliseconds, 1000)
    _ = try f.complete(index)
    f.assertResults(count: 2, selected: nil)
    XCTAssertEqual(f.source.selections, [], "Completion cannot auto-navigate")
    f.send(f.controls.previous)
    f.assertResults(count: 2, selected: 1)
    f.send(f.controls.next)
    f.assertResults(count: 2, selected: 0)
    f.send(f.controls.next)
    f.assertResults(count: 2, selected: 1)
    f.send(f.controls.next)
    f.assertResults(count: 2, selected: 0)
    XCTAssertEqual(f.source.selections, [f.ranges[1], f.ranges[0], f.ranges[1], f.ranges[0]])
    guard let empty = f.start(replacing: false) else { return }
    _ = try f.complete(empty, matches: [])
    f.assertResults(count: 0, selected: nil)
    XCTAssertFalse(f.controls.next.isEnabled)
    XCTAssertFalse(f.controls.previous.isEnabled)
    XCTAssertTrue(f.controls.approvalRow.isHidden)
    // Return's own query-control action must be Find, never destructive approval.
    let beforeReturn = f.backend.submissions.count
    f.send(f.controls.query)
    XCTAssertEqual(f.backend.submissions.count, beforeReturn + 1)
    XCTAssertEqual(f.panel.testOnlySessionState, .searching)
    XCTAssertEqual(f.panel.testOnlyRenderedState, .searching)
    guard f.backend.submissions.count == beforeReturn + 1 else { return }
    XCTAssertEqual(try f.backend.submission(beforeReturn).descriptor.operation, .find)
    _ = try f.complete(beforeReturn, matches: [])
    f.assertResults(count: 0, selected: nil)
  }

  func testEveryInputChangeInvalidatesApprovalAndLateDelivery() throws {
    for field in ["query", "replacement", "mode", "case", "word"] {
      let f = try PanelFixture()
      defer { f.finish() }
      guard let first = f.start(replacing: true) else { return }
      let lease = try f.complete(first, replacement: "😀yy")
      guard let token = f.token() else { return }
      f.panel.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: f.controls.status))
      XCTAssertEqual(
        f.panel.testOnlyDisplayedApproval, token, "Unrelated field cannot invalidate approval")
      XCTAssertFalse(f.backend.released.contains(lease))
      f.change(field)
      f.assertIdle()
      XCTAssertTrue(f.backend.released.contains(lease), field)
      XCTAssertFalse(f.panel.testOnlyRespondToApproval(token, approved: true), field)
      XCTAssertEqual(f.source.replacements, 0)
      guard let pending = f.start(replacing: false) else { return }
      let captured = try f.backend.capture(pending)
      let job = try f.backend.submission(pending).job
      f.change(field)
      f.assertIdle()
      XCTAssertTrue(f.backend.cancelled.contains(job), field)
      XCTAssertEqual(f.backend.pendingTerminalCount, 1, "Logical cancel is not backend completion")
      let late = f.backend.install(captured, matches: f.ranges, replacement: nil)
      f.backend.deliver(pending, .completed(late))
      f.assertIdle()
      XCTAssertTrue(f.backend.released.contains(late), field)
      XCTAssertEqual(f.backend.pendingTerminalCount, 0)
    }
  }

  func testInlineApprovalConsumesExactTokenAndAppliesOnce() throws {
    let f = try PanelFixture()
    defer { f.finish() }
    guard let first = f.start(replacing: true) else { return }
    let approvedLease = try f.complete(first, replacement: "😀yy")
    guard let approved = f.token() else { return }
    XCTAssertEqual(f.source.replacements, 0)
    XCTAssertEqual(f.backend.borrowDepth, 0)
    XCTAssertFalse(f.controls.next.isEnabled)
    XCTAssertFalse(f.controls.previous.isEnabled)
    XCTAssertFalse(f.controls.approvalRow.isHidden)
    XCTAssertTrue(f.controls.approve.isEnabled)
    f.send(f.controls.approve)
    XCTAssertEqual(f.source.replacements, 1)
    XCTAssertEqual(f.panel.testOnlySessionState, .replaced(matchCount: 2))
    XCTAssertEqual(f.panel.testOnlyRenderedState, .replaced(matchCount: 2))
    XCTAssertTrue(f.controls.approvalRow.isHidden)
    XCTAssertFalse(f.controls.approve.isEnabled)
    XCTAssertTrue(f.backend.released.contains(approvedLease))
    XCTAssertFalse(f.panel.testOnlyRespondToApproval(approved, approved: true))
    guard let second = f.start(replacing: true) else { return }
    let rejectedLease = try f.complete(second, replacement: "😀zz")
    guard let rejected = f.token() else { return }
    XCTAssertNotEqual(approved, rejected)
    f.send(f.controls.reject)
    f.assertIdle()
    XCTAssertTrue(f.backend.released.contains(rejectedLease))
    XCTAssertFalse(f.panel.testOnlyRespondToApproval(rejected, approved: true))
    XCTAssertEqual(f.source.replacements, 1)
    guard let third = f.start(replacing: true) else { return }
    _ = try f.complete(third, replacement: "😀yy")
    guard let stale = f.token(), let fourth = f.start(replacing: false) else { return }
    XCTAssertFalse(f.panel.testOnlyRespondToApproval(stale, approved: true))
    XCTAssertEqual(f.source.replacements, 1)
    _ = try f.complete(fourth)
    f.assertResults(count: 2, selected: nil)
    XCTAssertTrue(f.controls.approvalRow.isHidden)
  }

  func testThrownStartAndReplacementReentryPreserveNewerState() throws {
    let f = try PanelFixture()
    defer { f.finish() }
    f.backend.throwAfterSubmit = .resultBudget
    f.backend.onSubmit = { [weak f] index in
      guard let f else { return }
      do { _ = try f.complete(index) } catch { XCTFail("Scripted synchronous completion failed") }
    }
    let oldCount = f.backend.submissions.count
    f.send(f.controls.find)
    XCTAssertEqual(f.backend.submissions.count, oldCount + 1)
    guard f.backend.submissions.count == oldCount + 1 else { return }
    XCTAssertEqual(f.panel.testOnlySessionState, .failed(.admission(.resultBudget)))
    XCTAssertEqual(f.panel.testOnlyRenderedState, .failed(.admission(.resultBudget)))
    XCTAssertTrue(f.controls.approvalRow.isHidden)
    XCTAssertFalse(f.controls.next.isEnabled)
    XCTAssertFalse(
      f.controls.status.stringValue.contains(f.source.text), "Failure UI cannot expose source text")
    XCTAssertEqual(f.backend.payloads.count, 0)
    f.backend.throwAfterSubmit = nil
    guard let replacement = f.start(replacing: true) else { return }
    _ = try f.complete(replacement, replacement: "😀yy")
    guard let token = f.token() else { return }
    f.source.onReplace = { [weak f] in
      guard let f else { return }
      XCTAssertEqual(f.source.replacements, 1)
      f.send(f.controls.find)
    }
    XCTAssertFalse(f.panel.testOnlyRespondToApproval(token, approved: true))
    XCTAssertEqual(
      f.source.replacements, 1, "False response can follow the scripted replacement effect")
    XCTAssertEqual(f.panel.testOnlySessionState, .searching)
    XCTAssertEqual(f.panel.testOnlyRenderedState, .searching)
    XCTAssertTrue(f.controls.approvalRow.isHidden)
    guard f.backend.submissions.count == 3 else {
      XCTFail("Reentrant Find must submit exactly once")
      return
    }
    _ = try f.complete(2)
    f.assertResults(count: 2, selected: nil)
  }

  func testCancelAndCloseRetireOnlyOwnConsumerWithoutShutdown() throws {
    let f = try PanelFixture()
    defer { f.finish() }
    guard f.attached() else { return }
    let siblingSource = PanelSource()
    let siblingTicket = try f.owner.attachWindow(
      windowID: siblingSource.window, endpointID: siblingSource.endpoint)
    var siblingState: DocumentSearchSessionState = .idle
    let sibling = try DocumentSearchSession(
      owner: f.owner, window: siblingTicket,
      source: siblingSource, onState: { siblingState = $0 })
    defer {
      sibling.close()
      f.owner.detachWindow(siblingTicket)
    }
    guard let own = f.start(replacing: true) else { return }
    let ownLease = try f.complete(own, replacement: "😀yy")
    guard let ownToken = f.token() else { return }
    try sibling.start(
      query: SearchQuery(pattern: "x", mode: .literal), operation: .find,
      scope: nil,
      limits: SearchWireLimits(
        maxTextUTF16: 4, maxOutputUTF16: 4, maxMatches: 4,
        cooperativeMilliseconds: 100))
    let siblingIndex = f.backend.submissions.count - 1
    let siblingSubmission = try f.backend.submission(siblingIndex)
    let ownRegistration = try f.backend.registration(0)
    f.send(f.controls.cancel)
    f.assertIdle()
    XCTAssertTrue(f.backend.released.contains(ownLease))
    XCTAssertFalse(f.panel.testOnlyRespondToApproval(ownToken, approved: true))
    f.panel.close()
    f.panel.close()
    XCTAssertEqual(f.backend.unregistered, [ownRegistration])
    XCTAssertFalse(f.backend.cancelled.contains(siblingSubmission.job))
    XCTAssertEqual(f.backend.shutdownCalls, 0)
    let captured = try f.backend.capture(siblingIndex)
    let siblingLease = f.backend.install(captured, matches: f.ranges, replacement: nil)
    f.backend.deliver(siblingIndex, .completed(siblingLease))
    XCTAssertEqual(siblingState, .results(matchCount: 2, selectedIndex: nil))
    XCTAssertTrue(sibling.next())
    XCTAssertEqual(siblingSource.selections, [f.ranges[0]])
    XCTAssertFalse(f.backend.released.contains(siblingLease))
    sibling.close()
    f.owner.detachWindow(siblingTicket)
    XCTAssertTrue(f.backend.released.contains(siblingLease))
    XCTAssertEqual(f.backend.unregistered.count, 2)
  }

  func testExactHiddenCloseAndDelegateIdentityNotifyOnce() throws {
    for route in ["programmatic", "delegate"] {
      let log = PanelCloseLog()
      let f = try PanelFixture(onClose: { log.receive($0) })
      defer { f.finish() }
      guard f.attached() else { return }
      log.panel = f.panel
      log.backend = f.backend
      log.originalConsumer = try f.backend.registration(0)
      log.reenter = true
      let actualWindow = try XCTUnwrap(f.panel.window)
      XCTAssertFalse(actualWindow.isVisible)
      let other = NSPanel(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
      other.isReleasedWhenClosed = false
      defer { other.close() }
      // Injected UI delegate callback, not a claim of AppKit delivery.
      f.panel.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))
      XCTAssertFalse(f.panel.testOnlyLogicallyClosed)
      XCTAssertEqual(log.calls, 0)
      XCTAssertEqual(f.backend.unregistered, [])
      if route == "programmatic" {
        f.panel.close()
      } else {
        f.panel.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: actualWindow))
      }
      XCTAssertTrue(f.panel.testOnlyLogicallyClosed)
      XCTAssertEqual(f.panel.testOnlySessionState, .closed)
      XCTAssertEqual(f.panel.testOnlyRenderedState, .closed)
      XCTAssertEqual(log.calls, 1)
      XCTAssertTrue(log.exact)
      XCTAssertEqual(f.backend.unregistered, f.backend.registered)
      XCTAssertTrue(f.controls.approvalRow.isHidden)
      XCTAssertFalse(f.controls.find.isEnabled)
      f.panel.close()
      f.panel.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: actualWindow))
      XCTAssertEqual(log.calls, 1)
      let submissions = f.backend.submissions.count
      f.send(f.controls.find)
      f.send(f.controls.replace)
      XCTAssertEqual(f.backend.submissions.count, submissions)
    }
  }

  func testOwnPanelBackendAndSourceReentryCannotReopenOrOverwriteState() throws {
    for seam in ["release", "cancel", "source"] {
      let f = try PanelFixture()
      defer { f.finish() }
      guard let old = f.start(replacing: false) else { return }
      if seam == "source" {
        let lease = try f.complete(old)
        f.source.onSelect = { [weak f] in f?.panel.close() }
        f.send(f.controls.next)
        XCTAssertEqual(f.panel.testOnlySessionState, .closed)
        XCTAssertEqual(f.panel.testOnlyRenderedState, .closed)
        XCTAssertTrue(f.panel.testOnlyLogicallyClosed)
        XCTAssertTrue(f.backend.released.contains(lease))
        let count = f.backend.submissions.count
        f.send(f.controls.find)
        XCTAssertEqual(f.backend.submissions.count, count)
        continue
      }
      var captured: SearchAdmissionCapture<DocumentSearchCredential>?
      if seam == "release" {
        _ = try f.complete(old)
        f.backend.onRelease = { [weak f] _ in if let f { f.send(f.controls.find) } }
      } else {
        captured = try f.backend.capture(old)
        f.backend.onCancel = { [weak f] _ in if let f { f.send(f.controls.find) } }
      }
      f.send(f.controls.cancel)
      XCTAssertEqual(f.backend.submissions.count, 2)
      XCTAssertEqual(f.panel.testOnlySessionState, .searching)
      XCTAssertEqual(f.panel.testOnlyRenderedState, .searching)
      guard f.backend.submissions.count == 2 else { return }
      let newerJob = try f.backend.submission(1).job
      XCTAssertFalse(f.backend.cancelled.contains(newerJob))
      if let captured {
        let late = f.backend.install(captured, matches: f.ranges, replacement: nil)
        f.backend.deliver(old, .completed(late))
        XCTAssertTrue(f.backend.released.contains(late))
        XCTAssertEqual(f.panel.testOnlyRenderedState, .searching)
      }
      _ = try f.complete(1)
      f.assertResults(count: 2, selected: nil)
    }
  }
}

private enum PanelFixtureError: Error { case missing, bound }

private struct PanelCloseCallbackFacts {
  let session: DocumentSearchSessionState?
  let rendered: DocumentSearchSessionState
  let logicallyClosed: Bool
  let approvalHidden: Bool
  let controlsDisabled: Bool
  let originalConsumerRetired: Bool
}

@MainActor private final class PanelCloseLog {
  weak var panel: DocumentSearchPanelController?
  weak var backend: PanelBackend?
  var originalConsumer: SearchConsumerID?
  var calls = 0, exact = true, reenter = false
  private(set) var snapshots: [PanelCloseCallbackFacts] = []
  func receive(_ value: DocumentSearchPanelController) {
    guard calls < 4 else {
      XCTFail("Own close callback exceeded bound")
      return
    }
    calls += 1
    exact = exact && value === panel
    let controls = value.testOnlyControls
    let interactive: [NSControl] = [
      controls.query, controls.replacement, controls.mode,
      controls.matchCase, controls.wholeWord, controls.find, controls.replace, controls.cancel,
      controls.previous, controls.next, controls.approve, controls.reject,
    ]
    let retired: Bool
    if let backend, let originalConsumer {
      retired =
        backend.registered.contains(originalConsumer)
        && backend.unregistered.contains(originalConsumer)
    } else {
      retired = false
    }
    // Immutable actual facts sampled INSIDE onClose, before its own reentrant close.
    let facts = PanelCloseCallbackFacts(
      session: value.testOnlySessionState,
      rendered: value.testOnlyRenderedState, logicallyClosed: value.testOnlyLogicallyClosed,
      approvalHidden: controls.approvalRow.isHidden,
      controlsDisabled: interactive.allSatisfy { !$0.isEnabled }, originalConsumerRetired: retired)
    snapshots.append(facts)
    XCTAssertTrue(facts.logicallyClosed)
    XCTAssertEqual(facts.session, .closed)
    XCTAssertEqual(facts.rendered, .closed)
    XCTAssertTrue(facts.approvalHidden)
    XCTAssertTrue(facts.controlsDisabled)
    XCTAssertTrue(facts.originalConsumerRetired, "Own real consumer must retire before onClose")
    if reenter { value.close() }
  }
}

@MainActor private final class PanelSource: ApplicationDocumentSearchSource {
  let window = UUID(), endpoint = UUID(), document = UUID(), pane = UUID(), ownership = UUID()
  let text = "😀xx"
  var inspections = 0, captures = 0, replacements = 0
  var selections: [NSRange] = []
  var onReplace: (@MainActor () -> Void)?, onSelect: (@MainActor () -> Void)?
  func credential() throws -> DocumentSearchCredential {
    try DocumentSearchCredential(
      windowID: window, endpointID: endpoint, documentID: document,
      paneID: pane, ownershipGeneration: ownership, editRevision: 7, inputUTF16: 4)
  }
  func inspect() throws -> DocumentSearchCredential {
    guard inspections < 64 else {
      XCTFail("Inspection cap")
      throw PanelFixtureError.bound
    }
    inspections += 1
    return try credential()
  }
  func capture(expected: DocumentSearchCredential) throws -> SearchAdmissionCapture<
    DocumentSearchCredential
  > {
    guard captures < 16, try credential() == expected else {
      throw ApplicationDocumentSearchFailure.staleSource
    }
    captures += 1
    return SearchAdmissionCapture(text: text, inputUTF16: 4, context: expected)
  }
  func isCurrent(expected: DocumentSearchCredential) -> Bool { (try? credential()) == expected }
  func select(expected: DocumentSearchCredential, source: String, range: NSRange) -> Bool {
    guard selections.count < 16, (try? credential()) == expected, source == text else {
      return false
    }
    let callback = onSelect
    onSelect = nil
    callback?()
    selections.append(range)
    return true
  }
  func replace(expected: DocumentSearchCredential, source: String, replacement: String) -> Bool {
    guard replacements < 8, (try? credential()) == expected, source == text,
      replacement.utf16.count <= 16
    else { return false }
    replacements += 1  // Explicit scripted counter effect only; no native/document text mutation.
    let callback = onReplace
    onReplace = nil
    callback?()
    return true
  }
}

@MainActor private final class PanelBackend: ApplicationSearchBackend {
  final class Submission {
    let consumer: SearchConsumerID, job: SearchJobID
    let descriptor: SearchAdmissionDescriptor
    var capture: (@MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>)?
    var completion: (@MainActor (SearchAdmissionDelivery) -> Void)?
    var delivered = false
    init(
      consumer: SearchConsumerID, job: SearchJobID, descriptor: SearchAdmissionDescriptor,
      capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
      completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
    ) {
      self.consumer = consumer
      self.job = job
      self.descriptor = descriptor
      self.capture = capture
      self.completion = completion
    }
  }
  struct Payload {
    let captured: SearchAdmissionCapture<DocumentSearchCredential>
    let output: SearchExecutionOutput
  }
  var registered: [SearchConsumerID] = [], unregistered: [SearchConsumerID] = []
  var cancelled: [SearchJobID] = [], released: [SearchResultLeaseID] = []
  var submissions: [Submission] = [], payloads: [SearchResultLeaseID: Payload] = [:]
  var onSubmit: (@MainActor (Int) -> Void)?
  var onCancel: (@MainActor (SearchJobID) -> Void)?,
    onRelease: (@MainActor (SearchResultLeaseID) -> Void)?
  var throwAfterSubmit: SearchAdmissionFailure?
  var borrowDepth = 0, shutdownCalls = 0
  var pendingTerminalCount: Int { submissions.filter { !$0.delivered }.count }
  func registration(_ index: Int) throws -> SearchConsumerID {
    guard registered.indices.contains(index) else {
      XCTFail("Missing real registration")
      throw PanelFixtureError.missing
    }
    return registered[index]
  }
  func submission(_ index: Int) throws -> Submission {
    guard submissions.indices.contains(index) else {
      XCTFail("Missing real submission")
      throw PanelFixtureError.missing
    }
    return submissions[index]
  }
  func register() -> SearchConsumerID {
    precondition(registered.count < 8)
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func unregister(_ consumer: SearchConsumerID) {
    XCTAssertTrue(registered.contains(consumer))
    XCTAssertFalse(unregistered.contains(consumer))
    guard unregistered.count < 8 else {
      XCTFail("Unregister cap")
      return
    }
    unregistered.append(consumer)
  }
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    guard submissions.count < 8 else {
      XCTFail("Submission cap")
      throw PanelFixtureError.bound
    }
    let job = SearchJobID()
    submissions.append(
      Submission(
        consumer: consumer, job: job, descriptor: descriptor,
        capture: capture, completion: completion))
    let callback = onSubmit
    onSubmit = nil
    callback?(submissions.count - 1)
    if let throwAfterSubmit { throw throwAfterSubmit }
    return job
  }
  func cancel(_ id: SearchJobID) {
    XCTAssertFalse(cancelled.contains(id))
    guard cancelled.count < 16 else {
      XCTFail("Cancel cap")
      return
    }
    cancelled.append(id)
    let callback = onCancel
    onCancel = nil
    callback?(id)
  }
  func release(_ id: SearchResultLeaseID) {
    XCTAssertFalse(released.contains(id))
    guard released.count < 16 else {
      XCTFail("Release cap")
      return
    }
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
    guard let payload = payloads[id], borrowDepth == 0 else { return false }
    borrowDepth += 1
    defer { borrowDepth -= 1 }
    body(payload.captured.context, payload.captured.text, payload.output)
    return true
  }
  func capture(_ index: Int) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    let request = try submission(index)
    let callback = try XCTUnwrap(request.capture)
    return try callback()
  }
  func install(
    _ captured: SearchAdmissionCapture<DocumentSearchCredential>, matches: [NSRange],
    replacement: String?
  ) -> SearchResultLeaseID {
    precondition(matches.count <= 4 && payloads.count < 16)
    let id = SearchResultLeaseID()
    payloads[id] = Payload(
      captured: captured, output: SearchExecutionOutput(matches: matches, replacement: replacement))
    return id
  }
  func deliver(_ index: Int, _ delivery: SearchAdmissionDelivery) {
    guard submissions.indices.contains(index), !submissions[index].delivered else {
      XCTFail("Missing/duplicate actual scripted terminal completion")
      return
    }
    let request = submissions[index]
    request.delivered = true
    let callback = request.completion
    request.completion = nil
    request.capture = nil
    callback?(delivery)
  }
  func finishPending() {
    for index in submissions.indices where !submissions[index].delivered {
      deliver(index, .failed(.cancelled))
    }
  }
  func clearHooks() {
    onSubmit = nil
    onCancel = nil
    onRelease = nil
    throwAfterSubmit = nil
  }
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    shutdownCalls += 1
    return .callerRefused(.unsupportedDriver)
  }
}

@MainActor private final class PanelFixture {
  let backend = PanelBackend(), source = PanelSource()
  let owner: ApplicationSearchOwner, ticket: ApplicationSearchWindowID
  let panel: DocumentSearchPanelController
  let inspectionsBeforePanel: Int, capturesBeforePanel: Int
  let ranges = [NSRange(location: 2, length: 1), NSRange(location: 3, length: 1)]
  var controls: DocumentSearchPanelTestControls { panel.testOnlyControls }
  init(onClose: @escaping @MainActor (DocumentSearchPanelController) -> Void = { _ in }) throws {
    _ = NSApplication.shared
    owner = ApplicationSearchOwner(backend: backend)
    ticket = try owner.attachWindow(windowID: source.window, endpointID: source.endpoint)
    inspectionsBeforePanel = source.inspections
    capturesBeforePanel = source.captures
    panel = try DocumentSearchPanelController(
      owner: owner, window: ticket, source: source, onClose: onClose)
    controls.query.stringValue = "x"
    controls.replacement.stringValue = "y"
  }
  func attached() -> Bool {
    XCTAssertEqual(backend.registered.count, 1, "Panel must attach one real session consumer")
    XCTAssertNotNil(panel.testOnlySessionState, "Missing actual panel session is declaration RED")
    return backend.registered.count == 1 && panel.testOnlySessionState != nil
  }
  func send(_ control: NSControl) {
    guard let action = control.action, let target = control.target else {
      XCTFail("Missing actual control target/action")
      return
    }
    XCTAssertTrue(NSApp.sendAction(action, to: target, from: control))
  }
  func start(replacing: Bool) -> Int? {
    let before = backend.submissions.count
    send(replacing ? controls.replace : controls.find)
    XCTAssertEqual(
      backend.submissions.count, before + 1, "Panel action must start real session request")
    XCTAssertEqual(panel.testOnlySessionState, .searching)
    XCTAssertEqual(panel.testOnlyRenderedState, .searching)
    guard backend.submissions.count == before + 1, panel.testOnlySessionState == .searching else {
      return nil
    }
    return before
  }
  func complete(_ index: Int, matches: [NSRange]? = nil, replacement: String? = nil) throws
    -> SearchResultLeaseID
  {
    let captured = try backend.capture(index)
    let lease = backend.install(captured, matches: matches ?? ranges, replacement: replacement)
    backend.deliver(index, .completed(lease))
    return lease
  }
  func token() -> DocumentSearchApprovalToken? {
    guard let state = panel.testOnlySessionState,
      case .awaitingApproval(let token, let count) = state
    else {
      XCTFail("Actual session approval horizon missing")
      return nil
    }
    XCTAssertEqual(count, 2)
    XCTAssertEqual(panel.testOnlyDisplayedApproval, token)
    XCTAssertEqual(panel.testOnlyRenderedState, .awaitingApproval(token: token, matchCount: 2))
    XCTAssertFalse(controls.approvalRow.isHidden)
    XCTAssertTrue(controls.approve.isEnabled)
    XCTAssertTrue(controls.status.stringValue.contains("2"))
    return token
  }
  func assertIdle() {
    XCTAssertEqual(panel.testOnlySessionState, .idle)
    XCTAssertEqual(panel.testOnlyRenderedState, .idle)
    XCTAssertNil(panel.testOnlyDisplayedApproval)
    XCTAssertTrue(controls.approvalRow.isHidden)
    XCTAssertFalse(controls.next.isEnabled)
    XCTAssertFalse(controls.previous.isEnabled)
  }
  func assertResults(count: Int, selected: Int?) {
    XCTAssertEqual(panel.testOnlySessionState, .results(matchCount: count, selectedIndex: selected))
    XCTAssertEqual(
      panel.testOnlyRenderedState, .results(matchCount: count, selectedIndex: selected))
    XCTAssertTrue(controls.status.stringValue.contains(String(count)))
    XCTAssertEqual(controls.next.isEnabled, count > 0)
    XCTAssertEqual(controls.previous.isEnabled, count > 0)
    XCTAssertTrue(controls.approvalRow.isHidden)
    XCTAssertEqual(backend.borrowDepth, 0)
  }
  func change(_ field: String) {
    switch field {
    case "query":
      controls.query.stringValue += "q"
      panel.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: controls.query))
    case "replacement":
      controls.replacement.stringValue += "r"
      panel.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: controls.replacement))
    case "mode":
      controls.mode.selectItem(at: controls.mode.indexOfSelectedItem == 0 ? 1 : 0)
      send(controls.mode)
    case "case":
      controls.matchCase.state = controls.matchCase.state == .on ? .off : .on
      send(controls.matchCase)
    case "word":
      controls.wholeWord.state = controls.wholeWord.state == .on ? .off : .on
      send(controls.wholeWord)
    default: XCTFail("Unknown finite input row")
    }
  }
  func finish() {
    backend.clearHooks()
    source.onSelect = nil
    source.onReplace = nil
    panel.close()
    // Test owns this exact window ticket; detach retires only it even on declaration RED.
    // All panel close/isolation assertions run BEFORE this authorized final cleanup.
    owner.detachWindow(ticket)
    backend.finishPending()
    XCTAssertEqual(Set(backend.registered), Set(backend.unregistered))
    XCTAssertEqual(backend.registered.count, backend.unregistered.count)
    XCTAssertEqual(backend.pendingTerminalCount, 0)
    XCTAssertTrue(backend.payloads.isEmpty)
    XCTAssertEqual(backend.borrowDepth, 0)
    XCTAssertEqual(backend.shutdownCalls, 0)
  }
}
