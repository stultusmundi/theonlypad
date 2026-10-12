// SPDX-License-Identifier: MIT
// SOURCE ONLY. Access blocks are appended to matched native files and removed
// from the test-target copy. They implement no factory, source fence or validator.
import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting
@testable import SearchExecution

@MainActor private final class ChronologyForwarder: NSObject, NSTextViewDelegate {
  let controller: EditorWindowController
  let permission = NativeSourceCounter("chronology permission")
  let changes = NativeSourceCounter("chronology change")
  let selections = NativeSourceCounter("chronology selection")
  let decision: (NSTextView, NSRange, String?, Bool) -> Bool
  init(
    controller: EditorWindowController,
    decision: @escaping (NSTextView, NSRange, String?, Bool) -> Bool
  ) {
    self.controller = controller
    self.decision = decision
  }
  func textView(
    _ view: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool {
    guard permission.enter() else { return false }
    let permitted: Bool = controller.textView(
      view, shouldChangeTextIn: range,
      replacementString: replacementString)
    return decision(view, range, replacementString, permitted)
  }
  func textDidChange(_ notification: Notification) {
    guard changes.enter() else { return }
    controller.textDidChange(notification)
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard selections.enter() else { return }
    controller.textViewDidChangeSelection(notification)
  }
  func assertFinite() {
    XCTAssertFalse(permission.overflow || changes.overflow || selections.overflow)
  }
}

@MainActor private func macroSeed(
  _ f: NativeSourceFixture, text: String,
  bookmarks: [Int], active: Bool
) throws {
  // Finite synthetic starting state, not a recorded edit or commitment oracle.
  f.document.storage.mutableString.setString(text)
  f.document.bookmarks = try DocumentBookmarks(offsets: bookmarks, in: text)
  f.document.undoManager.removeAllActions()
  f.controller.nativeSearchTestRecording(active ? f.document.id : nil, commands: [], units: 0)
  XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
}

@MainActor private func macroReplaceWhole(
  _ f: NativeSourceFixture,
  before: String, after: String
) throws
  -> (source: EditorDocumentSearchSource, credential: DocumentSearchCredential)
{
  let source: EditorDocumentSearchSource = try f.source()
  let credential: DocumentSearchCredential = try source.inspect()
  let committed: Bool
  do {
    f.document.undoManager.beginUndoGrouping()
    defer { f.document.undoManager.endUndoGrouping() }
    committed = source.replace(expected: credential, source: before, replacement: after)
  }
  XCTAssertTrue(committed)
  guard committed else { throw NativeClientFailure.unavailable }
  XCTAssertFalse(source.isCurrent(expected: credential))
  return (source: source, credential: credential)
}

@MainActor private func macroStage(
  _ f: NativeSourceFixture,
  text: String, bookmarks: [Int], commands: [MacroCommand], units: Int,
  start: String, recording: UUID?, canUndo: Bool, canRedo: Bool
) throws {
  let actual: [MacroCommand] = f.controller.nativeSearchTestCommands
  XCTAssertEqual(actual, commands)  // Independent literal arrays first.
  XCTAssertEqual(f.controller.nativeSearchTestUnits, units)
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, recording)
  XCTAssertEqual(f.document.storage.string, text)
  XCTAssertEqual(f.document.bookmarks.offsets, bookmarks)
  XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
  XCTAssertFalse(f.document.undoManager.isUndoing || f.document.undoManager.isRedoing)
  XCTAssertEqual(f.document.undoManager.canUndo, canUndo)
  XCTAssertEqual(f.document.undoManager.canRedo, canRedo)
  let id: UUID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
  let macro: EditorMacro = EditorMacro(name: "Synthetic chronology", commands: actual, id: id)
  XCTAssertEqual(try MacroPlayer.replay(macro, on: start), text)
}

