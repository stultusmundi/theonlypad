// SPDX-License-Identifier: MIT
// Append to the whole SearchReplacementTests source: reuse its genuine managed fixture.
private enum NestedStringTestError: Error { case unavailable }
@MainActor private final class NestedStringCleanupCustody {
  var incomplete = false
  var event: EventBoundaryOracleFixture?
}
@MainActor private enum NestedStringRetainedCustody {
  static var fixtures: [NestedStringFixture] = []
  static var setup: [ManagedReplacementFixture] = []
}
@MainActor private func nestedStringProtocolIsSettled(_ base: ManagedReplacementFixture) -> Bool {
  let state = base.controller.nestedStringTestState()
  let context = EditorWindowController.nestedStringTestContext()
  let manager = base.document.undoManager
  return !state.hasPreparation && !state.hasExplicitFrame
    && context.broker == 0 && context.context == 0 && !context.overflow
    && !manager.isUndoing && !manager.isRedoing
}
@MainActor private struct NestedStringFixture {
  let base: ManagedReplacementFixture
  let pane: EditorPane
  let panel: SearchPanelController
  let original: String
  let custody = NestedStringCleanupCustody()
  func stopPassiveObservation() {
    guard let event = custody.event else { return }
    event.closureArmed = false
    event.timer?.invalidate()
    event.timer = nil
    if let observer = event.observer { NotificationCenter.default.removeObserver(observer) }
    event.observer = nil
  }
  func retainIncomplete(file: StaticString = #filePath, line: UInt = #line) throws -> Never {
    if !custody.incomplete {
      custody.incomplete = true
      NestedStringRetainedCustody.fixtures.append(self)
    }
    // Retire only this Test's passive observation; preserve native/group/owner custody.
    stopPassiveObservation()
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE", file: file, line: line)
    throw NestedStringTestError.unavailable
  }
  func close() {
    guard !custody.incomplete else { return }
    guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty
    else {
      _ = try? retainIncomplete()
      return
    }
    do { try nestedStringSettled(self) } catch {
      if !custody.incomplete { _ = try? retainIncomplete() }
      return
    }
    stopPassiveObservation()
    guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty,
      custody.event?.incomplete != true,
      nestedStringProtocolIsSettled(base), base.document.undoManager.groupingLevel == 0,
      pane.editor.delegate === base.controller
    else {
      _ = try? retainIncomplete()
      return
    }
    base.admission = nil
    // Settlement already proved the genuine delegate identity; no redundant setter callout.
    base.controller.replacementTestCleanup()
  }
}
@MainActor private func nestedStringFixture(
  text: String = "alpha\nomega", bookmarks: [Int] = [0, 6], recording: Bool = true
) async throws -> NestedStringFixture {
  guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty
  else {
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE")
    throw NestedStringTestError.unavailable
  }
  let f = try await ManagedReplacementFixture()
  do {
    let pane = try XCTUnwrap(f.controller.visiblePanes.first)
    if f.document.storage.string != text { f.document.storage.mutableString.setString(text) }
    f.document.bookmarks = try DocumentBookmarks(offsets: bookmarks, in: text)
    try f.controller.focusPane(id: pane.id)
    pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    let panel = try XCTUnwrap(f.controller.replacementTestPanel())
    XCTAssertFalse(try XCTUnwrap(f.controller.window).isVisible)
    XCTAssertFalse(try XCTUnwrap(panel.window).isVisible)
    XCTAssertFalse(f.document.undoManager.canUndo)
    XCTAssertEqual(f.document.undoManager.groupingLevel, 0)
    if recording {
      f.controller.execute("macro.start")
      let state = f.controller.nestedStringTestState()
      XCTAssertNotNil(state.epoch)
      XCTAssertTrue(state.active && state.complete)
      XCTAssertEqual(state.commands, [])
      guard state.epoch != nil, state.active, state.complete, state.commands.isEmpty else {
        throw NestedStringTestError.unavailable
      }
    }
    return NestedStringFixture(base: f, pane: pane, panel: panel, original: text)
  } catch {
    guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty,
      nestedStringProtocolIsSettled(f), f.document.undoManager.groupingLevel == 0
    else {
      NestedStringRetainedCustody.setup.append(f)
      XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE")
      throw error
    }
    f.admission = nil
    f.controller.replacementTestCleanup()
    throw error
  }
}
// Actual outer delegate + actual subsequent managed owner admission, not a fake phase setter.
@MainActor private func nestedStringOuter(
  _ f: NestedStringFixture, _ body: @escaping @MainActor () -> Void
) -> (accepted: Bool, callbacks: Int) {
  var calls = 0
  let c = f.base.controller!
  let delegate = ReentrantReplacementDelegate {
    let allowed = c.textView(
      f.pane.editor,
      shouldChangeTextIn: NSRange(location: 0, length: f.original.utf16.count),
      replacementString: "outer")
    f.base.admission = {
      f.base.admission = nil
      calls += 1
      guard calls == 1 else {
        XCTFail("Only one owned outer callback")
        return
      }
      f.pane.editor.delegate = c
      body()
    }
    return allowed
  }
  f.pane.editor.delegate = delegate
  let accepted = f.panel.replacementTestApply(expected: f.original, replacement: "outer")
  f.base.admission = nil
  f.pane.editor.delegate = c
  withExtendedLifetime(delegate) {}
  return (accepted, calls)
}
@MainActor private func nestedStringAssertProtocol(
  _ f: NestedStringFixture,
  file: StaticString, line: UInt
) {
  let s = f.base.controller.nestedStringTestState()
  let stacks = EditorWindowController.nestedStringTestContext()
  XCTAssertFalse(s.hasPreparation, file: file, line: line)
  XCTAssertFalse(s.hasExplicitFrame, file: file, line: line)
  XCTAssertEqual(stacks.broker, 0, "Settled broker depth", file: file, line: line)
  XCTAssertEqual(stacks.context, 0, "Settled context depth", file: file, line: line)
  XCTAssertFalse(stacks.overflow, file: file, line: line)
  XCTAssertFalse(
    f.base.document.undoManager.isUndoing || f.base.document.undoManager.isRedoing,
    file: file, line: line)
}
@MainActor private func nestedStringSettled(
  _ f: NestedStringFixture,
  file: StaticString = #filePath, line: UInt = #line
) throws {
  nestedStringAssertProtocol(f, file: file, line: line)
  guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty,
    !f.custody.incomplete, f.custody.event?.incomplete != true,
    nestedStringProtocolIsSettled(f.base),
    f.pane.editor.delegate === f.base.controller
  else { try f.retainIncomplete(file: file, line: line) }
  let manager = f.base.document.undoManager
  if manager.groupingLevel != 0 {
    // A real bounded default-mode closure must establish automatic1 -> settled0.
    // Never end an inherited/unknown group or change native grouping settings.
    guard manager.groupingLevel == 1, manager.groupsByEvent, manager.runLoopModes == [.default]
    else { try f.retainIncomplete(file: file, line: line) }
    let event: EventBoundaryOracleFixture
    if let existing = f.custody.event {
      event = existing
    } else {
      event = EventBoundaryOracleFixture(f.base)
      event.pane = f.pane
      event.installObserver()
      f.custody.event = event
    }
    do { try event.requireAutomaticClosure() } catch {
      try f.retainIncomplete(file: file, line: line)
    }
    guard !event.incomplete else { try f.retainIncomplete(file: file, line: line) }
  }
  nestedStringAssertProtocol(f, file: file, line: line)
  XCTAssertEqual(
    manager.groupingLevel, 0, "Settled native undo grouping level", file: file, line: line)
  guard NestedStringRetainedCustody.fixtures.isEmpty, NestedStringRetainedCustody.setup.isEmpty,
    f.custody.event?.incomplete != true,
    nestedStringProtocolIsSettled(f.base), manager === f.base.document.undoManager,
    manager.groupingLevel == 0, f.pane.editor.delegate === f.base.controller
  else { try f.retainIncomplete(file: file, line: line) }
}
// Real shallow commit is a required positive premise BEFORE complex reentry/capacity controls.
@MainActor private func nestedStringRequireSupported(
  file: StaticString = #filePath, line: UInt = #line
) async throws -> Bool {
  let f = try await nestedStringFixture()
  defer { f.close() }
  let epoch = f.base.controller.nestedStringTestState().epoch
  let revision = f.base.document.editRevision
  let result = nestedStringOuter(f) {
    f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
  }
  let s = f.base.controller.nestedStringTestState()
  XCTAssertFalse(result.accepted, file: file, line: line)
  XCTAssertEqual(result.callbacks, 1, file: file, line: line)
  XCTAssertEqual(f.base.document.storage.string, "Xlpha\nomega", file: file, line: line)
  XCTAssertGreaterThan(f.base.document.editRevision, revision, file: file, line: line)
  XCTAssertEqual(
    s.commands, [.replace(location: 0, length: 1, text: "X")],
    "Genuine nested source-owned write must record before deeper controls", file: file, line: line)
  XCTAssertEqual(s.epoch, epoch, file: file, line: line)
  XCTAssertTrue(s.complete && s.active, file: file, line: line)
  try nestedStringSettled(f, file: file, line: line)
  return !result.accepted && result.callbacks == 1
    && f.base.document.storage.string == "Xlpha\nomega"
    && s.commands == [.replace(location: 0, length: 1, text: "X")]
    && s.epoch == epoch && s.complete && s.active && !s.hasPreparation && !s.hasExplicitFrame
}
@MainActor private func nestedStringReplay(_ commands: [MacroCommand], from: String, to: String)
  throws
{
  XCTAssertEqual(
    try MacroPlayer.replay(
      EditorMacro(name: "Synthetic nested replacement", commands: commands), on: from), to)
}
@MainActor private func nestedStringProcessingBoundary(
  _ depth: Int = 0,
  body: () -> Void
) {
  let s = EditorWindowController.nestedStringTestContext()
  XCTAssertLessThanOrEqual(s.broker + s.context, 64)
  guard depth < 33 else {
    XCTFail("Finite real processing boundary")
    return
  }
  if s.broker + s.context >= 62 {
    body()
    return
  }
  EditorWindowController.withNativeMacroProcessingBarrier {
    nestedStringProcessingBoundary(depth + 1, body: body)
  }
}

