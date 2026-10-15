// Owner-only test-first candidate. Baseline refusals are ordinary failures, not coverage.
import Foundation
import XCTest

@testable import NativeLanguageCatalogComponent
@testable import PadCore

@MainActor final class NativeLanguageCatalogMutationTests: XCTestCase {
  func testDraftRejectsDuplicateIdentityWithoutStoringAuthority() throws {
    let definition = try CatalogTestFixture.definition()
    XCTAssertThrowsError(
      try NativeLanguageCatalogDraft(definitions: [definition, definition], overrides: []))
    let draft = try NativeLanguageCatalogDraft(definitions: [definition], overrides: [])
    XCTAssertEqual(draft.definitions, [definition])
    XCTAssertTrue(draft.overrides.isEmpty)
  }

  func testStoreInitializationIsLazyAndInitialCapabilitiesAreTruthful() async throws {
    try await withMutation { h in
      XCTAssertTrue(h.control.calls.isEmpty)
      XCTAssertNil(h.owner.mutationState.activeOperation)
      XCTAssertNil(h.owner.mutationState.lastGoodDisplay)
      XCTAssertNil(h.owner.mutationState.writeReceiptPublicationID)
      XCTAssertTrue(h.owner.mutationState.canInspect)
      XCTAssertTrue(h.owner.mutationState.canPrepareQuit)
      XCTAssertFalse(h.owner.mutationState.canApply)
    }
  }

  func testReadOnlyInitializerLoadsButAllStoreRequestsRefuseWithoutCalls() async throws {
    try await withMutation(readOnly: true) { h in
      let draft = try h.draft()
      let absent = UUID()
      let requests = [
        h.owner.requestApply(draft, expectedPublication: .none),
        h.owner.requestInspect(expectedPublication: .none),
        h.owner.requestRepair(draft, inspection: absent, expectedPublication: .none),
        h.owner.requestVerifyPending(absent), h.owner.requestRetryPending(absent),
        h.owner.requestRetryFailedAttempt(absent),
        h.owner.requestDiscardAndReload(.pending(absent), confirmation: .discardAttemptAndReload),
      ]
      for value in requests {
        refused(value) {
          if case .servicesUnavailable = $0 { return true }
          return false
        }
      }
      XCTAssertTrue(h.control.calls.isEmpty)
      XCTAssertEqual(h.notifications, 0)
      guard await loaded(h) else { return }
      XCTAssertFalse(h.owner.mutationState.canApply)
      XCTAssertFalse(h.owner.mutationState.canInspect)
      XCTAssertFalse(h.owner.mutationState.canRepair)
      XCTAssertFalse(h.owner.mutationState.canVerifyPending)
      XCTAssertFalse(h.owner.mutationState.canRetryPending)
      XCTAssertFalse(h.owner.mutationState.canRetryFailedAttempt)
      XCTAssertFalse(h.owner.mutationState.canDiscardAndReload)
    }
  }

  func testReadOnlyGlobalBusyAndInvalidatedPrecedeServicesUnavailable() async throws {
    try await withMutation(readOnly: true) { h in
      let gate = h.control.hold(.read)
      guard case .started(let id) = h.owner.requestLoad() else {
        return XCTFail("Legacy read must start")
      }
      await fulfillment(of: [gate.entered], timeout: 4)
      refused(h.owner.requestInspect(expectedPublication: .none)) {
        if case .busy(let active) = $0 { return active == id }
        return false
      }
      XCTAssertEqual(h.control.count(.read), 1)
      h.owner.invalidate()
      gate.release()
      await h.owner.invalidateAndWait()
      refused(h.owner.requestInspect(expectedPublication: .none)) {
        if case .invalidated = $0 { return true }
        return false
      }
    }
  }

  func testReadOnlyQuitReservationRepeatedPrepareAndExactCancellation() async throws {
    try await withMutation(readOnly: true) { h in
      guard let id = prepared(h.owner.prepareQuit()) else { return }
      let count = h.notifications
      if case .refused(.quitPrepared(let same)) = h.owner.prepareQuit() {
        XCTAssertEqual(same, id)
      } else {
        XCTFail("Repeated preparation must retain the same reservation")
      }
      if case .quitPrepared(let same) = h.owner.requestLoad() {
        XCTAssertEqual(same, id)
      } else {
        XCTFail("Read must report the real quit ID")
      }
      refused(h.owner.requestInspect(expectedPublication: .none)) {
        if case .quitPrepared(let same) = $0 { return same == id }
        return false
      }
      XCTAssertEqual(h.notifications, count)
      XCTAssertTrue(h.control.calls.isEmpty)
      XCTAssertFalse(h.owner.cancelPreparedQuit(UUID()))
      XCTAssertTrue(h.owner.cancelPreparedQuit(id))
      XCTAssertNil(h.owner.mutationState.preparedQuitID)
      guard await loaded(h) else { return }
    }
  }