@MainActor final class NativeMacroChronologyTests: XCTestCase {
  func testChronologicalUnicodeReplacementUndoRedoPayloadsAndReplay() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try f.controller.splitCurrent(.sideBySide)
    let other: EditorPane = try XCTUnwrap(
      f.document.panePool.first { $0 !== f.pane && $0.isAttached })
    try f.controller.focusPane(id: other.id)
    try macroSeed(f, text: "😀x", bookmarks: [0], active: true)
    var phase: String = "forward"
    let spy = ChronologyForwarder(controller: f.controller) { view, range, text, permitted in
      XCTAssertTrue(view === f.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 3))
      switch phase {
      case "forward", "redo": XCTAssertEqual(text, "😀y")
      case "undo": XCTAssertEqual(text, "😀x")
      default:
        XCTFail("Unexpected bounded phase")
        return false
      }
      XCTAssertTrue(permitted)
      return permitted
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    let old = try macroReplaceWhole(f, before: "😀x", after: "😀y")
    let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    let expectedUndo: MacroCommand = .replace(location: 0, length: 3, text: "😀x")
    let expectedRedo: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward], units: 3,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertEqual(spy.permission.count, 1)
    XCTAssertEqual(f.document.preferredPaneID, other.id)
    XCTAssertFalse(old.source.isCurrent(expected: old.credential))
    phase = "undo"
    f.document.undoManager.undo()
    try macroStage(
      f, text: "😀x", bookmarks: [0], commands: [expectedForward, expectedUndo], units: 6,
      start: "😀x", recording: f.document.id, canUndo: false, canRedo: true)
    XCTAssertEqual(spy.permission.count, 2)
    phase = "redo"
    f.document.undoManager.redo()
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward, expectedUndo, expectedRedo],
      units: 9,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertEqual(spy.permission.count, 3)
    spy.assertFinite()
  }

  func testChronologicalLengthChangingUndoContinueInvalidatesRedo() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: true)
    let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    let expectedCommandA: MacroCommand = .replace(location: 0, length: 2, text: "Xab")
    let expectedCommandB: MacroCommand = .replace(location: 0, length: 3, text: "ab")
    let expectedCommandC: MacroCommand = .replace(location: 0, length: 2, text: "Qb")
    _ = try macroReplaceWhole(f, before: "ab", after: "Xab")
    try macroStage(
      f, text: "Xab", bookmarks: [], commands: [expectedCommandA], units: 3,
      start: "ab", recording: f.document.id, canUndo: true, canRedo: false)
    f.document.undoManager.undo()
    try macroStage(
      f, text: "ab", bookmarks: [], commands: [expectedCommandA, expectedCommandB], units: 5,
      start: "ab", recording: f.document.id, canUndo: false, canRedo: true)
    _ = try macroReplaceWhole(f, before: "ab", after: "Qb")
    try macroStage(
      f, text: "Qb", bookmarks: [],
      commands: [expectedCommandA, expectedCommandB, expectedCommandC], units: 7,
      start: "ab", recording: f.document.id, canUndo: true, canRedo: false)
    let calls: Int = spy.permission.count
    f.document.undoManager.redo()
    try macroStage(
      f, text: "Qb", bookmarks: [],
      commands: [expectedCommandA, expectedCommandB, expectedCommandC], units: 7,
      start: "ab", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertEqual(spy.permission.count, calls)
    spy.assertFinite()
  }

  func testChronologicalPreRecordingHistoryAndBookmarkOnlyReplay() async throws {
    do {
      let f = try await NativeSourceFixture()
      defer { f.close() }
      try macroSeed(f, text: "ab", bookmarks: [], active: false)
      let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
      let previous = f.pane.editor.delegate
      f.pane.editor.delegate = spy
      defer {
        f.pane.editor.delegate = previous
        withExtendedLifetime(spy) {}
      }
      _ = try macroReplaceWhole(f, before: "ab", after: "Xab")
      XCTAssertEqual(f.document.storage.string, "Xab")
      XCTAssertEqual(f.controller.nativeSearchTestCommands, [])
      XCTAssertEqual(f.controller.nativeSearchTestUnits, 0)
      XCTAssertNil(f.controller.nativeSearchTestRecordingID)
      XCTAssertTrue(f.document.undoManager.canUndo)
      // Existing finite state access starts recording; never seed a command.
      f.controller.nativeSearchTestRecording(f.document.id, commands: [], units: 0)
      let expectedCommandB: MacroCommand = .replace(location: 0, length: 3, text: "ab")
      let expectedCommandC: MacroCommand = .replace(location: 0, length: 2, text: "Qb")
      f.document.undoManager.undo()
      try macroStage(
        f, text: "ab", bookmarks: [], commands: [expectedCommandB], units: 2,
        start: "Xab", recording: f.document.id, canUndo: false, canRedo: true)
      _ = try macroReplaceWhole(f, before: "ab", after: "Qb")
      try macroStage(
        f, text: "Qb", bookmarks: [], commands: [expectedCommandB, expectedCommandC], units: 4,
        start: "Xab", recording: f.document.id, canUndo: true, canRedo: false)
      spy.assertFinite()
    }
    do {
      let f = try await NativeSourceFixture()
      defer { f.close() }
      try macroSeed(f, text: "a\nb", bookmarks: [], active: true)
      let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
      let previous = f.pane.editor.delegate
      f.pane.editor.delegate = spy
      defer {
        f.pane.editor.delegate = previous
        withExtendedLifetime(spy) {}
      }
      let marks: DocumentBookmarks = try DocumentBookmarks(offsets: [2], in: "a\nb")
      do {
        f.document.undoManager.beginUndoGrouping()
        defer { f.document.undoManager.endUndoGrouping() }
        f.controller.nativeMacroTestSetBookmarks(f.document, value: marks)
      }
      try macroStage(
        f, text: "a\nb", bookmarks: [2], commands: [], units: 0,
        start: "a\nb", recording: f.document.id, canUndo: true, canRedo: false)
      f.document.undoManager.undo()
      try macroStage(
        f, text: "a\nb", bookmarks: [], commands: [], units: 0,
        start: "a\nb", recording: f.document.id, canUndo: false, canRedo: true)
      f.document.undoManager.redo()
      try macroStage(
        f, text: "a\nb", bookmarks: [2], commands: [], units: 0,
        start: "a\nb", recording: f.document.id, canUndo: true, canRedo: false)
      XCTAssertEqual(spy.permission.count, 0)
      spy.assertFinite()
    }
  }

  func testChronologicalGroupedAndCoalescedEditsReplayActualText() async throws {
    do {
      let f = try await NativeSourceFixture()
      defer { f.close() }
      try macroSeed(f, text: "ab", bookmarks: [], active: true)
      let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
      let previous = f.pane.editor.delegate
      f.pane.editor.delegate = spy
      defer {
        f.pane.editor.delegate = previous
        withExtendedLifetime(spy) {}
      }
      let expectedGroup1: MacroCommand = .replace(location: 0, length: 2, text: "Xb")
      let expectedGroup2: MacroCommand = .replace(location: 0, length: 2, text: "XY")
      let expectedUndoGroup2: MacroCommand = .replace(location: 0, length: 2, text: "Xb")
      let expectedUndoGroup1: MacroCommand = .replace(location: 0, length: 2, text: "ab")
      do {
        f.document.undoManager.beginUndoGrouping()
        defer { f.document.undoManager.endUndoGrouping() }
        _ = try macroReplaceWhole(f, before: "ab", after: "Xb")
        XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedGroup1])
        XCTAssertEqual(f.controller.nativeSearchTestUnits, 2)
        f.pane.editor.breakUndoCoalescing()
        _ = try macroReplaceWhole(f, before: "Xb", after: "XY")
      }
      try macroStage(
        f, text: "XY", bookmarks: [], commands: [expectedGroup1, expectedGroup2], units: 4,
        start: "ab", recording: f.document.id, canUndo: true, canRedo: false)
      XCTAssertEqual(spy.permission.count, 2)
      f.document.undoManager.undo()
      try macroStage(
        f, text: "ab", bookmarks: [],
        commands: [expectedGroup1, expectedGroup2, expectedUndoGroup2, expectedUndoGroup1],
        units: 8,
        start: "ab", recording: f.document.id, canUndo: false, canRedo: true)
      XCTAssertEqual(spy.permission.count, 4)
      f.document.undoManager.redo()
      try macroStage(
        f, text: "XY", bookmarks: [],
        commands: [
          expectedGroup1, expectedGroup2, expectedUndoGroup2, expectedUndoGroup1, expectedGroup1,
          expectedGroup2,
        ], units: 12,
        start: "ab", recording: f.document.id, canUndo: true, canRedo: false)
      XCTAssertEqual(spy.permission.count, 6)
      spy.assertFinite()
    }
    do {
      let f = try await NativeSourceFixture()
      defer { f.close() }
      try macroSeed(f, text: "", bookmarks: [], active: true)
      let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
      let previous = f.pane.editor.delegate
      f.pane.editor.delegate = spy
      defer {
        f.pane.editor.delegate = previous
        withExtendedLifetime(spy) {}
      }
      let expectedTransformation1: MacroCommand = .replace(location: 0, length: 0, text: "a")
      let expectedTransformation2: MacroCommand = .replace(location: 1, length: 0, text: "b")
      f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
      XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 0, length: 0))
      do {
        f.document.undoManager.beginUndoGrouping()
        defer { f.document.undoManager.endUndoGrouping() }
        f.pane.editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(f.document.storage.string, "a")
        XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedTransformation1])
        XCTAssertEqual(f.controller.nativeSearchTestUnits, 1)
        // No breakUndoCoalescing here; the returned first insertion selects its actual caret.
        f.pane.editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
      }
      try macroStage(
        f, text: "ab", bookmarks: [], commands: [expectedTransformation1, expectedTransformation2],
        units: 2,
        start: "", recording: f.document.id, canUndo: true, canRedo: false)
      XCTAssertEqual(spy.permission.count, 2)
      f.document.undoManager.undo()
      let one: [MacroCommand] = [
        expectedTransformation1, expectedTransformation2,
        .replace(location: 0, length: 2, text: ""),
      ]
      let two: [MacroCommand] = [
        expectedTransformation1, expectedTransformation2,
        .replace(location: 1, length: 1, text: ""),
        .replace(location: 0, length: 1, text: ""),
      ]
      let actual: [MacroCommand] = f.controller.nativeSearchTestCommands
      if actual == one {
        try macroStage(
          f, text: "", bookmarks: [], commands: one, units: 2,
          start: "", recording: f.document.id, canUndo: false, canRedo: true)
        XCTAssertEqual(spy.permission.count, 3)
      } else if actual == two {
        try macroStage(
          f, text: "", bookmarks: [], commands: two, units: 2,
          start: "", recording: f.document.id, canUndo: false, canRedo: true)
        XCTAssertEqual(spy.permission.count, 4)
      } else {
        XCTFail("Outside two independently literal native inverse representations")
        throw NativeClientFailure.unavailable
      }
      spy.assertFinite()
    }
  }

  func testRejectedFallbackNativeInsertionPublishesNoGhostMacroCommand() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: true)
    let refused = NativeSourceCounter("forwarded permission then false")
    let spy = ChronologyForwarder(controller: f.controller) { view, range, text, permitted in
      guard refused.enter() else { return false }
      XCTAssertTrue(view === f.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 0))
      XCTAssertEqual(text, "X")
      XCTAssertFalse(f.controller.nativeSearchTestProposal)
      XCTAssertTrue(permitted)
      return false
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    XCTAssertFalse(f.document.undoManager.canUndo || f.document.undoManager.canRedo)
    f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(refused.count, 1)
    XCTAssertEqual(spy.permission.count, 1)
    XCTAssertEqual(spy.changes.count, 0)
    try macroStage(
      f, text: "ab", bookmarks: [], commands: [], units: 0,
      start: "ab", recording: f.document.id, canUndo: false, canRedo: false)
    XCTAssertFalse(f.controller.nativeSearchTestProposal)
    XCTAssertFalse(refused.overflow)
    spy.assertFinite()
  }

  func testDeniedNativeUndoLeavesChronologicalStreamAndTextUnchanged() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "😀x", bookmarks: [0], active: true)
    let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in permitted }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    _ = try macroReplaceWhole(f, before: "😀x", after: "😀y")
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward], units: 3,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertTrue(f.registry.allows(.undoRedo, documentID: f.document.id))
    f.routing.armed = true
    f.routing.onAdmission = { throw NativeClientFailure.unavailable }
    defer {
      f.routing.onAdmission = nil
      f.routing.armed = false
    }
    let admissions: Int = f.routing.admissionCalls.count
    let permissions: Int = spy.permission.count
    let revision: UInt64 = f.document.editRevision
    f.document.undoManager.undo()
    XCTAssertGreaterThan(f.routing.admissionCalls.count, admissions)
    XCTAssertEqual(spy.permission.count, permissions)
    XCTAssertEqual(f.document.editRevision, revision)
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward], units: 3,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertFalse(f.routing.admissionCalls.overflow)
    spy.assertFinite()
  }

  func testRefusedSearchProposalPreservesChronologicalPrefixAndCallbackEdits() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "😀x", bookmarks: [0], active: true)
    var refuse: Bool = false
    let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in
      refuse ? false : permitted
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    _ = try macroReplaceWhole(f, before: "😀x", after: "😀y")
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward], units: 3,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertEqual(spy.permission.count, 1)
    let source: EditorDocumentSearchSource = try f.source()
    let credential: DocumentSearchCredential = try source.inspect()
    let revision: UInt64 = f.document.editRevision
    refuse = true
    do {
      f.document.undoManager.beginUndoGrouping()
      defer { f.document.undoManager.endUndoGrouping() }
      XCTAssertFalse(source.replace(expected: credential, source: "😀y", replacement: "😀z"))
    }
    XCTAssertEqual(spy.permission.count, 2)
    try macroStage(
      f, text: "😀y", bookmarks: [], commands: [expectedForward], units: 3,
      start: "😀x", recording: f.document.id, canUndo: true, canRedo: false)
    XCTAssertEqual(f.document.editRevision, revision)
    XCTAssertTrue(source.isCurrent(expected: credential))
    XCTAssertNil(f.document.pendingBookmarks)
    XCTAssertFalse(f.controller.nativeSearchTestProposal)
    spy.assertFinite()
  }
}

private enum NativeClientFailure: Error { case bound, unavailable, cleanup }

@MainActor private final class NativeSourceCounter {
  let label: String
  private(set) var count = 0
  private(set) var overflow = false
  let maximum: Int
  init(_ label: String, maximum: Int = 64) {
    precondition(maximum == 64 || maximum == 256, "Unsupported native fixture callback budget")
    self.label = label
    self.maximum = maximum
  }
  func enter() -> Bool {
    guard count < maximum else {
      if !overflow { XCTFail("Bounded native callback overflow: \(label)") }
      overflow = true
      return false
    }
    count += 1
    return true
  }
}

@MainActor private final class NativeOnceMutation {
  private(set) var claimed = false
  func claim() -> Bool {
    guard !claimed else { return false }
    claimed = true
    return true
  }
}

@MainActor private final class NativeSourceRoutingState {
  var endpointCurrent = true
  var armed = false
  var onAdmission: (() throws -> Void)?
  let endpointCalls: NativeSourceCounter
  let admissionCalls: NativeSourceCounter
  init(maximum: Int = 64) {
    endpointCalls = NativeSourceCounter("actual endpoint-current admission", maximum: maximum)
    admissionCalls = NativeSourceCounter("actual user admission", maximum: maximum)
  }
  func requireCurrent() throws {
    if armed, !endpointCalls.enter() { throw NativeClientFailure.bound }
    guard endpointCurrent else { throw EditorApplicationRoutingError.staleEndpoint }
  }
  func requireUser() throws {
    if armed, !admissionCalls.enter() { throw NativeClientFailure.bound }
    try onAdmission?()
  }
  func clear() {
    armed = false
    onAdmission = nil
    endpointCurrent = true
  }
}

@MainActor private final class NativeSourceDelegate: NSObject, NSTextViewDelegate {
  let should: (NSTextView, NSRange, String?) -> Bool
  let did: (Notification) -> Void
  let calls = NativeSourceCounter("native delegate entry")
  let changes = NativeSourceCounter("native delegate textDidChange")
  init(
    should: @escaping (NSTextView, NSRange, String?) -> Bool,
    did: @escaping (Notification) -> Void
  ) {
    self.should = should
    self.did = did
  }
  func textView(
    _ textView: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool {
    guard calls.enter() else { return false }
    return should(textView, range, replacementString)
  }
  func textDidChange(_ notification: Notification) {
    guard changes.enter() else { return }
    did(notification)
  }
}

@MainActor private final class NativeSourceFixture {
  let assignment: DocumentAssignment
  let endpointID: UUID
  let directory: URL
  let recovery: RecoveryCoordinator
  let registry: ApplicationDocuments
  let document: EditorDocument
  let pane: EditorPane
  let controller: EditorWindowController
  let routing: NativeSourceRoutingState
  let errors: NativeSourceCounter
  let typing = NativeSourceCounter("native typing-run boundary")
  let focus = NativeSourceCounter("native focus boundary")
  let scroll = NativeSourceCounter("native scroll bounds notification")
  private var observers: [NSObjectProtocol] = []  // One guarded observer slot.
  var configuration: UUID?
  var operation: UUID?
  var editingOpen = false
  private var closeTicket: DocumentCloseTicket?
  private var delegate: NativeSourceDelegate?
  private var secondDocument: EditorDocument?
  private var sinkObservationInstalled = false
  private var closed = false

