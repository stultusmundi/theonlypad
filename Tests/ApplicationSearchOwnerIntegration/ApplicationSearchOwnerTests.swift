import Foundation
import PadCore
import XCTest

@testable import ApplicationSearchOwnerComponent
@testable import SearchExecution

// Original clients of the accepted application contract. No candidate owner is present.
@MainActor
final class ApplicationSearchOwnerTests: XCTestCase {
  // Catches admission after insertion, trusting caller counts, and foreign-ticket eviction.
  func testThirtySecondWindowAdmitsAndThirtyThirdNeverRegisters() throws {
    let backend = ScriptedBackend()
    let owner = ApplicationSearchOwner(backend: backend)
    let numbers: [UInt16] = [
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
      17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    ]
    var windows: [ApplicationSearchWindowID] = []
    var consumers: [ApplicationDocumentSearchConsumer] = []
    var sources: [SourceState] = []
    for number in numbers {
      windows.append(
        try owner.attachWindow(windowID: literalID(number), endpointID: literalID(number)))
    }
    XCTAssertEqual(backend.registered.count, 0)
    XCTAssertThrowsError(try owner.attachWindow(windowID: literalID(33), endpointID: literalID(33)))
    {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .windowCapacity)
    }
    for window in windows {
      let state = try SourceState()
      sources.append(state)
      consumers.append(
        try owner.attachDocument(
          window: window, source: state.source,
          onDelivery: { _ in
            XCTFail("No submission was made")
          }))
    }
    XCTAssertEqual(backend.registered.count, 32)
    let foreignBackend = ScriptedBackend()
    let foreign = ApplicationSearchOwner(backend: foreignBackend)
    let foreignTicket = try foreign.attachWindow(windowID: literalID(1), endpointID: literalID(1))
    owner.detachWindow(foreignTicket)
    XCTAssertEqual(backend.unregistered.count, 0)
    XCTAssertThrowsError(try owner.attachWindow(windowID: literalID(33), endpointID: literalID(33)))
    {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .windowCapacity)
    }
    owner.detachWindow(windows[0])
    XCTAssertEqual(backend.unregistered, [try backend.registeredID(0)])
    let fresh = try owner.attachWindow(windowID: literalID(33), endpointID: literalID(33))
    owner.detachWindow(windows[0])
    XCTAssertEqual(backend.unregistered.count, 1)
    let replacement = try SourceState()
    consumers.append(
      try owner.attachDocument(
        window: fresh, source: replacement.source,
        onDelivery: { _ in
          XCTFail("No submission was made")
        }))
    XCTAssertEqual(backend.registered.count, 33)
    XCTAssertEqual(sources.count, 32)
    XCTAssertEqual(consumers.count, 33)
  }

  // Catches silent document-role replacement and double unregister on explicit close.
  func testOneDocumentRoleAndEmptyFolderReservation() throws {
    let f = try Fixture()
    XCTAssertThrowsError(
      try f.owner.attachDocument(
        window: f.window, source: f.state.source,
        onDelivery: { _ in XCTFail("Duplicate role must not receive") })
    ) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .documentSlotOccupied)
    }
    XCTAssertEqual(f.backend.registered.count, 1)
    f.consumer.close()
    f.consumer.close()
    XCTAssertEqual(f.backend.unregistered, [try f.backend.registeredID(0)])
    let next = try f.owner.attachDocument(
      window: f.window, source: f.state.source, onDelivery: { _ in })
    XCTAssertEqual(f.backend.registered.count, 2)
    XCTAssertNotEqual(try f.backend.registeredID(0), try f.backend.registeredID(1))
    next.close()
    XCTAssertEqual(f.backend.unregistered, f.backend.registered)
  }

  // Catches eager String capture and silently searching the new revision of a queued request.
  func testQueuedInvocationContainsNoTextAndCapturesOnlyAfterAdmission() throws {
    let changed = try Fixture()
    _ = try changed.start()
    XCTAssertEqual(changed.state.inspectCalls, 1)
    XCTAssertEqual(changed.state.captureCalls, 0)
    let queued = try changed.backend.submission(0)
    XCTAssertEqual(queued.descriptor.estimatedInputUTF16, 3)
    XCTAssertEqual(queued.descriptor.query.pattern, "x")
    XCTAssertNil(queued.descriptor.scope)
    changed.state.text = "😀z"
    changed.state.credential = try credential(revision: 8)
    XCTAssertThrowsError(try changed.backend.capture(0))
    XCTAssertEqual(changed.backend.captures.count, 0)
    XCTAssertEqual(changed.state.selections.count, 0)
    let same = try Fixture()
    _ = try same.start()
    XCTAssertEqual(same.state.captureCalls, 0)
    let captured = try same.backend.capture(0)
    XCTAssertEqual(captured.text, "😀x")
    XCTAssertEqual(captured.inputUTF16, 3)
    XCTAssertEqual(captured.context, try credential(revision: 7))
    XCTAssertEqual(same.state.captureCalls, 1)
  }

  // Catches capture despite rejected submit; no duplicate of the core budget algorithm.
  func testBudgetOrQueueRefusalNeverCaptures() throws {
    let rows: [SearchAdmissionFailure] = [.resultBudget, .queueFull]
    for failure in rows {
      let f = try Fixture()
      f.backend.submitFailure = failure
      XCTAssertThrowsError(try f.start()) {
        XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .admission(failure))
      }
      XCTAssertEqual(f.state.inspectCalls, 1)
      XCTAssertEqual(f.state.captureCalls, 0)
      XCTAssertEqual(f.state.selections.count, 0)
      XCTAssertEqual(f.state.replacements.count, 0)
      XCTAssertEqual(f.backend.submitCalls, 1)
    }
  }

  // Catches missing post-callback fences and loss of a returned core handle after reentry.
  func testCancelDuringSourceCallbackRejectsReturnedCapture() throws {
    for seam in ["current", "capture"] {
      let f = try Fixture()
      let events = EventLog()
      let cancel: @MainActor () -> Void = {
        events.add("cancelIntent")
        f.consumer.cancel()
      }
      if seam == "current" { f.state.onCurrent = cancel } else { f.state.onCapture = cancel }
      f.backend.onSubmit = { index in
        do {
          _ = try f.backend.capture(index)
          XCTFail("Cancelled capture must throw")
        } catch {}
        events.add("captureReturned")
      }
      f.backend.onCancel = { _ in events.add("returnedJobCancelled") }
      XCTAssertThrowsError(try f.start()) {
        XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .cancelled)
      }
      XCTAssertEqual(f.backend.cancelled, [try f.backend.submission(0).job])
      XCTAssertEqual(events.values, ["cancelIntent", "captureReturned", "returnedJobCancelled"])
      XCTAssertEqual(f.backend.captures.count, 0)
      XCTAssertEqual(f.deliveries.values.count, 0)
    }
  }

  // Catches keeping the old result usable after replacement admission refuses.
  func testReplacementRetiresLeaseBeforeCoreBusyRefusal() throws {
    let f = try Fixture()
    let held = try f.complete(replacement: nil)
    let events = EventLog()
    f.backend.onRelease = { id in
      XCTAssertEqual(id, held.lease)
      events.add("releasedOld")
    }
    f.backend.onSubmitAttempt = { events.add("submitNew") }
    f.backend.submitFailure = .consumerBusy
    XCTAssertThrowsError(try f.start()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .admission(.consumerBusy))
    }
    XCTAssertEqual(events.values, ["releasedOld", "submitNew"])
    XCTAssertEqual(f.backend.released, [held.lease])
    XCTAssertFalse(f.consumer.navigate(result: held.result, matchIndex: 0))
    XCTAssertEqual(f.state.captureCalls, 1)
    XCTAssertEqual(f.backend.registered.count, 1)
    XCTAssertEqual(f.backend.submitCalls, 2)
  }

  // Catches orphan completion leaking its exact lease or invoking a closed UI callback.
  func testLateCompletionAfterCloseReleasesExactLease() throws {
    let f = try Fixture()
    _ = try f.start()
    let job = try f.backend.submission(0).job
    f.backend.onUnregister = { _ in
      XCTAssertEqual(f.backend.cancelled, [job])
      do {
        _ = try f.start()
        XCTFail("Closed consumer must refuse start")
      } catch {
        XCTAssertEqual(error as? ApplicationDocumentSearchFailure, .closed)
      }
    }
    f.consumer.close()
    let late = f.backend.install(context: try credential(), replacement: nil)
    f.backend.deliver(0, .completed(late))
    f.consumer.close()
    XCTAssertEqual(f.backend.cancelled, [job])
    XCTAssertEqual(f.backend.unregistered, [try f.backend.registeredID(0)])
    XCTAssertEqual(f.backend.released, [late])
    XCTAssertEqual(f.deliveries.values.count, 0)
    XCTAssertEqual(f.state.selections.count, 0)
    XCTAssertEqual(f.state.replacements.count, 0)
  }

  // Catches detaching by slot/index instead of exact opaque window/consumer identity.
  func testSiblingWindowSurvivesExactConsumerDetach() throws {
    let backend = ScriptedBackend()
    let owner = ApplicationSearchOwner(backend: backend)
    let a = try Fixture(backend: backend, owner: owner)
    let b = try Fixture(
      backend: backend, owner: owner, windowNumber: 0x0111, endpointNumber: 0x0112)
    let first = try a.complete(replacement: nil)
    let sibling = try b.complete(replacement: nil)
    _ = try a.start()
    let pending = try backend.submission(2).job
    owner.detachWindow(a.window)
    XCTAssertEqual(backend.cancelled, [pending])
    XCTAssertEqual(backend.unregistered, [try backend.registeredID(0)])
    XCTAssertEqual(backend.released, [first.lease])
    XCTAssertEqual(
      b.consumer.summary(for: sibling.result),
      DocumentSearchSummary(matchCount: 1, hasReplacement: false))
    XCTAssertTrue(b.consumer.navigate(result: sibling.result, matchIndex: 0))
    let newA = try owner.attachWindow(windowID: literalID(0x0101), endpointID: literalID(0x0102))
    owner.detachWindow(a.window)
    XCTAssertEqual(backend.unregistered.count, 1)
    let next = try owner.attachDocument(window: newA, source: a.state.source, onDelivery: { _ in })
    XCTAssertEqual(backend.registered.count, 3)
    XCTAssertTrue(b.consumer.navigate(result: sibling.result, matchIndex: 0))
    next.close()
  }

  // Catches payload use outside a borrow and navigation after in-borrow invalidation.
  func testMetadataAndNavigationUseLeaseBorrow() throws {
    let f = try Fixture()
    let held = try f.complete(replacement: "😀y")
    XCTAssertEqual(
      f.consumer.summary(for: held.result),
      DocumentSearchSummary(matchCount: 1, hasReplacement: true))
    XCTAssertFalse(f.consumer.navigate(result: held.result, matchIndex: 1))
    XCTAssertEqual(f.state.selections.count, 0)
    f.state.onSelect = {
      XCTAssertEqual(f.backend.borrowDepth, 1)
      f.consumer.cancel()
      XCTAssertEqual(f.backend.released, [held.lease])
      // The backend's stack-local snapshot remains alive until this borrow returns.
      XCTAssertEqual(f.backend.borrowedSource, "😀x")
    }
    XCTAssertFalse(f.consumer.navigate(result: held.result, matchIndex: 0))
    XCTAssertEqual(f.state.selections.count, 1)
    let selection = try checked(f.state.selections, at: 0)
    XCTAssertEqual(selection.0, try credential())
    XCTAssertEqual(selection.1, "😀x")
    XCTAssertEqual(selection.2, NSRange(location: 2, length: 1))
    XCTAssertEqual(f.backend.borrowDepth, 0)
    XCTAssertNil(f.backend.borrowedSource)
    XCTAssertFalse(f.consumer.navigate(result: held.result, matchIndex: 0))
    XCTAssertEqual(f.state.selections.count, 1)
    let invalid = try Fixture()
    let invalidHeld = try invalid.complete(replacement: nil)
    invalid.backend.invalidate(invalidHeld.lease)
    XCTAssertFalse(invalid.consumer.navigate(result: invalidHeld.result, matchIndex: 0))
    XCTAssertEqual(invalid.state.selections.count, 0)
  }

  // Catches retaining naked replacement through a modal gap or approving a stale nonce.
  func testModalApprovalReborrowsAndRejectsSupersededResult() throws {
    for gap in ["edit", "cancel", "newResult", "prepare", "close", "unchanged"] {
      let f = try Fixture()
      let held = try f.complete(replacement: "😀y")
      XCTAssertEqual(
        f.consumer.summary(for: held.result),
        DocumentSearchSummary(matchCount: 1, hasReplacement: true))
      XCTAssertEqual(f.backend.borrowDepth, 0)
      switch gap {
      case "edit": f.state.credential = try credential(revision: 8)
      case "cancel": f.consumer.cancel()
      case "newResult": _ = try f.complete(replacement: "😀y")
      case "prepare": _ = try f.owner.prepareQuit()
      case "close": f.consumer.close()
      default: break
      }
      let before = f.backend.borrowCalls
      let replaced = f.consumer.replaceAll(result: held.result)
      if gap == "unchanged" {
        XCTAssertTrue(replaced)
        XCTAssertEqual(f.backend.borrowCalls, before + 1)
        XCTAssertEqual(f.state.replacements.count, 1)
        let replacement = try checked(f.state.replacements, at: 0)
        XCTAssertEqual(replacement.0, try credential())
        XCTAssertEqual(replacement.1, "😀x")
        XCTAssertEqual(replacement.2, "😀y")
        XCTAssertEqual(f.backend.released, [held.lease])
      } else {
        XCTAssertFalse(replaced)
        XCTAssertEqual(f.state.replacements.count, 0)
      }
      XCTAssertEqual(f.backend.borrowDepth, 0)
    }
  }

  // Catches comparing equal text/count instead of the original revision after ABA edits.
  func testEditThenRestoreCannotUseEarlierResultCredential() throws {
    let f = try Fixture()
    _ = try f.start()
    let captured = try f.backend.capture(0)
    f.state.text = "😀z"
    f.state.credential = try credential(revision: 8)
    f.state.text = "😀x"
    f.state.credential = try credential(revision: 9)
    let lease = f.backend.install(context: captured.context, replacement: "😀y")
    f.backend.deliver(0, .completed(lease))
    XCTAssertEqual(f.backend.released, [lease])
    XCTAssertEqual(f.deliveries.values.count, 1)
    if case .failed(_, let failure) = try checked(f.deliveries.values, at: 0) {
      XCTAssertEqual(failure, .staleSource)
    } else {
      XCTFail("Restored equal text must not complete revision seven")
    }
    let existing = try Fixture()
    let held = try existing.complete(replacement: "😀y")
    existing.state.credential = try credential(revision: 8)
    existing.state.text = "😀z"
    existing.state.credential = try credential(revision: 9)
    existing.state.text = "😀x"
    XCTAssertNil(existing.consumer.summary(for: held.result))
    XCTAssertFalse(existing.consumer.navigate(result: held.result, matchIndex: 0))
    XCTAssertFalse(existing.consumer.replaceAll(result: held.result))
    XCTAssertEqual(existing.backend.released, [held.lease])
    XCTAssertEqual(existing.state.selections.count, 0)
    XCTAssertEqual(existing.state.replacements.count, 0)
  }

  // Catches treating text equality as ownership/pane/native admission authority.
  func testEndpointOwnershipPaneAndCompositionChangesFenceSource() throws {
    for change in [
      "endpoint", "ownership", "pane", "detached", "saving", "composition", "admission",
    ] {
      let f = try Fixture()
      _ = try f.start()
      try f.state.change(change)
      XCTAssertThrowsError(try f.backend.capture(0))
      XCTAssertEqual(f.backend.captures.count, 0)
      let resultFixture = try Fixture()
      let held = try resultFixture.complete(replacement: "😀y")
      try resultFixture.state.change(change)
      XCTAssertFalse(resultFixture.consumer.navigate(result: held.result, matchIndex: 0))
      XCTAssertFalse(resultFixture.consumer.replaceAll(result: held.result))
      XCTAssertEqual(resultFixture.state.selections.count, 0)
      XCTAssertEqual(resultFixture.state.replacements.count, 0)
    }
    let finalCheck = try Fixture()
    let held = try finalCheck.complete(replacement: nil)
    finalCheck.state.onSelect = {
      do { try finalCheck.state.change("ownership") } catch {
        XCTFail("Literal mutation failed: \(error)")
      }
    }
    XCTAssertFalse(finalCheck.consumer.navigate(result: held.result, matchIndex: 0))
    XCTAssertEqual(finalCheck.state.selections.count, 0)
  }

  // Catches phase publication after cancel/release and replacing the backend on veto.
  func testPrepareFencesBeforeEffectsAndVetoReusesBackend() throws {
    let backend = ScriptedBackend()
    let owner = ApplicationSearchOwner(backend: backend)
    let pending = try Fixture(backend: backend, owner: owner)
    let result = try Fixture(
      backend: backend, owner: owner, windowNumber: 0x0111, endpointNumber: 0x0112)
    _ = try pending.start()
    let held = try result.complete(replacement: nil)
    let check: @MainActor () -> Void = {
      do {
        _ = try pending.start()
        XCTFail("Prepared search must refuse")
      } catch {
        XCTAssertEqual(error as? ApplicationDocumentSearchFailure, .preparingQuit)
      }
      XCTAssertNil(result.consumer.summary(for: held.result))
      XCTAssertFalse(result.consumer.navigate(result: held.result, matchIndex: 0))
      XCTAssertEqual(backend.joinCalls, 0)
    }
    backend.onCancel = { _ in check() }
    backend.onRelease = { _ in check() }
    let quit = try owner.prepareQuit()
    XCTAssertEqual(owner.phase, .prepared(quit))
    XCTAssertEqual(backend.cancelled, [try backend.submission(0).job])
    XCTAssertEqual(backend.released, [held.lease])
    XCTAssertEqual(backend.unregistered.count, 0)
    XCTAssertTrue(owner.resumeAfterVeto(quit))
    XCTAssertEqual(owner.phase, .open)
    XCTAssertEqual(backend.registered.count, 2)
    XCTAssertNil(result.consumer.summary(for: held.result))
    backend.submitFailure = .consumerBusy
    XCTAssertThrowsError(try pending.start()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .admission(.consumerBusy))
    }
    XCTAssertEqual(try backend.submission(0).consumer, try backend.registeredID(0))
    XCTAssertEqual(backend.submitCalls, 3)
    XCTAssertEqual(backend.joinCalls, 0)
  }

  // Catches stale veto replay and duplicate preparation effects.
  func testOldVetoTicketCannotReopenNewPreparation() throws {
    let f = try Fixture()
    _ = try f.start()
    let q1 = try f.owner.prepareQuit()
    XCTAssertTrue(f.owner.resumeAfterVeto(q1))
    let q2 = try f.owner.prepareQuit()
    XCTAssertNotEqual(q1, q2)
    XCTAssertFalse(f.owner.resumeAfterVeto(q1))
    XCTAssertEqual(f.owner.phase, .prepared(q2))
    XCTAssertEqual(try f.owner.prepareQuit(), q2)
    XCTAssertEqual(f.backend.cancelled.count, 1)
    XCTAssertEqual(f.backend.released.count, 0)
    XCTAssertTrue(f.owner.resumeAfterVeto(q2))
    let q3 = try f.owner.prepareQuit()
    guard case .admitted = f.owner.admitShutdownJoined(after: q3) else {
      XCTFail("Outside callback admission must issue a join ticket")
      return
    }
    XCTAssertEqual(f.owner.phase, .terminal)
    XCTAssertFalse(f.owner.resumeAfterVeto(q1))
    XCTAssertFalse(f.owner.resumeAfterVeto(q2))
    XCTAssertFalse(f.owner.resumeAfterVeto(q3))
    XCTAssertThrowsError(try f.owner.prepareQuit()) {
      XCTAssertEqual($0 as? ApplicationDocumentSearchFailure, .terminal)
    }
  }

  // Catches async-only/preflight admission, effectful callback reentry and caller-owned join cancellation.
  func testJoinRefusesSynchronousReentryAndRetainsSharedOwner() async throws {
    for seam in ["capture", "delivery", "select"] {
      let f = try Fixture()
      let events = EventLog()
      var entered = false
      let direct: @MainActor () -> Void = {
        guard !entered else {
          XCTFail("Unexpected second callback")
          return
        }
        entered = true
        events.add("entered")
        do {
          let q = try f.owner.prepareQuit()
          events.add("prepared")
          XCTAssertEqual(f.owner.phase, .prepared(q))
          XCTAssertEqual(f.backend.unregistered.count, 0)
          XCTAssertEqual(f.backend.joinCalls, 0)
          let decision = f.owner.admitShutdownJoined(after: q)
          XCTAssertEqual(decision, .callerRefused(.synchronousCallbackActive))
          events.add("admissionRefused")
          XCTAssertEqual(f.owner.phase, .prepared(q))
          XCTAssertEqual(f.backend.unregistered.count, 0)
          XCTAssertEqual(f.backend.joinCalls, 0)
          XCTAssertTrue(f.owner.resumeAfterVeto(q))
          XCTAssertEqual(f.owner.phase, .open)
          events.add("resumed")
        } catch { XCTFail("Reversible preparation failed: \(error)") }
      }
      switch seam {
      case "capture":
        _ = try f.start()
        f.state.onCapture = direct
        XCTAssertThrowsError(try f.backend.capture(0))
        let lateLease = f.backend.install(context: try credential(), replacement: nil)
        f.backend.deliver(0, .completed(lateLease))
        XCTAssertEqual(f.backend.released, [lateLease])
        XCTAssertEqual(f.deliveries.values.count, 0)
      case "delivery":
        f.deliveries.onDelivery = direct
        let held = try f.complete(replacement: nil)
        XCTAssertNil(f.consumer.summary(for: held.result))
      default:
        let held = try f.complete(replacement: nil)
        f.state.onSelect = direct
        XCTAssertFalse(f.consumer.navigate(result: held.result, matchIndex: 0))
        XCTAssertNil(f.consumer.summary(for: held.result))
      }
      events.add("callbackReturned")
      XCTAssertTrue(entered)
      XCTAssertEqual(
        events.values, ["entered", "prepared", "admissionRefused", "resumed", "callbackReturned"])
      XCTAssertEqual(f.backend.unregistered.count, 0)
      XCTAssertEqual(f.backend.joinCalls, 0)
      XCTAssertEqual(f.owner.phase, .open)
    }

    let backend = ScriptedBackend()
    backend.holdJoin = true
    defer { backend.releaseJoinHold() }
    var owner: ApplicationSearchOwner? = ApplicationSearchOwner(backend: backend)
    let weakOwner = WeakOwnerReference(owner)
    let state = try SourceState()
    var consumer: ApplicationDocumentSearchConsumer?
    let q: ApplicationSearchQuitID
    let join: ApplicationSearchJoinID
    do {
      guard let currentOwner = owner else {
        XCTFail("Explicit owner missing")
        return
      }
      let window = try currentOwner.attachWindow(
        windowID: literalID(0x0101), endpointID: literalID(0x0102))
      consumer = try currentOwner.attachDocument(
        window: window, source: state.source,
        onDelivery: { _ in XCTFail("No submitted work") })
      q = try currentOwner.prepareQuit()
      guard case .admitted(let ticket) = currentOwner.admitShutdownJoined(after: q) else {
        XCTFail("Outside callbacks must issue a ticket")
        return
      }
      join = ticket
      XCTAssertEqual(currentOwner.phase, .terminal)
      XCTAssertEqual(backend.unregistered, backend.registered)
      XCTAssertEqual(currentOwner.admitShutdownJoined(after: q), .admitted(join))
    }
    consumer = nil
    owner = nil
    // No observer or local strong owner alias yet: the installed terminal task owns the hold.
    for _ in 0..<64 { await Task.yield() }
    XCTAssertNotNil(weakOwner.value)
    XCTAssertEqual(backend.joinCalls, 1)
    guard let admittedOwner = weakOwner.value else {
      backend.releaseJoinHold()
      XCTFail("Owner vanished with its admitted join held")
      return
    }
    let first = Task { @MainActor in await admittedOwner.observeShutdownJoined(join) }
    let second = Task { @MainActor in await admittedOwner.observeShutdownJoined(join) }
    first.cancel()
    // Bounded scheduling opportunities, not a deadline or a sleep. Release is sticky for late entry.
    for _ in 0..<64 { await Task.yield() }
    XCTAssertNotNil(weakOwner.value)
    XCTAssertNil(consumer)
    XCTAssertEqual(backend.joinCalls, 1)
    backend.releaseJoinHold()
    let firstValue = await first.value
    let secondValue = await second.value
    XCTAssertEqual(firstValue, .observed(.callerRefused(.unsupportedDriver)))
    XCTAssertEqual(secondValue, .observed(.callerRefused(.unsupportedDriver)))
    XCTAssertFalse(backend.joinTaskWasCancelled)
    XCTAssertEqual(backend.joinCalls, 1)
    let other = ApplicationSearchOwner(backend: ScriptedBackend())
    let foreignQ = try other.prepareQuit()
    guard case .admitted(let foreignJoin) = other.admitShutdownJoined(after: foreignQ) else {
      XCTFail("Foreign finite owner failed admission")
      return
    }
    let foreignResult = await admittedOwner.observeShutdownJoined(foreignJoin)
    XCTAssertEqual(foreignResult, .callerRefused(.staleJoin))
    XCTAssertEqual(admittedOwner.admitShutdownJoined(after: foreignQ), .callerRefused(.staleQuit))
    XCTAssertEqual(backend.joinCalls, 1)
  }

  // Catches flattening raw terminal facts, reopening after refusal, or refresh on repeated admission.
  func testTerminalObservationPreservesResidualAndUncertainFacts() async throws {
    let generation = literalID(77)
    let parentPending = SearchParentJoinedShutdownResult.completed(
      SearchParentJoinedShutdownCompletion(
        shutdown: SearchParentWireShutdown(
          child: SearchChildShutdown(
            cleanup: .stopUnconfirmed(generation: generation), channelsClosed: false),
          parentLaneSettled: false, retainedParentLanes: 1),
        ownership: .refused(.observerPresent), laneStop: .failed))
    let parentSettled = SearchParentJoinedShutdownResult.completed(
      SearchParentJoinedShutdownCompletion(
        shutdown: SearchParentWireShutdown(
          child: SearchChildShutdown(
            cleanup: .noChild,
            channelsClosed: true), parentLaneSettled: true, retainedParentLanes: 0),
        ownership: .admitted, laneStop: .acknowledged))
    let rows: [SearchAdmissionJoinedShutdownResult] = [
      .callerRefused(.synchronousCallbackActive),
      .observed(
        SearchAdmissionJoinedShutdownObservation(
          parent: .callerRefused(.differentJoinOwner),
          driverSettlement: .pending, retainedActiveJobs: 1, retainedLeases: 2,
          activeCharge: 41, retainedCharge: 17, reservedRetainedCharge: 9)),
      .observed(
        SearchAdmissionJoinedShutdownObservation(
          parent: parentPending,
          driverSettlement: .pending, retainedActiveJobs: 2, retainedLeases: 3,
          activeCharge: 53, retainedCharge: 23, reservedRetainedCharge: 11)),
      .observed(
        SearchAdmissionJoinedShutdownObservation(
          parent: parentPending,
          driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0,
          retainedLeases: 1,
          activeCharge: 13, retainedCharge: 7, reservedRetainedCharge: 0)),
      .observed(
        SearchAdmissionJoinedShutdownObservation(
          parent: parentSettled,
          driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0,
          retainedLeases: 0,
          activeCharge: 13, retainedCharge: 0, reservedRetainedCharge: 0)),
    ]
    for row in rows {
      let backend = ScriptedBackend()
      backend.joinValues = [row]
      let owner = ApplicationSearchOwner(backend: backend)
      let q = try owner.prepareQuit()
      guard case .admitted(let j) = owner.admitShutdownJoined(after: q) else {
        XCTFail("Explicit terminal admission failed")
        continue
      }
      let value = await owner.observeShutdownJoined(j)
      XCTAssertEqual(value, .observed(row))
      XCTAssertEqual(owner.phase, .terminal)
      XCTAssertFalse(owner.resumeAfterVeto(q))
      XCTAssertEqual(owner.admitShutdownJoined(after: q), .admitted(j))
      XCTAssertEqual(backend.joinCalls, 1)
      XCTAssertEqual(backend.registered.count, 0)
      XCTAssertEqual(backend.cancelled.count, 0)
    }
    let backend = ScriptedBackend()
    backend.joinValues = [rows[2], rows[3]]
    let owner = ApplicationSearchOwner(backend: backend)
    let q = try owner.prepareQuit()
    guard case .admitted(let j) = owner.admitShutdownJoined(after: q) else {
      XCTFail("Refresh owner failed admission")
      return
    }
    let initial = await owner.observeShutdownJoined(j)
    XCTAssertEqual(initial, .observed(rows[2]))
    XCTAssertEqual(owner.admitShutdownJoined(after: q), .admitted(j))
    XCTAssertEqual(backend.joinCalls, 1)
    let refreshed = await owner.observeShutdownJoined(j)
    XCTAssertEqual(refreshed, .observed(rows[3]))
    XCTAssertEqual(backend.joinCalls, 2)
    XCTAssertEqual(owner.phase, .terminal)
    XCTAssertFalse(owner.resumeAfterVeto(q))
  }
}

