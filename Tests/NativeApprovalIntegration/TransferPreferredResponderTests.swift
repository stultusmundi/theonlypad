// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting

// SPDX-License-Identifier: MIT
// Supplemental actual-process transfer tests. Original App7/probe prefix stays whole.
private enum TransferPreferredTestError: Error { case unavailable, retained }
@MainActor private enum TransferPreferredCustody {
  static var retained: [TransferPreferredFixture] = []
}
@MainActor private final class TransferPreferredFixture {
  let directory: URL
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let session: SessionCoordinator
  let sourceID: UUID, targetID: UUID
  let sourceTabID: UUID
  let tabIDs: [UUID]
  let fileText = "😀e\u{301}\nq"
  var owner: NativeApplicationDocuments!
  var source: EditorWindowController!
  var target: EditorWindowController!
  var model: EditorDocument!
  var preferred: EditorPane!
  var before = ""
  var reports = 0
  var unresolvedActionHistory: UndoManager?
  var capturedStorage: NSTextStorage!
  var capturedHistory: UndoManager!
  var capturedBookmarks = DocumentBookmarks()
  var capturedRecovery: RecoveryWriteAuthority?
  init(neighbor: Bool) throws {
    guard TransferPreferredCustody.retained.isEmpty,
      let state = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"], !state.isEmpty
    else { throw TransferPreferredTestError.unavailable }
    let sourceID = UUID()
    let targetID = UUID()
    self.sourceID = sourceID
    self.targetID = targetID
    let directory = URL(fileURLWithPath: state, isDirectory: true)
      .appendingPathComponent("preferred-" + UUID().uuidString, isDirectory: true)
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    let movedFile = directory.appendingPathComponent("moved.txt")
    let targetFile = directory.appendingPathComponent("target.txt")
    let neighborFile = directory.appendingPathComponent("neighbor.txt")
    for (url, text) in [
      (movedFile, "😀e\u{301}\nq"), (targetFile, "target\n"), (neighborFile, "neighbor\n"),
    ] {
      try Data(text.utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }
    let moved = SessionTab(originalPath: movedFile.path)
    sourceTabID = moved.id
    let other = SessionTab(originalPath: neighborFile.path)
    let targetTab = SessionTab(originalPath: targetFile.path)
    tabIDs = neighbor ? [moved.id, other.id, targetTab.id] : [moved.id, targetTab.id]
    try store.save(
      .init(windows: [
        .init(id: sourceID, tabs: neighbor ? [moved, other] : [moved], selectedTabID: moved.id),
        .init(id: targetID, tabs: [targetTab], selectedTabID: targetTab.id),
      ]))
    let actualStore = store
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try actualStore.save($0) },
      readCheckpointSession: { try actualStore.load() })
    self.recovery = recovery
    session = SessionCoordinator(
      loadSession: { try actualStore.load() },
      claimRecovery: { [recovery] in try await recovery.claimStartup() })
  }
  func start(configuration: Int) async throws {
    owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { [weak self] _ in self?.reports += 1 })
    try await owner.start()
    source = try XCTUnwrap(owner.windows.first { $0.sessionMetadata.id == sourceID })
    target = try XCTUnwrap(owner.windows.first { $0.sessionMetadata.id == targetID })
    model = try XCTUnwrap(owner.registry.handle(id: sourceTabID) as? EditorDocument)
    XCTAssertTrue(source.isWindowLoaded && target.isWindowLoaded)
    XCTAssertFalse(try XCTUnwrap(source.window).isVisible)
    XCTAssertFalse(try XCTUnwrap(target.window).isVisible)
    for id in tabIDs {
      let document = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
      let history = document.undoManager
      ownedModels.append(
        .init(
          model: document, storage: document.storage, history: history,
          groupsByEvent: history.groupsByEvent, modes: history.runLoopModes))
    }
    try requireClosed()
    if configuration != 0 {
      source.execute(configuration == 1 ? "view.splitVertical" : "view.splitHorizontal")
    }
    try requireClosed()
    let panes = model.panePool.filter(\.isAttached)
    XCTAssertEqual(panes.count, configuration == 0 ? 1 : 2)
    guard panes.count == (configuration == 0 ? 1 : 2) else {
      throw TransferPreferredTestError.unavailable
    }
    preferred = try XCTUnwrap(panes.last)
    try requireClosed()
    try source.focusPane(id: preferred.id)
    try requireClosed()
    XCTAssertTrue(source.window?.firstResponder === preferred.editor)
    guard source.window?.firstResponder === preferred.editor else {
      throw TransferPreferredTestError.unavailable
    }
    model.bookmarks = try DocumentBookmarks(offsets: [0], in: fileText)
    capturedBookmarks = model.bookmarks
    capturedRecovery = try XCTUnwrap(model.recoveryAuthority)
    capturedStorage = model.storage
    capturedHistory = model.undoManager
    try installWitness()
    try assertDisplayed(in: source)
    // Genuine pre-existing native history, never cleared or fabricated.
    try nativeAction {
      preferred.editor.insertText("P", replacementRange: NSRange(location: 0, length: 0))
      preferred.editor.breakUndoCoalescing()
    }
    before = "P" + fileText
    XCTAssertEqual(model.storage.string, before)
    let seedBinding = try currentBinding(editor: preferred.editor)
    let seedFence = try makeEventFence()
    XCTAssertTrue(model.undoManager.canUndo)
    try requireFence(seedFence, binding: seedBinding)
    try assertPreservedMetadata()
    guard model.storage.string == before, model.undoManager.canUndo else {
      throw TransferPreferredTestError.unavailable
    }
    try requireFence(seedFence, binding: seedBinding)
  }
  // Every fixture-created model/history is owned from startup, including the neighbor/target.
  struct OwnedModel {
    let model: EditorDocument
    let storage: NSTextStorage
    let history: UndoManager
    let groupsByEvent: Bool
    let modes: [RunLoop.Mode]
  }
  var ownedModels: [OwnedModel] = []
  var incomplete = false
  var knownQuitLedger: TransferPreferredQuitLedger?
  var knownTargetRetirement: TransferPreferredTargetRetirementLedger?
  var retirementMoveID: ApplicationDocumentTransferID?
  var retirementUserChecks: [@MainActor () -> Bool] = []
  var retirementOriginalWindows: [DocumentWindowSnapshot] = []
  var observer: NSObjectProtocol?
  var timer: Timer?
  var closureArmed = false
  var notifications = 0
  var closedAtZero = 0
  var timerTicks = 0
  func retainIncomplete() {
    incomplete = true
    if !TransferPreferredCustody.retained.contains(where: { $0 === self }) {
      TransferPreferredCustody.retained.append(self)
    }
  }
  func unavailable(file: StaticString = #filePath, line: UInt = #line) throws -> Never {
    retainIncomplete()  // Retain BEFORE throwing or entering owner/native cleanup.
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE", file: file, line: line)
    throw TransferPreferredTestError.retained
  }
  func installWitness() throws {
    guard observer == nil, let history = capturedHistory, history.groupingLevel == 0 else {
      try unavailable()
    }
    observer = NotificationCenter.default.addObserver(
      forName: .NSUndoManagerDidCloseUndoGroup, object: history, queue: nil
    ) { [weak self, weak history] note in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard let history, (note.object as? UndoManager) === history,
          self.capturedHistory === history, self.notifications < 256
        else {
          self.retainIncomplete()
          return
        }
        self.notifications += 1
        if self.closureArmed {
          guard history.groupingLevel == 0 else {
            self.retainIncomplete()
            return
          }
          self.closedAtZero += 1
        }
      }
    }
  }
  // Pure identities only. This deliberately does not demand phase0 inside a transfer hook.
  func callbackIdentitiesKnown() -> Bool {
    guard !incomplete, let owner, let model, let capturedStorage, let capturedHistory,
      model.storage === capturedStorage, model.undoManager === capturedHistory,
      owner.registry.handle(id: model.id) === model, ownedModels.count == tabIDs.count
    else { return false }
    return ownedModels.allSatisfy {
      $0.model.storage === $0.storage && $0.model.undoManager === $0.history
        && owner.registry.handle(id: $0.model.id) === $0.model
        && $0.history.groupsByEvent == $0.groupsByEvent && $0.history.runLoopModes == $0.modes
    }
  }
  var bindingDiagnosticEmitted = false
  // Failure observations only: no permission or success code is returned from this path.
  func bindingUnavailable(
    role: Int, selected: Int, evaluated: UInt32, passed: UInt32,
    failed: Int, file: StaticString = #filePath, line: UInt = #line
  ) throws -> Never {
    retainIncomplete()  // Keep every native/model resource BEFORE diagnostic I/O.
    if !bindingDiagnosticEmitted {
      bindingDiagnosticEmitted = true
      FileHandle.standardError.write(
        Data(
          "TRANSFER_BINDING_INCOMPLETE|1|\(role)|\(selected)|\(evaluated)|\(passed)|\(failed)\n"
            .utf8))
    }
    try unavailable(file: file, line: line)
  }
  // Storage attachment and native hosting are separate. Resolve only the CURRENT registry owner.
  func requireRegisteredPaneBinding(
    _ owned: OwnedModel,
    protocolControllers: [EditorWindowController]
  ) throws {
    let document = owned.model
    let role: Int
    if document.id == sourceTabID {
      role = 0
    } else if document.id == tabIDs.last {
      role = 1
    } else if tabIDs.count == 3, document.id == tabIDs[1] {
      role = 2
    } else {
      role = 3
    }
    var selectedRole = 2
    var evaluated: UInt32 = 0
    var passed: UInt32 = 0
    @MainActor func check(
      _ value: Bool, bit: Int,
      file: StaticString = #filePath, line: UInt = #line
    ) throws {
      let mask = UInt32(1) << UInt32(bit)
      evaluated |= mask
      if value {
        passed |= mask
      } else {
        passed &= ~mask
        try bindingUnavailable(
          role: role, selected: selectedRole,
          evaluated: evaluated, passed: passed, failed: bit, file: file, line: line)
      }
    }
    guard let owner else {
      try bindingUnavailable(
        role: role, selected: selectedRole,
        evaluated: 1, passed: 0, failed: 0)
    }
    try check(owner.registry.handle(id: document.id) === document, bit: 0)
    let revision = owner.registry.workspaceRevision
    let capturedAssignment = owner.registry.assignment(of: document.id)
    try check(capturedAssignment != nil, bit: 1)
    // Exact immutable local checked above; never a fresh lookup.
    let assignment = capturedAssignment!
    let capturedSnapshot = owner.registry.window(id: assignment.windowID)
    try check(capturedSnapshot != nil, bit: 2)
    let snapshot = capturedSnapshot!
    try check(snapshot.id == assignment.windowID, bit: 3)
    try check(snapshot.groups.count == 1, bit: 4)
    let group = snapshot.groups[0]
    try check(group.id == assignment.groupID, bit: 5)
    try check(group.documentIDs.contains(document.id), bit: 6)
    try check(snapshot.focusedGroupID == group.id, bit: 7)
    let currentControllers = owner.windows
    let candidates = currentControllers.filter { $0.sessionID == assignment.windowID }
    try check(candidates.count == 1, bit: 8)
    let controller = candidates[0]
    let selection = controller.selectedDocumentID
    try check(selection == group.selectedDocumentID, bit: 12)
    selectedRole = selection == document.id ? 1 : 0
    let panes = document.panePool.filter(\.isAttached)
    // Capture ALL model scalar facts before any native getter, not a newer callback outcome.
    let scalarChecks: [@MainActor () -> Bool] = ownedModels.map { value in
      let model = value.model
      let ownership = model.ownershipGeneration
      let mutation = model.closeMutationGeneration
      let edit = model.editRevision
      let operation = model.operationID
      let configuration = model.nativeConfigurationToken
      let composing = model.composingPaneID
      let saving = model.saving
      let storage = model.storage as? DocumentCommitTextStorage
      let primitive = storage?.nativeMacroPrimitiveState
      let attached = model.panePool.filter(\.isAttached)
      let placement = owner.registry.assignment(of: model.id)
      let registeredHandle = owner.registry.handle(id: model.id)
      let level = value.history.groupingLevel
      return {
        model.storage === value.storage && model.undoManager === value.history
          && owner.registry.handle(id: model.id) === registeredHandle
          && owner.registry.assignment(of: model.id) == placement
          && model.ownershipGeneration == ownership && model.closeMutationGeneration == mutation
          && model.editRevision == edit && model.operationID == operation
          && model.nativeConfigurationToken == configuration && model.composingPaneID == composing
          && model.saving == saving && storage?.nativeMacroPrimitiveState == primitive
          && model.panePool.filter(\.isAttached).map(ObjectIdentifier.init)
            == attached.map(ObjectIdentifier.init)
          && value.history.groupingLevel == level && !value.history.isUndoing
          && !value.history.isRedoing
          && value.history.groupsByEvent == value.groupsByEvent
          && value.history.runLoopModes == value.modes
      }
    }
    @MainActor func originalFacts() -> Bool {
      guard !incomplete, owner.registry.workspaceRevision == revision,
        owner.registry.handle(id: document.id) === document,
        owner.registry.assignment(of: document.id) == assignment,
        owner.registry.window(id: assignment.windowID) == snapshot,
        controller.selectedDocumentID == selection,
        document.panePool.filter(\.isAttached).map(ObjectIdentifier.init)
          == panes.map(ObjectIdentifier.init),
        scalarChecks.allSatisfy({ $0() })
      else { return false }
      let liveControllers = owner.windows
      guard liveControllers.count == currentControllers.count,
        zip(liveControllers, currentControllers).allSatisfy({ $0 === $1 })
      else { return false }
      let context = EditorWindowController.nestedStringTestContext()
      guard context.broker == 0, context.context == 0, !context.overflow else { return false }
      return protocolControllers.allSatisfy {
        let state = $0.nestedStringTestState()
        let focus = $0.transferPreferredTestFacts
        return !state.hasPreparation && !state.hasExplicitFrame && !focus.projecting
          && !focus.scopedFocus
      }
    }
    try check(originalFacts(), bit: 26)
    try check(controller.isWindowLoaded, bit: 9)  // Do not trigger lazy window loading.
    let capturedWindow = controller.window
    try check(originalFacts(), bit: 26)
    try check(capturedWindow != nil, bit: 10)
    let nativeWindow = capturedWindow!
    let nativeWindowController = nativeWindow.windowController
    try check(originalFacts(), bit: 26)
    try check(nativeWindowController === controller, bit: 11)
    for pane in panes {
      try check(originalFacts(), bit: 26)
      try check(pane.document === document, bit: 13)
      let textStorage = pane.editor.textStorage
      try check(originalFacts(), bit: 26)
      try check(textStorage === owned.storage, bit: 14)
      let delegate = pane.editor.delegate
      try check(originalFacts(), bit: 26)
      try check(delegate === controller, bit: 15)
      try check(!pane.editor.isComposingText, bit: 16)
      let logicallyVisible = controller.visiblePanes.contains { $0 === pane }
      if selectedRole == 1 {
        try check(logicallyVisible, bit: 17)
        let editorWindow = pane.editor.window
        try check(originalFacts(), bit: 26)
        try check(editorWindow === nativeWindow, bit: 18)
        let editorWindowController = editorWindow?.windowController
        try check(originalFacts(), bit: 26)
        try check(editorWindowController === controller, bit: 19)
        let scrollWindow = pane.scroll.window
        try check(originalFacts(), bit: 26)
        try check(scrollWindow === nativeWindow, bit: 20)
        let superview = pane.scroll.superview
        try check(originalFacts(), bit: 26)
        try check(superview != nil, bit: 21)
      } else {
        try check(!logicallyVisible, bit: 22)
        let editorWindow = pane.editor.window
        try check(originalFacts(), bit: 26)
        try check(editorWindow == nil, bit: 23)
        let scrollWindow = pane.scroll.window
        try check(originalFacts(), bit: 26)
        try check(scrollWindow == nil, bit: 24)
        let superview = pane.scroll.superview
        try check(originalFacts(), bit: 26)
        try check(superview == nil, bit: 25)
      }
      try check(originalFacts(), bit: 26)
    }
    // Recheck the same exact native owner after all pane getters; never recapture a successor.
    try check(controller.isWindowLoaded, bit: 9)
    let finalWindow = controller.window
    try check(originalFacts(), bit: 26)
    try check(finalWindow === nativeWindow, bit: 27)
    let finalWindowController = nativeWindow.windowController
    try check(originalFacts(), bit: 26)
    try check(finalWindowController === controller, bit: 11)
  }
  func requireCustody(allowRetired: Bool = false, eligible: Bool = false) throws {
    guard !incomplete, let owner, ownedModels.count == tabIDs.count else { try unavailable() }
    let context = EditorWindowController.nestedStringTestContext()
    guard context.broker == 0, context.context == 0, !context.overflow else { try unavailable() }
    var controllers = owner.windows
    for original in [source, target].compactMap({ $0 }) {
      if !controllers.contains(where: { $0 === original }) { controllers.append(original) }
    }
    for controller in controllers {
      let state = controller.nestedStringTestState()
      let focus = controller.transferPreferredTestFacts
      guard !state.hasPreparation, !state.hasExplicitFrame, !focus.projecting, !focus.scopedFocus
      else {
        try unavailable()
      }
    }
    for owned in ownedModels {
      let document = owned.model
      let history = owned.history
      let registered = owner.registry.handle(id: document.id)
      guard document.storage === owned.storage, document.undoManager === history,
        registered === document || (allowRetired && registered == nil),
        history.groupsByEvent == owned.groupsByEvent, history.runLoopModes == owned.modes,
        owned.groupsByEvent, owned.modes.contains(.default), !history.isUndoing, !history.isRedoing,
        let storage = document.storage as? DocumentCommitTextStorage,
        !storage.nativeMacroPrimitiveState.exhausted,
        !storage.nativeMacroPrimitiveState.backingReentry
      else { try unavailable() }
      if registered != nil {
        try requireRegisteredPaneBinding(owned, protocolControllers: controllers)
      }
      if eligible {
        guard document.operationID == nil, document.nativeConfigurationToken == nil,
          document.composingPaneID == nil, !document.saving
        else { try unavailable() }
      }
    }
  }
  func requireClosed(allowRetired: Bool = false) throws {
    try requireCustody(allowRetired: allowRetired)
    guard unresolvedActionHistory == nil,
      ownedModels.allSatisfy({ $0.history.groupingLevel == 0 })
    else { try unavailable() }
  }
  // Capture after the legitimate action. Event pumping cannot hide a callback edit or ABA.
  func makeEventFence(excludingMoved: Bool = false) throws -> @MainActor () -> Bool {
    try requireCustody(eligible: true)
    let checks: [@MainActor () -> Bool] = try ownedModels.filter {
      !excludingMoved || $0.model !== model
    }.map { owned in
      let document = owned.model
      let storage = try XCTUnwrap(document.storage as? DocumentCommitTextStorage)
      let revision = document.editRevision
      let mutation = document.closeMutationGeneration
      let ownership = document.ownershipGeneration
      let primitive = storage.nativeMacroPrimitiveState
      let assignment = owner.registry.assignment(of: document.id)
      return { [self] in
        document.storage === owned.storage && document.undoManager === owned.history
          && owner.registry.handle(id: document.id) === document
          && owner.registry.assignment(of: document.id) == assignment
          && document.editRevision == revision && document.closeMutationGeneration == mutation
          && document.ownershipGeneration == ownership
          && storage.nativeMacroPrimitiveState == primitive
      }
    }
    return { checks.allSatisfy { $0() } }
  }
  func requireFence(_ fence: @MainActor () -> Bool, binding: @MainActor () -> Bool) throws {
    try requireCustody(eligible: true)
    guard fence(), binding(),
      ownedModels.allSatisfy({
        $0.history === capturedHistory || $0.history.groupingLevel == 0
      })
    else { try unavailable() }
  }
  // Synchronous MainActor helper, with the accepted exact-manager/default-mode witness.
  // No Test group begin/end, registration suppression, settings write or manual history clearing.
  func settleNativeEvent(fence: @MainActor () -> Bool, binding: @MainActor () -> Bool) throws {
    try requireFence(fence, binding: binding)
    let history = try XCTUnwrap(capturedHistory)
    if history.groupingLevel == 0 { return }  // Already closed; no invented closure credit.
    guard history.groupingLevel == 1 else { try unavailable() }
    let before = closedAtZero
    let previousTicks = timerTicks
    closureArmed = true
    defer {
      closureArmed = false
      timer?.invalidate()
      timer = nil
    }
    for _ in 0..<8 {
      try requireFence(fence, binding: binding)
      guard history.groupingLevel == 0 || history.groupingLevel == 1 else { try unavailable() }
      let actualTimer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          guard self.timerTicks < 128 else {
            self.retainIncomplete()
            return
          }
          self.timerTicks += 1
        }
      }
      timer = actualTimer
      RunLoop.main.add(actualTimer, forMode: .default)
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))
      try requireFence(fence, binding: binding)
      actualTimer.invalidate()
      timer = nil
      guard history.groupingLevel == 0 || history.groupingLevel == 1 else { try unavailable() }
      guard closedAtZero <= before + 1 else { try unavailable() }
      if timerTicks > previousTicks, closedAtZero == before + 1, history.groupingLevel == 0 {
        return
      }
    }
    try unavailable()
  }
  func currentBinding(editor: DocumentTextView? = nil) throws -> @MainActor () -> Bool {
    try requireClosed()
    try requireCustody(eligible: true)
    let beforeGetters = try makeEventFence()
    guard let assignment = owner.registry.assignment(of: model.id),
      let controller = owner.windows.first(where: { $0.sessionMetadata.id == assignment.windowID }),
      let window = controller.window, let pane = controller.focusedPane,
      pane.document === model, pane.isAttached, pane.editor.window === window,
      pane.editor.textStorage === capturedStorage, pane.editor.delegate === controller,
      !pane.editor.isComposingText, editor == nil || editor === pane.editor
    else { try unavailable() }
    if let editor {
      XCTAssertTrue(
        window.firstResponder === editor, "Native input requires the independent real responder")
      guard window.firstResponder === editor else { throw TransferPreferredTestError.unavailable }
    }
    try requireFence(beforeGetters, binding: { true })
    try requireClosed()
    let ownership = model.ownershipGeneration
    return { [self] in
      owner.registry.handle(id: model.id) === model
        && owner.registry.assignment(of: model.id) == assignment
        && owner.windows.contains(where: { $0 === controller }) && controller.window === window
        && controller.focusedPane === pane && pane.document === model && pane.isAttached
        && pane.editor.window === window && pane.editor.textStorage === capturedStorage
        && pane.editor.delegate === controller && !pane.editor.isComposingText
        && model.ownershipGeneration == ownership
        && (editor == nil || window.firstResponder === editor)
    }
  }
  func performNativeEvent(editor: DocumentTextView? = nil, _ body: @MainActor () -> Void) throws {
    let binding = try currentBinding(editor: editor)
    guard unresolvedActionHistory == nil, binding() else { try unavailable() }
    let preAction = try makeEventFence()
    let otherModels = try makeEventFence(excludingMoved: true)
    // The owner/assignment/binding must not change; only this legitimate action may edit its model.
    guard preAction(), binding() else { try unavailable() }
    unresolvedActionHistory = capturedHistory
    body()
    try requireCustody(eligible: true)
    guard binding(), otherModels() else { try unavailable() }
    let postAction = try makeEventFence()
    try settleNativeEvent(fence: postAction, binding: binding)
    guard capturedHistory.groupingLevel == 0 else { try unavailable() }
    unresolvedActionHistory = nil
    try requireClosed()
  }
  func nativeAction(editor: DocumentTextView? = nil, _ body: @MainActor () -> Void) throws {
    try performNativeEvent(editor: editor ?? preferred.editor, body)
  }
  enum HistoryAction: Equatable { case undo, redo }
  @discardableResult func nativeHistory(
    _ action: HistoryAction,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Bool {
    try requireClosed()
    let binding = try currentBinding()
    let fence = try makeEventFence()
    let available = action == .undo ? capturedHistory.canUndo : capturedHistory.canRedo
    // Getters cannot grant an action after edit/ownership ABA.
    try requireFence(fence, binding: binding)
    try requireClosed()
    XCTAssertTrue(
      available, "Expected native history action is unavailable; dependent branch UNENTERED",
      file: file, line: line)
    guard available else { return false }
    try performNativeEvent {
      if action == .undo { capturedHistory.undo() } else { capturedHistory.redo() }
    }
    return true
  }
  func waitForTransfer(_ id: ApplicationDocumentTransferID) async throws
    -> ApplicationDocumentTransferResult
  {
    try requireClosed()
    let result = try await owner.waitForTransfer(id)
    try requireClosed()
    return result
  }
  func retryRecovery() async throws {
    try requireClosed()
    try await owner.retryRecovery()
    try requireClosed()
  }
  func assertPreservedMetadata(file: StaticString = #filePath, line: UInt = #line) throws {
    try requireClosed()
    XCTAssertTrue(owner.registry.handle(id: model.id) === model, file: file, line: line)
    XCTAssertTrue(model.storage === capturedStorage, file: file, line: line)
    XCTAssertTrue(model.undoManager === capturedHistory, file: file, line: line)
    XCTAssertEqual(model.bookmarks, capturedBookmarks, file: file, line: line)
    XCTAssertNotNil(capturedRecovery, file: file, line: line)
    XCTAssertEqual(model.recoveryAuthority, capturedRecovery, file: file, line: line)
  }
  func assertDisplayed(
    in controller: EditorWindowController, pane expectedPane: EditorPane? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try requireClosed()
    let pane = expectedPane ?? preferred!
    XCTAssertEqual(controller.selectedDocumentID, model.id, file: file, line: line)
    XCTAssertTrue(controller.focusedPane === pane, file: file, line: line)
    XCTAssertEqual(model.preferredPaneID, pane.id, file: file, line: line)
    XCTAssertTrue(controller.visiblePanes.contains { $0 === pane }, file: file, line: line)
    XCTAssertTrue(pane.isAttached && pane.document === model, file: file, line: line)
    XCTAssertNotNil(controller.window, file: file, line: line)
    XCTAssertTrue(pane.editor.window === controller.window, file: file, line: line)
    try assertPreservedMetadata(file: file, line: line)
  }
  func move() throws -> ApplicationDocumentTransferID {
    try requireClosed()
    return try owner.moveDocument(model.id, toWindowID: targetID)
  }
  func restored(_ result: ApplicationDocumentTransferResult) -> Bool {
    if case .restored = result { return true }
    XCTFail("Forward refusal with lawful rollback must restore")
    return false
  }
  func assertRestoredHistory(file: StaticString = #filePath, line: UInt = #line) throws {
    try requireClosed()
    XCTAssertEqual(
      owner.registry.assignment(of: model.id)?.windowID, sourceID, file: file, line: line)
    let actualSource = owner.windows.first { $0.sessionMetadata.id == sourceID }
    XCTAssertTrue(actualSource?.window?.firstResponder === preferred.editor, file: file, line: line)
    XCTAssertTrue(owner.registry.handle(id: model.id) === model, file: file, line: line)
    XCTAssertEqual(model.storage.string, before, file: file, line: line)
    if let actualSource { try assertDisplayed(in: actualSource, file: file, line: line) }
    guard try nativeHistory(.undo, file: file, line: line) else { return }
    XCTAssertEqual(
      model.storage.string, fileText, "Existing native undo remains first", file: file, line: line)
    try assertPreservedMetadata(file: file, line: line)
    guard try nativeHistory(.redo, file: file, line: line) else { return }
    XCTAssertEqual(model.storage.string, before, file: file, line: line)
    try assertPreservedMetadata(file: file, line: line)
    guard try nativeHistory(.undo, file: file, line: line) else { return }
    XCTAssertEqual(model.storage.string, fileText, file: file, line: line)
    if let actualSource { try assertDisplayed(in: actualSource, file: file, line: line) }
  }
  func finish() async throws {
    // Remove only this fixture's passive instrumentation and Test callouts.
    TransferPreferredNativeHook.beforeFocus = nil
    if !incomplete { do { try requireClosed() } catch { retainIncomplete() } }
    closureArmed = false
    timer?.invalidate()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    // The global unknown latch always wins; missing owners cannot enter the quit ledger.
    try requireClosed()
    if let owner {
      if owner.canRetryRecovery { try await retryRecovery() }
      try requireClosed()
      let beforePreparation = try quitModelChecks(includeIssuedRevision: false)
      let receipt: SessionCheckpointReceipt
      do { receipt = try await owner.prepareQuit() } catch {
        retainIncomplete()
        throw error
      }
      let ledger = try captureQuitLedger(receipt: receipt, beforePreparation: beforePreparation)
      try await finishKnownQuit(ledger)
      try ledger.requireBindings()
    }
    do { try FileManager.default.removeItem(at: directory) } catch {
      retainIncomplete()
      knownQuitLedger?.stopPassive()
      throw error
    }
    // Known cleanup acknowledged; break only this successful Test ledger's resource cycle.
    knownQuitLedger?.bindingChecks = []
    knownQuitLedger = nil
    knownTargetRetirement?.stopPassive()
    knownTargetRetirement = nil
    retirementUserChecks = []
  }

}
// Only ordinary cleanup after a genuine final receipt can own this ledger.
// No callers can feed it into source admission or turn an absent endpoint live.
@MainActor private final class TransferPreferredQuitEntry {
  let windowID: UUID
  let endpointID: UUID
  let assignment: DocumentAssignment
  let controller: EditorWindowController
  let window: NSWindow
  let snapshot: DocumentWindowSnapshot
  let visible: [ObjectIdentifier]
  let selection: UUID?
  var notifications = 0
  var retired = false
  var observer: NSObjectProtocol?
  init(
    _ facts: TransferPreferredEndpointFacts, controller: EditorWindowController,
    window: NSWindow, snapshot: DocumentWindowSnapshot
  ) {
    windowID = facts.windowID
    endpointID = facts.endpointID
    assignment = facts.assignment
    self.controller = controller
    self.window = window
    self.snapshot = snapshot
    visible = controller.visiblePanes.map(ObjectIdentifier.init)
    selection = controller.selectedDocumentID
  }
}
@MainActor private final class TransferPreferredQuitLedger {
  let fixture: TransferPreferredFixture
  let receipt: SessionCheckpointReceipt
  let phase: ApplicationPublisherPhase
  let session: EditorSession
  let modelChecks: [@MainActor () -> Bool]
  // Passive strong resources only; never consulted for admission or retirement.
  let capturedEndpointCustody: [TransferPreferredEndpointFacts]
  var observedWindowCustody: [NSWindow] = []
  var entries: [TransferPreferredQuitEntry] = []
  var bindingChecks: [@MainActor () throws -> Void] = []
  var revision: UUID
  var expectedWindows: [DocumentWindowSnapshot]
  var closing: UUID?
  init(
    _ fixture: TransferPreferredFixture, receipt: SessionCheckpointReceipt,
    phase: ApplicationPublisherPhase, session: EditorSession,
    modelChecks: [@MainActor () -> Bool], windows: [DocumentWindowSnapshot],
    endpointCustody: [TransferPreferredEndpointFacts]
  ) {
    self.fixture = fixture
    self.receipt = receipt
    self.phase = phase
    self.session = session
    self.modelChecks = modelChecks
    expectedWindows = windows
    capturedEndpointCustody = endpointCustody
    revision = fixture.owner.registry.workspaceRevision
  }
  func stopPassive() {
    for entry in entries {
      if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
      entry.observer = nil
    }
  }
  func fail() throws -> Never {
    fixture.retainIncomplete()  // Keep the stored ledger and all native resources before I/O/throw.
    stopPassive()
    try fixture.unavailable()
  }
  func requireCore(checkRevision: Bool = true, checkEndpoints: Bool = true) throws {
    let f = fixture
    guard !f.incomplete, f.unresolvedActionHistory == nil,
      TransferPreferredCustody.retained.isEmpty,
      modelChecks.allSatisfy({ $0() })
    else { try fail() }
    let context = EditorWindowController.nestedStringTestContext()
    guard context.broker == 0, context.context == 0, !context.overflow else { try fail() }
    for controller in [f.source, f.target].compactMap({ $0 }) + entries.map(\.controller) {
      let state = controller.nestedStringTestState()
      let focus = controller.transferPreferredTestFacts
      guard !state.hasPreparation, !state.hasExplicitFrame,
        !focus.projecting, !focus.scopedFocus
      else { try fail() }
    }
    let facts = f.owner.transferPreferredTestQuitFacts
    guard facts.quitting, facts.phase == phase, !facts.checkpointHasError,
      receipt.generation > 0, facts.acknowledgedGeneration == receipt.generation
    else { try fail() }
    if checkRevision {
      guard f.owner.registry.workspaceRevision == revision,
        f.owner.registry.windowIDs == expectedWindows.map(\.id),
        expectedWindows.allSatisfy({ f.owner.registry.window(id: $0.id) == $0 })
      else { try fail() }
    }
    if checkEndpoints {
      let live = entries.filter { !$0.retired }
      guard facts.endpoints.count == live.count else { try fail() }
      for row in facts.endpoints {
        guard let exact = live.first(where: { $0.windowID == row.windowID }),
          row.endpointID == exact.endpointID, row.assignment == exact.assignment,
          row.controller === exact.controller
        else { try fail() }
      }
      let current = f.owner.windows
      guard current.count == live.count,
        live.allSatisfy({ entry in current.contains { $0 === entry.controller } })
      else { try fail() }
    }
  }
  func requireBindings() throws {
    try requireCore()
    for entry in entries {
      let facts = entry.controller.managedSearchTestFacts
      guard facts.windowClosed == entry.retired,
        entry.controller.xmlNativeTestPreparingToQuit,
        facts.endpointID == entry.endpointID,
        facts.documentIDs == entry.snapshot.groups.flatMap(\.documentIDs),
        facts.selectedDocumentID == entry.selection,
        entry.controller.selectedDocumentID == entry.selection,
        entry.controller.visiblePanes.map(ObjectIdentifier.init) == entry.visible,
        entry.controller.isWindowLoaded
      else { try fail() }
      let window = entry.controller.window
      try requireCore()
      guard window === entry.window else { try fail() }
      let controller = entry.window.windowController
      try requireCore()
      guard controller === entry.controller else { try fail() }
    }
    for check in bindingChecks { try check() }
    try requireCore()
  }
  func armObservers() throws {
    try requireBindings()
    for entry in entries {
      guard entry.observer == nil, entry.notifications == 0, !entry.retired else { try fail() }
      entry.observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: entry.window, queue: nil
      ) { [weak self, weak entry] note in
        MainActor.assumeIsolated {
          guard let self, let entry else { return }
          guard !self.fixture.incomplete, self.closing == entry.windowID,
            (note.object as? NSWindow) === entry.window, entry.notifications == 0,
            !entry.retired
          else {
            self.fixture.retainIncomplete()
            return
          }
          entry.notifications += 1  // No native getter/delegate ordering assumption here.
        }
      }
    }
    try requireBindings()
  }
  func close(_ entry: TransferPreferredQuitEntry) throws {
    try requireBindings()
    guard closing == nil, !entry.retired, entry.notifications == 0 else { try fail() }
    let oldRevision = revision
    let oldWindows = expectedWindows
    closing = entry.windowID
    entry.window.close()  // The actual native call, exactly once for this captured entry.
    closing = nil
    // Do not run LIVE lookup while proving the exact just-closed endpoint's transition.
    try requireCore(checkRevision: false, checkEndpoints: false)
    let current = fixture.owner.transferPreferredTestQuitFacts
    guard entry.notifications == 1, entry.controller.managedSearchTestFacts.windowClosed,
      entry.controller.xmlNativeTestPreparingToQuit,
      !current.endpoints.contains(where: { $0.windowID == entry.windowID })
    else { try fail() }
    let stillLive = entries.filter { !$0.retired && $0 !== entry }
    guard current.endpoints.count == stillLive.count,
      current.endpoints.allSatisfy({ row in
        stillLive.contains {
          $0.windowID == row.windowID && $0.endpointID == row.endpointID
            && $0.assignment == row.assignment && row.controller === $0.controller
        }
      })
    else { try fail() }
    let empty = entry.snapshot.groups.allSatisfy { $0.documentIDs.isEmpty }
    let expected = empty ? oldWindows.filter { $0.id != entry.windowID } : oldWindows
    guard fixture.owner.registry.windowIDs == expected.map(\.id),
      expected.allSatisfy({ fixture.owner.registry.window(id: $0.id) == $0 }),
      !empty || fixture.owner.registry.window(id: entry.windowID) == nil,
      empty
        ? fixture.owner.registry.workspaceRevision != oldRevision
        : fixture.owner.registry.workspaceRevision == oldRevision
    else { try fail() }
    // Adopt only the proven exact empty-window removal, never a different topology/model.
    try requireCore(checkRevision: false, checkEndpoints: false)
    expectedWindows = expected
    revision = fixture.owner.registry.workspaceRevision
    entry.retired = true
    try requireBindings()
    guard entries.allSatisfy({ $0.notifications == ($0.retired ? 1 : 0) }) else { try fail() }
  }
}