  func testQuitCallbackCancellationCannotClobberItsSuccessorReservation() async throws {
    try await withMutation { h in
      var handling = false
      var original: UUID? = nil
      var successor: UUID? = nil
      h.action = { _ in
        guard !handling, let id = h.owner.mutationState.preparedQuitID else { return }
        handling = true
        original = id
        XCTAssertTrue(h.owner.cancelPreparedQuit(id))
        successor = self.prepared(h.owner.prepareQuit())
      }
      let result = h.owner.prepareQuit()
      guard case .refused(.reservationWithdrawn) = result else {
        return XCTFail("Old frame must report withdrawal")
      }
      XCTAssertNotNil(original)
      XCTAssertNotNil(successor)
      guard let original, let successor else { return }
      XCTAssertNotEqual(original, successor)
      XCTAssertEqual(h.owner.mutationState.preparedQuitID, successor)
      XCTAssertFalse(h.owner.cancelPreparedQuit(original))
      XCTAssertEqual(h.owner.mutationState.preparedQuitID, successor)
    }
  }

  func testQuitPreparationObserverInvalidationReturnsInvalidated() async throws {
    try await withMutation { h in
      h.action = { _ in if h.owner.mutationState.preparedQuitID != nil { h.owner.invalidate() } }
      if case .refused(.invalidated) = h.owner.prepareQuit() {
      } else {
        XCTFail("No stale prepared token after invalidation")
      }
      XCTAssertTrue(h.control.calls.isEmpty)
    }
  }

  func testLegacyLoadingObserverCannotReserveQuitOverActualRead() async throws {
    try await withMutation { h in
      var seen = false
      h.action = { state in
        guard let id = state.activeRequestID else { return }
        seen = true
        if case .refused(.busy(let active)) = h.owner.prepareQuit() {
          XCTAssertEqual(active, id)
        } else {
          XCTFail("Actual active read takes precedence over quit")
        }
      }
      guard await loaded(h) else { return }
      XCTAssertTrue(seen)
      XCTAssertNil(h.owner.mutationState.preparedQuitID)
    }
  }