  init(routingCallbackBudget: Int = 64) async throws {
    guard routingCallbackBudget == 64 || routingCallbackBudget == 256 else {
      throw NativeClientFailure.bound
    }
    _ = NSApplication.shared
    let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
    let endpoint = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000202"))
    let documentID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000203"))
    let groupID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000204"))
    let placement = DocumentAssignment(windowID: windowID, groupID: groupID)
    let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-NativeEditorSearchSource-" + UUID().uuidString, isDirectory: true)
    let owner = RecoveryCoordinator(
      directory: fixtureDirectory,
      saveCheckpointSession: { _ in throw NativeClientFailure.unavailable },
      readCheckpointSession: { nil })
    let documents = ApplicationDocuments(
      closeServices: DocumentCloseServices(readState: { handle in
        guard let model = handle as? EditorDocument else { throw NativeClientFailure.unavailable }
        return try model.captureCloseState()
      }),
      adoptionServices: DocumentAdoptionServices(
        coordinatorID: owner.coordinatorID,
        readState: { handle in
          guard let model = handle as? EditorDocument else { throw NativeClientFailure.unavailable }
          return DocumentAdoptionState(
            documentID: model.id,
            ownershipGeneration: model.ownershipGeneration, authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        }))
    let model = EditorDocument(id: documentID)
    let nativePane = try XCTUnwrap(model.panePool.first)
    let routeState = NativeSourceRoutingState(maximum: routingCallbackBudget)
    let errorCounter = NativeSourceCounter("native source error publication")
    var partiallyConstructed: EditorWindowController?
    var directoryCreated = false
    do {
      try FileManager.default.createDirectory(
        at: fixtureDirectory, withIntermediateDirectories: false)
      directoryCreated = true
      try documents.registerWindow(id: windowID, initialGroupID: groupID)
      model.storage.mutableString.setString("😀x")
      let adoptionTicket = try documents.registerPending(
        model, requestID: UUID(),
        expectedRevision: documents.workspaceRevision, metadata: .init(pinned: false),
        in: placement, at: 0, select: true)
      let adopted = try await owner.adoptManagedDocument(id: documentID)
      try model.installRecoveryAdoption(
        adopted, expectedOwnershipGeneration: model.ownershipGeneration)
      try documents.activateAdoption(adoptionTicket, receipt: adopted)
      // A real authorized synthetic recovery file is part of this fixture's declared directory.
      try await owner.persistAuthorized(model.captureAuthorizedRecovery())
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath:
            fixtureDirectory.appendingPathComponent(documentID.uuidString + ".json").path))
      let application = EditorApplicationRouting(
        endpointID: endpoint, assignment: placement,
        registry: documents, requireEndpointCurrent: { try routeState.requireCurrent() },
        requireUserAdmission: { try routeState.requireUser() },
        submit: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
        wait: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
        requestClose: { _ in throw EditorApplicationRoutingError.unsupportedSeed },
        requestReopen: { throw EditorApplicationRoutingError.unsupportedSeed },
        detachDocumentEndpoint: { _ in }, reattachDocumentEndpoint: { _, _, _ in },
        endpointClosed: { _ in }, requestCheckpoint: {})
      let native = try EditorWindowController(
        id: windowID, application: application,
        onError: { _ in
          guard errorCounter.enter() else { return }
          XCTFail("Unexpected native source error publication")
        })
      partiallyConstructed = native
      let projection = try XCTUnwrap(documents.window(id: windowID))
      try native.applyRegistryProjection(
        projection, revision: documents.workspaceRevision, endpointID: endpoint)
      model.nativeSearchTestSeedRevision(7)
      model.undoManager.groupsByEvent = false
      model.undoManager.removeAllActions()
      assignment = placement
      endpointID = endpoint
      directory = fixtureDirectory
      recovery = owner
      registry = documents
      document = model
      pane = nativePane
      routing = routeState
      errors = errorCounter
      controller = native
    } catch {
      routeState.clear()
      partiallyConstructed?.nativeSearchTestTearDown()
      if directoryCreated {
        do { try FileManager.default.removeItem(at: fixtureDirectory) } catch {
          XCTFail("Partial native fixture directory cleanup failed: \(error)")
        }
      }
      throw error
    }
  }

  func source() throws -> EditorDocumentSearchSource {
    try controller.nativeSearchTestSource(document: document, pane: pane)
  }
  func observeSinks() {
    guard !sinkObservationInstalled else {
      XCTFail("Second sink observation installation")
      return
    }
    sinkObservationInstalled = true
    routing.armed = true
    let originalTyping = pane.editor.onTypingRunEnded
    let originalFocus = pane.editor.onFocus
    let originalBounds = pane.onBoundsChanged
    let typingCounter = typing
    let focusCounter = focus
    let boundsCounter = scroll
    pane.editor.onTypingRunEnded = {
      guard typingCounter.enter() else { return }
      originalTyping?()
    }
    pane.editor.onFocus = {
      guard focusCounter.enter() else { return }
      originalFocus?()
    }
    pane.onBoundsChanged = {
      guard boundsCounter.enter() else { return }
      originalBounds?()
    }
  }
  func installDelegate(_ should: @escaping (NSTextView, NSRange, String?) -> Bool) {
    guard delegate == nil else {
      XCTFail("Second delegate installation")
      return
    }
    let native = controller
    let forwarding = NativeSourceDelegate(should: should, did: { native.textDidChange($0) })
    delegate = forwarding
    pane.editor.delegate = forwarding
  }
  func blockRegistry() throws {
    guard closeTicket == nil else {
      XCTFail("Second registry close lease")
      throw NativeClientFailure.bound
    }
    let request = try registry.requestClose(documentID: document.id)
    closeTicket = try registry.beginClose(request, disposition: .discardWithoutHistory)
  }
  func addSecondDocument() async throws -> EditorDocument {
    guard secondDocument == nil else {
      XCTFail("Second extra document")
      throw NativeClientFailure.bound
    }
    let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000205"))
    let other = EditorDocument(id: id)
    other.storage.mutableString.setString("other")
    let ticket = try registry.registerPending(
      other, requestID: UUID(),
      expectedRevision: registry.workspaceRevision, metadata: .init(pinned: false),
      in: assignment, at: 1, select: false)
    let adopted = try await recovery.adoptManagedDocument(id: id)
    try other.installRecoveryAdoption(
      adopted, expectedOwnershipGeneration: other.ownershipGeneration)
    try registry.activateAdoption(ticket, receipt: adopted)
    try await recovery.persistAuthorized(other.captureAuthorizedRecovery())
    secondDocument = other
    let projection = try XCTUnwrap(registry.window(id: assignment.windowID))
    try controller.applyRegistryProjection(
      projection, revision: registry.workspaceRevision, endpointID: endpointID)
    return other
  }
  func observeUndoGroup(_ body: @escaping @MainActor () -> Void) {
    guard observers.isEmpty else {
      XCTFail("Second undo observer installation")
      return
    }
    let counter = NativeSourceCounter("undo-open notification")
    let observer = NotificationCenter.default.addObserver(
      forName: .NSUndoManagerDidOpenUndoGroup, object: document.undoManager, queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        guard counter.enter() else { return }
        body()
      }
    }
    observers = [observer]
  }
  func prepareOffscreenScroll() {
    pane.editor.setFrameSize(NSSize(width: 900, height: 650))
    let clip = pane.scroll.contentView
    clip.setBoundsSize(NSSize(width: 1, height: 1))
    clip.scroll(to: NSPoint(x: 0, y: 200))
    pane.scroll.reflectScrolledClipView(clip)
  }
  func close() {
    guard !closed else { return }
    closed = true
    routing.clear()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let ticket = closeTicket {
      closeTicket = nil
      do {
        _ = try registry.completeClose(ticket, result: .notRemoved(NativeClientFailure.cleanup))
      } catch { XCTFail("Owned synthetic registry lease cleanup failed: \(error)") }
    }
    controller.nativeSearchTestQuitState(false)
    if let token = configuration {
      configuration = nil
      document.endNativeConfiguration(token)
    }
    if let token = operation {
      operation = nil
      _ = document.finishFileOperation(token)
    }
    document.saving = false
    document.panePresentation.installing = nil
    if editingOpen {
      editingOpen = false
      document.storage.endEditing()
    }
    if pane.editor.isComposingText || pane.editor.hasMarkedText() { pane.editor.unmarkText() }
    document.composingPaneID = nil
    controller.nativeSearchTestRecording(nil, commands: [], units: 0)
    let models: [EditorDocument] = secondDocument.map { [document, $0] } ?? [document]
    for model in models {
      model.onCharactersChanged = nil
      model.canUndoRedo = nil
      for nativePane in model.panePool {
        nativePane.editor.delegate = nil
        nativePane.editor.onFocus = nil
        nativePane.editor.onTypingRunEnded = nil
        nativePane.editor.onMarkedTextUpdated = nil
        nativePane.editor.onCompositionBegan = nil
        nativePane.editor.onCompositionEnded = nil
        nativePane.editor.canFocus = nil
        nativePane.editor.canMutate = nil
        nativePane.editor.canChangeSelection = nil
        nativePane.onBoundsChanged = nil
      }
      if model.undoManager.groupingLevel <= 64 {
        for _ in 0..<64 {
          guard model.undoManager.groupingLevel > 0 else { break }
          model.undoManager.endUndoGrouping()
        }
        model.undoManager.removeAllActions()
      } else {
        XCTFail("Unexpected native undo nesting beyond bounded fixture cleanup")
      }
    }
    delegate = nil
    controller.nativeSearchTestTearDown()
    secondDocument = nil
    do { try FileManager.default.removeItem(at: directory) } catch {
      XCTFail("Owned synthetic recovery directory cleanup failed: \(error)")
    }
    for counter in [errors, typing, focus, scroll, routing.endpointCalls, routing.admissionCalls] {
      XCTAssertFalse(counter.overflow, counter.label)
    }
  }
}