@MainActor extension TransferPreferredFixture {
  // Core model reads; preparation is allowed only its real presentation/interactivity/revision issuance.
  fileprivate func quitModelChecks(includeIssuedRevision: Bool) throws -> [@MainActor () -> Bool] {
    guard ownedModels.count == tabIDs.count else { try unavailable() }
    return try ownedModels.map { owned in
      let d = owned.model
      guard let storage = d.storage as? DocumentCommitTextStorage,
        owner.registry.handle(id: d.id) === d, let placement = owner.registry.assignment(of: d.id),
        let metadata = owner.registry.metadata(id: d.id),
        owner.registry.adoptionStatus(documentID: d.id) == .active,
        owner.registry.closeStatus(documentID: d.id) == .open,
        d.operationID == nil, d.nativeConfigurationToken == nil, d.composingPaneID == nil,
        !d.saving, d.panePresentation.installing == nil, owned.history.groupingLevel == 0,
        !storage.nativeMacroPrimitiveState.exhausted,
        !storage.nativeMacroPrimitiveState.backingReentry
      else { try unavailable() }
      let primitive = storage.nativeMacroPrimitiveState
      let text = d.storage.string
      let edit = d.editRevision
      let mutation = d.closeMutationGeneration
      let ownership = d.ownershipGeneration
      let authority = d.recoveryAuthority
      let issued = d.highestIssuedRecoveryRevision
      let marks = d.bookmarks
      let pending = d.pendingBookmarks
      let pendingUndo = d.pendingBookmarksHaveUndo
      let composition = d.compositionBookmarks
      let originalComposition = d.compositionOriginalText
      let compositionUndo = d.compositionUndoRegistered
      let nextTyping = d.typingBookmarkNextLocation
      let encoding = d.encoding
      let bom = d.hasBOM
      let savedEncoding = d.savedEncoding
      let savedBOM = d.savedHasBOM
      let url = d.url
      let bytes = d.originalBytes
      let savedText = d.savedText
      let publication = d.pendingPublication?.id
      let pinned = d.pinned
      let language = d.language
      let manual = d.manualLanguage
      let typography = d.appliedTypography
      let wrap = d.appliedWrap
      let preferred = d.preferredPaneID
      let axis = d.splitAxis
      let panes = d.panePool
      let attached = panes.map(\.isAttached)
      let presentation = d.panePresentation
      let interaction = presentation.interaction
      let frozen = presentation.frozenCapture
      let pendingPresentation = presentation.pending?.presentation
      let pendingPane = presentation.pending?.livePaneID
      let pendingSlot = presentation.pending?.liveSlot
      let pendingRevision = presentation.pending?.resolvedAtRevision
      let presented = presentation.pending?.presented
      let warning = presentation.warning
      let suppression = presentation.suppression
      return { [self] in
        d.storage === owned.storage && d.undoManager === owned.history
          && owner.registry.handle(id: d.id) === d
          && owner.registry.assignment(of: d.id) == placement
          && owner.registry.metadata(id: d.id) == metadata
          && owner.registry.adoptionStatus(documentID: d.id) == .active
          && owner.registry.closeStatus(documentID: d.id) == .open
          && storage.nativeMacroPrimitiveState == primitive && d.storage.string == text
          && d.editRevision == edit && d.closeMutationGeneration == mutation
          && d.ownershipGeneration == ownership && d.recoveryAuthority == authority
          && (!includeIssuedRevision || d.highestIssuedRecoveryRevision == issued)
          && d.bookmarks == marks && d.pendingBookmarks == pending
          && d.pendingBookmarksHaveUndo == pendingUndo
          && d.compositionBookmarks == composition
          && d.compositionOriginalText == originalComposition
          && d.compositionUndoRegistered == compositionUndo
          && d.typingBookmarkNextLocation == nextTyping
          && d.encoding == encoding && d.hasBOM == bom && d.savedEncoding == savedEncoding
          && d.savedHasBOM == savedBOM
          && d.url == url && d.originalBytes == bytes && d.savedText == savedText
          && d.pendingPublication?.id == publication
          && d.pinned == pinned && d.language == language && d.manualLanguage == manual
          && d.appliedTypography == typography && d.appliedWrap == wrap
          && d.preferredPaneID == preferred && d.splitAxis == axis
          && d.operationID == nil && d.nativeConfigurationToken == nil && d.composingPaneID == nil
          && !d.saving
          && presentation.installing == nil
          && (!includeIssuedRevision
            || (presentation.interaction == interaction && presentation.frozenCapture == frozen
              && presentation.pending?.presentation == pendingPresentation
              && presentation.pending?.livePaneID == pendingPane
              && presentation.pending?.liveSlot == pendingSlot
              && presentation.pending?.resolvedAtRevision == pendingRevision
              && presentation.pending?.presented == presented && presentation.warning == warning
              && presentation.suppression == suppression))
          && d.panePool.map(ObjectIdentifier.init) == panes.map(ObjectIdentifier.init)
          && d.panePool.map(\.isAttached) == attached
          && owned.history.groupingLevel == 0 && !owned.history.isUndoing
          && !owned.history.isRedoing
          && owned.history.groupsByEvent == owned.groupsByEvent
          && owned.history.runLoopModes == owned.modes
          && owned.groupsByEvent && owned.modes.contains(.default)
      }
    }
  }
  fileprivate func captureQuitLedger(
    receipt: SessionCheckpointReceipt,
    beforePreparation: [@MainActor () -> Bool]
  ) throws -> TransferPreferredQuitLedger {
    try requireClosed()
    guard !incomplete, beforePreparation.allSatisfy({ $0() }) else { try unavailable() }
    let facts = owner.transferPreferredTestQuitFacts
    guard facts.quitting, case .finalReady = facts.phase,
      facts.acknowledgedGeneration == receipt.generation, receipt.generation > 0,
      !facts.checkpointHasError,
      Set(receipt.recoveryRevisions.keys) == Set(tabIDs),
      Set(receipt.recoveryAuthorities.keys) == Set(tabIDs)
    else { try unavailable() }
    for owned in ownedModels {
      let d = owned.model
      guard let authority = d.recoveryAuthority,
        receipt.recoveryAuthorities[d.id] == authority,
        authority.coordinatorID == recovery.coordinatorID,
        let issued = receipt.recoveryRevisions[d.id], issued > 0,
        d.highestIssuedRecoveryRevision == issued
      else { try unavailable() }
    }
    let checks = try quitModelChecks(includeIssuedRevision: true)
    let windowIDs = owner.registry.windowIDs
    var windows: [DocumentWindowSnapshot] = []
    for id in windowIDs {
      guard id == sourceID || id == targetID, let snapshot = owner.registry.window(id: id),
        snapshot.groups.count == 1
      else { try unavailable() }
      windows.append(snapshot)
    }
    guard Set(windows.flatMap { $0.groups.flatMap(\.documentIDs) }) == Set(tabIDs),
      windows.flatMap({ $0.groups.flatMap(\.documentIDs) }).count == tabIDs.count,
      facts.endpoints.count == windowIDs.count,
      Set(facts.endpoints.map(\.windowID)) == Set(windowIDs)
    else { try unavailable() }
    let loaded: EditorSession
    do {
      guard let actual = try store.load() else { try unavailable() }
      loaded = actual
    } catch {
      retainIncomplete()
      throw error
    }
    guard !incomplete, beforePreparation.allSatisfy({ $0() }), checks.allSatisfy({ $0() }),
      owner.registry.windowIDs == windowIDs,
      windows.allSatisfy({ owner.registry.window(id: $0.id) == $0 }),
      loaded.windows.map(\.id) == windowIDs
    else { try unavailable() }
    for snapshot in windows {
      guard let saved = loaded.windows.first(where: { $0.id == snapshot.id }),
        saved.tabs.map(\.id) == snapshot.groups[0].documentIDs,
        saved.selectedTabID == snapshot.groups[0].selectedDocumentID
      else { try unavailable() }
      for tab in saved.tabs {
        guard let d = ownedModels.first(where: { $0.model.id == tab.id })?.model,
          tab.originalPath == d.url?.path, tab.pinned == d.pinned,
          tab.encoding == d.savedEncoding, tab.bookmarks == d.bookmarks.offsets,
          tab.manualLanguage == (d.manualLanguage ? d.language : nil)
        else { try unavailable() }
      }
    }
    let ledger = TransferPreferredQuitLedger(
      self, receipt: receipt, phase: facts.phase,
      session: loaded, modelChecks: checks, windows: windows, endpointCustody: facts.endpoints)
    knownQuitLedger = ledger  // Resource custody before any native callback/getter or close.
    @MainActor func captureFence() throws {
      try ledger.requireCore(checkEndpoints: false)
      let current = owner.transferPreferredTestQuitFacts
      guard current.endpoints.count == facts.endpoints.count,
        current.endpoints.allSatisfy({ row in
          facts.endpoints.contains {
            $0.windowID == row.windowID && $0.endpointID == row.endpointID
              && $0.assignment == row.assignment && row.controller === $0.controller
          }
        }), owner.windows.count == facts.endpoints.count,
        owner.windows.allSatisfy({ c in facts.endpoints.contains { $0.controller === c } })
      else { try ledger.fail() }
    }
    for row in facts.endpoints {
      try captureFence()
      guard let c = row.controller, let snapshot = windows.first(where: { $0.id == row.windowID }),
        row.assignment.windowID == row.windowID, row.assignment.groupID == snapshot.groups[0].id,
        snapshot.focusedGroupID == row.assignment.groupID,
        c.sessionID == row.windowID, c.isWindowLoaded,
        !c.managedSearchTestFacts.windowClosed, c.xmlNativeTestPreparingToQuit,
        c.managedSearchTestFacts.endpointID == row.endpointID,
        c.managedSearchTestFacts.documentIDs == snapshot.groups[0].documentIDs,
        c.selectedDocumentID == snapshot.groups[0].selectedDocumentID,
        !ledger.entries.contains(where: { $0.controller === c })
      else { try ledger.fail() }
      let visible = c.visiblePanes.map(ObjectIdentifier.init)
      let w = c.window
      // Retain before any possible refusal/unwind.
      if let w { ledger.observedWindowCustody.append(w) }
      try captureFence()
      guard c.selectedDocumentID == snapshot.groups[0].selectedDocumentID,
        c.visiblePanes.map(ObjectIdentifier.init) == visible, let window = w,
        !ledger.entries.contains(where: { $0.window === window })
      else { try ledger.fail() }
      ledger.entries.append(.init(row, controller: c, window: window, snapshot: snapshot))
    }
    try ledger.requireCore()
    // Capture scalar bindings first; native getters are followed by original-fact rechecks.
    for owned in ownedModels {
      guard let placement = owner.registry.assignment(of: owned.model.id),
        let entry = ledger.entries.first(where: { $0.windowID == placement.windowID })
      else { try ledger.fail() }
      for pane in owned.model.panePool where pane.isAttached {
        try ledger.requireCore()
        guard pane.document === owned.model else { try ledger.fail() }
        let textStorage = pane.editor.textStorage
        try ledger.requireCore()
        guard textStorage === owned.storage else { try ledger.fail() }
        let delegate = pane.editor.delegate
        try ledger.requireCore()
        guard delegate === entry.controller else { try ledger.fail() }
        let editorWindow = pane.editor.window
        try ledger.requireCore()
        let scrollWindow = pane.scroll.window
        try ledger.requireCore()
        let superview = pane.scroll.superview
        try ledger.requireCore()
        let selected = entry.selection == owned.model.id
        let composing = pane.editor.isComposingText
        try ledger.requireCore()
        guard !composing,
          selected
            ? (editorWindow === entry.window && scrollWindow === entry.window && superview != nil)
            : (editorWindow == nil && scrollWindow == nil && superview == nil),
          entry.controller.visiblePanes.contains(where: { $0 === pane }) == selected
        else { try ledger.fail() }
        ledger.bindingChecks.append { [ledger, pane, entry] in
          try ledger.requireCore()
          guard pane.document === owned.model, pane.isAttached else { try ledger.fail() }
          let storage = pane.editor.textStorage
          try ledger.requireCore()
          guard storage === textStorage else { try ledger.fail() }
          let delegate = pane.editor.delegate
          try ledger.requireCore()
          guard delegate === entry.controller else { try ledger.fail() }
          let w = pane.editor.window
          try ledger.requireCore()
          guard w === editorWindow else { try ledger.fail() }
          let scroll = pane.scroll.window
          try ledger.requireCore()
          guard scroll === scrollWindow else { try ledger.fail() }
          let parent = pane.scroll.superview
          try ledger.requireCore()
          guard parent === superview else { try ledger.fail() }
          let composing = pane.editor.isComposingText
          try ledger.requireCore()
          guard !composing else { try ledger.fail() }
          let editable = pane.editor.isEditable
          try ledger.requireCore()
          guard !editable else { try ledger.fail() }
          let selectable = pane.editor.isSelectable
          try ledger.requireCore()
          guard !selectable else { try ledger.fail() }
        }
      }
    }
    try ledger.requireBindings()
    return ledger
  }
  fileprivate func finishKnownQuit(_ ledger: TransferPreferredQuitLedger) async throws {
    try ledger.armObservers()
    for entry in ledger.entries { try ledger.close(entry) }
    try ledger.requireBindings()
    guard ledger.entries.allSatisfy({ $0.retired && $0.notifications == 1 }),
      owner.transferPreferredTestQuitFacts.endpoints.isEmpty, owner.windows.isEmpty
    else { try ledger.fail() }
    do { try EditorWindowController.assertNoPendingCloses() } catch { try ledger.fail() }
    try ledger.requireBindings()
    do { try await EditorWindowController.drainPendingCloses() } catch { try ledger.fail() }
    try ledger.requireBindings()
    do { try EditorWindowController.assertNoPendingCloses() } catch { try ledger.fail() }
    try ledger.requireBindings()
    let loaded: EditorSession
    do {
      guard let actual = try store.load() else { try ledger.fail() }
      loaded = actual
    } catch {
      retainIncomplete()
      ledger.stopPassive()
      throw error
    }
    try ledger.requireBindings()
    guard loaded == ledger.session else { try ledger.fail() }
    ledger.stopPassive()
    try ledger.requireBindings()
  }
}