  func testMutationLoadingCallbackSeesOneSharedBusyIDBeforeStoreLaunch() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      let gate = h.control.hold(.save)
      var callbackID: UUID?
      h.action = { state in
        guard let id = state.activeRequestID else { return }
        callbackID = id
        XCTAssertEqual(h.owner.mutationState.activeOperation?.id, id)
        XCTAssertEqual(h.control.count(.save), 0)
        if case .busy(let busy) = h.owner.requestLoad() {
          XCTAssertEqual(busy, id)
        } else {
          XCTFail("Legacy read reentry must report the actual mutation ID")
        }
        self.refused(h.owner.requestInspect(expectedPublication: h.expectation)) {
          if case .busy(let busy) = $0 { return busy == id }
          return false
        }
        if case .refused(.busy(let busy)) = h.owner.prepareQuit() {
          XCTAssertEqual(busy, id)
        } else {
          XCTFail("Quit cannot cross actual admission")
        }
      }
      guard
        let id = admitted(h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
      else { return }
      XCTAssertEqual(callbackID, id)
      await fulfillment(of: [gate.entered], timeout: 4)
      XCTAssertEqual(h.owner.state.activeRequestID, id)
      XCTAssertEqual(h.control.count(.save), 1)
      gate.release()
      await settled(h, id)
      XCTAssertEqual(h.owner.state.lastSettledRequestID, id)
      XCTAssertEqual(h.control.maximum, 1)
      XCTAssertTrue(h.control.calls.allSatisfy { !$0.onMain })
    }
  }

  func testMutationLoadingInvalidationRetainsUnlaunchedIntentWithoutStoreCall() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      var operation: UUID?
      h.action = { state in
        if let id = state.activeRequestID {
          operation = id
          h.owner.invalidate()
        }
      }
      refused(h.owner.requestApply(try h.draft(), expectedPublication: h.expectation)) {
        if case .invalidatedDuringAdmission = $0 { return true }
        return false
      }
      XCTAssertEqual(h.control.count(.save), 0)
      XCTAssertNotNil(operation)
      XCTAssertNotNil(h.owner.mutationState.invalidationCustody)
      guard let custody = h.owner.mutationState.invalidationCustody else { return }
      XCTAssertEqual(custody.operationID, operation)
      XCTAssertNotNil(custody.attemptID)
      if case .notLaunched = custody.outcome {} else { XCTFail("No fake failed Store result") }
    }
  }

  func testDefaultStoreApplyUsesActualGenerationAndRevisionAssignments() async throws {
    try await withMutation(defaultStore: true) { h in
      guard await loaded(h) else { return }
      let draft = try h.draft()
      guard let id = admitted(h.owner.requestApply(draft, expectedPublication: h.expectation))
      else { return }
      await settled(h, id)
      try await assertCanonical(h)
      let first = try await h.fresh()
      XCTAssertEqual(first.snapshot.generation, 8)
      XCTAssertEqual(CatalogTestFixture.profile(first.snapshot).definitionRevision, 4)
      guard let next = admitted(h.owner.requestApply(draft, expectedPublication: h.expectation))
      else { return }
      await settled(h, next)
      let unchanged = try await h.fresh()
      XCTAssertEqual(unchanged.snapshot.generation, 9)
      XCTAssertEqual(CatalogTestFixture.profile(unchanged.snapshot).definitionRevision, 4)
      XCTAssertNil(h.owner.mutationState.unresolved)
      XCTAssertEqual(h.owner.mutationState.writeReceiptPublicationID, h.owner.state.current?.id)
    }
  }

  func testWrongPublicationAndNoReceiptRefuseBeforeStoreCalls() async throws {
    try await withMutation { h in
      let draft = try h.draft()
      refused(h.owner.requestApply(draft, expectedPublication: .none)) {
        if case .noWriteReceipt = $0 { return true }
        return false
      }
      XCTAssertTrue(h.control.calls.isEmpty)
      guard await loaded(h) else { return }
      let before = h.control.calls.count
      let bytes = try h.bytes()
      for expectation in [CatalogPublicationExpectation.none, .current(UUID())] {
        refused(h.owner.requestApply(draft, expectedPublication: expectation)) {
          if case .wrongPublication = $0 { return true }
          return false
        }
        refused(h.owner.requestInspect(expectedPublication: expectation)) {
          if case .wrongPublication = $0 { return true }
          return false
        }
      }
      refused(h.owner.requestRepair(draft, inspection: UUID(), expectedPublication: h.expectation))
      {
        if case .wrongInspection = $0 { return true }
        return false
      }
      XCTAssertEqual(h.control.calls.count, before)
      XCTAssertEqual(try h.bytes(), bytes)
    }
  }

  func testInitialFailedLoadCanInspectNoneAndRepairActualCorruption() async throws {
    try await withMutation { h in
      try h.install(CatalogTestFixture.changed(#""generation":7"#, #""generation":0"#))
      guard case .started(let load) = h.owner.requestLoad() else {
        return XCTFail("Read admission")
      }
      await settled(h, load)
      XCTAssertNil(h.owner.state.current)
      XCTAssertNotNil(h.owner.state.failure)
      guard let inspect = admitted(h.owner.requestInspect(expectedPublication: .none)) else {
        return
      }
      await settled(h, inspect)
      assertNoReceiptSuccess(h, id: inspect)
      guard case .corrupt(let token, _) = h.owner.mutationState.inspection else {
        return XCTFail("Real known corruption token")
      }
      XCTAssertNil(h.owner.state.current)
      XCTAssertNil(h.owner.state.failure)
      refused(h.owner.requestRepair(try h.draft(), inspection: UUID(), expectedPublication: .none))
      {
        if case .wrongInspection = $0 { return true }
        return false
      }
      guard
        let repair = admitted(
          h.owner.requestRepair(try h.draft(), inspection: token, expectedPublication: .none))
      else { return }
      await settled(h, repair)
      try await assertCanonical(h)
      let fresh = try await h.fresh()
      XCTAssertEqual(fresh.snapshot.generation, 1)
      XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 1)
      XCTAssertEqual(h.control.count(.repair), 1)
    }
  }

  func testLoadedInspectionReturnsGenuineFreshPublication() async throws {
    try await withMutation { h in
      guard let first = admitted(h.owner.requestInspect(expectedPublication: .none)) else { return }
      await settled(h, first)
      try await assertCanonical(h)
      let previous = h.owner.state.current?.id
      XCTAssertNotNil(previous)
      guard let second = admitted(h.owner.requestInspect(expectedPublication: h.expectation)) else {
        return
      }
      await settled(h, second)
      try await assertCanonical(h)
      XCTAssertNotEqual(h.owner.state.current?.id, previous)
      XCTAssertEqual(h.owner.state.current?.requestID, second)
      XCTAssertEqual(h.owner.mutationState.writeReceiptPublicationID, h.owner.state.current?.id)
    }
  }

  func testCorruptAndUnsupportedInspectionPreserveDisplayAndClearOnlyWriteAuthority() async throws {
    for unsupported in [false, true] {
      try await withMutation { h in
        guard await loaded(h) else { return }
        let before = h.owner.state.current?.id
        try h.install(
          unsupported
            ? CatalogTestFixture.changed(#""version":1"#, #""version":99"#)
            : CatalogTestFixture.changed(#""generation":7"#, #""generation":0"#))
        let disk = try h.bytes()
        guard let id = admitted(h.owner.requestInspect(expectedPublication: h.expectation)) else {
          return
        }
        await settled(h, id)
        assertNoReceiptSuccess(h, id: id)
        XCTAssertEqual(h.owner.state.current?.id, before)
        XCTAssertEqual(h.owner.mutationState.lastGoodDisplay?.publicationID, before)
        XCTAssertNil(h.owner.state.failure)
        XCTAssertNil(h.owner.mutationState.writeReceiptPublicationID)
        XCTAssertFalse(h.owner.mutationState.canApply)
        if unsupported {
          if case .unsupported = h.owner.mutationState.inspection {
          } else {
            XCTFail("Unsupported must stay non-write")
          }
          XCTAssertFalse(h.owner.mutationState.canRepair)
        } else {
          if case .corrupt = h.owner.mutationState.inspection {
          } else {
            XCTFail("Known corruption must retain token")
          }
          XCTAssertTrue(h.owner.mutationState.canRepair)
        }
        XCTAssertEqual(try h.bytes(), disk)
        guard prepared(h.owner.prepareQuit()) != nil else { return }
      }
    }
  }

  func testThrownInspectionPreservesPriorReceiptAndActualFailure() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      let current = h.owner.state.current?.id
      h.control.failReads(true)
      guard let id = admitted(h.owner.requestInspect(expectedPublication: h.expectation)) else {
        return
      }
      await settled(h, id)
      XCTAssertEqual(h.owner.state.current?.id, current)
      XCTAssertEqual(h.owner.mutationState.writeReceiptPublicationID, current)
      XCTAssertEqual(h.owner.state.failure?.requestID, id)
      XCTAssertEqual(
        h.owner.state.failure?.underlyingError as? MutationFixtureError, .selectedReadFailure)
      XCTAssertEqual(h.control.count(.inspect), 1)
    }
  }

  func testFailedApplyRetainsOriginalDraftAndRetriesOnlyThatIntent() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      let disk = try h.bytes()
      let draft = try h.draft("Exact original attempt")
      h.control.mode(.prepublication)
      guard let failed = admitted(h.owner.requestApply(draft, expectedPublication: h.expectation))
      else { return }
      await settled(h, failed)
      guard let attemptID = attempt(h) else { return }
      if case .injectedFailure? = h.control.error as? FileStoreError {
      } else {
        XCTFail("Actual selected Atomic prepublication hook")
      }
      XCTAssertEqual(try h.bytes(), disk)
      XCTAssertTrue(h.owner.mutationState.canRetryFailedAttempt)
      refused(
        h.owner.requestApply(try h.draft("Different draft"), expectedPublication: h.expectation)
      ) {
        if case .unresolvedAttempt(let id) = $0 { return id == attemptID }
        return false
      }
      if case .refused(.unresolvedAttempt(let id)) = h.owner.prepareQuit() {
        XCTAssertEqual(id, attemptID)
      } else {
        XCTFail("Unsubmitted failed intent vetoes owner quit")
      }
      refused(h.owner.requestRetryFailedAttempt(UUID())) {
        if case .wrongAttempt = $0 { return true }
        return false
      }
      h.control.mode(.clean)
      guard let retry = admitted(h.owner.requestRetryFailedAttempt(attemptID)) else { return }
      await settled(h, retry)
      try await assertCanonical(h)
      XCTAssertNil(h.owner.mutationState.unresolved)
      XCTAssertEqual(
        h.control.savedCandidates.map { $0.definitions.first?.name },
        ["Exact original attempt", "Exact original attempt"])
      XCTAssertEqual(h.control.savedCandidates.map(\.generation), [7, 7])
      let fresh = try await h.fresh()
      XCTAssertEqual(fresh.snapshot.generation, 8)
    }
  }

  func testFailedRepairRetainsExactTokenIntentAndRetriesRealRepair() async throws {
    try await withMutation { h in
      try h.install(CatalogTestFixture.changed(#""generation":7"#, #""generation":0"#))
      guard let inspect = admitted(h.owner.requestInspect(expectedPublication: .none)) else {
        return
      }
      await settled(h, inspect)
      guard case .corrupt(let token, _) = h.owner.mutationState.inspection else {
        return XCTFail("Actual corrupt token")
      }
      h.control.mode(.prepublication)
      guard
        let repair = admitted(
          h.owner.requestRepair(
            try h.draft("Retained repair"), inspection: token, expectedPublication: .none))
      else { return }
      await settled(h, repair)
      guard let attemptID = attempt(h) else { return }
      if case .failedAttempt(_, .repair, _)? = h.owner.mutationState.unresolved {
      } else {
        XCTFail("Repair intent kind")
      }
      h.control.mode(.clean)
      guard let retry = admitted(h.owner.requestRetryFailedAttempt(attemptID)) else { return }
      await settled(h, retry)
      let fresh = try await h.fresh()
      XCTAssertEqual(fresh.snapshot.generation, 1)
      XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Retained repair")
      XCTAssertEqual(h.control.count(.repair), 2)
      XCTAssertNil(h.owner.mutationState.unresolved)
    }
  }

  func testOrdinaryLoadMakesFailedAttemptAuthorityStaleWithoutDiscardingIt() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      h.control.mode(.prepublication)
      guard
        let failed = admitted(
          h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
      else { return }
      await settled(h, failed)
      guard let attemptID = attempt(h) else { return }
      h.control.mode(.clean)
      guard await loaded(h) else { return }
      XCTAssertEqual(attempt(h), attemptID)
      XCTAssertFalse(h.owner.mutationState.canRetryFailedAttempt)
      let calls = h.control.calls.count
      refused(h.owner.requestRetryFailedAttempt(attemptID)) {
        if case .notRetryableFailedAttempt = $0 { return true }
        return false
      }
      XCTAssertEqual(h.control.calls.count, calls)
      guard
        let discard = admitted(
          h.owner.requestDiscardAndReload(
            .attempt(attemptID), confirmation: .discardAttemptAndReload))
      else { return }
      await settled(h, discard)
      XCTAssertNil(h.owner.mutationState.unresolved)
      XCTAssertTrue(h.owner.mutationState.canApply)
    }
  }

  func testRealPendingVerificationVoidSuccessAndFailureNeverRenewAuthority() async throws {
    try await withMutation { h in
      guard let pendingID = try await makePending(h) else { return }
      let publication = h.owner.state.current?.id
      let write = h.owner.mutationState.writeReceiptPublicationID
      let bytes = try h.bytes()
      guard let actual = h.control.error as? CustomLanguagePublicationUncertain else {
        return XCTFail("Real Store evidence")
      }
      XCTAssertEqual(actual.attemptedBytes, bytes)
      XCTAssertEqual(actual.evidence.destination, h.capsule.file)
      h.control.mode(.clean)
      guard let verify = admitted(h.owner.requestVerifyPending(pendingID.recovery)) else { return }
      await settled(h, verify)
      assertNoReceiptSuccess(h, id: verify)
      XCTAssertEqual(h.owner.state.current?.id, publication)
      XCTAssertEqual(h.owner.mutationState.writeReceiptPublicationID, write)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      XCTAssertFalse(h.owner.mutationState.canApply)
      XCTAssertFalse(h.owner.mutationState.canPrepareQuit)
      h.control.failReads(true)
      guard let failure = admitted(h.owner.requestVerifyPending(pendingID.recovery)) else { return }
      await settled(h, failure)
      XCTAssertEqual(h.owner.state.failure?.requestID, failure)
      XCTAssertEqual(
        h.owner.state.failure?.underlyingError as? MutationFixtureError, .selectedReadFailure)
      XCTAssertEqual(pending(h)?.attempt, pendingID.attempt)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      XCTAssertEqual(h.owner.state.current?.id, publication)
      XCTAssertEqual(try h.bytes(), bytes)
      XCTAssertEqual(h.control.count(.verify), 2)
    }
  }

  func testPendingRetryPublishesExactOriginalWireWithoutAnotherGenerationEdit() async throws {
    try await withMutation { h in
      guard let pendingID = try await makePending(h) else { return }
      let wire = try h.bytes()
      let oldPublication = h.owner.state.current?.id
      let calls = h.control.calls.count
      refused(h.owner.requestRetryPending(UUID())) {
        if case .wrongRecovery = $0 { return true }
        return false
      }
      XCTAssertEqual(h.control.calls.count, calls)
      h.control.mode(.clean)
      guard let retry = admitted(h.owner.requestRetryPending(pendingID.recovery)) else { return }
      await settled(h, retry)
      try await assertCanonical(h)
      XCTAssertEqual(try h.bytes(), wire)
      let fresh = try await h.fresh()
      XCTAssertEqual(fresh.snapshot.generation, 8)
      XCTAssertEqual(CatalogTestFixture.profile(fresh.snapshot).definitionRevision, 4)
      XCTAssertNotEqual(h.owner.state.current?.id, oldPublication)
      XCTAssertNil(h.owner.mutationState.unresolved)
      XCTAssertEqual(h.control.count(.save), 1)
      XCTAssertEqual(h.control.count(.retry), 1)
    }
  }

  func testPendingRetryPlainFailurePreservesExactIDsAndUsableEvidence() async throws {
    try await withMutation { h in
      guard let pendingID = try await makePending(h) else { return }
      let wire = try h.bytes()
      h.control.mode(.prepublication)
      guard let retry = admitted(h.owner.requestRetryPending(pendingID.recovery)) else { return }
      await settled(h, retry)
      XCTAssertEqual(pending(h)?.attempt, pendingID.attempt)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      XCTAssertEqual(try h.bytes(), wire)
      h.control.mode(.clean)
      guard let verify = admitted(h.owner.requestVerifyPending(pendingID.recovery)) else { return }
      await settled(h, verify)
      assertNoReceiptSuccess(h, id: verify)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      XCTAssertNil(h.owner.state.failure)
    }
  }

  func testPendingRetryNewTypedOutcomesRotateOnlyRecoveryID() async throws {
    for readback in [false, true] {
      try await withMutation { h in
        guard let previous = try await makePending(h) else { return }
        let wire = try h.bytes()
        h.control.mode(readback ? .unconfirmed : .uncertain)
        guard let retry = admitted(h.owner.requestRetryPending(previous.recovery)) else { return }
        await settled(h, retry)
        guard let next = pending(h, readback: readback) else { return }
        XCTAssertEqual(next.attempt, previous.attempt)
        XCTAssertNotEqual(next.recovery, previous.recovery)
        XCTAssertEqual(try h.bytes(), wire)
        XCTAssertEqual(h.control.count(.retry), 1)
        XCTAssertTrue(
          readback
            ? h.control.error is CustomLanguageReadbackUnconfirmed
            : h.control.error is CustomLanguagePublicationUncertain)
      }
    }
  }

  func testReadbackUnconfirmedHasNoVerifyOrRetryAndOrdinaryLoadCannotResolveIt() async throws {
    try await withMutation { h in
      guard let pendingID = try await makePending(h, readback: true) else { return }
      XCTAssertFalse(h.owner.mutationState.canVerifyPending)
      XCTAssertFalse(h.owner.mutationState.canRetryPending)
      let calls = h.control.calls.count
      refused(h.owner.requestVerifyPending(pendingID.recovery)) {
        if case .notRetryable = $0 { return true }
        return false
      }
      refused(h.owner.requestRetryPending(pendingID.recovery)) {
        if case .notRetryable = $0 { return true }
        return false
      }
      XCTAssertEqual(h.control.calls.count, calls)
      h.control.mode(.clean)
      guard await loaded(h) else { return }
      XCTAssertEqual(pending(h, readback: true)?.recovery, pendingID.recovery)
      XCTAssertFalse(h.owner.mutationState.canApply)
      XCTAssertFalse(h.owner.mutationState.canPrepareQuit)
      guard
        let discard = admitted(
          h.owner.requestDiscardAndReload(
            .pending(pendingID.recovery), confirmation: .discardAttemptAndReload))
      else { return }
      await settled(h, discard)
      XCTAssertNil(h.owner.mutationState.unresolved)
      XCTAssertTrue(h.owner.mutationState.canApply)
    }
  }

  func testConfirmedDiscardFailedLoadPreservesAttemptAndPendingThenRealLoadResolves() async throws {
    for uncertain in [false, true] {
      try await withMutation { h in
        guard await loaded(h) else { return }
        h.control.mode(uncertain ? .uncertain : .prepublication)
        guard
          let write = admitted(
            h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
        else { return }
        await settled(h, write)
        let originalAttempt: UUID
        let originalRecovery: UUID?
        let unresolvedID: CatalogUnresolvedID
        if uncertain {
          guard let value = pending(h) else { return }
          originalAttempt = value.attempt
          originalRecovery = value.recovery
          unresolvedID = .pending(value.recovery)
        } else {
          guard let value = attempt(h) else { return }
          originalAttempt = value
          originalRecovery = nil
          unresolvedID = .attempt(value)
        }
        let current = h.owner.state.current?.id
        let disk = try h.bytes()
        let saves = h.control.count(.save)
        h.control.mode(.clean)
        h.control.failReads(true)
        guard
          let failed = admitted(
            h.owner.requestDiscardAndReload(unresolvedID, confirmation: .discardAttemptAndReload))
        else { return }
        await settled(h, failed)
        XCTAssertEqual(h.owner.state.current?.id, current)
        if uncertain {
          XCTAssertEqual(pending(h)?.attempt, originalAttempt)
          XCTAssertEqual(pending(h)?.recovery, originalRecovery)
        } else {
          XCTAssertEqual(attempt(h), originalAttempt)
        }
        XCTAssertEqual(try h.bytes(), disk)
        XCTAssertEqual(h.control.count(.save), saves)
        h.control.failReads(false)
        guard
          let success = admitted(
            h.owner.requestDiscardAndReload(unresolvedID, confirmation: .discardAttemptAndReload))
        else { return }
        await settled(h, success)
        try await assertCanonical(h)
        XCTAssertNil(h.owner.mutationState.unresolved)
        XCTAssertNotEqual(h.owner.state.current?.id, current)
        XCTAssertEqual(h.control.count(.save), saves)
      }
    }
  }

  func testOrdinaryLoadSuccessAndFailurePreservePendingAndQuitVeto() async throws {
    try await withMutation { h in
      guard let pendingID = try await makePending(h) else { return }
      let before = h.owner.state.current?.id
      h.control.mode(.clean)
      h.control.failReads(true)
      guard case .started(let failed) = h.owner.requestLoad() else {
        return XCTFail("Read admission")
      }
      await settled(h, failed)
      XCTAssertEqual(h.owner.state.current?.id, before)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      h.control.failReads(false)
      guard await loaded(h) else { return }
      XCTAssertNotEqual(h.owner.state.current?.id, before)
      XCTAssertEqual(pending(h)?.attempt, pendingID.attempt)
      XCTAssertEqual(pending(h)?.recovery, pendingID.recovery)
      XCTAssertFalse(h.owner.mutationState.canApply)
      if case .refused(.unresolvedPending(let id)) = h.owner.prepareQuit() {
        XCTAssertEqual(id, pendingID.recovery)
      } else {
        XCTFail("A genuine read is never pending acknowledgement")
      }
    }
  }

  func testTerminalMutationCallbackSuccessorRetainsItsOwnWorker() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      let gate = h.control.hold(.inspect)
      var first: UUID? = nil
      var successor: NativeLanguageCatalogMutationAdmission? = nil
      h.action = { state in
        guard state.activeRequestID == nil, state.lastSettledRequestID == first, successor == nil
        else { return }
        successor = h.owner.requestInspect(expectedPublication: h.expectation)
      }
      guard
        let id = admitted(h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
      else { return }
      first = id
      await settled(h, id)
      XCTAssertNotNil(successor)
      guard let successor, let next = admitted(successor) else { return }
      await fulfillment(of: [gate.entered], timeout: 4)
      XCTAssertEqual(h.owner.state.activeRequestID, next)
      XCTAssertEqual(h.owner.mutationState.activeOperation?.id, next)
      XCTAssertEqual(h.owner.state.lastSettledRequestID, id)
      gate.release()
      await settled(h, next)
      XCTAssertEqual(h.owner.state.lastSettledRequestID, next)
      XCTAssertEqual(h.control.maximum, 1)
    }
  }

  func testInvalidatedActualWriteJoinsAndRetainsEveryRealTerminalCategory() async throws {
    for mode in [MutationFaultMode.clean, .prepublication, .uncertain, .unconfirmed] {
      try await withMutation { h in
        guard await loaded(h) else { return }
        h.control.mode(mode)
        let gate = h.control.hold(.save)
        guard
          let id = admitted(h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
        else { return }
        await fulfillment(of: [gate.entered], timeout: 4)
        let count = h.notifications
        let entered = XCTestExpectation(description: "actual invalidation join entered")
        var joined = false
        let join = Task { @MainActor in
          entered.fulfill()
          await h.owner.invalidateAndWait()
          joined = true
        }
        await fulfillment(of: [entered], timeout: 4)
        join.cancel()
        let heartbeat = Task { @MainActor in
          XCTAssertFalse(joined)
          XCTAssertTrue(Thread.isMainThread)
        }
        await heartbeat.value
        XCTAssertNil(h.owner.state.current)
        XCTAssertNil(h.owner.state.activeRequestID)
        gate.release()
        await join.value
        XCTAssertTrue(joined)
        XCTAssertEqual(h.notifications, count)
        XCTAssertNil(h.owner.state.current)
        XCTAssertNil(h.owner.state.failure)
        XCTAssertNil(h.owner.mutationState.writeReceiptPublicationID)
        XCTAssertFalse(h.owner.mutationState.canPrepareQuit)
        guard let custody = h.owner.mutationState.invalidationCustody else {
          return XCTFail("Late actual result custody")
        }
        XCTAssertEqual(custody.operationID, id)
        XCTAssertNotNil(custody.attemptID)
        switch (mode, custody.outcome) {
        case (.clean, .succeededReceiptRetainedWithoutPublication), (.prepublication, .failed),
          (.uncertain, .publicationUncertain), (.unconfirmed, .readbackUnconfirmed):
          break
        default: XCTFail("Actual late outcome was lost or invented")
        }
        XCTAssertEqual(h.control.count(.save), 1)
        XCTAssertEqual(h.control.maximum, 1)
      }
    }
  }

  func testLateVerifyVoidSuccessAndFailureRetainOriginalPendingWithoutPublication() async throws {
    for fails in [false, true] {
      try await withMutation { h in
        guard let original = try await makePending(h) else { return }
        h.control.mode(.clean)
        h.control.failReads(fails)
        let gate = h.control.hold(.verify)
        let disk = try h.bytes()
        guard let id = admitted(h.owner.requestVerifyPending(original.recovery)) else { return }
        await fulfillment(of: [gate.entered], timeout: 4)
        h.owner.invalidate()
        let join = Task { @MainActor in await h.owner.invalidateAndWait() }
        gate.release()
        await join.value
        XCTAssertEqual(pending(h)?.attempt, original.attempt)
        XCTAssertEqual(pending(h)?.recovery, original.recovery)
        guard let custody = h.owner.mutationState.invalidationCustody else {
          return XCTFail("Late Void custody")
        }
        XCTAssertEqual(custody.operationID, id)
        if fails {
          if case .validationFailedWithoutAcknowledgement = custody.outcome {
          } else {
            XCTFail("Late failed validation kind")
          }
        } else {
          if case .validationCompletedWithoutAcknowledgement = custody.outcome {
          } else {
            XCTFail("Late Void is not a receipt")
          }
        }
        XCTAssertNil(h.owner.state.current)
        XCTAssertNil(h.owner.mutationState.writeReceiptPublicationID)
        XCTAssertEqual(try h.bytes(), disk)
      }
    }
  }

  func testLateConfirmedDiscardSuccessAndFailureNeverResolveOriginalPending() async throws {
    for fails in [false, true] {
      try await withMutation { h in
        guard let original = try await makePending(h) else { return }
        h.control.mode(.clean)
        h.control.failReads(fails)
        let gate = h.control.hold(.read)
        let disk = try h.bytes()
        guard
          let id = admitted(
            h.owner.requestDiscardAndReload(
              .pending(original.recovery), confirmation: .discardAttemptAndReload))
        else { return }
        await fulfillment(of: [gate.entered], timeout: 4)
        h.owner.invalidate()
        let join = Task { @MainActor in await h.owner.invalidateAndWait() }
        gate.release()
        await join.value
        XCTAssertEqual(pending(h)?.attempt, original.attempt)
        XCTAssertEqual(pending(h)?.recovery, original.recovery)
        guard let custody = h.owner.mutationState.invalidationCustody else {
          return XCTFail("Late discard custody")
        }
        XCTAssertEqual(custody.operationID, id)
        if case .discardReloadCompletedWithoutResolution = custody.outcome {
        } else {
          XCTFail("Invalidation cannot discard")
        }
        XCTAssertNil(h.owner.state.current)
        XCTAssertNil(h.owner.mutationState.writeReceiptPublicationID)
        XCTAssertEqual(try h.bytes(), disk)
      }
    }
  }

  func testLateInspectionRetainsActualResultWithoutAuthority() async throws {
    try await withMutation { h in
      guard await loaded(h) else { return }
      let gate = h.control.hold(.inspect)
      guard let id = admitted(h.owner.requestInspect(expectedPublication: h.expectation)) else {
        return
      }
      await fulfillment(of: [gate.entered], timeout: 4)
      h.owner.invalidate()
      let join = Task { @MainActor in await h.owner.invalidateAndWait() }
      gate.release()
      await join.value
      guard let custody = h.owner.mutationState.invalidationCustody else {
        return XCTFail("Actual late inspection custody")
      }
      XCTAssertEqual(custody.operationID, id)
      if case .inspectionCompleted = custody.outcome {
      } else {
        XCTFail("Inspection result stays private")
      }
      XCTAssertNil(h.owner.state.current)
      XCTAssertFalse(h.owner.mutationState.canApply)
      XCTAssertFalse(h.owner.mutationState.canRepair)
    }
  }
}