@MainActor final class NativeMacroNestedStringReplacementTests: XCTestCase {
  func testActualConcreteRangeChildRecordsOnceAndLeavesUsableOriginalAuthority() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    let first = nestedStringOuter(f) {
      f.pane.editor.insertText("replacement", replacementRange: NSRange(location: 0, length: 11))
    }
    XCTAssertFalse(first.accepted)
    XCTAssertEqual(first.callbacks, 1)
    let expected: [MacroCommand] = [.replace(location: 0, length: 11, text: "replacement")]
    XCTAssertEqual(f.base.controller.replacementTestCommands, expected)
    XCTAssertEqual(f.base.document.storage.string, "replacement")
    try nestedStringSettled(f)
    try nestedStringReplay(
      f.base.controller.replacementTestCommands, from: f.original, to: "replacement")
    // Actual existing strict helper after child cleanup: residual proposal cannot merely look absent.
    XCTAssertTrue(
      f.base.controller.replacementTestTransform(
        f.base.document, source: f.pane,
        expected: "replacement", replacement: "Replacement",
        edit: TextEdit(range: NSRange(location: 0, length: 1), replacement: "R")))
    XCTAssertEqual(
      f.base.controller.replacementTestCommands,
      expected + [.replace(location: 0, length: 1, text: "R")])
    XCTAssertEqual(f.base.document.storage.string, "Replacement")
    try nestedStringSettled(f)
  }

  func testChildNativeVetoHasOnePermissionNoFallbackAndKeepsLawfulParent() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    var vetoes = 0
    var afterChild = ""
    let veto = ReentrantReplacementDelegate {
      vetoes += 1
      return false
    }
    let result = nestedStringOuter(f) {
      f.pane.editor.delegate = veto
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
      afterChild = f.base.document.storage.string
      f.pane.editor.delegate = f.base.controller
    }
    withExtendedLifetime(veto) {}
    XCTAssertEqual(vetoes, 1, "Recognized refusal must not retry inherited insertion")
    XCTAssertEqual(afterChild, f.original)
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertTrue(result.accepted, "Unchanged refused child must not burn otherwise lawful parent")
    XCTAssertEqual(f.base.document.storage.string, "outer")
    XCTAssertEqual(
      f.base.controller.replacementTestCommands,
      [.replace(location: 0, length: 11, text: "outer")])
    XCTAssertTrue(f.base.controller.nestedStringTestState().complete)
    try nestedStringSettled(f)
    f.base.document.undoManager.undo()
    XCTAssertEqual(f.base.document.storage.string, f.original)
    XCTAssertEqual(f.base.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.base.document.undoManager.canUndo)
  }

  func testRawCharacterWriteInSameAdmissionStillDisclosesIncompleteInterval() async throws {
    let f = try await nestedStringFixture()
    defer { f.close() }
    let epoch = f.base.controller.nestedStringTestState().epoch
    let result = nestedStringOuter(f) {
      f.base.document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "R")
      f.pane.editor.didChangeText()
    }
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(f.base.document.storage.string, "Rlpha\nomega")
    let s = f.base.controller.nestedStringTestState()
    XCTAssertEqual(s.epoch, epoch)
    XCTAssertTrue(s.active)
    XCTAssertFalse(s.complete)
    XCTAssertEqual(s.reason, .unsupportedCharacterMutation)
    XCTAssertEqual(s.commands, [])
    XCTAssertNil(f.base.controller.recordingSnapshot(named: "Raw write remains incomplete"))
    try nestedStringSettled(f)
  }

  func testRealEmptyStopAndRestartProtectNewEpochFromOldParent() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    let oldEpoch = f.base.controller.nestedStringTestState().epoch
    var stopped = false
    var newEpoch: UUID?
    let result = nestedStringOuter(f) {
      f.base.controller.execute("macro.stop")  // No commands: genuine stop does not open Save UI.
      let state = f.base.controller.nestedStringTestState()
      stopped = !state.active && state.commands.isEmpty
      f.base.controller.execute("macro.start")
      newEpoch = f.base.controller.nestedStringTestState().epoch
      f.pane.editor.insertText("N", replacementRange: NSRange(location: 0, length: 1))
    }
    XCTAssertTrue(stopped)
    XCTAssertNotNil(newEpoch)
    XCTAssertNotEqual(newEpoch, oldEpoch)
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(f.base.document.storage.string, "Nlpha\nomega")
    let state = f.base.controller.nestedStringTestState()
    XCTAssertEqual(state.epoch, newEpoch)
    XCTAssertTrue(state.active && state.complete)
    XCTAssertEqual(state.commands, [.replace(location: 0, length: 1, text: "N")])
    try nestedStringSettled(f)
  }

  func testUnicodeReplacementCaretHistoryAndBookmarksMatchActualNonrecordingTwin() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let original = "😀e\u{301}\nq"
    let twin = try await nestedStringFixture(text: original, bookmarks: [0, 5], recording: false)
    defer { twin.close() }
    let f = try await nestedStringFixture(text: original, bookmarks: [0, 5])
    defer { f.close() }
    for target in [twin, f] {
      let result = nestedStringOuter(target) {
        target.pane.editor.insertText("Ω", replacementRange: NSRange(location: 0, length: 2))
      }
      XCTAssertEqual(result.callbacks, 1)
      XCTAssertFalse(result.accepted)
      XCTAssertEqual(target.base.document.storage.string, "Ωe\u{301}\nq")
      XCTAssertEqual(target.base.document.bookmarks.offsets, [0, 4])
      XCTAssertEqual(target.pane.editor.selectedRange(), NSRange(location: 1, length: 0))
      XCTAssertTrue(target.base.document.undoManager.canUndo)
      try nestedStringSettled(target)
    }
    XCTAssertEqual(
      f.base.controller.replacementTestCommands,
      [.replace(location: 0, length: 2, text: "Ω")])
    XCTAssertEqual(
      f.base.document.undoManager.undoActionName, twin.base.document.undoManager.undoActionName)
    XCTAssertEqual(f.pane.editor.selectedRange(), twin.pane.editor.selectedRange())
    for target in [twin, f] {
      target.base.document.undoManager.undo()
      XCTAssertEqual(target.base.document.storage.string, original)
      XCTAssertEqual(target.base.document.bookmarks.offsets, [0, 5])
      XCTAssertFalse(target.base.document.undoManager.canUndo, "No unapplied outer action")
    }
    XCTAssertEqual(f.pane.editor.selectedRange(), twin.pane.editor.selectedRange())
    for target in [twin, f] {
      target.base.document.undoManager.redo()
      XCTAssertEqual(target.base.document.storage.string, "Ωe\u{301}\nq")
      XCTAssertEqual(target.base.document.bookmarks.offsets, [0, 4])
      try nestedStringSettled(target)
    }
    XCTAssertEqual(f.pane.editor.selectedRange(), twin.pane.editor.selectedRange())
    XCTAssertTrue(f.base.controller.nestedStringTestState().complete)
    try nestedStringReplay(
      f.base.controller.replacementTestCommands,
      from: original, to: "Ωe\u{301}\nq")
  }

  func testSiblingChildrenKeepChronologicalCommandsAndOneNativeEventUndoWithoutOuter() async throws
  {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    let result = nestedStringOuter(f) {
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
      f.pane.editor.insertText("Y", replacementRange: NSRange(location: 1, length: 1))
    }
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(f.base.document.storage.string, "XYpha\nomega")
    let commands: [MacroCommand] = [
      .replace(location: 0, length: 1, text: "X"),
      .replace(location: 1, length: 1, text: "Y"),
    ]
    XCTAssertEqual(f.base.controller.replacementTestCommands, commands)
    XCTAssertTrue(f.base.controller.nestedStringTestState().complete)
    try nestedStringReplay(
      f.base.controller.replacementTestCommands, from: f.original, to: "XYpha\nomega")
    try nestedStringSettled(f)
    f.base.document.undoManager.undo()
    XCTAssertEqual(f.base.document.storage.string, f.original)
    XCTAssertEqual(f.base.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(
      f.base.document.undoManager.canUndo, "One native event; no unapplied outer action")
    XCTAssertTrue(f.base.document.undoManager.canRedo)
    let inverse: [MacroCommand] = [
      .replace(location: 1, length: 1, text: "l"),
      .replace(location: 0, length: 1, text: "a"),
    ]
    XCTAssertEqual(f.base.controller.replacementTestCommands, commands + inverse)
    try nestedStringReplay(
      f.base.controller.replacementTestCommands, from: f.original, to: f.original)
    try nestedStringSettled(f)
    f.base.document.undoManager.redo()
    XCTAssertEqual(f.base.document.storage.string, "XYpha\nomega")
    XCTAssertEqual(f.base.document.bookmarks.offsets, [0, 6])
    XCTAssertTrue(f.base.document.undoManager.canUndo)
    XCTAssertFalse(f.base.document.undoManager.canRedo)
    XCTAssertEqual(f.base.controller.replacementTestCommands, commands + inverse + commands)
    try nestedStringReplay(
      f.base.controller.replacementTestCommands, from: f.original, to: "XYpha\nomega")
    nestedStringAssertProtocol(f, file: #filePath, line: #line)
    guard nestedStringProtocolIsSettled(f.base) else { try f.retainIncomplete() }
    // The existing defer calls strict settlement again before any fixture cleanup.
  }

  func testActualGrandchildCommitRejectsBothStaleAncestorsWithoutClearingIt() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    var childPermissions = 0
    var grandchildren = 0
    let childDelegate = ReentrantReplacementDelegate {
      childPermissions += 1
      guard childPermissions == 1 else {
        XCTFail("Finite genuine child permission")
        return false
      }
      let admitted = f.base.controller.textView(
        f.pane.editor,
        shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "X")
      f.base.admission = {
        f.base.admission = nil
        grandchildren += 1
        guard grandchildren == 1 else {
          XCTFail("Finite grandchild admission")
          return
        }
        f.pane.editor.delegate = f.base.controller
        f.pane.editor.insertText("G", replacementRange: NSRange(location: 1, length: 1))
      }
      return admitted
    }
    let result = nestedStringOuter(f) {
      f.pane.editor.delegate = childDelegate
      f.pane.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
    }
    withExtendedLifetime(childDelegate) {}
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertEqual(childPermissions, 1)
    XCTAssertEqual(grandchildren, 1, "Actual child post-permission owner admission must enter")
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(f.base.document.storage.string, "aGpha\nomega")
    let expected: [MacroCommand] = [.replace(location: 1, length: 1, text: "G")]
    XCTAssertEqual(f.base.controller.replacementTestCommands, expected)
    XCTAssertTrue(f.base.controller.nestedStringTestState().complete)
    try nestedStringSettled(f)
    f.base.document.undoManager.undo()
    XCTAssertEqual(f.base.document.storage.string, f.original)
    XCTAssertEqual(f.base.document.bookmarks.offsets, [0, 6])
    XCTAssertFalse(f.base.document.undoManager.canUndo)
    try nestedStringSettled(f)
  }

  func testSharedRealProcessingCapacityKeepsTextOnceAndMarksMissingRecording() async throws {
    guard try await nestedStringRequireSupported() else { return }
    let f = try await nestedStringFixture()
    defer { f.close() }
    let epoch = f.base.controller.nestedStringTestState().epoch
    let revision = f.base.document.editRevision
    var reached = false
    var samples = 0
    var maximum = 0
    let result = nestedStringOuter(f) {
      nestedStringProcessingBoundary {
        let before = EditorWindowController.nestedStringTestContext()
        reached = before.broker + before.context >= 62
        f.base.admission = {
          samples += 1
          guard samples <= 256 else {
            XCTFail("Finite actual admission samples")
            return
          }
          let state = EditorWindowController.nestedStringTestContext()
          maximum = max(maximum, state.broker + state.context)
          XCTAssertLessThanOrEqual(state.broker + state.context, 64)
        }
        f.pane.editor.insertText("C", replacementRange: NSRange(location: 0, length: 1))
        f.base.admission = nil
      }
    }
    XCTAssertTrue(reached)
    XCTAssertGreaterThan(samples, 0, "Real owner admission must occur at the shared boundary")
    XCTAssertLessThanOrEqual(samples, 256)
    XCTAssertLessThanOrEqual(maximum, 64)
    XCTAssertEqual(result.callbacks, 1)
    XCTAssertFalse(result.accepted)
    XCTAssertEqual(f.base.document.storage.string, "Clpha\nomega")
    XCTAssertEqual(f.base.document.editRevision, revision + 1, "Only the real child text change")
    let state = f.base.controller.nestedStringTestState()
    XCTAssertEqual(state.epoch, epoch)
    XCTAssertTrue(state.active)
    XCTAssertFalse(state.complete)
    XCTAssertNotNil(state.reason)
    XCTAssertEqual(state.commands, [])
    XCTAssertNil(f.base.controller.recordingSnapshot(named: "Boundary remains incomplete"))
    try nestedStringSettled(f)
  }
}