// Exact intentional-retirement evidence only; never an editor admission predicate.
private final class TransferPreferredRetirementNotice: @unchecked Sendable {
  private let lock = NSLock()
  private var inside = false
  private var records: [(ObjectIdentifier, Bool, Bool)] = []
  private var overflow = false
  func arm(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    inside = value
  }
  func record(_ note: Notification) {
    guard let object = note.object as? NSWindow else { return }
    let identity = ObjectIdentifier(object)
    let main = Thread.isMainThread
    lock.lock()
    defer { lock.unlock() }
    guard records.count < 2 else {
      overflow = true
      return
    }
    records.append((identity, main, inside))
  }
  func witnessed(_ window: NSWindow) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !inside && !overflow && records.count == 1
      && records[0].0 == ObjectIdentifier(window) && records[0].1 && records[0].2
  }
}

@MainActor private final class TransferPreferredTargetRetirementLedger {
  let fixture: TransferPreferredFixture
  let moveID: ApplicationDocumentTransferID
  let captured: TransferPreferredRetirementOwnerFacts
  let windowIDs: [UUID]
  let windows: [DocumentWindowSnapshot]
  let revision: UUID
  let notice = TransferPreferredRetirementNotice()
  var observedObjects: [AnyObject] = []
  var nativeWindows: [UUID: NSWindow] = [:]
  var modelChecks: [@MainActor () -> Bool] = []
  var protocolChecks: [@MainActor () -> Bool] = []
  var restoredModelChecks: [@MainActor () -> Bool] = []
  var observer: NSObjectProtocol?
  var closedController: EditorWindowController?
  var closedWindow: NSWindow?
  var replacementCustody: [TransferPreferredRetirementEndpointFacts] = []
  var retired = false
  var restored = false
  init(
    _ f: TransferPreferredFixture, id: ApplicationDocumentTransferID,
    captured: TransferPreferredRetirementOwnerFacts
  ) {
    fixture = f
    moveID = id
    self.captured = captured
    windowIDs = f.owner.registry.windowIDs
    windows = windowIDs.compactMap { f.owner.registry.window(id: $0) }
    revision = f.owner.registry.workspaceRevision
  }
  func hold(_ object: AnyObject?) { if let object { observedObjects.append(object) } }
  func stopPassive() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
  func fail() throws -> Never {
    fixture.retainIncomplete()  // Ledger is already fixture-owned, before I/O or unwind.
    stopPassive()
    try fixture.unavailable()
  }
  func sameRows(
    _ current: [TransferPreferredRetirementEndpointFacts],
    _ expected: [TransferPreferredRetirementEndpointFacts]
  ) -> Bool {
    current.count == expected.count && Set(current.map(\.windowID)).count == current.count
      && current.allSatisfy { row in
        expected.contains {
          $0.windowID == row.windowID && $0.identity == row.identity
            && $0.endpointID == row.endpointID
            && $0.assignment == row.assignment && row.controller === $0.controller
        }
      }
  }
  func samePresentation(_ facts: TransferPreferredRetirementOwnerFacts) -> Bool {
    guard let original = captured.presentation, let current = facts.presentation else {
      return false
    }
    return facts.moveID == moveID && current.identity == original.identity
      && current.transactionID == original.transactionID && current.request == original.request
      && current.model === original.model && current.sourceIdentity == original.sourceIdentity
      && current.sourceEndpointID == original.sourceEndpointID
      && current.targetIdentity == original.targetIdentity
      && current.targetEndpointID == original.targetEndpointID
  }
  func common() throws {
    let f = fixture
    guard Thread.isMainThread, !f.incomplete, TransferPreferredCustody.retained.isEmpty,
      f.knownTargetRetirement === self, f.retirementMoveID == moveID,
      f.unresolvedActionHistory == nil, f.callbackIdentitiesKnown(),
      !f.retirementUserChecks.isEmpty, f.retirementUserChecks.allSatisfy({ $0() }),
      f.ownedModels.count == f.tabIDs.count
    else { try fail() }
    let context = EditorWindowController.nestedStringTestContext()
    guard context.broker == 0, context.context == 0, !context.overflow else { try fail() }
    for owned in f.ownedModels {
      let d = owned.model
      let history = owned.history
      guard f.owner.registry.handle(id: d.id) === d, d.storage === owned.storage,
        d.undoManager === history, history.groupingLevel == 0,
        !history.isUndoing, !history.isRedoing,
        history.groupsByEvent == owned.groupsByEvent, history.runLoopModes == owned.modes,
        owned.groupsByEvent, owned.modes.contains(.default),
        d.operationID == nil, d.nativeConfigurationToken == nil, d.composingPaneID == nil,
        !d.saving, d.panePresentation.installing == nil,
        let storage = d.storage as? DocumentCommitTextStorage,
        !storage.nativeMacroPrimitiveState.exhausted,
        !storage.nativeMacroPrimitiveState.backingReentry
      else { try fail() }
    }
  }
  func captureFence() throws {
    try common()
    guard !retired, !restored, samePresentation(fixture.owner.transferPreferredRetirementTestFacts),
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, captured.endpoints),
      windows.count == windowIDs.count, fixture.owner.registry.windowIDs == windowIDs,
      fixture.owner.registry.workspaceRevision == revision,
      windows.allSatisfy({ fixture.owner.registry.window(id: $0.id) == $0 }),
      modelChecks.allSatisfy({ $0() }), protocolChecks.allSatisfy({ $0() })
    else { try fail() }
  }
  func requireIdleProtocols() throws {
    let f = fixture
    for c in captured.endpoints.compactMap(\.controller) + f.owner.windows {
      let state = c.nestedStringTestState()
      let focus = c.transferPreferredTestFacts
      guard !state.hasPreparation, !state.hasExplicitFrame,
        !focus.projecting, !focus.scopedFocus
      else { try fail() }
    }
  }
  func requireGap() throws {
    try common()
    try requireIdleProtocols()
    guard retired, !restored, let controller = closedController, let window = closedWindow,
      notice.witnessed(window), controller.managedSearchTestFacts.windowClosed,
      let row = captured.endpoints.first(where: { $0.windowID == fixture.targetID }),
      controller === row.controller, controller.managedSearchTestFacts.endpointID == row.endpointID,
      samePresentation(fixture.owner.transferPreferredRetirementTestFacts),
      sameRows(
        fixture.owner.transferPreferredRetirementTestFacts.endpoints,
        captured.endpoints.filter { $0.windowID != fixture.targetID }),
      fixture.owner.registry.windowIDs == windowIDs,
      fixture.owner.registry.workspaceRevision == revision,
      windows.allSatisfy({ fixture.owner.registry.window(id: $0.id) == $0 }),
      modelChecks.allSatisfy({ $0() })
    else { try fail() }
    let current = fixture.owner.windows
    guard current.count == captured.endpoints.count - 1,
      current.allSatisfy({ c in
        captured.endpoints.contains { $0.windowID != fixture.targetID && $0.controller === c }
      })
    else { try fail() }
    // Only models bound to the proven missing target avoid retired native getters.
    for owned in fixture.ownedModels {
      guard let placement = fixture.owner.registry.assignment(of: owned.model.id) else {
        try fail()
      }
      if placement.windowID == fixture.targetID {
        guard placement == row.assignment,
          windows.first(where: { $0.id == fixture.targetID })?.groups.first?.documentIDs.contains(
            owned.model.id) == true
        else { try fail() }
      } else {
        try fixture.requireRegisteredPaneBinding(
          owned,
          protocolControllers: captured.endpoints.compactMap(\.controller) + current)
        try common()
      }
    }
    guard modelChecks.allSatisfy({ $0() }) else { try fail() }
  }
  func captureNativeGraph() throws {
    let f = fixture
    for row in captured.endpoints {
      try captureFence()
      guard let c = row.controller, c.sessionID == row.windowID, c.isWindowLoaded,
        !c.managedSearchTestFacts.windowClosed,
        c.managedSearchTestFacts.endpointID == row.endpointID,
        let snapshot = windows.first(where: { $0.id == row.windowID }), snapshot.groups.count == 1,
        row.assignment.windowID == row.windowID, snapshot.groups[0].id == row.assignment.groupID,
        snapshot.focusedGroupID == row.assignment.groupID,
        c.selectedDocumentID == snapshot.groups[0].selectedDocumentID,
        c.managedSearchTestFacts.documentIDs == snapshot.groups[0].documentIDs,
        c.managedSearchTestFacts.selectedDocumentID == snapshot.groups[0].selectedDocumentID
      else { try fail() }
      let window = c.window
      hold(window)  // Retain ANY returned resource before a possible failing recheck.
      try captureFence()
      guard let window, nativeWindows.values.allSatisfy({ $0 !== window }) else { try fail() }
      let nativeController = window.windowController
      hold(nativeController)
      try captureFence()
      guard nativeController === c else { try fail() }
      nativeWindows[row.windowID] = window
    }
    for owned in f.ownedModels {
      guard let placement = f.owner.registry.assignment(of: owned.model.id),
        let row = captured.endpoints.first(where: { $0.windowID == placement.windowID }),
        let c = row.controller, let window = nativeWindows[row.windowID],
        placement == row.assignment,
        let snapshot = windows.first(where: { $0.id == row.windowID }), snapshot.groups.count == 1,
        snapshot.groups[0].documentIDs.contains(owned.model.id)
      else { try fail() }
      let selected = c.selectedDocumentID == owned.model.id
      for pane in owned.model.panePool where pane.isAttached {
        try captureFence()
        guard pane.document === owned.model else { try fail() }
        let storage = pane.editor.textStorage
        hold(storage)
        try captureFence()
        guard storage === owned.storage else { try fail() }
        let delegate = pane.editor.delegate
        hold(delegate)
        try captureFence()
        guard delegate === c else { try fail() }
        let editorWindow = pane.editor.window
        hold(editorWindow)
        try captureFence()
        let scrollWindow = pane.scroll.window
        hold(scrollWindow)
        try captureFence()
        let parent = pane.scroll.superview
        hold(parent)
        try captureFence()
        let composing = pane.editor.isComposingText
        try captureFence()
        guard !composing, c.visiblePanes.contains(where: { $0 === pane }) == selected,
          selected
            ? (editorWindow === window && scrollWindow === window && parent != nil)
            : (editorWindow == nil && scrollWindow == nil && parent == nil)
        else { try fail() }
      }
    }
    for row in captured.endpoints {
      guard let c = row.controller, let original = nativeWindows[row.windowID] else { try fail() }
      let window = c.window
      hold(window)
      try captureFence()
      guard window === original else { try fail() }
      let controller = original.windowController
      hold(controller)
      try captureFence()
      guard controller === c else { try fail() }
    }
    try captureFence()
  }
  func closeActualTarget() throws {
    try captureFence()
    try captureNativeGraph()
    guard let row = captured.endpoints.first(where: { $0.windowID == fixture.targetID }),
      let controller = row.controller, controller === fixture.target,
      let window = nativeWindows[row.windowID], observer == nil,
      !controller.managedSearchTestFacts.windowClosed
    else { try fail() }
    closedController = controller
    closedWindow = window
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: nil
    ) { [notice] note in notice.record(note) }
    try captureFence()
    notice.arm(true)
    window.close()  // The one actual close, on the proven original target only.
    notice.arm(false)
    try common()
    let current = fixture.owner.transferPreferredRetirementTestFacts
    guard notice.witnessed(window), controller.managedSearchTestFacts.windowClosed,
      controller.managedSearchTestFacts.endpointID == row.endpointID,
      samePresentation(current),
      sameRows(current.endpoints, captured.endpoints.filter { $0.windowID != fixture.targetID }),
      fixture.owner.registry.windowIDs == windowIDs,
      fixture.owner.registry.workspaceRevision == revision,
      windows.allSatisfy({ fixture.owner.registry.window(id: $0.id) == $0 }),
      modelChecks.allSatisfy({ $0() }), protocolChecks.allSatisfy({ $0() })
    else { try fail() }
    retired = true  // Test evidence only; never returned to Source admission.
    stopPassive()
  }
  func adoptRestoredSuccessor(_ result: ApplicationDocumentTransferResult) throws {
    try common()
    try requireIdleProtocols()
    guard case .restored = result, retired, !restored,
      let oldController = closedController, let oldWindow = closedWindow,
      notice.witnessed(oldWindow), oldController.managedSearchTestFacts.windowClosed
    else { try fail() }
    let current = fixture.owner.transferPreferredRetirementTestFacts
    replacementCustody = current.endpoints  // Full strong map BEFORE any native getters.
    guard current.moveID == nil, current.presentation == nil,
      current.endpoints.count == captured.endpoints.count,
      sameRows(
        current.endpoints.filter { $0.windowID != fixture.targetID },
        captured.endpoints.filter { $0.windowID != fixture.targetID }),
      let original = captured.endpoints.first(where: { $0.windowID == fixture.targetID }),
      let successor = current.endpoints.first(where: { $0.windowID == fixture.targetID }),
      current.endpoints.filter({ $0.windowID == fixture.targetID }).count == 1,
      successor.identity != original.identity, successor.endpointID != original.endpointID,
      successor.assignment == original.assignment, let controller = successor.controller,
      controller !== oldController, controller.sessionID == fixture.targetID,
      controller.isWindowLoaded,
      !controller.managedSearchTestFacts.windowClosed,
      controller.managedSearchTestFacts.endpointID == successor.endpointID,
      fixture.owner.registry.windowIDs == fixture.retirementOriginalWindows.map(\.id),
      fixture.retirementOriginalWindows.allSatisfy({
        fixture.owner.registry.window(id: $0.id) == $0
      }),
      fixture.owner.registry.assignment(of: fixture.model.id)?.windowID == fixture.sourceID
    else { try fail() }
    let restoredRevision = fixture.owner.registry.workspaceRevision
    restoredModelChecks = try fixture.quitModelChecks(includeIssuedRevision: true)
    guard restoredModelChecks.allSatisfy({ $0() }) else { try fail() }
    let window = controller.window
    hold(window)
    try common()
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }),
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, current.endpoints),
      let window, window !== oldWindow
    else { try fail() }
    let nativeController = window.windowController
    hold(nativeController)
    try common()
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }),
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, current.endpoints),
      nativeController === controller
    else { try fail() }
    // Full original LIVE guard must establish EVERY current binding before fixture bookkeeping.
    try fixture.requireClosed()
    try common()
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }),
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, current.endpoints)
    else { try fail() }
    let finalWindow = controller.window
    hold(finalWindow)
    try common()
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }), finalWindow === window,
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, current.endpoints)
    else { try fail() }
    let finalController = window.windowController
    hold(finalController)
    try common()
    let rechecked = fixture.owner.transferPreferredRetirementTestFacts
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }), finalWindow === window,
      finalController === controller, rechecked.moveID == nil, rechecked.presentation == nil,
      sameRows(rechecked.endpoints, current.endpoints),
      fixture.owner.registry.windowIDs == fixture.retirementOriginalWindows.map(\.id),
      fixture.retirementOriginalWindows.allSatisfy({
        fixture.owner.registry.window(id: $0.id) == $0
      }),
      fixture.owner.registry.assignment(of: fixture.model.id)?.windowID == fixture.sourceID
    else { try fail() }
    fixture.target = controller  // Only this proven successor becomes the active fixture target.
    restored = true
    try fixture.requireClosed()
    try common()
    guard fixture.owner.registry.workspaceRevision == restoredRevision,
      restoredModelChecks.allSatisfy({ $0() }),
      sameRows(fixture.owner.transferPreferredRetirementTestFacts.endpoints, current.endpoints)
    else { try fail() }
  }
}

