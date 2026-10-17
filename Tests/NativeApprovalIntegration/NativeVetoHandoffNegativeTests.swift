// SPDX-License-Identifier: MIT
// Native handoff rejection boundaries; no receipt inspection or accepting injection.
private enum VetoHandoffNegativeError: Error { case incomplete }
private enum VetoHandoffNegativeMode: Equatable {
  case controllerOnly, foreignAfterVeto, nilAfterVeto, configurationRefusal
  case rawABA, epochABA, twoVetoes
}
@MainActor private final class VetoHandoffTestDelegate: NSObject, NSTextViewDelegate {
  let response: @MainActor (NSTextView, NSRange, String?) -> Bool
  init(_ response: @escaping @MainActor (NSTextView, NSRange, String?) -> Bool) {
    self.response = response
  }
  func textView(
    _ view: NSTextView, shouldChangeTextIn range: NSRange,
    replacementString: String?
  ) -> Bool { response(view, range, replacementString) }
}
@MainActor private final class VetoHandoffCall {
  let mode: VetoHandoffNegativeMode
  let expected: String
  let replacement: String
  var permissions = 0
  var approved = false
  var owners = 0
  var completed = false
  var accepted = false
  init(_ mode: VetoHandoffNegativeMode, expected: String, replacement: String) {
    self.mode = mode
    self.expected = expected
    self.replacement = replacement
  }
}
@MainActor private enum VetoHandoffNegativeRetained {
  static var states: [VetoHandoffNegativeState] = []
}
@MainActor private final class VetoHandoffNegativeState {
  let f: NestedStringFixture
  var delegates: [VetoHandoffTestDelegate] = []
  var foreign: VetoHandoffTestDelegate?
  var configuration: UUID?
  var configurationEntered = false
  var configurationReturned = false
  var childAttempts = 0
  var vetoCalls = 0
  var foreignCalls = 0
  var afterChild = ""
  var stopped = false
  var newEpoch: UUID?
  var ownsNil = false
  var bad = false
  var retained = false
  init(_ f: NestedStringFixture) { self.f = f }
  func unavailable() throws -> Never {
    if !retained {
      retained = true
      VetoHandoffNegativeRetained.states.append(self)
    }
    try f.retainIncomplete()
  }
  func keep(_ delegate: VetoHandoffTestDelegate) {
    guard delegates.count < 8 else {
      bad = true
      return
    }
    delegates.append(delegate)
  }
  func nativeVeto(_ view: NSTextView, range: NSRange, replacement: String?) -> Bool {
    guard vetoCalls < 3 else {
      bad = true
      return false
    }
    vetoCalls += 1
    XCTAssertTrue(view === f.pane.editor)
    XCTAssertEqual(range, NSRange(location: 0, length: 1))
    XCTAssertTrue(replacement?.utf16.elementsEqual("X".utf16) == true)
    return false  // Actual native original response; never permission-time command recording.
  }
  func ownerBody(_ call: VetoHandoffCall) {
    f.base.admission = nil
    call.owners += 1
    guard call.owners == 1 else {
      bad = true
      return
    }
    let editor = f.pane.editor
    let document = f.base.document
    editor.delegate = f.base.controller
    if call.mode != .controllerOnly {
      let veto = VetoHandoffTestDelegate { [weak self] view, range, replacement in
        self?.nativeVeto(view, range: range, replacement: replacement) ?? false
      }
      keep(veto)
      editor.delegate = veto
      if call.mode == .configurationRefusal {
        do {
          let token = try document.beginNativeConfiguration()
          configuration = token
          configurationEntered = document.nativeConfigurationToken == token
        } catch {
          bad = true
          return
        }
      }
      let attempts = call.mode == .twoVetoes ? 2 : 1
      for _ in 0..<attempts {
        childAttempts += 1
        editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(document.storage.string, call.expected)
      }
      afterChild = document.storage.string
      if call.mode == .configurationRefusal {
        guard let token = configuration, document.nativeConfigurationToken == token else {
          bad = true
          return
        }
        document.endNativeConfiguration(token)
        configurationReturned = document.nativeConfigurationToken == nil
        guard configurationReturned else {
          bad = true
          return
        }
        configuration = nil
      }
      editor.delegate = f.base.controller
    } else {
      afterChild = document.storage.string
    }
    switch call.mode {
    case .foreignAfterVeto:
      let successor = VetoHandoffTestDelegate { [weak self] _, _, _ in
        self?.foreignCalls += 1
        return false
      }
      keep(successor)
      foreign = successor
      editor.delegate = successor
    case .nilAfterVeto:
      editor.delegate = nil
      ownsNil = true
    case .rawABA:
      document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "R")
      document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "a")
      editor.didChangeText()
    case .epochABA:
      f.base.controller.execute("macro.stop")  // Actual empty stop: no Save UI.
      let stoppedState = f.base.controller.nestedStringTestState()
      stopped = !stoppedState.active && stoppedState.commands.isEmpty
      f.base.controller.execute("macro.start")
      newEpoch = f.base.controller.nestedStringTestState().epoch
    case .controllerOnly, .configurationRefusal, .twoVetoes:
      break
    }
    call.completed = true
  }
  func runOuter(
    _ mode: VetoHandoffNegativeMode, expected: String,
    replacement: String
  ) -> VetoHandoffCall {
    let call = VetoHandoffCall(mode, expected: expected, replacement: replacement)
    let delegate = VetoHandoffTestDelegate { [weak self, call] view, range, actualReplacement in
      guard let self else { return false }
      call.permissions += 1
      guard call.permissions == 1, view === self.f.pane.editor,
        range == NSRange(location: 0, length: expected.utf16.count),
        actualReplacement?.utf16.elementsEqual(replacement.utf16) == true
      else {
        self.bad = true
        return false
      }
      call.approved = self.f.base.controller.textView(
        view, shouldChangeTextIn: range,
        replacementString: actualReplacement)
      if call.approved {
        self.f.base.admission = { [weak self, call] in self?.ownerBody(call) }
      }
      return call.approved
    }
    keep(delegate)
    f.pane.editor.delegate = delegate
    call.accepted = f.panel.replacementTestApply(expected: expected, replacement: replacement)
    return call  // Observe the actual endpoint BEFORE any Test-owned restoration.
  }
  func restoreOwnedEndpointAndSettle() throws {
    guard !bad, configuration == nil, f.base.document.nativeConfigurationToken == nil,
      f.base.admission == nil, nestedStringProtocolIsSettled(f.base)
    else { try unavailable() }
    let current = f.pane.editor.delegate
    if current !== f.base.controller {
      let ownObject = current.map { value in delegates.contains { value === $0 } } ?? false
      guard ownObject || (current == nil && ownsNil) else { try unavailable() }
      f.pane.editor.delegate = f.base.controller
      guard f.pane.editor.delegate === f.base.controller,
        nestedStringProtocolIsSettled(f.base)
      else { try unavailable() }
    }
    ownsNil = false
    try nestedStringSettled(f)
  }
}
@MainActor private func vetoHandoffNegativeRun(_ mode: VetoHandoffNegativeMode) async throws {
  guard VetoHandoffNegativeRetained.states.isEmpty else {
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE")
    throw VetoHandoffNegativeError.incomplete
  }
  let f = try await nestedStringFixture()
  let s = VetoHandoffNegativeState(f)
  defer { if !s.retained { f.close() } }
  let document = f.base.document
  let storage = document.storage
  let ownership = document.ownershipGeneration
  let assignment = f.base.registry.assignment(of: document.id)
  let epoch = f.base.controller.nestedStringTestState().epoch
  let revision = document.editRevision
  let call = s.runOuter(mode, expected: f.original, replacement: "outer")
  XCTAssertEqual(call.permissions, 1)
  XCTAssertTrue(call.approved, "Actual original preparation must enter")
  XCTAssertEqual(call.owners, 1)
  XCTAssertTrue(call.completed)
  XCTAssertFalse(call.accepted, "A child veto alone cannot authorize a different destination")
  XCTAssertEqual(document.storage.string, f.original)
  XCTAssertEqual(document.bookmarks.offsets, [0, 6])
  XCTAssertEqual(s.afterChild, f.original)
  XCTAssertEqual(f.base.controller.replacementTestCommands, [])
  XCTAssertEqual(s.foreignCalls, 0)
  let expectedAttempts = mode == .controllerOnly ? 0 : mode == .twoVetoes ? 2 : 1
  let expectedVetoes = mode == .configurationRefusal ? 0 : expectedAttempts
  XCTAssertEqual(s.childAttempts, expectedAttempts)
  XCTAssertEqual(s.vetoCalls, expectedVetoes)
  switch mode {
  case .foreignAfterVeto:
    XCTAssertTrue(f.pane.editor.delegate === s.foreign, "Preserve the genuine foreign successor")
  case .nilAfterVeto:
    XCTAssertNil(f.pane.editor.delegate, "Preserve the actual nil successor")
  default:
    XCTAssertTrue(f.pane.editor.delegate === f.base.controller)
  }
  let state = f.base.controller.nestedStringTestState()
  XCTAssertTrue(state.active)
  if mode == .epochABA {
    XCTAssertTrue(s.stopped)
    XCTAssertNotNil(s.newEpoch)
    XCTAssertNotEqual(s.newEpoch, epoch)
    XCTAssertEqual(state.epoch, s.newEpoch)
  } else {
    XCTAssertEqual(state.epoch, epoch)
  }
  if mode == .rawABA {
    XCTAssertGreaterThan(document.editRevision, revision)
    XCTAssertFalse(state.complete)
    XCTAssertEqual(state.reason, .unsupportedCharacterMutation)
    XCTAssertNil(f.base.controller.recordingSnapshot(named: "Raw ABA stays incomplete"))
  } else {
    XCTAssertEqual(document.editRevision, revision)
    XCTAssertTrue(state.complete)
  }
  if mode == .configurationRefusal {
    XCTAssertTrue(s.configurationEntered && s.configurationReturned)
    XCTAssertNil(document.nativeConfigurationToken)
  }
  XCTAssertEqual(document.ownershipGeneration, ownership)
  XCTAssertTrue(document.storage === storage && f.pane.editor.textStorage === storage)
  XCTAssertTrue(f.base.registry.handle(id: document.id) === document)
  XCTAssertEqual(f.base.registry.assignment(of: document.id), assignment)
  guard !s.bad, call.permissions == 1, call.approved, call.owners == 1, call.completed,
    s.childAttempts == expectedAttempts, s.vetoCalls == expectedVetoes
  else { try s.unavailable() }
  try s.restoreOwnedEndpointAndSettle()
  // Exact original authority remains usable after the old parent/window has retired.
  let later = f.panel.replacementTestApply(expected: f.original, replacement: "later")
  XCTAssertTrue(later)
  XCTAssertEqual(document.storage.string, "later")
  let laterCommands: [MacroCommand] = [.replace(location: 0, length: 11, text: "later")]
  XCTAssertEqual(f.base.controller.replacementTestCommands, laterCommands)
  XCTAssertEqual(f.base.controller.nestedStringTestState().epoch, state.epoch)
  if mode == .rawABA {
    XCTAssertFalse(f.base.controller.nestedStringTestState().complete)
    XCTAssertEqual(f.base.controller.nestedStringTestState().reason, .unsupportedCharacterMutation)
  } else {
    XCTAssertTrue(f.base.controller.nestedStringTestState().complete)
  }
  try nestedStringSettled(f)
  // The old genuine veto cannot grant a new unrelated controller-only handoff.
  let stale = s.runOuter(.controllerOnly, expected: "later", replacement: "final")
  XCTAssertEqual(stale.permissions, 1)
  XCTAssertTrue(stale.approved)
  XCTAssertEqual(stale.owners, 1)
  XCTAssertTrue(stale.completed)
  XCTAssertFalse(stale.accepted, "Retired-window or consumed receipt cannot authorize a new parent")
  XCTAssertEqual(document.storage.string, "later")
  XCTAssertEqual(f.base.controller.replacementTestCommands, laterCommands)
  XCTAssertTrue(f.pane.editor.delegate === f.base.controller)
  XCTAssertEqual(document.ownershipGeneration, ownership)
  XCTAssertEqual(f.base.controller.nestedStringTestState().epoch, state.epoch)
  guard !s.bad, stale.permissions == 1, stale.approved,
    stale.owners == 1, stale.completed
  else { try s.unavailable() }
  try s.restoreOwnedEndpointAndSettle()
}
@MainActor final class NativeVetoHandoffNegativeTests: XCTestCase {
  func testControllerReplacementWithoutChildHasNoHandoff() async throws {
    try await vetoHandoffNegativeRun(.controllerOnly)
  }
  func testGenuineVetoCannotAuthorizeForeignSuccessor() async throws {
    try await vetoHandoffNegativeRun(.foreignAfterVeto)
  }
  func testGenuineVetoCannotAuthorizeNilSuccessor() async throws {
    try await vetoHandoffNegativeRun(.nilAfterVeto)
  }
  func testConfigurationRefusalBeforeNativePermissionHasNoVetoReceipt() async throws {
    try await vetoHandoffNegativeRun(.configurationRefusal)
  }
  func testGenuineVetoCannotSurviveRawTextRevisionABA() async throws {
    try await vetoHandoffNegativeRun(.rawABA)
  }
  func testGenuineVetoCannotSurviveRealEmptyRecorderEpochABA() async throws {
    try await vetoHandoffNegativeRun(.epochABA)
  }
  func testSecondRecognizedNativeVetoCannotReplaceFirstWindowDisposition() async throws {
    try await vetoHandoffNegativeRun(.twoVetoes)
  }
}