// SPDX-License-Identifier: MIT
// SOURCE ONLY: append as one suffix to the accepted original declaring test file.
// Existing private fixture/counter/seed/stage helpers remain in that same file.
// B is HELD: no method, skip, pass, bare-AppKit baseline or B-to-D credit.
// Added scalar reads are instrumentation, not a claim of observational neutrality.
// No added canRedo sampling: retain only the matched original baseline and A stage.

private enum NativeRejectedDiagnosticCase: String, Encodable {
  case diagnosticG = "G"
  case diagnosticD = "D"
  case diagnosticI = "I"
  case diagnosticA = "A"
}

private enum NativeRejectedDiagnosticPhase: String, Encodable {
  case preGroup, afterBegin, insertReturnInGroup, postEnd
  case permissionEntry, controllerPermissionBefore, controllerPermissionAfter, permissionExit
  case didEntry, didExit, selectionEntry, selectionExit
}

private struct NativeRejectedDiagnosticRow: Encodable {
  let phase: NativeRejectedDiagnosticPhase
  let canUndo: Bool
  let groupingLevel: Int
  let isUndoing: Bool
  let isRedoing: Bool
  let commandCount: Int
  let units: Int
  let recordingIDEqualsDocument: Bool
  let proposal: Bool
  let textEqualsAB: Bool
  let selectedLocation: Int
  let selectedLength: Int
  let permissionCount: Int
  let didCount: Int
  let selectionCount: Int
  let refusalCount: Int
  let controllerBool: Bool?
}

private struct NativeRejectedDiagnosticEnvelope: Encodable {
  let schema: Int
  let caseID: NativeRejectedDiagnosticCase
  let captureCapacity: Int
  let captureOverflow: Bool
  let rows: [NativeRejectedDiagnosticRow]
}

@MainActor private final class NativeRejectedDiagnosticCapture {
  // 64 admitted permission callbacks x4 cells + did x2 + selection x2 = 512.
  // At most4 fixed cells (G3); 528 therefore covers every admitted cell with margin.
  static let capacity = 528
  static let encodedByteCapacity = 524_288
  let fixture: NativeSourceFixture  // Strong model owner: pane.document is unowned.
  let caseID: NativeRejectedDiagnosticCase
  let permission = NativeSourceCounter("diagnostic permission")
  let changes = NativeSourceCounter("diagnostic change")
  let selections = NativeSourceCounter("diagnostic selection")
  let refusal: NativeSourceCounter?
  private var rows: [NativeRejectedDiagnosticRow] = []
  private(set) var overflow = false
  private var emitted = false

  init(
    _ fixture: NativeSourceFixture, caseID: NativeRejectedDiagnosticCase,
    refusal: NativeSourceCounter? = nil
  ) {
    self.fixture = fixture
    self.caseID = caseID
    self.refusal = refusal
    rows.reserveCapacity(Self.capacity)
  }

  @discardableResult
  func capture(_ phase: NativeRejectedDiagnosticPhase, controllerBool: Bool? = nil) -> Bool {
    guard rows.count < Self.capacity else {
      if !overflow { XCTFail("Bounded diagnostic capture overflow") }
      overflow = true
      return false
    }
    let f = fixture
    let manager = f.document.undoManager
    let selected = f.pane.editor.selectedRange()
    rows.append(
      NativeRejectedDiagnosticRow(
        phase: phase,
        canUndo: manager.canUndo, groupingLevel: manager.groupingLevel,
        isUndoing: manager.isUndoing, isRedoing: manager.isRedoing,
        commandCount: f.controller.nativeSearchTestCommands.count,
        units: f.controller.nativeSearchTestUnits,
        recordingIDEqualsDocument: f.controller.nativeSearchTestRecordingID == f.document.id,
        proposal: f.controller.nativeSearchTestProposal,
        textEqualsAB: f.document.storage.string == "ab",
        selectedLocation: selected.location, selectedLength: selected.length,
        permissionCount: permission.count, didCount: changes.count,
        selectionCount: selections.count, refusalCount: refusal?.count ?? 0,
        controllerBool: controllerBool))
    return true
  }

  func emitOnce() {
    guard !emitted else {
      XCTFail("Second diagnostic emission")
      return
    }
    emitted = true
    let envelope = NativeRejectedDiagnosticEnvelope(
      schema: 1, caseID: caseID,
      captureCapacity: Self.capacity, captureOverflow: overflow, rows: rows)
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let bytes = try encoder.encode(envelope)
      guard bytes.count <= Self.encodedByteCapacity,
        bytes.allSatisfy({ $0 >= 32 && $0 < 127 })
      else {
        XCTFail("Diagnostic encoding exceeds finite ASCII contract")
        return
      }
      // Only fixed ASCII case/phase names and bounded scalar records, never paths/payloads.
      print(
        "NATIVE_MACRO_REJECTED_INSERTION_DIAGNOSTIC_V1 " + String(decoding: bytes, as: UTF8.self))
    } catch {
      XCTFail("Diagnostic scalar encoding failed")
    }
  }

  func assertFinite() {
    XCTAssertFalse(overflow)
    XCTAssertFalse(permission.overflow || changes.overflow || selections.overflow)
  }
}

@MainActor private final class NativeRejectedDiagnosticForwarder: NSObject, NSTextViewDelegate {
  let controller: EditorWindowController
  let trace: NativeRejectedDiagnosticCapture
  let forwardToController: Bool
  let decision: ((NSTextView, NSRange, String?, Bool) -> Bool)?
  var permission: NativeSourceCounter { trace.permission }
  var changes: NativeSourceCounter { trace.changes }
  var selections: NativeSourceCounter { trace.selections }

  init(
    controller: EditorWindowController, trace: NativeRejectedDiagnosticCapture,
    forwardToController: Bool,
    decision: ((NSTextView, NSRange, String?, Bool) -> Bool)? = nil
  ) {
    self.controller = controller
    self.trace = trace
    self.forwardToController = forwardToController
    self.decision = decision
  }

  func textView(
    _ view: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool {
    // The existing saturating64 guard fails before any unexpected entry is forwarded.
    guard permission.enter() else { return false }
    guard trace.capture(.permissionEntry) else { return false }
    guard forwardToController else {
      XCTAssertTrue(view === trace.fixture.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 0))
      XCTAssertEqual(replacementString, "X")
      trace.capture(.permissionExit)
      return false
    }
    guard trace.capture(.controllerPermissionBefore) else { return false }
    let permitted: Bool = controller.textView(
      view, shouldChangeTextIn: range,
      replacementString: replacementString)
    trace.capture(.controllerPermissionAfter, controllerBool: permitted)
    // An A decision retains the original independent rejected-path assertions verbatim.
    // I's decision checks actual input, without predicting the controller Bool.
    _ = decision?(view, range, replacementString, permitted)
    trace.capture(.permissionExit, controllerBool: permitted)
    return false
  }

  func textDidChange(_ notification: Notification) {
    guard changes.enter() else { return }
    guard trace.capture(.didEntry) else { return }
    if forwardToController { controller.textDidChange(notification) }
    trace.capture(.didExit)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard selections.enter() else { return }
    guard trace.capture(.selectionEntry) else { return }
    if forwardToController { controller.textViewDidChangeSelection(notification) }
    trace.capture(.selectionExit)
  }

  func assertFinite() {
    XCTAssertFalse(permission.overflow || changes.overflow || selections.overflow)
    XCTAssertFalse(trace.overflow)
  }
}

@MainActor private func nativeRejectedDiagnosticSetup(_ f: NativeSourceFixture, active: Bool) {
  XCTAssertTrue(f.pane.editor.undoManager === f.document.undoManager)
  XCTAssertTrue(f.pane.editor.documentUndo === f.document.undoManager)
  XCTAssertFalse(f.document.undoManager.groupsByEvent)
  XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 0, length: 0))
  XCTAssertEqual(f.document.storage.string, "ab")
  XCTAssertEqual(f.document.bookmarks.offsets, [])
  XCTAssertEqual(f.controller.nativeSearchTestCommands, [])
  XCTAssertEqual(f.controller.nativeSearchTestUnits, 0)
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, active ? f.document.id : nil)
  XCTAssertFalse(f.controller.nativeSearchTestProposal)
}