@MainActor extension TransferPreferredFixture {
  fileprivate func prepareKnownTargetRetirement() throws {
    guard Thread.isMainThread else { try unavailable() }
    try requireClosed()
    guard knownTargetRetirement == nil, retirementMoveID == nil, retirementUserChecks.isEmpty else {
      try unavailable()
    }
    retirementOriginalWindows = owner.registry.windowIDs.compactMap {
      owner.registry.window(id: $0)
    }
    guard retirementOriginalWindows.count == owner.registry.windowIDs.count else {
      try unavailable()
    }
    retirementUserChecks = try ownedModels.map { owned in
      let d = owned.model
      guard let storage = d.storage as? DocumentCommitTextStorage,
        owner.registry.handle(id: d.id) === d, d.operationID == nil,
        d.nativeConfigurationToken == nil, d.composingPaneID == nil, !d.saving,
        d.panePresentation.installing == nil
      else { try unavailable() }
      let text = d.storage.string
      let primitive = storage.nativeMacroPrimitiveState
      let edit = d.editRevision
      let baseline = d.baselineRevision
      let marks = d.bookmarks
      let recovery = d.recoveryAuthority
      let issued = d.highestIssuedRecoveryRevision
      let pending = d.pendingBookmarks
      let pendingUndo = d.pendingBookmarksHaveUndo
      let composing = d.compositionOriginalText
      let compositionMarks = d.compositionBookmarks
      let compositionUndo = d.compositionUndoRegistered
      let typing = d.typingBookmarkNextLocation
      let encoding = d.encoding
      let bom = d.hasBOM
      let savedEncoding = d.savedEncoding
      let savedBOM = d.savedHasBOM
      let url = d.url
      let bytes = d.originalBytes
      let savedText = d.savedText
      let publication = d.pendingPublication?.id
      let pinned = d.pinned
      let language = d.language
      let manual = d.manualLanguage
      let typography = d.appliedTypography
      let wrap = d.appliedWrap
      let axis = d.splitAxis
      let preferred = d.preferredPaneID
      let panes = d.panePool
      let attached = panes.map(\.isAttached)
      return { [self] in
        owner.registry.handle(id: d.id) === d && d.storage === owned.storage
          && d.undoManager === owned.history
          && d.storage.string == text && storage.nativeMacroPrimitiveState == primitive
          && d.editRevision == edit && d.baselineRevision == baseline && d.bookmarks == marks
          && d.recoveryAuthority == recovery && d.highestIssuedRecoveryRevision == issued
          && d.pendingBookmarks == pending && d.pendingBookmarksHaveUndo == pendingUndo
          && d.compositionOriginalText == composing && d.compositionBookmarks == compositionMarks
          && d.compositionUndoRegistered == compositionUndo
          && d.typingBookmarkNextLocation == typing
          && d.encoding == encoding && d.hasBOM == bom && d.savedEncoding == savedEncoding
          && d.savedHasBOM == savedBOM
          && d.url == url && d.originalBytes == bytes && d.savedText == savedText
          && d.pendingPublication?.id == publication
          && d.pinned == pinned && d.language == language && d.manualLanguage == manual
          && d.appliedTypography == typography && d.appliedWrap == wrap && d.splitAxis == axis
          && d.preferredPaneID == preferred
          && d.panePool.map(ObjectIdentifier.init) == panes.map(ObjectIdentifier.init)
          && d.panePool.map(\.isAttached) == attached
      }
    }
    guard retirementUserChecks.allSatisfy({ $0() }) else { try unavailable() }
  }
  fileprivate func closeKnownTargetFromActualHook(_ controller: EditorWindowController) throws {
    guard knownTargetRetirement == nil, let id = retirementMoveID,
      controller === target, controller.transferPreferredTestFacts.phase == 3,
      controller.transferPreferredTestFacts.projecting
        && controller.transferPreferredTestFacts.scopedFocus,
      callbackIdentitiesKnown(), retirementUserChecks.allSatisfy({ $0() })
    else { try unavailable() }
    let facts = owner.transferPreferredRetirementTestFacts
    let ledger = TransferPreferredTargetRetirementLedger(self, id: id, captured: facts)
    // Retain full raw endpoint/controller inventory before ANY native getter.
    knownTargetRetirement = ledger
    guard let presentation = facts.presentation, facts.moveID == id,
      presentation.model === model, presentation.request.documentID == model.id,
      presentation.request.source.windowID == sourceID,
      presentation.request.target.windowID == targetID,
      facts.endpoints.count == 2,
      Set(facts.endpoints.map(\.windowID)) == Set([sourceID, targetID]),
      ledger.windowIDs.count == 2, Set(ledger.windowIDs) == Set([sourceID, targetID]),
      Set(ledger.windows.flatMap({ $0.groups.flatMap(\.documentIDs) })) == Set(tabIDs),
      ledger.windows.flatMap({ $0.groups.flatMap(\.documentIDs) }).count == tabIDs.count,
      facts.endpoints.allSatisfy({ $0.controller != nil }),
      let sourceRow = facts.endpoints.first(where: { $0.windowID == sourceID }),
      let targetRow = facts.endpoints.first(where: { $0.windowID == targetID }),
      sourceRow.identity == presentation.sourceIdentity,
      sourceRow.endpointID == presentation.sourceEndpointID,
      targetRow.identity == presentation.targetIdentity,
      targetRow.endpointID == presentation.targetEndpointID,
      sourceRow.controller === source, targetRow.controller === controller
    else { try ledger.fail() }
    ledger.modelChecks = try quitModelChecks(includeIssuedRevision: true)
    for c in facts.endpoints.compactMap(\.controller) {
      let state = c.nestedStringTestState()
      let focus = c.transferPreferredTestFacts
      guard !state.hasPreparation, !state.hasExplicitFrame else { try ledger.fail() }
      ledger.protocolChecks.append {
        let now = c.nestedStringTestState()
        let current = c.transferPreferredTestFacts
        return !now.hasPreparation && !now.hasExplicitFrame && now.epoch == state.epoch
          && now.active == state.active && now.complete == state.complete
          && now.reason == state.reason
          && now.commands == state.commands && current.phase == focus.phase
          && current.projecting == focus.projecting && current.scopedFocus == focus.scopedFocus
      }
    }
    try ledger.closeActualTarget()
  }
  fileprivate func waitForKnownTargetRetirement(_ id: ApplicationDocumentTransferID) async throws
    -> ApplicationDocumentTransferResult
  {
    guard retirementMoveID == id else { try unavailable() }
    if let ledger = knownTargetRetirement {
      guard ledger.moveID == id else { try unavailable() }
      try ledger.requireGap()
    } else {
      try requireClosed()
    }
    let result: ApplicationDocumentTransferResult
    do { result = try await owner.waitForTransfer(id) } catch {
      if let ledger = knownTargetRetirement {
        ledger.replacementCustody = owner.transferPreferredRetirementTestFacts.endpoints
        ledger.stopPassive()
      }
      retainIncomplete()
      throw error
    }
    guard let ledger = knownTargetRetirement, ledger.moveID == id else { try unavailable() }
    try ledger.requireGap()
    return result
  }
  fileprivate func assertKnownTargetRetirementMetadata(
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    guard let ledger = knownTargetRetirement else { try unavailable() }
    try ledger.requireGap()
    XCTAssertTrue(owner.registry.handle(id: model.id) === model, file: file, line: line)
    XCTAssertTrue(model.storage === capturedStorage, file: file, line: line)
    XCTAssertTrue(model.undoManager === capturedHistory, file: file, line: line)
    XCTAssertEqual(model.bookmarks, capturedBookmarks, file: file, line: line)
    XCTAssertNotNil(capturedRecovery, file: file, line: line)
    XCTAssertEqual(model.recoveryAuthority, capturedRecovery, file: file, line: line)
    try ledger.requireGap()
  }
  fileprivate func retryKnownTargetRetirement() async throws {
    guard let ledger = knownTargetRetirement else { try unavailable() }
    try ledger.requireGap()
    let result: ApplicationDocumentTransferResult
    do {
      // Real owner retry consumes its real terminal wait internally.
      try await owner.retryRecovery()
      // Exact retained last ID remains queryable.
      result = try await owner.waitForTransfer(ledger.moveID)
    } catch {
      ledger.replacementCustody = owner.transferPreferredRetirementTestFacts.endpoints
      retainIncomplete()
      ledger.stopPassive()
      throw error
    }
    try ledger.adoptRestoredSuccessor(result)
  }
}

