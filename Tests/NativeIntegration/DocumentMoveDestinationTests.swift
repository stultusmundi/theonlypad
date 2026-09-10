import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class DocumentMoveDestinationTests: XCTestCase {
  private func controls(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { controls($0) }
  }
  @MainActor private final class Fixture {
    let directory: URL
    let session: SessionCoordinator
    let delegate: AppDelegate
    var owner: NativeApplicationDocuments { delegate.moveOwnerTest! }
    let documentID: UUID
    final class Observations {
      var panels: [DocumentMoveDestinationController] = []
      var presented: [EditorWindowController] = []
      var errors: [Error] = []
      var replies: [Bool] = []
    }
    let observations = Observations()
    init(windows: Int = 1, liveWindows: Int = 1) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("synthetic.txt")
      try Data("synthetic text".utf8).write(to: file)
      let tab = SessionTab(originalPath: file.path)
      documentID = tab.id
      var saved = [SessionWindow(tabs: [tab], selectedTabID: tab.id)]
      for index in 1..<max(1, windows) {
        let path: String?
        if index < liveWindows {
          let other = directory.appendingPathComponent("synthetic-\(index).txt")
          try Data("other synthetic text".utf8).write(to: other)
          path = other.path
        } else {
          path = nil
        }
        let missing = SessionTab(originalPath: path)
        saved.append(SessionWindow(tabs: [missing], selectedTabID: missing.id))
      }
      let snapshot = EditorSession(windows: saved)
      let store = SessionStore(directory: directory.appendingPathComponent("session"))
      let recovery = RecoveryCoordinator(
        directory: directory.appendingPathComponent("recovery"),
        saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
      session = SessionCoordinator(
        loadSession: { snapshot }, claimRecovery: { try await recovery.claimStartup() })
      let observations = observations
      delegate = AppDelegate(
        session: session, recovery: recovery,
        presentEditorWindow: { observations.presented.append($0) },
        reportDocumentError: { observations.errors.append($0) },
        presentMoveDestination: { observations.panels.append($0) },
        replyToTermination: { observations.replies.append($0) })
    }
    func start() async throws {
      try await delegate.startMoveTest()
      observations.presented.removeAll()
      moveFactoryCalls = 0
      movePresentationAttempts = 0
    }
    func cleanup() async {
      for panel in observations.panels { panel.close() }
      _ = try? await owner.prepareQuit()
      try? FileManager.default.removeItem(at: directory)
    }
  }
  private func popup(_ chooser: DocumentMoveDestinationController) throws -> NSPopUpButton {
    try XCTUnwrap(controls(chooser.window?.contentView).compactMap { $0 as? NSPopUpButton }.first)
  }
  private func button(_ chooser: DocumentMoveDestinationController, _ suffix: String) throws
    -> NSButton
  {
    try XCTUnwrap(
      controls(chooser.window?.contentView).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move." + suffix
      })
  }
  func testSingleWindowNewChoiceMovesActualModelAndPresentsOnlySettledTarget() async throws {
    let f = try Fixture()
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let storage = model.storage
    let undo = model.undoManager
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    let menu = try popup(chooser)
    XCTAssertTrue(menu.itemTitles.contains("New Window"), "A single window must offer New Window")
    guard menu.itemTitles.contains("New Window") else {
      await f.cleanup()
      return
    }
    menu.selectItem(withTitle: "New Window")
    let pane = try XCTUnwrap(source.focusedPane)
    pane.editor.insertText("edited 👩🏽‍💻 ", replacementRange: NSRange(location: 0, length: 0))
    try button(chooser, "confirm").performClick(nil)
    try button(chooser, "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.presented.isEmpty && f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(f.observations.errors.isEmpty)
    XCTAssertEqual(f.observations.presented.count, 1)
    let target = try XCTUnwrap(f.observations.presented.first)
    XCTAssertEqual(f.owner.windows.count, 2)
    XCTAssertTrue(target !== source)
    XCTAssertEqual(target.selectedDocumentID, model.id)
    XCTAssertNil(source.selectedDocumentID)
    XCTAssertTrue(f.owner.registry.handle(id: model.id) === model)
    XCTAssertTrue(model.storage === storage)
    XCTAssertTrue(model.undoManager === undo)
    XCTAssertTrue(target.focusedPane === pane)
    XCTAssertEqual(storage.string, "edited 👩🏽‍💻 synthetic text")
    undo.undo()
    XCTAssertEqual(storage.string, "synthetic text")
    undo.redo()
    XCTAssertEqual(storage.string, "edited 👩🏽‍💻 synthetic text")
    XCTAssertEqual(
      f.owner.registry.windowIDs.compactMap { f.owner.registry.window(id: $0) }
        .flatMap { $0.groups.flatMap(\.documentIDs) }, [model.id])
    XCTAssertEqual(moveFactoryCalls, 0)
    XCTAssertFalse(target.window!.isVisible)
    await f.cleanup()
  }
  func testTypedNewWindowChoiceConsumesOnlyOnce() throws {
    var choices = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [])
    choices.newWindowRefusalReason = nil
    var picked: [NativeDocumentMoveTarget] = []
    var cancellations = 0
    let chooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { picked.append($0) }, onCancel: { cancellations += 1 })
    XCTAssertEqual(try popup(chooser).itemTitles, ["New Window"])
    try button(chooser, "confirm").performClick(nil)
    try button(chooser, "confirm").performClick(nil)
    chooser.close()
    XCTAssertEqual(picked, [.newWindow])
    XCTAssertEqual(cancellations, 0)
  }
  func testUnavailableNewWindowExplainsReasonAndCannotConfirmProgrammatically() throws {
    let destination = NativeDocumentMoveDestination(
      windowID: UUID(), endpointID: UUID(), title: "Other")
    var choices = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [destination])
    choices.newWindowRefusalReason = "Recovery cleanup is pending. Retry after cleanup completes."
    var picked: [NativeDocumentMoveTarget] = []
    let chooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { picked.append($0) }, onCancel: {})
    let menu = try popup(chooser)
    XCTAssertTrue(try button(chooser, "confirm").isEnabled)
    XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "New Window")).isEnabled)
    XCTAssertTrue(
      controls(chooser.window?.contentView).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("Recovery cleanup is pending")
      })
    menu.selectItem(withTitle: "New Window")
    _ = menu.sendAction(menu.action, to: menu.target)
    XCTAssertFalse(try button(chooser, "confirm").isEnabled)
    let move = try button(chooser, "confirm")
    _ = move.sendAction(move.action, to: move.target)
    XCTAssertTrue(picked.isEmpty)
    menu.selectItem(at: 0)
    _ = menu.sendAction(menu.action, to: menu.target)
    move.performClick(nil)
    XCTAssertEqual(picked, [.existing(destination)])
  }
  func testSingleWindowCancelCreatesNothing() async throws {
    let f = try Fixture()
    try await f.start()
    let windows = f.owner.registry.windowIDs
    let model = f.owner.registry.handle(id: f.documentID)
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    try button(chooser, "cancel").performClick(nil)
    try button(chooser, "confirm").performClick(nil)
    XCTAssertEqual(f.owner.registry.windowIDs, windows)
    XCTAssertTrue(f.owner.registry.handle(id: f.documentID) === model)
    XCTAssertTrue(f.observations.presented.isEmpty)
    XCTAssertTrue(f.observations.errors.isEmpty)
    XCTAssertEqual(moveFactoryCalls, 0)
    await f.cleanup()
  }
  func testCapacityHintComesFromActualUnresolvedWindowUnion() async throws {
    let f = try Fixture(windows: 32, liveWindows: 2)
    try await f.start()
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    let menu = try popup(chooser)
    XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "New Window")).isEnabled)
    let content = try XCTUnwrap(chooser.window?.contentView)
    content.layoutSubtreeIfNeeded()
    let label = try XCTUnwrap(controls(content).compactMap { $0 as? NSTextField }.first)
    let labelBounds = label.convert(label.bounds, to: content)
    XCTAssertLessThanOrEqual(labelBounds.maxX, content.bounds.maxX)
    XCTAssertGreaterThanOrEqual(labelBounds.minY, 0)
    let required = try XCTUnwrap(label.cell).cellSize(
      forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10000))
    XCTAssertGreaterThanOrEqual(label.bounds.height, required.height)
    let refusal = try XCTUnwrap(f.owner.newWindowMoveRefusalReason())
    XCTAssertTrue(
      controls(chooser.window?.contentView).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains(refusal)
      })
    XCTAssertTrue(try button(chooser, "confirm").isEnabled)
    let sourceID = try XCTUnwrap(f.owner.windows.last?.selectedDocumentID)
    let oldWindow = f.owner.registry.assignment(of: sourceID)?.windowID
    try button(chooser, "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.presented.isEmpty && f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(f.observations.errors.isEmpty)
    XCTAssertEqual(f.observations.presented.count, 1)
    XCTAssertNotEqual(f.owner.registry.assignment(of: sourceID)?.windowID, oldWindow)
    XCTAssertEqual(f.owner.windows.count, 2)
    await f.cleanup()
  }
  func testCapacityChangeWhileChooserOpenRefusesNewWindow() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    XCTAssertTrue(try XCTUnwrap(popup(chooser).item(withTitle: "New Window")).isEnabled)
    let added = UUID()
    try f.owner.registry.registerWindow(id: added, initialGroupID: UUID())
    let before = f.owner.registry.windowIDs
    try button(chooser, "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(f.observations.errors.count, 1)
    XCTAssertTrue(f.observations.presented.isEmpty)
    XCTAssertEqual(f.owner.registry.windowIDs, before)
    XCTAssertEqual(f.owner.windows.count, 1)
    XCTAssertEqual(moveFactoryCalls, 0)
    try f.owner.registry.unregisterEmptyWindow(
      added, expectedRevision: f.owner.registry.workspaceRevision)
    await f.cleanup()
  }
  func testStaleSourceChooserCannotMoveOwnershipAgain() async throws {
    let f = try Fixture()
    try await f.start()
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    let id = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(id) else {
      await f.cleanup()
      return XCTFail("Fixture move must settle")
    }
    try button(chooser, "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(f.observations.errors.count, 1)
    XCTAssertEqual(f.owner.windows.count, 2)
    XCTAssertEqual(f.owner.registry.assignment(of: f.documentID)?.windowID, destination.windowID)
    XCTAssertTrue(f.observations.presented.isEmpty)
    await f.cleanup()
  }
  func testNewerChooserEntryFencesActualNewWindowCompletion() async throws {
    let f = try Fixture()
    try await f.start()
    f.delegate.dispatchMoveTest()
    let chooser = try XCTUnwrap(f.observations.panels.last)
    try button(chooser, "confirm").performClick(nil)
    let generation = f.delegate.movePresentationGenerationTest
    f.delegate.dispatchMoveTest()
    XCTAssertNotEqual(f.delegate.movePresentationGenerationTest, generation)
    for _ in 0..<1000 where movePresentationAttempts == 0 {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(movePresentationAttempts, 1)
    XCTAssertEqual(f.owner.windows.count, 2)
    XCTAssertEqual(f.owner.windows.last?.selectedDocumentID, f.documentID)
    XCTAssertTrue(f.observations.presented.isEmpty)
    await f.cleanup()
  }
  func testQuitVetoFencesActualNewWindowCompletion() async throws {
    let f = try Fixture()
    try await f.start()
    f.delegate.dispatchMoveTest()
    try button(XCTUnwrap(f.observations.panels.last), "confirm").performClick(nil)
    let generation = f.delegate.movePresentationGenerationTest
    XCTAssertEqual(f.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    for _ in 0..<1000 where f.observations.replies.isEmpty || movePresentationAttempts == 0 {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(f.observations.replies, [false])
    XCTAssertFalse(f.delegate.movePreparingQuitTest)
    XCTAssertNotEqual(f.delegate.movePresentationGenerationTest, generation)
    XCTAssertEqual(movePresentationAttempts, 1)
    XCTAssertEqual(f.owner.windows.count, 2)
    XCTAssertEqual(f.owner.windows.last?.selectedDocumentID, f.documentID)
    XCTAssertTrue(f.observations.presented.isEmpty)
    await f.cleanup()
  }
  func testRestoredPreparationFailureReportsErrorWithoutPresentation() async throws {
    let f = try Fixture()
    try await f.start()
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let source = f.owner.registry.assignment(of: model.id)
    let original = f.owner.registry.onChange
    var injected = false
    f.owner.registry.onChange = { revision in
      original?(revision)
      if !injected && f.owner.registry.windowIDs.count == 2 {
        injected = true
        model.panePresentation.installing = UUID()
      }
    }
    f.delegate.dispatchMoveTest()
    try button(XCTUnwrap(f.observations.panels.last), "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(injected)
    XCTAssertEqual(f.observations.errors.count, 1)
    XCTAssertFalse(f.owner.canRetryRecovery)
    XCTAssertTrue(f.observations.presented.isEmpty)
    XCTAssertEqual(f.owner.registry.assignment(of: model.id), source)
    XCTAssertEqual(f.owner.registry.windowIDs.count, 1)
    model.panePresentation.installing = nil
    f.owner.registry.onChange = original
    await f.cleanup()
  }
  func testRetainedDestinationLossUsesActualRetryRecoveryCommand() async throws {
    let f = try Fixture()
    try await f.start()
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let source = try XCTUnwrap(f.owner.registry.assignment(of: model.id))
    let original = f.owner.registry.onChange
    var injected = false
    f.owner.registry.onChange = { revision in
      original?(revision)
      if !injected, let assignment = f.owner.registry.assignment(of: model.id), assignment != source
      {
        injected = true
        // The real ownership callback runs after settlement. Closing this hidden endpoint
        // makes terminal cleanup retain the committed move until explicit reconciliation.
        f.owner.windows.first { $0.sessionMetadata.id == assignment.windowID }?.window?.close()
      }
    }
    f.delegate.dispatchMoveTest()
    try button(XCTUnwrap(f.observations.panels.last), "confirm").performClick(nil)
    for _ in 0..<1000 where f.observations.errors.isEmpty {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(injected)
    XCTAssertEqual(f.observations.errors.count, 1)
    XCTAssertTrue(f.owner.canRetryRecovery)
    let retry = NSMenuItem()
    retry.representedObject = "file.retrySession"
    XCTAssertTrue(f.delegate.validateMenuItem(retry))
    XCTAssertTrue(f.observations.presented.isEmpty)
    f.owner.registry.onChange = original
    f.delegate.dispatchMoveRetryTest()
    for _ in 0..<1000 where f.owner.canRetryRecovery {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertFalse(f.owner.canRetryRecovery)
    XCTAssertFalse(f.delegate.validateMenuItem(retry))
    XCTAssertEqual(f.observations.errors.count, 1)
    XCTAssertTrue(f.observations.presented.isEmpty)
    XCTAssertNotEqual(f.owner.registry.assignment(of: model.id), source)
    XCTAssertTrue(f.owner.registry.handle(id: model.id) === model)
    XCTAssertEqual(f.owner.registry.windowIDs.count, 2)
    XCTAssertEqual(moveFactoryCalls, 0)
    await f.cleanup()
  }
  func testOwnerReplacementFencesChoiceAndActualTerminalPresentation() async throws {
    let f = try Fixture()
    try await f.start()
    let originalOwner = f.owner
    f.delegate.dispatchMoveTest()
    let first = try XCTUnwrap(f.observations.panels.last)
    f.delegate.moveOwnerTest = nil
    try button(first, "confirm").performClick(nil)
    XCTAssertEqual(originalOwner.windows.count, 1)
    XCTAssertTrue(f.observations.errors.isEmpty)
    f.delegate.moveOwnerTest = originalOwner
    f.delegate.dispatchMoveTest()
    try button(XCTUnwrap(f.observations.panels.last), "confirm").performClick(nil)
    f.delegate.moveOwnerTest = nil
    for _ in 0..<1000 where movePresentationAttempts == 0 {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(movePresentationAttempts, 1)
    XCTAssertEqual(originalOwner.windows.count, 2)
    XCTAssertTrue(f.observations.presented.isEmpty)
    XCTAssertTrue(f.observations.errors.isEmpty)
    f.delegate.moveOwnerTest = originalOwner
    await f.cleanup()
  }
  func testCanonicalCommandAndActualChoiceAndCancel() throws {
    _ = NSApplication.shared
    let command = try XCTUnwrap(
      AppCommands.registry().commands.first { $0.id == "file.moveToWindow" })
    XCTAssertNil(command.shortcut)
    let target = NativeDocumentMoveDestination(
      windowID: UUID(), endpointID: UUID(), title: "Notes — Window 2")
    let choices = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [target])
    var picked: [NativeDocumentMoveTarget] = []
    var cancellations = 0
    let chooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { picked.append($0) }, onCancel: { cancellations += 1 })
    let views = controls(chooser.window?.contentView)
    let move = try XCTUnwrap(
      views.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move.confirm"
      })
    move.performClick(nil)
    move.performClick(nil)
    XCTAssertEqual(picked, [.existing(target)])
    XCTAssertEqual(cancellations, 0)
    let cancelChooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { picked.append($0) }, onCancel: { cancellations += 1 })
    let cancel = try XCTUnwrap(
      controls(cancelChooser.window?.contentView).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move.cancel"
      })
    cancel.performClick(nil)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(picked, [.existing(target)])
  }
  func testActualDelegateDispatchPresentsCapturedChoices() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    var panels: [DocumentMoveDestinationController] = []
    var presented: [EditorWindowController] = []
    var errors: [Error] = []
    var replies: [Bool] = []
    let delegate = AppDelegate(
      session: session, recovery: recovery, presentEditorWindow: { presented.append($0) },
      reportDocumentError: { errors.append($0) },
      presentMoveDestination: { panels.append($0) }, replyToTermination: { replies.append($0) })
    try await delegate.startMoveTest()
    let owner = try XCTUnwrap(delegate.moveOwnerTest)
    let source = try owner.createWindow()
    for _ in 0..<1000 where source.selectedDocumentID == nil {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let sourceID = try XCTUnwrap(source.selectedDocumentID)
    for _ in 0..<1000 {
      if (try? owner.prepareMove(documentID: sourceID)) != nil { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let destination = try XCTUnwrap(owner.prepareMove(documentID: sourceID).destinations.first)
    presented.removeAll()
    delegate.dispatchMoveTest()
    XCTAssertEqual(panels.count, 1)
    let first = try XCTUnwrap(panels.first)
    first.close()
    XCTAssertEqual(owner.registry.assignment(of: sourceID)?.windowID, source.sessionMetadata.id)
    delegate.dispatchMoveTest()
    XCTAssertEqual(panels.count, 2)
    let chooser = try XCTUnwrap(panels.last)
    let move = try XCTUnwrap(
      controls(chooser.window?.contentView).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move.confirm"
      })
    move.performClick(nil)
    for _ in 0..<1000 {
      if owner.registry.assignment(of: sourceID)?.windowID != source.sessionMetadata.id
        && !owner.canRetryRecovery && !presented.isEmpty
      {
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertNotEqual(owner.registry.assignment(of: sourceID)?.windowID, source.sessionMetadata.id)
    XCTAssertEqual(presented.count, 1)
    XCTAssertEqual(
      presented.first?.sessionMetadata.id, owner.registry.assignment(of: sourceID)?.windowID)
    XCTAssertEqual(presented.first?.selectedDocumentID, sourceID)
    XCTAssertTrue(errors.isEmpty)
    let oldGeneration = delegate.movePresentationGenerationTest
    let nextSource = try owner.createWindow()
    for _ in 0..<1000 where nextSource.selectedDocumentID == nil {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let nextID = try XCTUnwrap(nextSource.selectedDocumentID)
    for _ in 0..<1000 {
      if (try? owner.prepareMove(documentID: nextID)) != nil { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let presentationCount = presented.count
    delegate.dispatchMoveTest()
    XCTAssertEqual(panels.count, 3)
    XCTAssertNotEqual(delegate.movePresentationGenerationTest, oldGeneration)
    delegate.completeMovePresentationTest(
      documentID: sourceID, destination: destination, generation: oldGeneration)
    XCTAssertEqual(presented.count, presentationCount)
    panels.last?.close()
    let quitGeneration = delegate.movePresentationGenerationTest
    let nextModel = try XCTUnwrap(owner.registry.handle(id: nextID) as? EditorDocument)
    nextModel.panePresentation.installing = UUID()
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    for _ in 0..<1000 where replies.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertEqual(replies, [false])
    XCTAssertFalse(delegate.movePreparingQuitTest)
    nextModel.panePresentation.installing = nil
    XCTAssertNotEqual(delegate.movePresentationGenerationTest, quitGeneration)
    delegate.completeMovePresentationTest(
      documentID: sourceID, destination: destination, generation: quitGeneration)
    XCTAssertEqual(presented.count, presentationCount)
    let currentGeneration = delegate.movePresentationGenerationTest
    let errorCount = errors.count
    let stale = NativeDocumentMoveDestination(
      windowID: destination.windowID, endpointID: UUID(), title: destination.title)
    delegate.completeMovePresentationTest(
      documentID: sourceID, destination: stale, generation: currentGeneration)
    XCTAssertEqual(presented.count, presentationCount)
    XCTAssertEqual(errors.count, errorCount + 1)
    XCTAssertTrue(errors.last?.localizedDescription.contains("The document was moved") == true)
    XCTAssertEqual(owner.registry.assignment(of: sourceID)?.windowID, destination.windowID)
    _ = try await owner.prepareQuit()
  }
  func testEmptyDestinationsOfferNoMove() throws {
    _ = NSApplication.shared
    let choices = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [])
    let chooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { _ in XCTFail("No destination") }, onCancel: {})
    let views = controls(chooser.window?.contentView)
    let move = try XCTUnwrap(
      views.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move.confirm"
      })
    XCTAssertFalse(move.isEnabled)
    XCTAssertTrue(
      views.compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("New Window is unavailable")
      })
  }
}