private enum ClientFailure: Error { case guardFailure }

private func checked<Value>(_ values: [Value], at index: Int) throws -> Value {
  guard values.indices.contains(index) else {
    XCTFail("Expected effect was absent")
    throw ClientFailure.guardFailure
  }
  return values[index]
}

private func literalID(_ suffix: UInt16) -> UUID {
  UUID(
    uuid: (
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      UInt8(truncatingIfNeeded: suffix >> 8), UInt8(truncatingIfNeeded: suffix)
    ))
}

private func credential(
  revision: UInt64 = 7, window: UInt16 = 0x0101, endpoint: UInt16 = 0x0102,
  pane: UInt16 = 0x0104, ownership: UInt16 = 0x0105
) throws -> DocumentSearchCredential {
  try DocumentSearchCredential(
    windowID: literalID(window), endpointID: literalID(endpoint),
    documentID: literalID(0x0103), paneID: literalID(pane),
    ownershipGeneration: literalID(ownership),
    editRevision: revision, inputUTF16: 3)
}

@MainActor
private final class WeakOwnerReference {
  weak var value: ApplicationSearchOwner?
  init(_ value: ApplicationSearchOwner?) { self.value = value }
}

@MainActor
private final class EventLog {
  private(set) var values: [String] = []
  func add(_ value: String) {
    guard values.count < 128 else {
      XCTFail("Event history overflow")
      return
    }
    values.append(value)
  }
}

