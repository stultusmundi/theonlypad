import Foundation
import XCTest

@testable import PadCore

final class ExternalFileStateTests: XCTestCase {
  private let document = UUID()
  private func token(
    _ sequence: UInt64 = 1, epoch: UInt64 = 1, baseline: UInt64 = 1,
    id: UUID? = nil
  ) -> FileObservationToken {
    FileObservationToken(
      documentID: id ?? document, epoch: epoch, baselineRevision: baseline, sequence: sequence)
  }
  private func observation(
    _ relation: DiskContentRelation = .differsFromBaseline,
    problem: DiskLocationProblem? = nil, readOnly: Bool = false, inode: UInt64 = 2
  ) -> DiskObservation {
    DiskObservation(
      metadata: problem == nil
        ? FileMetadata(
          identity: FileTargetIdentity(
            parentDevice: 1, parentInode: 1, fileDevice: 1, fileInode: inode),
          byteCount: 5, mode: readOnly ? 0o100444 : 0o100644, flags: 0,
          modificationSeconds: 1, modificationNanoseconds: 0, changeSeconds: 1, changeNanoseconds: 0
        ) : nil,
      content: relation, locationProblem: problem, readOnlyHint: readOnly, movedCandidate: nil)
  }
  private func accepted(_ value: DiskObservation? = nil) -> ObservedFileState {
    var state = ObservedFileState()
    XCTAssertTrue(state.accept(value ?? observation(), token: token(), currentToken: token()))
    return state
  }