@MainActor final class NativeMacroRejectedInsertionDiagnosticTests: XCTestCase {
  func testGEmptyManagedGroupRecordingInactive() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: false)
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    nativeRejectedDiagnosticSetup(f, active: false)
    let trace = NativeRejectedDiagnosticCapture(f, caseID: .diagnosticG)
    // No insertion or replacement delegate in G. Callback counters are uninstalled slots.
    // Same original checkpoint read, after setup and immediately before sampled group.
    XCTAssertFalse(f.document.undoManager.canUndo || f.document.undoManager.canRedo)
    trace.capture(.preGroup)
    do {
      f.document.undoManager.beginUndoGrouping()
      defer { f.document.undoManager.endUndoGrouping() }
      trace.capture(.afterBegin)
    }
    trace.capture(.postEnd)
    trace.emitOnce()
    XCTAssertEqual(f.document.storage.string, "ab")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
    XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
    trace.assertFinite()
  }

  func testDRejectedDocumentTextViewRecordingInactiveWithoutControllerForwarding() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: false)
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    nativeRejectedDiagnosticSetup(f, active: false)
    let trace = NativeRejectedDiagnosticCapture(f, caseID: .diagnosticD)
    let spy = NativeRejectedDiagnosticForwarder(
      controller: f.controller, trace: trace,
      forwardToController: false)
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    XCTAssertFalse(f.document.undoManager.canUndo || f.document.undoManager.canRedo)
    trace.capture(.preGroup)
    do {
      f.document.undoManager.beginUndoGrouping()
      defer { f.document.undoManager.endUndoGrouping() }
      trace.capture(.afterBegin)
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
      trace.capture(.insertReturnInGroup)
    }
    trace.capture(.postEnd)
    trace.emitOnce()
    XCTAssertEqual(spy.permission.count, 1)
    XCTAssertEqual(spy.changes.count, 0)
    XCTAssertEqual(f.document.storage.string, "ab")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
    XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
    spy.assertFinite()
  }

  func testIRejectedForwardedDocumentTextViewRecordingInactive() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: false)
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    nativeRejectedDiagnosticSetup(f, active: false)
    let trace = NativeRejectedDiagnosticCapture(f, caseID: .diagnosticI)
    let spy = NativeRejectedDiagnosticForwarder(
      controller: f.controller, trace: trace,
      forwardToController: true
    ) { view, range, text, _ in
      XCTAssertTrue(view === f.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 0))
      XCTAssertEqual(text, "X")
      return false
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    XCTAssertFalse(f.document.undoManager.canUndo || f.document.undoManager.canRedo)
    trace.capture(.preGroup)
    do {
      f.document.undoManager.beginUndoGrouping()
      defer { f.document.undoManager.endUndoGrouping() }
      trace.capture(.afterBegin)
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
      trace.capture(.insertReturnInGroup)
    }
    trace.capture(.postEnd)
    trace.emitOnce()
    XCTAssertEqual(spy.permission.count, 1)
    XCTAssertEqual(spy.changes.count, 0)
    XCTAssertEqual(f.document.storage.string, "ab")
    XCTAssertEqual(f.document.bookmarks.offsets, [])
    XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
    spy.assertFinite()
  }

  func testAOriginalRejectedFallbackInsertionRecordingActiveWithScalarDiagnostics() async throws {
    let f = try await NativeSourceFixture()
    defer { f.close() }
    try macroSeed(f, text: "ab", bookmarks: [], active: true)
    f.pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    nativeRejectedDiagnosticSetup(f, active: true)
    let refused = NativeSourceCounter("forwarded permission then false")
    let trace = NativeRejectedDiagnosticCapture(f, caseID: .diagnosticA, refusal: refused)
    let spy = NativeRejectedDiagnosticForwarder(
      controller: f.controller, trace: trace,
      forwardToController: true
    ) { view, range, text, permitted in
      guard refused.enter() else { return false }
      XCTAssertTrue(view === f.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 0))
      XCTAssertEqual(text, "X")
      XCTAssertFalse(f.controller.nativeSearchTestProposal)
      XCTAssertTrue(permitted)
      return false
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    XCTAssertFalse(f.document.undoManager.canUndo || f.document.undoManager.canRedo)
    trace.capture(.preGroup)
    do {
      f.document.undoManager.beginUndoGrouping()
      defer { f.document.undoManager.endUndoGrouping() }
      trace.capture(.afterBegin)
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
      trace.capture(.insertReturnInGroup)
    }
    trace.capture(.postEnd)
    // Emission precedes the original post-group assertions and consumer oracle,
    // preserving the scalar record even if the retained known RED recurs.
    trace.emitOnce()
    XCTAssertEqual(refused.count, 1)
    XCTAssertEqual(spy.permission.count, 1)
    XCTAssertEqual(spy.changes.count, 0)
    try macroStage(
      f, text: "ab", bookmarks: [], commands: [], units: 0,
      start: "ab", recording: f.document.id, canUndo: false, canRedo: false)
    XCTAssertFalse(f.controller.nativeSearchTestProposal)
    XCTAssertFalse(refused.overflow)
    spy.assertFinite()
  }
}

// SPDX-License-Identifier: MIT
// SOURCE ONLY: append once to the reviewed declaring fixture; no receipt API seam.
// Original whole F/U/R and every original chronology assertion remain in the prefix.
// These deliberately foreign continuations test approved writes, not native origin.
private enum NativeApprovedViewCase: String {
  case matching, finalFalse, expired, mismatched, extraPendingNil, pendingABA
}

@MainActor private func approvedViewCharacterWrite(
  _ storage: DocumentCommitTextStorage, view: DocumentTextView,
  replacement: String, priorSequence: UInt64
) {
  // Caller opened the real batch before permission. Sample before native fixing.
  storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: replacement)
  let stamp = storage.nativeMacroTestLastPrimitiveCommit
  XCTAssertEqual(stamp?.kind, .characters)
  XCTAssertEqual(stamp?.sequence, priorSequence + 1)
  XCTAssertEqual(stamp?.sequenceExhausted, false)
  XCTAssertEqual(stamp?.range, NSRange(location: 0, length: 3))
  XCTAssertEqual(stamp?.replacementUTF16Count, 3)
  XCTAssertEqual(stamp?.beforeUTF16Count, 3)
  XCTAssertEqual(stamp?.afterUTF16Count, 3)
  XCTAssertEqual(stamp?.changedCharacters, true)
  XCTAssertEqual(stamp?.backingReentry, false)
  XCTAssertEqual(storage.string, replacement)
  // Processing ends normally; no assumed last slot or callback multiplicity after it.
  storage.endEditing()
  view.didChangeText()
}