@MainActor
private final class DeliveryLog {
  private(set) var values: [ApplicationDocumentSearchDelivery] = []
  var onDelivery: (@MainActor () -> Void)?
  func receive(_ value: ApplicationDocumentSearchDelivery) {
    guard values.count < 4 else {
      XCTFail("Unexpected delivery overflow")
      return
    }
    values.append(value)
    let action = onDelivery
    onDelivery = nil
    action?()
  }
}

@MainActor
private final class SourceState {
  var credential: DocumentSearchCredential
  var text = "😀x"
  var available = true
  var paneAttached = true
  var saving = false
  var composition = false
  var admissionAllowed = true
  var sourceAvailable: Bool {
    available && paneAttached && !saving && !composition && admissionAllowed
  }
  var inspectCalls = 0
  var captureCalls = 0
  var currentCalls = 0
  var selectCalls = 0
  var replaceCalls = 0
  var selections: [(DocumentSearchCredential, String, NSRange)] = []
  var replacements: [(DocumentSearchCredential, String, String)] = []
  var onCurrent: (@MainActor () -> Void)?
  var onCapture: (@MainActor () -> Void)?
  var onSelect: (@MainActor () -> Void)?
  var source: EditorDocumentSearchSource {
    EditorDocumentSearchSource(
      inspect: { [self] in
        guard inspectCalls < 8 else {
          XCTFail("Inspect overflow")
          throw ClientFailure.guardFailure
        }
        inspectCalls += 1
        guard sourceAvailable else { throw ApplicationDocumentSearchFailure.sourceUnavailable }
        return credential
      },
      capture: { [self] expected in
        guard captureCalls < 4 else {
          XCTFail("Capture overflow")
          throw ClientFailure.guardFailure
        }
        captureCalls += 1
        guard sourceAvailable, credential == expected else {
          throw ApplicationDocumentSearchFailure.staleSource
        }
        let action = onCapture
        onCapture = nil
        action?()
        guard sourceAvailable, credential == expected else {
          throw ApplicationDocumentSearchFailure.staleSource
        }
        return SearchAdmissionCapture(text: text, inputUTF16: 3, context: credential)
      },
      isCurrent: { [self] expected in
        guard currentCalls < 32 else {
          XCTFail("Current check overflow")
          return false
        }
        currentCalls += 1
        let action = onCurrent
        onCurrent = nil
        action?()
        return sourceAvailable && credential == expected
      },
      select: { [self] expected, original, range in
        guard selectCalls < 4 else {
          XCTFail("Select overflow")
          return false
        }
        selectCalls += 1
        guard sourceAvailable, credential == expected, original == text else { return false }
        let action = onSelect
        onSelect = nil
        action?()
        guard sourceAvailable, credential == expected, original == text else { return false }
        selections.append((expected, original, range))
        return true
      },
      replace: { [self] expected, original, replacement in
        guard replaceCalls < 4 else {
          XCTFail("Replace overflow")
          return false
        }
        replaceCalls += 1
        guard sourceAvailable, credential == expected, original == text else { return false }
        replacements.append((expected, original, replacement))
        return true
      })
  }
  init(window: UInt16 = 0x0101, endpoint: UInt16 = 0x0102) throws {
    credential = try applicationSearchOwnerTestsCredential(window: window, endpoint: endpoint)
  }
  func change(_ row: String) throws {
    switch row {
    case "endpoint": credential = try applicationSearchOwnerTestsCredential(endpoint: 0x0202)
    case "ownership": credential = try applicationSearchOwnerTestsCredential(ownership: 0x0205)
    case "pane": credential = try applicationSearchOwnerTestsCredential(pane: 0x0204)
    case "detached": paneAttached = false
    case "saving": saving = true
    case "composition": composition = true
    case "admission": admissionAllowed = false
    default:
      XCTFail("Unknown literal source row")
      available = false
    }
  }
}