@MainActor private func withTransferPreferred(
  configuration: Int = 0,
  _ body: @MainActor (TransferPreferredFixture) async throws -> Void
) async throws {
  let f = try TransferPreferredFixture(neighbor: configuration != 0)
  var primary: Error?
  do {
    try await f.start(configuration: configuration)
    try await body(f)
  } catch { primary = error }
  do { try await f.finish() } catch {
    f.retainIncomplete()
    // Retain unresolved owner/resources; never destructively acknowledge it.
    throw primary ?? error
  }
  if let primary { throw primary }
}
@MainActor private func transferPreferredRequireSupported(
  file: StaticString = #filePath, line: UInt = #line
) async throws -> Bool {
  var supported = false
  try await withTransferPreferred { f in
    let id = try f.move()
    let result = try await f.waitForTransfer(id)
    let moved: Bool
    if case .moved = result { moved = true } else { moved = false }
    XCTAssertTrue(
      moved, "Actual ordinary transfer must move before deeper controls", file: file, line: line)
    XCTAssertTrue(
      f.target.window?.firstResponder === f.preferred.editor,
      "Actual transferred preferred native responder required; deep controls UNENTERED", file: file,
      line: line)
    XCTAssertEqual(
      f.owner.registry.assignment(of: f.model.id)?.windowID, f.targetID,
      "Actual target registry assignment required before deeper controls", file: file, line: line)
    supported =
      moved && f.target.window?.firstResponder === f.preferred.editor
      && f.owner.registry.assignment(of: f.model.id)?.windowID == f.targetID
  }
  XCTAssertTrue(supported, file: file, line: line)
  return supported
}