@MainActor private func runApprovedViewCase(_ selectedCase: NativeApprovedViewCase) async throws {
  let f = try await NativeSourceFixture(routingCallbackBudget: 256)
  defer { f.close() }
  try macroSeed(f, text: "😀x", bookmarks: [], active: true)
  f.observeSinks()
  let storage = try XCTUnwrap(f.document.storage as? DocumentCommitTextStorage)
  let window = try XCTUnwrap(f.controller.window)
  XCTAssertTrue(f.pane.isAttached)
  XCTAssertTrue(f.pane.editor.window === window)
  XCTAssertTrue(f.pane.editor.textStorage === storage)
  XCTAssertTrue(f.pane.editor.documentUndo === f.document.undoManager)
  guard f.pane.isAttached, f.pane.editor.window === window,
    f.pane.editor.textStorage === storage,
    f.pane.editor.documentUndo === f.document.undoManager
  else { throw NativeClientFailure.unavailable }
  let abaValue = try DocumentBookmarks(offsets: [0], in: "😀y")
  var inContinuation = false
  var controllerPermission: Bool?
  var finalPermission: Bool?
  var callbackBookkeepingChanged = false
  var foreignCalls = 0
  var foreignWasUndoing = false
  var attemptedWrite = false
  var usablePrimitive = true
  var decisionSequence: UInt64?
  let spy = ChronologyForwarder(controller: f.controller) { view, range, text, permitted in
    XCTAssertTrue(view === f.pane.editor)
    XCTAssertEqual(range, NSRange(location: 0, length: 3))
    if !inContinuation {
      XCTAssertEqual(text, "😀y")
      XCTAssertTrue(permitted, "Real explicit prefix permission prerequisite")
      return permitted
    }
    XCTAssertEqual(text, "😀z")
    XCTAssertTrue(permitted, "Real controller permission prerequisite")
    XCTAssertTrue(f.document.undoManager.isUndoing)
    XCTAssertFalse(f.controller.nativeSearchTestProposal, "Explicit preparation has ended")
    controllerPermission = permitted
    let oldMutation = f.document.closeMutationGeneration
    switch selectedCase {
    case .extraPendingNil:
      XCTAssertNil(f.document.pendingBookmarks)
      f.document.pendingBookmarks = nil  // Actual nil-to-nil setter, after real C.
      callbackBookkeepingChanged = f.document.closeMutationGeneration != oldMutation
    case .pendingABA:
      XCTAssertNil(f.document.pendingBookmarks)
      f.document.pendingBookmarks = abaValue
      let middleMutation = f.document.closeMutationGeneration
      f.document.pendingBookmarks = nil
      callbackBookkeepingChanged =
        middleMutation != oldMutation
        && f.document.closeMutationGeneration != middleMutation
    case .matching, .finalFalse, .expired, .mismatched:
      break
    }
    return selectedCase == .finalFalse ? false : permitted
  }
  let previous = f.pane.editor.delegate
  f.pane.editor.delegate = spy
  defer {
    f.pane.editor.delegate = previous
    withExtendedLifetime(spy) {}
  }
  let prefixSource = try macroReplaceWhole(f, before: "😀x", after: "😀y")
  let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
  let expectedCommandB: MacroCommand = .replace(location: 0, length: 3, text: "😀z")
  XCTAssertEqual(f.document.storage.string, "😀y")
  XCTAssertEqual(f.document.bookmarks.offsets, [])
  XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
  XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, f.document.id)
  XCTAssertEqual(
    f.controller.recordingSnapshot(named: "Approved prefix")?.commands, [expectedForward])
  let captured = f.controller.nativeMacroTestIntegrityState()
  XCTAssertNotNil(captured.epoch)
  XCTAssertTrue(captured.complete && captured.active && !captured.exhausted)
  XCTAssertNil(captured.reason)
  XCTAssertEqual(spy.permission.count, 1)
  XCTAssertEqual(spy.changes.count, 1)
  guard f.document.storage.string == "😀y",
    f.controller.nativeSearchTestCommands == [expectedForward],
    f.controller.nativeSearchTestUnits == 3,
    captured.epoch != nil, captured.complete, captured.active, !captured.exhausted,
    captured.reason == nil, spy.permission.count == 1, spy.changes.count == 1
  else { throw NativeClientFailure.unavailable }  // Failed positive: no later guard credit.
  XCTAssertTrue(f.document.undoManager.canUndo, "Original prefix undo history remains")
  let beforeRevision = f.document.editRevision
  let ownership = f.document.ownershipGeneration

  // A real new undo action above the prefix; preserve all preceding undo history.
  f.document.undoManager.beginUndoGrouping()
  f.document.undoManager.registerUndo(withTarget: f.pane.editor) { view in
    foreignCalls += 1
    guard foreignCalls == 1 else {
      XCTFail("Repeated foreign undo continuation")
      return
    }
    foreignWasUndoing = f.document.undoManager.isUndoing
    inContinuation = true
    defer { inContinuation = false }
    storage.beginEditing()
    let sequence = storage.nativeMacroTestPrimitiveSequence
    guard !storage.nativeMacroTestSequenceExhausted, sequence < UInt64.max else {
      usablePrimitive = false
      storage.endEditing()
      XCTFail("Real primitive prerequisite unavailable")
      return
    }
    decisionSequence = sequence
    let allowed = view.shouldChangeText(
      in: NSRange(location: 0, length: 3),
      replacementString: "😀z")
    finalPermission = allowed
    if selectedCase == .finalFalse || selectedCase == .expired || !allowed {
      storage.endEditing()
      return
    }
    attemptedWrite = true
    let actualReplacement = selectedCase == .mismatched ? "😀q" : "😀z"
    approvedViewCharacterWrite(
      storage, view: view,
      replacement: actualReplacement, priorSequence: sequence)
  }
  f.document.undoManager.endUndoGrouping()
  f.document.undoManager.undo()

  XCTAssertEqual(foreignCalls, 1)
  XCTAssertTrue(foreignWasUndoing, "Real undo invocation prerequisite")
  XCTAssertEqual(controllerPermission, true)
  XCTAssertEqual(finalPermission, selectedCase == .finalFalse ? false : true)
  XCTAssertTrue(usablePrimitive)
  XCTAssertEqual(spy.permission.count, 2)
  guard foreignCalls == 1, foreignWasUndoing, controllerPermission == true, usablePrimitive,
    finalPermission == (selectedCase == .finalFalse ? false : true),
    spy.permission.count == 2
  else { throw NativeClientFailure.unavailable }  // Actual decision never reached: NO_RED.
  if selectedCase == .extraPendingNil || selectedCase == .pendingABA {
    XCTAssertTrue(callbackBookkeepingChanged, "Genuine extra setter/ABA prerequisite")
    XCTAssertNil(f.document.pendingBookmarks)
    guard callbackBookkeepingChanged else { throw NativeClientFailure.unavailable }
  }

  if selectedCase == .finalFalse || selectedCase == .expired {
    XCTAssertFalse(attemptedWrite)
    XCTAssertEqual(f.document.storage.string, "😀y")
    XCTAssertEqual(f.document.editRevision, beforeRevision)
    XCTAssertEqual(storage.nativeMacroTestPrimitiveSequence, decisionSequence)
    XCTAssertEqual(spy.changes.count, 1)
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
    XCTAssertEqual(
      f.controller.recordingSnapshot(named: "No write at return")?.commands, [expectedForward])
    let afterReturn = f.controller.nativeMacroTestIntegrityState()
    XCTAssertEqual(afterReturn.epoch, captured.epoch)
    XCTAssertEqual(afterReturn.serial, captured.serial)
    XCTAssertTrue(afterReturn.complete)
    XCTAssertNil(afterReturn.reason)
    XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
    XCTAssertFalse(f.document.undoManager.isUndoing || f.document.undoManager.isRedoing)
    // A distinct raw mutation after the real history invocation has returned.
    storage.beginEditing()
    let rawSequence = storage.nativeMacroTestPrimitiveSequence
    guard !storage.nativeMacroTestSequenceExhausted, rawSequence < UInt64.max else {
      storage.endEditing()
      throw NativeClientFailure.unavailable
    }
    approvedViewCharacterWrite(
      storage, view: f.pane.editor,
      replacement: "😀z", priorSequence: rawSequence)
  } else {
    XCTAssertTrue(attemptedWrite, "Actual changed backing prerequisite")
    guard attemptedWrite else { throw NativeClientFailure.unavailable }
  }

  let expectedText = selectedCase == .mismatched ? "😀q" : "😀z"
  XCTAssertEqual(f.document.storage.string, expectedText)
  XCTAssertGreaterThan(f.document.editRevision, beforeRevision)
  XCTAssertEqual(f.document.ownershipGeneration, ownership)
  XCTAssertEqual(f.document.bookmarks.offsets, [])
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, f.document.id)
  XCTAssertEqual(spy.changes.count, 2)
  XCTAssertFalse(prefixSource.source.isCurrent(expected: prefixSource.credential))
  let finished = f.controller.nativeMacroTestIntegrityState()
  XCTAssertEqual(finished.epoch, captured.epoch)
  XCTAssertTrue(finished.active && !finished.exhausted)
  if selectedCase == .matching {
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward, expectedCommandB])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 6)
    XCTAssertGreaterThan(finished.serial, captured.serial)
    XCTAssertTrue(finished.complete)
    XCTAssertNil(finished.reason)
    XCTAssertEqual(
      f.controller.recordingSnapshot(named: "Approved foreign write")?.commands,
      [expectedForward, expectedCommandB])
    let macro = EditorMacro(
      name: "Literal approved replay", commands: f.controller.nativeSearchTestCommands)
    XCTAssertEqual(try MacroPlayer.replay(macro, on: "😀x"), "😀z")
  } else {
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
    XCTAssertEqual(finished.serial, captured.serial)
    XCTAssertFalse(finished.complete)
    XCTAssertEqual(finished.reason, .unsupportedCharacterMutation)
    XCTAssertNil(f.controller.recordingSnapshot(named: "Unsupported write"))
    let prefix = EditorMacro(
      name: "Preserved prefix", commands: f.controller.nativeSearchTestCommands)
    XCTAssertEqual(try MacroPlayer.replay(prefix, on: "😀x"), "😀y")
  }
  let currentSource = try f.source()
  let currentCredential = try currentSource.inspect()
  XCTAssertTrue(currentSource.isCurrent(expected: currentCredential))
  XCTAssertTrue(f.controller.nativeSearchTestCurrent === f.document)
  XCTAssertTrue(f.controller.window === window && f.pane.editor.window === window)
  XCTAssertTrue(f.pane.editor.textStorage === storage && f.pane.isAttached)
  XCTAssertFalse(f.controller.nativeSearchTestProposal)
  XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
  XCTAssertFalse(f.document.undoManager.isUndoing || f.document.undoManager.isRedoing)
  XCTAssertTrue(f.document.undoManager.canUndo, "Original prefix history was not cleared")
  XCTAssertEqual(f.errors.count, 0)
  XCTAssertFalse(f.errors.overflow)
  XCTAssertFalse(f.routing.endpointCalls.overflow || f.routing.admissionCalls.overflow)
  XCTAssertEqual(f.routing.endpointCalls.maximum, 256)
  XCTAssertGreaterThan(f.routing.endpointCalls.count, 0)
  XCTAssertGreaterThan(f.routing.admissionCalls.count, 0)
  spy.assertFinite()
  print(
    "APPROVED_VIEW_CASE \(selectedCase.rawValue) permission=\(spy.permission.count) changes=\(spy.changes.count) foreign=\(foreignCalls) routing=\(f.routing.endpointCalls.count)/256"
  )
}

@MainActor final class NativeMacroApprovedViewReceiptTests: XCTestCase {
  func testForeignExactApprovedWriteAppendsOnceWithoutCallerAttribution() async throws {
    try await runApprovedViewCase(.matching)
  }
  func testFalseOuterDecisionCannotApproveLaterRawWrite() async throws {
    try await runApprovedViewCase(.finalFalse)
  }
  func testTrueNoWriteDecisionExpiresWhenHistoryInvocationReturns() async throws {
    try await runApprovedViewCase(.expired)
  }
  func testTrueDecisionCannotApproveDifferentReplacementPayload() async throws {
    try await runApprovedViewCase(.mismatched)
  }
  func testExtraPendingNilAfterControllerPermissionBurnsApproval() async throws {
    try await runApprovedViewCase(.extraPendingNil)
  }
  func testPendingNilValueNilABAPreservesTextButNotRecordingApproval() async throws {
    try await runApprovedViewCase(.pendingABA)
  }
}

// SPDX-License-Identifier: MIT
// Test-only actual-entry and exact delegate-payload discriminators; no receipt issuance seam.
private enum ApprovedBarrierTestFailure: Error { case intentional }

@MainActor private func runApprovedBarrierBoundary(throwAtLeaf: Bool) throws {
  let initial = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertTrue(initial.contextInstalled)
  XCTAssertEqual(initial.broker, 0)
  XCTAssertEqual(initial.context, 0)
  XCTAssertFalse(initial.overflow)
  guard initial.contextInstalled, initial.broker == 0, initial.context == 0, !initial.overflow
  else { throw NativeClientFailure.unavailable }
  var calls = 0
  var deepest = 0
  func enter(_ depth: Int) throws {
    try EditorWindowController.withNativeMacroProcessingBarrier {
      calls += 1
      deepest = max(deepest, depth)
      let actual = EditorWindowController.nativeApprovedTestBarrierState()
      XCTAssertLessThanOrEqual(
        actual.broker + actual.context, 64,
        "Actual broker/context retained entries share the accepted capacity")
      if depth <= 32 {
        XCTAssertEqual(actual.broker, depth)
        XCTAssertEqual(actual.context, depth)
        XCTAssertFalse(actual.overflow)
      } else {
        XCTAssertEqual(actual.broker + actual.context, 64)
        XCTAssertTrue(actual.overflow, "Rejected pair uses the real context overflow barrier")
      }
      if depth < 33 {
        try enter(depth + 1)
      } else if throwAtLeaf {
        throw ApprovedBarrierTestFailure.intentional
      }
    }
  }
  if throwAtLeaf {
    do {
      try enter(1)
      XCTFail("Actual throwing body must rethrow")
    } catch ApprovedBarrierTestFailure.intentional {}
  } else {
    try enter(1)
  }
  XCTAssertEqual(calls, 33, "Every real callback body runs once")
  XCTAssertEqual(deepest, 33)
  let after = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertEqual(after.broker, 0)
  XCTAssertEqual(after.context, 0)
  XCTAssertFalse(after.overflow)
  var freshCalls = 0
  EditorWindowController.withNativeMacroProcessingBarrier {
    freshCalls += 1
    let fresh = EditorWindowController.nativeApprovedTestBarrierState()
    XCTAssertEqual(fresh.broker, 1)
    XCTAssertEqual(fresh.context, 1)
    XCTAssertFalse(fresh.overflow)
  }
  XCTAssertEqual(freshCalls, 1)
  let final = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertEqual(final.broker + final.context, 0)
  XCTAssertFalse(final.overflow)
  print(
    "APPROVED_BARRIER depth=\(deepest) bodies=\(calls) throwing=\(throwAtLeaf) retained=\(final.broker + final.context)"
  )
}

@MainActor final class NativeMacroApprovedViewCapacityTests: XCTestCase {
  func testThirtyThirdRealProcessingBarrierDoesNotExceedCombinedCapacity() throws {
    try runApprovedBarrierBoundary(throwAtLeaf: false)
  }
  func testRejectedPairRethrowsOnceAndRestoresActualStacks() throws {
    try runApprovedBarrierBoundary(throwAtLeaf: true)
  }
}