// Avoids resolving the helper name against SourceState.credential's stored property.
private func applicationSearchOwnerTestsCredential(
  window: UInt16 = 0x0101, endpoint: UInt16 = 0x0102,
  pane: UInt16 = 0x0104, ownership: UInt16 = 0x0105
) throws -> DocumentSearchCredential {
  try credential(window: window, endpoint: endpoint, pane: pane, ownership: ownership)
}

@MainActor
private final class ScriptedBackend: ApplicationSearchBackend {
  struct Submission {
    let consumer: SearchConsumerID
    let job: SearchJobID
    let descriptor: SearchAdmissionDescriptor
    let capture: @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>
    let completion: @MainActor (SearchAdmissionDelivery) -> Void
    var captured = false
    var delivered = false
  }
  struct Payload {
    let credential: DocumentSearchCredential
    let source: String
    let output: SearchExecutionOutput
  }
  private let fallbackConsumer = SearchConsumerID()
  private let fallbackJob = SearchJobID()
  private let fallbackLease = SearchResultLeaseID()
  private(set) var registered: [SearchConsumerID] = []
  private(set) var unregistered: [SearchConsumerID] = []
  private(set) var cancelled: [SearchJobID] = []
  private(set) var released: [SearchResultLeaseID] = []
  private(set) var submissions: [Submission] = []
  private(set) var captures: [SearchAdmissionCapture<DocumentSearchCredential>] = []
  private var payloads: [SearchResultLeaseID: Payload] = [:]
  var submitFailure: SearchAdmissionFailure?
  var onSubmitAttempt: (@MainActor () -> Void)?
  var onSubmit: (@MainActor (Int) -> Void)?
  var onCancel: (@MainActor (SearchJobID) -> Void)?
  var onRelease: (@MainActor (SearchResultLeaseID) -> Void)?
  var onUnregister: (@MainActor (SearchConsumerID) -> Void)?
  private(set) var submitCalls = 0
  private(set) var borrowCalls = 0
  private(set) var borrowDepth = 0
  private(set) var borrowedSource: String?
  private(set) var joinCalls = 0
  private(set) var joinTaskWasCancelled = false
  var joinValues: [SearchAdmissionJoinedShutdownResult] = [.callerRefused(.unsupportedDriver)]
  var holdJoin = false
  private var holdReleased = false
  private var joinContinuation: CheckedContinuation<Void, Never>?