  // First intended behavioral red: the seam currently discards this current observation.
  func testCurrentChangedReadOnlyObservationPreservesBothFacets() {
    let state = accepted(observation(readOnly: true))
    XCTAssertEqual(state.observation?.content, .differsFromBaseline)
    XCTAssertEqual(state.observation?.readOnlyHint, true)
    XCTAssertEqual(state.token, token())
    XCTAssertTrue(state.noticeIsProminent)
  }
  func testForeignDocumentOldEpochOldBaselineAndOldSequenceAreRejectedWithoutMutation() {
    var state = accepted()
    let current = token(3)
    XCTAssertTrue(state.accept(observation(readOnly: true), token: current, currentToken: current))
    let stale = [
      token(4, id: UUID()), token(4, epoch: 0), token(4, baseline: 0), token(2), token(3), token(4),
    ]
    for incoming in stale {
      XCTAssertFalse(
        state.accept(observation(.matchesBaseline), token: incoming, currentToken: current))
      XCTAssertEqual(state.token, current)
      XCTAssertEqual(state.observation?.content, .differsFromBaseline)
      XCTAssertEqual(state.observation?.readOnlyHint, true)
    }
  }
  func testCurrentContextRejectsUnacceptedOlderSequence() {
    var state = ObservedFileState()
    XCTAssertFalse(state.accept(observation(), token: token(7), currentToken: token(8)))
    XCTAssertNil(state.observation)
  }
  func testNewEpochCanStartAtOneButPreviousEpochCannotReactivate() {
    var state = accepted()
    let last = token(UInt64.max)
    XCTAssertTrue(state.accept(observation(), token: last, currentToken: last))
    XCTAssertFalse(state.accept(observation(), token: token(0), currentToken: last))
    let fresh = token(1, epoch: 2)
    XCTAssertTrue(state.accept(observation(.matchesBaseline), token: fresh, currentToken: fresh))
    XCTAssertFalse(state.accept(observation(), token: last, currentToken: fresh))
    XCTAssertEqual(state.token, fresh)
  }
  func testBaselineReplacementRequiresCurrentContextButAllowsFreshSequence() {
    var state = accepted()
    let fresh = token(0, baseline: 2)
    XCTAssertTrue(state.accept(observation(.matchesBaseline), token: fresh, currentToken: fresh))
    XCTAssertEqual(state.token, fresh)
    XCTAssertFalse(state.accept(observation(), token: token(9), currentToken: fresh))
  }
  func testKeepBufferDismissesProminenceWithoutChangingContentOrReloadAdmission() {
    var state = accepted()
    state.dismiss(token: token(0))
    XCTAssertTrue(state.noticeIsProminent, "Wrong observation cannot dismiss current notice")
    state.dismiss(token: token(1))
    XCTAssertFalse(state.noticeIsProminent)
    XCTAssertEqual(state.observation?.content, .differsFromBaseline)
    XCTAssertEqual(
      state.admission(for: .reload, dirty: true, pendingPublication: false),
      .requiresDiscardConfirmation)
  }
  func testRepeatedIdenticalObservationDoesNotRepromptButChangedIdentityDoes() {
    var state = accepted()
    state.dismiss(token: token(1))
    XCTAssertTrue(state.accept(observation(), token: token(2), currentToken: token(2)))
    XCTAssertFalse(state.noticeIsProminent)
    XCTAssertTrue(state.accept(observation(inode: 3), token: token(3), currentToken: token(3)))
    XCTAssertTrue(state.noticeIsProminent)
  }
  func testDuplicateDismissedCompletionCannotRepromoteNotice() {
    var state = accepted()
    state.dismiss(token: token(1))
    XCTAssertFalse(state.accept(observation(inode: 999), token: token(), currentToken: token()))
    XCTAssertFalse(state.noticeIsProminent)
    XCTAssertEqual(state.observation?.metadata?.identity.fileInode, 2)
  }
  func testPendingLatestRequestRejectsOlderResultAndRetainsAcceptedState() {
    var state = accepted(observation(readOnly: true))
    XCTAssertFalse(
      state.accept(observation(.matchesBaseline), token: token(2), currentToken: token(3)))
    XCTAssertEqual(state.token, token(1))
    XCTAssertEqual(state.observation?.content, .differsFromBaseline)
    XCTAssertEqual(state.observation?.readOnlyHint, true)
    XCTAssertTrue(
      state.accept(observation(.matchesBaseline), token: token(3), currentToken: token(3)))
    XCTAssertEqual(state.token, token(3))
  }
  func testNewLiveEpochDoesNotReusePriorDismissal() {
    var state = accepted()
    state.dismiss(token: token(1))
    let fresh = token(1, epoch: 2)
    XCTAssertTrue(state.accept(observation(), token: fresh, currentToken: fresh))
    XCTAssertTrue(state.noticeIsProminent)
  }
  func testStaleEpochDismissalCannotHideFreshNoticeWithReusedSequence() {
    var state = accepted()
    let fresh = token(1, epoch: 2)
    XCTAssertTrue(state.accept(observation(), token: fresh, currentToken: fresh))
    state.dismiss(token: token(1))
    XCTAssertTrue(state.noticeIsProminent)
    XCTAssertEqual(state.token, fresh)
    state.dismiss(token: fresh)
    XCTAssertFalse(state.noticeIsProminent)
  }
  func testStaleBaselineDismissalCannotHideFreshNoticeWithReusedSequence() {
    var state = accepted()
    let fresh = token(1, baseline: 2)
    XCTAssertTrue(state.accept(observation(), token: fresh, currentToken: fresh))
    state.dismiss(token: token(1))
    XCTAssertTrue(state.noticeIsProminent)
    state.dismiss(token: fresh)
    XCTAssertFalse(state.noticeIsProminent)
  }
  func testForeignDocumentDismissalCannotHideCurrentNotice() {
    var state = accepted()
    state.dismiss(token: token(1, id: UUID()))
    XCTAssertTrue(state.noticeIsProminent)
  }
  func testMatchingContentCanRetainIndependentReadOnlyNotice() {
    let state = accepted(observation(.matchesBaseline, readOnly: true))
    XCTAssertEqual(state.observation?.content, .matchesBaseline)
    XCTAssertEqual(state.observation?.readOnlyHint, true)
    XCTAssertTrue(state.noticeIsProminent)
    XCTAssertEqual(
      state.admission(for: .openDiskCopy, dirty: false, pendingPublication: false), .allowed)
    XCTAssertEqual(state.admission(for: .reload, dirty: false, pendingPublication: false), .allowed)
  }
  func testMatchingBytesCannotResolvePendingPublicationOrDirtyDisposition() {
    let state = accepted(observation(.matchesBaseline))
    XCTAssertFalse(state.noticeIsProminent)
    XCTAssertEqual(
      state.admission(for: .reload, dirty: false, pendingPublication: true),
      .requiresDiscardConfirmation)
    XCTAssertEqual(
      state.admission(for: .reload, dirty: true, pendingPublication: false),
      .requiresDiscardConfirmation)
    XCTAssertEqual(state.admission(for: .locate, dirty: true, pendingPublication: true), .refused)
    XCTAssertEqual(
      state.admission(for: .openDiskCopy, dirty: true, pendingPublication: true), .allowed)
  }
  func testCleanAndDirtyAccessibleContentActionTable() {
    let state = accepted(observation(readOnly: true))
    for action in FileConflictAction.allCases {
      XCTAssertEqual(
        state.admission(for: action, dirty: false, pendingPublication: false), .allowed)
      XCTAssertEqual(
        state.admission(for: action, dirty: true, pendingPublication: false),
        action == .reload ? .requiresDiscardConfirmation : .allowed)
    }
  }
  func testUnavailableLocationNeverAdmitsReadActions() {
    let problems: [DiskLocationProblem] = [
      .missing, .inaccessible, .symbolicLink, .nonregular,
      .parentChanged, .changedDuringRead, .unsupportedVolume, .tooLarge, .checkDelayed,
    ]
    for problem in problems {
      let state = accepted(observation(.unavailable, problem: problem))
      XCTAssertTrue(state.noticeIsProminent)
      for action in [FileConflictAction.reload, .openDiskCopy] {
        XCTAssertEqual(
          state.admission(for: action, dirty: true, pendingPublication: false), .refused)
      }
      for action in [FileConflictAction.saveAs, .keepBuffer, .checkAgain] {
        XCTAssertEqual(
          state.admission(for: action, dirty: true, pendingPublication: false), .allowed)
      }
    }
  }
  func testUnavailableContentWithoutLocationProblemRefusesReadActions() {
    let state = accepted(observation(.unavailable))
    XCTAssertNil(state.observation?.locationProblem)
    XCTAssertNotNil(state.observation?.metadata)
    for action in [FileConflictAction.reload, .openDiskCopy] {
      XCTAssertEqual(
        state.admission(for: action, dirty: false, pendingPublication: false), .refused)
      XCTAssertEqual(state.admission(for: action, dirty: true, pendingPublication: true), .refused)
    }
  }
  func testMissingMetadataRefusesReadActionsEvenWhenContentClaimsAccessible() {
    for relation in [DiskContentRelation.matchesBaseline, .differsFromBaseline, .unavailable] {
      let incomplete = DiskObservation(
        metadata: nil, content: relation, locationProblem: nil,
        readOnlyHint: false, movedCandidate: nil)
      let state = accepted(incomplete)
      for action in [FileConflictAction.reload, .openDiskCopy] {
        XCTAssertEqual(
          state.admission(for: action, dirty: false, pendingPublication: false), .refused)
        XCTAssertEqual(
          state.admission(for: action, dirty: true, pendingPublication: true), .refused)
      }
    }
  }
  func testUnsafeOrMissingLocationCanBeChosenExplicitlyButUncertaintyCannotRedirect() {
    for problem in [DiskLocationProblem.missing, .symbolicLink, .nonregular, .parentChanged] {
      let state = accepted(observation(.unavailable, problem: problem))
      XCTAssertEqual(
        state.admission(for: .locate, dirty: true, pendingPublication: false), .allowed)
      XCTAssertEqual(state.admission(for: .locate, dirty: true, pendingPublication: true), .refused)
    }
  }
  func testNoObservationStillPermitsManualCheckAndSaveAsWithoutInventingReadAuthority() {
    let state = ObservedFileState()
    XCTAssertFalse(state.noticeIsProminent)
    for action in [FileConflictAction.checkAgain, .saveAs] {
      XCTAssertEqual(state.admission(for: action, dirty: true, pendingPublication: false), .allowed)
    }
    for action in [FileConflictAction.reload, .openDiskCopy, .keepBuffer, .locate] {
      XCTAssertEqual(state.admission(for: action, dirty: true, pendingPublication: false), .refused)
    }
  }
  func testRecordingVetoCannotBeBypassedByCleanObservation() {
    let state = accepted(observation(.matchesBaseline))
    XCTAssertEqual(
      state.admission(for: .reload, dirty: false, pendingPublication: false, recording: true),
      .refused)
  }
  func testClosedOrQuittingOwnerRefusesEveryAction() {
    let state = accepted()
    for action in FileConflictAction.allCases {
      XCTAssertEqual(
        state.admission(for: action, dirty: true, pendingPublication: true, quitting: true),
        .refused)
      XCTAssertEqual(
        state.admission(for: action, dirty: false, pendingPublication: false, closed: true),
        .refused)
    }
  }
  func testSaveAndCompositionFreezeMutatingActionsButAllowPassiveCheckDismiss() {
    let state = accepted()
    for action in [FileConflictAction.reload, .openDiskCopy, .saveAs, .locate] {
      XCTAssertEqual(
        state.admission(for: action, dirty: false, pendingPublication: false, busy: true), .refused)
      XCTAssertEqual(
        state.admission(for: action, dirty: false, pendingPublication: false, composing: true),
        .refused)
    }
    for action in [FileConflictAction.keepBuffer, .checkAgain] {
      XCTAssertEqual(
        state.admission(for: action, dirty: true, pendingPublication: true, busy: true), .allowed)
      XCTAssertEqual(
        state.admission(for: action, dirty: true, pendingPublication: true, composing: true),
        .allowed)
    }
  }
}