@MainActor private final class ApprovedPayloadForwarder: NSObject, NSTextViewDelegate {
  let controller: EditorWindowController
  let should: (NSTextView, NSRange, String?) -> Bool
  let permission = NativeSourceCounter("approved family permission")
  let changes = NativeSourceCounter("approved family change")
  let selections = NativeSourceCounter("approved family selection")
  init(
    controller: EditorWindowController,
    should: @escaping (NSTextView, NSRange, String?) -> Bool
  ) {
    self.controller = controller
    self.should = should
  }
  func textView(
    _ view: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool {
    guard permission.enter() else { return false }
    return should(view, range, replacementString)
  }
  func textDidChange(_ notification: Notification) {
    guard changes.enter() else { return }
    controller.textDidChange(notification)
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard selections.enter() else { return }
    controller.textViewDidChangeSelection(notification)
  }
}

@MainActor private func runApprovedFamilyPayload(canonicalDifferent: Bool) async throws {
  let f = try await NativeSourceFixture(routingCallbackBudget: 256)
  defer { f.close() }
  try macroSeed(f, text: "😀x", bookmarks: [], active: true)
  f.observeSinks()
  let storage = try XCTUnwrap(f.document.storage as? DocumentCommitTextStorage)
  let window = try XCTUnwrap(f.controller.window)
  let composed = "\u{00E9}x"
  let decomposed = "e\u{0301}x"
  XCTAssertEqual(composed, decomposed, "Canonical equivalence is the discriminator setup")
  XCTAssertEqual(Array(composed.utf16), [233, 120])
  XCTAssertEqual(Array(decomposed.utf16), [101, 769, 120])
  XCTAssertFalse(composed.utf16.elementsEqual(decomposed.utf16))
  var foreign = false
  var familyReached = false
  var permitted: Bool?
  var finalPermission: Bool?
  var calls = 0
  var wrote = false
  var sequence: UInt64?
  let spy = ApprovedPayloadForwarder(controller: f.controller) { view, range, text in
    guard !foreign else {
      let sample = f.controller.nativeApprovedTestFamily(f.pane.editor)
      XCTAssertTrue(view === f.pane.editor)
      XCTAssertEqual(range, NSRange(location: 0, length: 3))
      XCTAssertEqual(text.map { Array($0.utf16) }, [233, 120])
      XCTAssertEqual(sample?.replacementUTF16, [233, 120])
      XCTAssertEqual(sample?.range, NSRange(location: 0, length: 3))
      XCTAssertEqual(sample?.currentInvocation, true)
      XCTAssertEqual(sample?.edgeCount, 0)
      XCTAssertEqual(sample?.primitiveSequence, sequence)
      familyReached =
        sample != nil && sample?.replacementUTF16 == [233, 120]
        && sample?.range == NSRange(location: 0, length: 3)
        && sample?.currentInvocation == true && sample?.edgeCount == 0
        && sample?.primitiveSequence == sequence
      // Genuine C delegate entry uses a different immutable payload only in the negative case.
      let forwarded = canonicalDifferent ? decomposed : composed
      let result = f.controller.textView(
        view, shouldChangeTextIn: range,
        replacementString: forwarded)
      permitted = result
      return result
    }
    return f.controller.textView(view, shouldChangeTextIn: range, replacementString: text)
  }
  let oldDelegate = f.pane.editor.delegate
  f.pane.editor.delegate = spy
  defer {
    f.pane.editor.delegate = oldDelegate
    withExtendedLifetime(spy) {}
  }
  let prefixSource = try macroReplaceWhole(f, before: "😀x", after: "😀y")
  let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
  let expectedCommandB: MacroCommand = .replace(location: 0, length: 3, text: composed)
  let prefix = f.controller.nativeMacroTestIntegrityState()
  XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
  XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
  XCTAssertEqual(
    f.controller.recordingSnapshot(named: "Exact family prefix")?.commands, [expectedForward])
  XCTAssertTrue(prefix.complete && prefix.active && !prefix.exhausted)
  XCTAssertNil(prefix.reason)
  XCTAssertTrue(f.pane.editor.window === window && f.pane.editor.textStorage === storage)
  XCTAssertTrue(f.pane.editor.documentUndo === f.document.undoManager)
  guard f.controller.nativeSearchTestCommands == [expectedForward],
    f.controller.nativeSearchTestUnits == 3, prefix.complete, prefix.active,
    !prefix.exhausted, prefix.reason == nil,
    f.pane.editor.window === window, f.pane.editor.textStorage === storage,
    f.pane.editor.documentUndo === f.document.undoManager
  else { throw NativeClientFailure.unavailable }
  let revision = f.document.editRevision
  let ownership = f.document.ownershipGeneration
  f.document.undoManager.beginUndoGrouping()
  f.document.undoManager.registerUndo(withTarget: f.pane.editor) { view in
    calls += 1
    guard calls == 1 else {
      XCTFail("Repeated real undo continuation")
      return
    }
    XCTAssertTrue(f.document.undoManager.isUndoing)
    foreign = true
    defer { foreign = false }
    storage.beginEditing()
    let current = storage.nativeMacroTestPrimitiveSequence
    guard !storage.nativeMacroTestSequenceExhausted, current < UInt64.max else {
      storage.endEditing()
      XCTFail("Actual primitive prerequisite unavailable")
      return
    }
    sequence = current
    let result = view.shouldChangeText(
      in: NSRange(location: 0, length: 3),
      replacementString: composed)
    finalPermission = result
    guard result else {
      storage.endEditing()
      return
    }
    wrote = true
    storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: composed)
    let stamp = storage.nativeMacroTestLastPrimitiveCommit
    XCTAssertEqual(stamp?.kind, .characters)
    XCTAssertEqual(stamp?.sequence, current + 1)
    XCTAssertEqual(stamp?.sequenceExhausted, false)
    XCTAssertEqual(stamp?.range, NSRange(location: 0, length: 3))
    XCTAssertEqual(stamp?.replacementUTF16Count, 2)
    XCTAssertEqual(stamp?.beforeUTF16Count, 3)
    XCTAssertEqual(stamp?.afterUTF16Count, 2)
    XCTAssertEqual(stamp?.changedCharacters, true)
    XCTAssertEqual(stamp?.backingReentry, false)
    XCTAssertEqual(Array(storage.string.utf16), [233, 120])
    storage.endEditing()
    view.didChangeText()
  }
  f.document.undoManager.endUndoGrouping()
  f.document.undoManager.undo()
  XCTAssertEqual(calls, 1)
  XCTAssertTrue(familyReached, "Actual installed history/decision family prerequisite")
  XCTAssertEqual(permitted, true)
  XCTAssertEqual(finalPermission, true)
  XCTAssertTrue(wrote)
  guard calls == 1, familyReached, permitted == true, finalPermission == true, wrote
  else { throw NativeClientFailure.unavailable }
  XCTAssertEqual(Array(f.document.storage.string.utf16), [233, 120])
  XCTAssertGreaterThan(f.document.editRevision, revision)
  XCTAssertEqual(f.document.ownershipGeneration, ownership)
  XCTAssertEqual(f.document.bookmarks.offsets, [])
  XCTAssertEqual(spy.permission.count, 2)
  XCTAssertEqual(spy.changes.count, 2)
  XCTAssertFalse(prefixSource.source.isCurrent(expected: prefixSource.credential))
  let after = f.controller.nativeMacroTestIntegrityState()
  XCTAssertEqual(after.epoch, prefix.epoch)
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, f.document.id)
  if canonicalDifferent {
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
    XCTAssertEqual(after.serial, prefix.serial)
    XCTAssertFalse(after.complete)
    XCTAssertEqual(after.reason, .unsupportedCharacterMutation)
    XCTAssertNil(f.controller.recordingSnapshot(named: "Different UTF16 family"))
  } else {
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward, expectedCommandB])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 5)
    XCTAssertGreaterThan(after.serial, prefix.serial)
    XCTAssertTrue(after.complete)
    XCTAssertNil(after.reason)
    XCTAssertEqual(
      f.controller.recordingSnapshot(named: "Exact UTF16 family")?.commands,
      [expectedForward, expectedCommandB])
  }
  let freshSource = try f.source()
  let credential = try freshSource.inspect()
  XCTAssertTrue(freshSource.isCurrent(expected: credential))
  XCTAssertTrue(f.controller.window === window && f.pane.editor.window === window)
  XCTAssertTrue(f.pane.isAttached && f.pane.editor.textStorage === storage)
  XCTAssertFalse(f.controller.nativeSearchTestProposal)
  XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
  XCTAssertFalse(f.document.undoManager.isUndoing || f.document.undoManager.isRedoing)
  XCTAssertTrue(f.document.undoManager.canUndo, "Original prefix history preserved")
  XCTAssertEqual(f.errors.count, 0)
  XCTAssertFalse(
    f.errors.overflow || f.routing.endpointCalls.overflow || f.routing.admissionCalls.overflow)
  XCTAssertFalse(spy.permission.overflow || spy.changes.overflow || spy.selections.overflow)
  print(
    "APPROVED_FAMILY canonicalDifferent=\(canonicalDifferent) realFamily=\(familyReached) changes=\(spy.changes.count) routing=\(f.routing.endpointCalls.count)/256"
  )
}

@MainActor final class NativeMacroApprovedViewPayloadTests: XCTestCase {
  func testExactUTF16DelegateRequestAcknowledgesActualBookkeeping() async throws {
    try await runApprovedFamilyPayload(canonicalDifferent: false)
  }
  func testCanonicalEquivalentDifferentUTF16DelegateCannotAuthenticateBookkeeping() async throws {
    try await runApprovedFamilyPayload(canonicalDifferent: true)
  }
}

// SPDX-License-Identifier: MIT
// SOURCE ONLY: two actual controller entry controls, no frame/permit issuer seam.
@MainActor private final class ExplicitCapacityAdmissionLedger {
  private(set) var count = 0
  private(set) var overflow = false
  private(set) var sawFrame = false
  private(set) var maximum = 0
  func sample() {
    guard count < 256 else {
      overflow = true
      XCTFail("Actual admission observation exceeded immutable256 bound")
      return
    }
    count += 1
    let actual = EditorWindowController.nativeApprovedTestBarrierState()
    let active = EditorWindowController.nativeApprovedTestHasActiveExplicitFrame()
    sawFrame = sawFrame || active
    maximum = max(maximum, actual.broker + actual.context)
    XCTAssertLessThanOrEqual(
      actual.broker + actual.context, 64,
      "Real explicit entry must not exceed shared retained-entry capacity")
  }
}