  func registeredID(_ index: Int) throws -> SearchConsumerID { try checked(registered, at: index) }
  func submission(_ index: Int) throws -> Submission { try checked(submissions, at: index) }

  func register() -> SearchConsumerID {
    guard registered.count < 34 else {
      XCTFail("Register overflow")
      return fallbackConsumer
    }
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    guard submitCalls < 4 else {
      XCTFail("Submit overflow")
      throw SearchAdmissionFailure.internalFailure
    }
    submitCalls += 1
    let attempted = onSubmitAttempt
    onSubmitAttempt = nil
    attempted?()
    if let submitFailure { throw submitFailure }
    guard submissions.count < 4 else {
      XCTFail("Submission storage overflow")
      return fallbackJob
    }
    let id = SearchJobID()
    submissions.append(
      Submission(
        consumer: consumer, job: id, descriptor: descriptor,
        capture: capture, completion: completion))
    let callback = onSubmit
    onSubmit = nil
    callback?(submissions.count - 1)
    // Completion is NEVER invoked here. All deliveries are explicitly after this return.
    return id
  }
  func cancel(_ id: SearchJobID) {
    guard cancelled.count < 4, !cancelled.contains(id) else {
      XCTFail("Duplicate/excess cancel")
      return
    }
    cancelled.append(id)
    let action = onCancel
    onCancel = nil
    action?(id)
  }
  func unregister(_ consumer: SearchConsumerID) {
    guard unregistered.count < 34, !unregistered.contains(consumer) else {
      XCTFail("Duplicate/excess unregister")
      return
    }
    unregistered.append(consumer)
    let action = onUnregister
    onUnregister = nil
    action?(consumer)
  }
  func release(_ id: SearchResultLeaseID) {
    guard released.count < 4, !released.contains(id) else {
      XCTFail("Duplicate/excess release")
      return
    }
    released.append(id)
    payloads.removeValue(forKey: id)
    let action = onRelease
    onRelease = nil
    action?(id)
  }
  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    guard borrowCalls < 16, borrowDepth == 0 else {
      XCTFail("Borrow overflow/reentry")
      return false
    }
    borrowCalls += 1
    guard let payload = payloads[id] else { return false }
    borrowDepth = 1
    borrowedSource = payload.source
    body(payload.credential, payload.source, payload.output)
    borrowedSource = nil
    borrowDepth = 0
    return true
  }
  func capture(_ index: Int) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    guard submissions.indices.contains(index), !submissions[index].captured else {
      XCTFail("Unexpected second/missing capture")
      throw ClientFailure.guardFailure
    }
    submissions[index].captured = true
    let callback = submissions[index].capture
    let value = try callback()
    guard captures.count < 4 else {
      XCTFail("Capture result overflow")
      throw ClientFailure.guardFailure
    }
    captures.append(value)
    return value
  }
  func install(context: DocumentSearchCredential, replacement: String?) -> SearchResultLeaseID {
    guard payloads.count < 4 else {
      XCTFail("Payload storage overflow")
      return fallbackLease
    }
    let id = SearchResultLeaseID()
    payloads[id] = Payload(
      credential: context, source: "😀x",
      output: SearchExecutionOutput(
        matches: [NSRange(location: 2, length: 1)], replacement: replacement))
    return id
  }
  func invalidate(_ id: SearchResultLeaseID) { payloads.removeValue(forKey: id) }
  func deliver(_ index: Int, _ delivery: SearchAdmissionDelivery) {
    guard submissions.indices.contains(index), !submissions[index].delivered else {
      XCTFail("Unexpected second/missing completion")
      return
    }
    submissions[index].delivered = true
    let callback = submissions[index].completion
    callback(delivery)
  }
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    guard joinCalls < 2, joinCalls < joinValues.count else {
      XCTFail("Unexpected join/refresh")
      return .callerRefused(.unsupportedDriver)
    }
    let index = joinCalls
    joinCalls += 1
    if holdJoin && !holdReleased {
      await withCheckedContinuation { continuation in
        guard joinContinuation == nil else {
          XCTFail("Second held join callback")
          continuation.resume()
          return
        }
        joinContinuation = continuation
      }
    }
    joinTaskWasCancelled = Task.isCancelled
    return joinValues[index]
  }
  func releaseJoinHold() {
    holdReleased = true
    let continuation = joinContinuation
    joinContinuation = nil
    continuation?.resume()
  }
}