@MainActor private func transferPreferredAssertFocusRefused(
  _ controller: EditorWindowController, paneID: UUID
) {
  XCTAssertThrowsError(try controller.focusPane(id: paneID))
}

@MainActor final class TransferPreferredResponderTests: XCTestCase {
  func testActualPreferredResponderAndHistoryAcrossThreeTinyLayouts() async throws {
    for configuration in 0..<3 {
      try await withTransferPreferred(configuration: configuration) { f in
        let storage = f.model.storage
        let history = f.model.undoManager
        let id = try f.move()
        let result = try await f.waitForTransfer(id)
        guard case .moved = result else { return XCTFail("Actual tiny owner transfer must move") }
        XCTAssertTrue(f.target.window?.firstResponder === f.preferred.editor)
        XCTAssertTrue(f.model.storage === storage && f.model.undoManager === history)
        XCTAssertEqual(f.model.storage.string, f.before)
        try f.assertDisplayed(in: f.target)
        if configuration == 0 {
          XCTAssertNil(f.source.selectedDocumentID)
          XCTAssertFalse(f.source.window?.firstResponder === f.preferred.editor)
        } else {
          let neighbor = try XCTUnwrap(f.source.focusedPane)
          XCTAssertTrue(f.source.window?.firstResponder === neighbor.editor)
        }
        let preferredResponderMatches = f.target.window?.firstResponder === f.preferred.editor
        XCTAssertTrue(preferredResponderMatches)
        guard preferredResponderMatches else { return }
        // Drive only the independently verified real responder, after lease settlement.
        let responder = try XCTUnwrap(f.target.window?.firstResponder as? DocumentTextView)
        try f.nativeAction(editor: responder) {
          responder.breakUndoCoalescing()
          responder.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let changed = f.model.storage.string
        XCTAssertNotEqual(changed, f.before)
        try f.assertDisplayed(in: f.target)
        guard try f.nativeHistory(.undo) else { return }
        XCTAssertEqual(f.model.storage.string, f.before)
        try f.assertDisplayed(in: f.target)
        guard try f.nativeHistory(.undo) else { return }
        XCTAssertEqual(f.model.storage.string, f.fileText)
        try f.assertDisplayed(in: f.target)
        guard try f.nativeHistory(.redo) else { return }
        XCTAssertEqual(f.model.storage.string, f.before)
        try f.assertDisplayed(in: f.target)
        guard try f.nativeHistory(.redo) else { return }
        XCTAssertEqual(f.model.storage.string, changed)
        try f.assertDisplayed(in: f.target)
        guard try f.nativeHistory(.undo) else { return }
        guard try f.nativeHistory(.undo) else { return }
        XCTAssertEqual(f.model.storage.string, f.fileText)
        try f.assertDisplayed(in: f.target)
        XCTAssertEqual(f.reports, 0)
      }
    }
  }

  func testExactStagedPreferredRefusalRestoresOriginalResponderAndHistory() async throws {
    guard try await transferPreferredRequireSupported() else { return }
    try await withTransferPreferred { f in
      var attempts = 0
      TransferPreferredNativeHook.beforeFocus = { controller, responder in
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        guard controller === f.target, responder === f.preferred.editor,
          controller.transferPreferredTestFacts.phase == 3
        else { return nil }
        attempts += 1
        XCTAssertLessThanOrEqual(attempts, 4)
        XCTAssertTrue(controller.transferPreferredTestFacts.scopedFocus)
        return attempts == 1 ? false : nil
      }
      let id = try f.move()
      let result = try await f.waitForTransfer(id)
      XCTAssertEqual(attempts, 1, "No second staged target attempt may erase the original refusal")
      TransferPreferredNativeHook.beforeFocus = nil
      guard f.restored(result) else { return }
      try f.assertRestoredHistory()
    }
  }

  func testDeclaredFalseSuccessWithoutInstallingResponderMustRestore() async throws {
    guard try await transferPreferredRequireSupported() else { return }
    try await withTransferPreferred { f in
      var attempts = 0
      var actualMissingResponderPremise = false
      TransferPreferredNativeHook.beforeFocus = { controller, responder in
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        guard controller === f.target, responder === f.preferred.editor,
          controller.transferPreferredTestFacts.phase == 3
        else { return nil }
        attempts += 1
        guard attempts == 1 else { return nil }
        XCTAssertTrue(controller.transferPreferredTestFacts.scopedFocus)
        actualMissingResponderPremise = controller.window?.firstResponder !== f.preferred.editor
        XCTAssertTrue(actualMissingResponderPremise)
        // Isolated declared negative: fake native success WITHOUT calling super/installing.
        return true
      }
      let id = try f.move()
      let result = try await f.waitForTransfer(id)
      TransferPreferredNativeHook.beforeFocus = nil
      XCTAssertTrue(actualMissingResponderPremise)
      XCTAssertEqual(attempts, 1)
      guard f.restored(result) else { return }
      try f.assertRestoredHistory()
    }
  }

  func testRealFocusCallbackEndpointRetirementCannotGrantMutationAndRetriesExactly() async throws {
    guard try await transferPreferredRequireSupported() else { return }
    try await withTransferPreferred(configuration: 1) { f in
      var entries = 0
      var refusedEdit = false
      var refusedSelection = false
      TransferPreferredNativeHook.beforeFocus = { controller, responder in
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        guard controller === f.target, responder === f.preferred.editor,
          controller.transferPreferredTestFacts.phase == 3
        else { return nil }
        entries += 1
        guard entries == 1 else { return false }
        let facts = controller.transferPreferredTestFacts
        XCTAssertTrue(facts.scopedFocus && facts.projecting)
        let text = f.model.storage.string
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        let selection = f.preferred.editor.selectedRange()
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        f.preferred.editor.insertText("denied", replacementRange: NSRange(location: 0, length: 0))
        let deniedRange =
          selection == NSRange(location: 0, length: 0)
          ? NSRange(location: 1, length: 0) : NSRange(location: 0, length: 0)
        f.preferred.editor.setSelectedRange(deniedRange)
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        refusedEdit = f.model.storage.string == text
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        refusedSelection = f.preferred.editor.selectedRange() == selection
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        XCTAssertTrue(refusedEdit && refusedSelection)
        transferPreferredAssertFocusRefused(controller, paneID: f.preferred.id)
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        do { try f.closeKnownTargetFromActualHook(controller) } catch {
          f.retainIncomplete()
          return false
        }
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        return nil
      }
      try f.prepareKnownTargetRetirement()
      let id = try f.move()
      f.retirementMoveID = id  // Actual synchronous return, stored before the first await.
      let result = try await f.waitForKnownTargetRetirement(id)
      TransferPreferredNativeHook.beforeFocus = nil
      XCTAssertEqual(entries, 1)
      XCTAssertTrue(refusedEdit && refusedSelection)
      guard case .retained = result else {
        return XCTFail("Exact endpoint retirement must retain unfinished transfer")
      }
      XCTAssertTrue(f.owner.canRetryRecovery)
      XCTAssertEqual(f.model.storage.string, f.before)
      try f.assertKnownTargetRetirementMetadata()
      try await f.retryKnownTargetRetirement()
      let retried = try await f.waitForTransfer(id)
      guard f.restored(retried) else { return }
      XCTAssertFalse(f.owner.canRetryRecovery)
      try f.assertRestoredHistory()
    }
  }

  func testRollbackPreferredRefusalRetainsThenExactReleasedRetryRestores() async throws {
    guard try await transferPreferredRequireSupported() else { return }
    try await withTransferPreferred { f in
      var forward = 0
      var rollback = 0
      TransferPreferredNativeHook.beforeFocus = { controller, responder in
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        guard responder === f.preferred.editor else { return nil }
        let facts = controller.transferPreferredTestFacts
        if controller === f.target, facts.phase == 3 {
          forward += 1
          XCTAssertTrue(facts.scopedFocus)
          return false
        }
        if controller === f.source, facts.phase == 4 {
          rollback += 1
          XCTAssertTrue(facts.scopedFocus)
          return false
        }
        return nil
      }
      let id = try f.move()
      let result = try await f.waitForTransfer(id)
      // All refusals released BEFORE retry/owner awaits.
      TransferPreferredNativeHook.beforeFocus = nil
      XCTAssertEqual(forward, 1)
      XCTAssertEqual(rollback, 1)
      guard case .retained = result else {
        return XCTFail("Failed required rollback focus must retain exact transfer")
      }
      XCTAssertTrue(f.owner.canRetryRecovery)
      XCTAssertEqual(f.model.storage.string, f.before)
      try f.assertPreservedMetadata()
      XCTAssertFalse(f.source.transferPreferredTestFacts.scopedFocus)
      XCTAssertFalse(f.target.transferPreferredTestFacts.scopedFocus)
      try await f.retryRecovery()
      let retried = try await f.waitForTransfer(id)
      guard f.restored(retried) else { return }
      XCTAssertFalse(f.owner.canRetryRecovery)
      try f.assertRestoredHistory()
    }
  }

  func testDefaultOrdinaryHostStillFocusesAndEditsWithoutTransferScope() async throws {
    guard try await transferPreferredRequireSupported() else { return }
    try await withTransferPreferred(configuration: 1) { f in
      var focusCalls = 0
      TransferPreferredNativeHook.beforeFocus = { controller, responder in
        guard f.callbackIdentitiesKnown() else {
          f.retainIncomplete()
          return false
        }
        guard controller === f.source, responder is DocumentTextView else { return nil }
        focusCalls += 1
        let facts = controller.transferPreferredTestFacts
        XCTAssertEqual(facts.phase, 0)
        XCTAssertFalse(facts.scopedFocus)
        return nil  // Every ordinary call still reaches the original real native method.
      }
      let panes = f.model.panePool.filter(\.isAttached)
      let first = try XCTUnwrap(panes.first)
      try f.requireClosed()
      try f.source.focusPane(id: first.id)
      try f.requireClosed()
      XCTAssertGreaterThan(focusCalls, 0)
      XCTAssertTrue(f.source.window?.firstResponder === first.editor)
      XCTAssertTrue(first.editor.isSelectable && first.editor.isEditable)
      let ordinaryResponderMatches = f.source.window?.firstResponder === first.editor
      XCTAssertTrue(ordinaryResponderMatches)
      guard ordinaryResponderMatches else { return }
      let before = f.model.storage.string
      try f.nativeAction(editor: first.editor) {
        first.editor.breakUndoCoalescing()
        first.editor.insertText("O", replacementRange: NSRange(location: NSNotFound, length: 0))
      }
      XCTAssertNotEqual(f.model.storage.string, before)
      guard try f.nativeHistory(.undo) else { return }
      XCTAssertEqual(f.model.storage.string, before)
      XCTAssertEqual(f.source.transferPreferredTestFacts.phase, 0)
      try f.assertDisplayed(in: f.source, pane: first)
    }
  }
}