@MainActor private func enterExplicitCapacityDepth(
  _ depth: Int, target: () throws -> Void
) throws {
  try EditorWindowController.withNativeMacroProcessingBarrier {
    let actual = EditorWindowController.nativeApprovedTestBarrierState()
    XCTAssertEqual(actual.broker, depth)
    XCTAssertEqual(actual.context, depth)
    XCTAssertFalse(actual.overflow)
    XCTAssertLessThanOrEqual(actual.broker + actual.context, 64)
    if depth < 32 {
      try enterExplicitCapacityDepth(depth + 1, target: target)
    } else {
      try target()
    }
  }
}

@MainActor private func assertExplicitCapacityCleanup(_ f: NativeSourceFixture) {
  let after = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertEqual(after.broker, 0)
  XCTAssertEqual(after.context, 0)
  XCTAssertFalse(after.overflow)
  XCTAssertFalse(EditorWindowController.nativeApprovedTestHasActiveExplicitFrame())
  XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
  XCTAssertFalse(f.document.undoManager.isUndoing || f.document.undoManager.isRedoing)
  XCTAssertEqual(f.errors.count, 0)
  XCTAssertFalse(f.errors.overflow)
  XCTAssertFalse(f.routing.endpointCalls.overflow || f.routing.admissionCalls.overflow)
  var bodyCalls = 0
  EditorWindowController.withNativeMacroProcessingBarrier {
    bodyCalls += 1
    let fresh = EditorWindowController.nativeApprovedTestBarrierState()
    XCTAssertEqual(fresh.broker, 1)
    XCTAssertEqual(fresh.context, 1)
    XCTAssertFalse(fresh.overflow)
  }
  XCTAssertEqual(bodyCalls, 1)
  let final = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertEqual(final.broker + final.context, 0)
  XCTAssertFalse(final.overflow)
}

@MainActor private func runActualExplicitCapacity(controlled: Bool) async throws {
  let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
  let expectedCommandG: MacroCommand =
    controlled
    ? .replace(location: 3, length: 0, text: "z")
    : .replace(location: 0, length: 3, text: "😀z")
  // Separate genuine shallow positive; it never supplies the boundary's authority.
  do {
    let f = try await NativeSourceFixture(routingCallbackBudget: 256)
    defer { f.close() }
    try macroSeed(f, text: "😀x", bookmarks: [0], active: true)
    f.observeSinks()
    let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in
      XCTAssertTrue(permitted)
      return permitted
    }
    let previous = f.pane.editor.delegate
    f.pane.editor.delegate = spy
    defer {
      f.pane.editor.delegate = previous
      withExtendedLifetime(spy) {}
    }
    _ = try macroReplaceWhole(f, before: "😀x", after: "😀y")
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
    let initial = f.controller.nativeMacroTestIntegrityState()
    guard initial.complete, initial.active, initial.reason == nil, !initial.exhausted,
      spy.permission.count == 1, spy.changes.count == 1
    else { throw NativeClientFailure.unavailable }
    f.pane.editor.setSelectedRange(NSRange(location: 3, length: 0))
    var positive = false
    try EditorWindowController.withNativeMacroProcessingBarrier {
      if controlled {
        f.pane.editor.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        positive = f.document.storage.string == "😀yz"
      } else {
        let source = try f.source()
        let credential = try source.inspect()
        f.document.undoManager.beginUndoGrouping()
        defer { f.document.undoManager.endUndoGrouping() }
        positive = source.replace(expected: credential, source: "😀y", replacement: "😀z")
      }
    }
    XCTAssertTrue(positive, "Real shallow entry must succeed before boundary credit")
    XCTAssertEqual(f.document.storage.string, controlled ? "😀yz" : "😀z")
    XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward, expectedCommandG])
    XCTAssertEqual(f.controller.nativeSearchTestUnits, controlled ? 4 : 6)
    XCTAssertEqual(spy.permission.count, 2)
    XCTAssertEqual(spy.changes.count, 2)
    let complete = f.controller.nativeMacroTestIntegrityState()
    XCTAssertTrue(complete.complete)
    XCTAssertNil(complete.reason)
    guard positive, complete.complete, complete.reason == nil,
      f.controller.nativeSearchTestCommands == [expectedForward, expectedCommandG],
      f.controller.nativeSearchTestUnits == (controlled ? 4 : 6),
      spy.permission.count == 2, spy.changes.count == 2
    else { throw NativeClientFailure.unavailable }  // No boundary credit after failed positive.
    spy.assertFinite()
    assertExplicitCapacityCleanup(f)
  }

  let f = try await NativeSourceFixture(routingCallbackBudget: 256)
  defer { f.close() }
  let empty = EditorWindowController.nativeApprovedTestBarrierState()
  XCTAssertTrue(empty.contextInstalled)
  XCTAssertEqual(empty.broker + empty.context, 0)
  XCTAssertFalse(empty.overflow)
  guard empty.contextInstalled, empty.broker + empty.context == 0, !empty.overflow
  else { throw NativeClientFailure.unavailable }
  try macroSeed(f, text: "😀x", bookmarks: [0], active: true)
  f.observeSinks()
  let spy = ChronologyForwarder(controller: f.controller) { _, _, _, permitted in
    XCTAssertTrue(permitted)
    return permitted
  }
  let previous = f.pane.editor.delegate
  f.pane.editor.delegate = spy
  defer {
    f.pane.editor.delegate = previous
    withExtendedLifetime(spy) {}
  }
  _ = try macroReplaceWhole(f, before: "😀x", after: "😀y")
  let before = f.controller.nativeMacroTestIntegrityState()
  guard before.complete, before.active, before.reason == nil, !before.exhausted,
    f.controller.nativeSearchTestCommands == [expectedForward],
    f.controller.nativeSearchTestUnits == 3,
    spy.permission.count == 1, spy.changes.count == 1
  else { throw NativeClientFailure.unavailable }
  f.pane.editor.setSelectedRange(NSRange(location: 3, length: 0))
  let selection = f.pane.editor.selectedRange()
  let revision = f.document.editRevision
  let ownership = f.document.ownershipGeneration
  let bookmarks = f.document.bookmarks.offsets
  let storage = try XCTUnwrap(f.document.storage as? DocumentCommitTextStorage)
  let window = try XCTUnwrap(f.controller.window)
  let sequence = storage.nativeMacroTestPrimitiveSequence
  guard !storage.nativeMacroTestSequenceExhausted, sequence < UInt64.max
  else { throw NativeClientFailure.unavailable }
  let source = try f.source()
  let credential = try source.inspect()
  let samples = ExplicitCapacityAdmissionLedger()
  f.routing.onAdmission = { samples.sample() }
  defer { f.routing.onAdmission = nil }
  var attempted = 0
  var strictResult: Bool?
  // The strict caller's lawful native group is outside the saturated lexical scopes.
  if !controlled { f.document.undoManager.beginUndoGrouping() }
  do {
    try enterExplicitCapacityDepth(1) {
      attempted += 1
      if controlled {
        f.pane.editor.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
      } else {
        strictResult = source.replace(expected: credential, source: "😀y", replacement: "😀z")
      }
    }
  } catch {
    if !controlled { f.document.undoManager.endUndoGrouping() }
    throw error
  }
  if !controlled { f.document.undoManager.endUndoGrouping() }
  f.routing.onAdmission = nil
  XCTAssertEqual(attempted, 1)
  XCTAssertGreaterThan(samples.count, 0, "Real admission callbacks are a prerequisite")
  XCTAssertFalse(samples.overflow)
  guard attempted == 1, samples.count > 0, !samples.overflow,
    !f.routing.endpointCalls.overflow, !f.routing.admissionCalls.overflow
  else { throw NativeClientFailure.unavailable }
  XCTAssertEqual(f.controller.nativeSearchTestCommands, [expectedForward])
  XCTAssertEqual(f.controller.nativeSearchTestUnits, 3)
  XCTAssertEqual(f.controller.nativeSearchTestRecordingID, f.document.id)
  let incomplete = f.controller.nativeMacroTestIntegrityState()
  XCTAssertEqual(incomplete.epoch, before.epoch)
  XCTAssertTrue(incomplete.active)
  XCTAssertFalse(incomplete.complete)
  XCTAssertNotNil(incomplete.reason)
  if controlled {
    XCTAssertEqual(spy.permission.count, 2, "Continued ordinary native permission is required")
    XCTAssertEqual(spy.changes.count, 2)
    XCTAssertEqual(f.document.storage.string, "😀yz")
    XCTAssertEqual(f.pane.editor.selectedRange(), NSRange(location: 4, length: 0))
    XCTAssertGreaterThan(f.document.editRevision, revision)
    XCTAssertGreaterThan(storage.nativeMacroTestPrimitiveSequence, sequence)
    guard spy.permission.count == 2, spy.changes.count == 2,
      f.document.storage.string == "😀yz"
    else { throw NativeClientFailure.unavailable }  // Native refusal is not capacity RED.
  } else {
    XCTAssertEqual(strictResult, false)
    XCTAssertEqual(f.document.storage.string, "😀y")
    XCTAssertEqual(f.document.editRevision, revision)
    XCTAssertEqual(storage.nativeMacroTestPrimitiveSequence, sequence)
    XCTAssertEqual(f.document.bookmarks.offsets, bookmarks)
    XCTAssertEqual(f.pane.editor.selectedRange(), selection)
    XCTAssertTrue(source.isCurrent(expected: credential))
  }
  XCTAssertEqual(f.document.ownershipGeneration, ownership)
  XCTAssertTrue(f.controller.window === window)
  XCTAssertTrue(f.pane.editor.textStorage === storage)
  XCTAssertTrue(f.document.storage === storage)
  XCTAssertFalse(storage.nativeMacroTestSequenceExhausted)
  spy.assertFinite()
  assertExplicitCapacityCleanup(f)
  print(
    "EXPLICIT_CAPACITY controlled=\(controlled) samples=\(samples.count) max=\(samples.maximum) frame=\(samples.sawFrame) sticky=\(samples.overflow)"
  )
}

@MainActor final class NativeMacroStrictExplicitCapacityTests: XCTestCase {
  func testActualStrictEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity() async throws {
    try await runActualExplicitCapacity(controlled: false)
  }
}
@MainActor final class NativeMacroControlledExplicitCapacityTests: XCTestCase {
  func testActualControlledEntryInsideThirtyTwoProcessingScopesPreservesSharedCapacity()
    async throws
  {
    try await runActualExplicitCapacity(controlled: true)
  }
}