@MainActor
private final class Fixture {
  let backend: ScriptedBackend
  let owner: ApplicationSearchOwner
  let state: SourceState
  let deliveries: DeliveryLog
  let window: ApplicationSearchWindowID
  let consumer: ApplicationDocumentSearchConsumer
  let limits: SearchWireLimits
  init(
    backend: ScriptedBackend? = nil, owner: ApplicationSearchOwner? = nil,
    windowNumber: UInt16 = 0x0101, endpointNumber: UInt16 = 0x0102
  ) throws {
    let actualBackend = backend ?? ScriptedBackend()
    let actualOwner = owner ?? ApplicationSearchOwner(backend: actualBackend)
    self.backend = actualBackend
    self.owner = actualOwner
    state = try SourceState(window: windowNumber, endpoint: endpointNumber)
    deliveries = DeliveryLog()
    let sink = deliveries
    window = try actualOwner.attachWindow(
      windowID: literalID(windowNumber), endpointID: literalID(endpointNumber))
    consumer = try actualOwner.attachDocument(
      window: window, source: state.source,
      onDelivery: { value in sink.receive(value) })
    limits = try SearchWireLimits(
      maxTextUTF16: 3, maxOutputUTF16: 3, maxMatches: 2,
      cooperativeMilliseconds: 100)
  }
  func start(replacement: String? = nil) throws -> ApplicationDocumentSearchRequestID {
    let operation: SearchExecutionOperation
    if let replacement { operation = .replace(template: replacement) } else { operation = .find }
    return try consumer.start(
      query: SearchQuery(
        pattern: "x", mode: .literal,
        caseSensitive: true, wholeWord: false), operation: operation, scope: nil, limits: limits)
  }
  func complete(replacement: String?) throws -> (
    result: ApplicationDocumentSearchResultID, lease: SearchResultLeaseID
  ) {
    let request = try start(replacement: replacement == nil ? nil : "y")
    let index = backend.submissions.count - 1
    let value = try backend.capture(index)
    let lease = backend.install(context: value.context, replacement: replacement)
    backend.deliver(index, .completed(lease))
    guard let last = deliveries.values.last,
      case .completed(let deliveredRequest, let result, let summary) = last
    else {
      XCTFail("Real owner did not produce a completed delivery")
      throw ClientFailure.guardFailure
    }
    XCTAssertEqual(deliveredRequest, request)
    XCTAssertEqual(
      summary, DocumentSearchSummary(matchCount: 1, hasReplacement: replacement != nil))
    return (result, lease)
  }
}
