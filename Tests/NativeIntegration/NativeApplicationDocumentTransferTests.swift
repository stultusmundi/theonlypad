import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class NativeApplicationDocumentTransferTests: XCTestCase {
  func testDirtyScratchMovesWithNativeUndoAndOneFinalRecoveryOwner() async throws {
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
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    do {
      let source = try XCTUnwrap(owner.windows.first)
      let target = try XCTUnwrap(try owner.createWindow(createDocument: false))
      let documentID = try XCTUnwrap(source.sessionMetadata.selectedTabID)
      let model = try XCTUnwrap(owner.registry.handle(id: documentID) as? EditorDocument)
      let pane = try XCTUnwrap(source.focusedPane)
      let authority = model.recoveryAuthority
      let storage = model.storage
      let history = model.undoManager
      let text = "transfer 👩🏽‍💻 e\u{301}\r\n"
      pane.editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
      XCTAssertEqual(storage.string, text)
      XCTAssertTrue(history.canUndo)
      let choices = try owner.prepareMove(documentID: documentID)
      let destination = try XCTUnwrap(
        choices.destinations.first { $0.windowID == target.sessionMetadata.id })
      XCTAssertEqual(choices.sourceWindowID, source.sessionMetadata.id)
      let move = try owner.moveDocument(choices, to: destination)
      guard case .moved = try await owner.waitForTransfer(move) else {
        return XCTFail("Native transfer did not finish")
      }
      XCTAssertEqual(owner.windows.count, 2)
      XCTAssertTrue(owner.registry.handle(id: documentID) === model)
      XCTAssertTrue(model.storage === storage)
      XCTAssertTrue(model.undoManager === history)
      XCTAssertTrue(target.focusedPane === pane)
      XCTAssertNil(source.sessionMetadata.selectedTabID)
      XCTAssertEqual(target.sessionMetadata.selectedTabID, documentID)
      XCTAssertEqual(model.recoveryAuthority, authority)
      XCTAssertTrue(pane.editor.isEditable)
      history.undo()
      XCTAssertEqual(storage.string, "")
      history.redo()
      XCTAssertEqual(storage.string, text)
      let reverse = try owner.moveDocument(documentID, toWindowID: source.sessionMetadata.id)
      guard case .moved = try await owner.waitForTransfer(reverse) else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      XCTAssertThrowsError(
        try owner.moveDocument(choices, to: destination),
        "Old ownership must not revive after moving back")
      let fresh = try owner.prepareMove(documentID: documentID)
      let forward = try owner.moveDocument(
        fresh, to: try XCTUnwrap(fresh.destinations.first { $0.windowID == destination.windowID }))
      guard case .moved = try await owner.waitForTransfer(forward) else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      XCTAssertEqual(storage.string, text)
      _ = try await owner.prepareQuit()
      let saved = try XCTUnwrap(store.load())
      XCTAssertEqual(saved.windows.flatMap(\.tabs).map(\.id), [documentID])
      XCTAssertEqual(
        saved.windows.first(where: { $0.id == target.sessionMetadata.id })?.tabs.first?.id,
        documentID)
    } catch {
      _ = try? await owner.prepareQuit()
      throw error
    }
  }
  func testFileTransferPreservesBytesMonitorAndRecoveryAfterSourceWindowCloses() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.txt")
    let text = "original 👩🏽‍💻 e\u{301}\r\nsecond line\r\n"
    let bytes = try DocumentCodec.encode(.init(text: text, encoding: .utf16LE, hasBOM: true))
    try bytes.write(to: file)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let tab = SessionTab(originalPath: file.path, pinned: true, encoding: .utf16LE)
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    try store.save(.init(windows: [window]))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    do {
      let source = try XCTUnwrap(owner.windows.first)
      let target = try owner.createWindow(createDocument: false)
      let model = try XCTUnwrap(owner.registry.handle(id: tab.id) as? EditorDocument)
      let bridge = try XCTUnwrap(model.fileState)
      let authority = model.recoveryAuthority
      let baseline = model.baselineRevision
      let binding = model.fileBindingID
      let pane = try XCTUnwrap(source.focusedPane)
      let choices = try owner.prepareMove(documentID: tab.id)
      let destination = try XCTUnwrap(
        choices.destinations.first { $0.windowID == target.sessionMetadata.id })
      pane.editor.insertText("local ", replacementRange: NSRange(location: 0, length: 0))
      let expected = "local " + text
      let id = try owner.moveDocument(choices, to: destination)
      switch try await owner.waitForTransfer(id) {
      case .moved: break
      case .retained(let error), .restored(let error): throw error
      }
      XCTAssertTrue(model.fileState === bridge)
      XCTAssertEqual(model.originalBytes, bytes)
      XCTAssertEqual(model.encoding, .utf16LE)
      XCTAssertTrue(model.hasBOM)
      XCTAssertEqual(model.baselineRevision, baseline)
      XCTAssertEqual(model.fileBindingID, binding)
      XCTAssertEqual(model.recoveryAuthority, authority)
      XCTAssertEqual(model.storage.string, expected)
      XCTAssertTrue(model.pinned)
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      source.window?.close()
      XCTAssertEqual(owner.windows.count, 1)
      XCTAssertTrue(owner.registry.handle(id: tab.id) === model)
      try Data("external changed bytes".utf8).write(to: file)
      bridge.checkAgain()
      for _ in 0..<5000 {
        if bridge.state.observation?.content == .differsFromBaseline { break }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      XCTAssertEqual(bridge.state.observation?.content, .differsFromBaseline)
      XCTAssertEqual(model.storage.string, expected, "Monitoring never overwrites local edits")
      _ = try await owner.prepareQuit()
      XCTAssertEqual(try store.load()?.windows.flatMap(\.tabs).map(\.id), [tab.id])
      let recovered = try RecoveryStore(directory: directory.appendingPathComponent("recovery"))
        .loadAll()
      XCTAssertEqual(recovered.map(\.id), [tab.id])
      XCTAssertEqual(recovered.first?.text, expected)
    } catch {
      _ = try? await owner.prepareQuit()
      throw error
    }
  }

  func testSourceLossBeforeStageCanRetry() async throws {
    try await endpointLoss(port: "suspend", sourceLost: true)
  }
  func testTargetLossBeforeStageCanRetry() async throws {
    try await endpointLoss(port: "suspend", sourceLost: false)
  }
  func testSourceLossAfterStageCanRetry() async throws {
    try await endpointLoss(port: "source", sourceLost: true)
  }
  func testTargetLossAfterStageCanRetry() async throws {
    try await endpointLoss(port: "target", sourceLost: false)
  }
  func testTargetLossDuringTerminalRefreshCanRetry() async throws {
    try await endpointLoss(port: "refresh", sourceLost: false)
  }

  func testTerminalRetryPreservesEditMadeAfterSettlement() async throws {
    try await endpointLoss(port: "refresh", sourceLost: true, editBeforeRetry: true)
  }
  func testFileMonitorSurvivesTerminalEndpointReplacement() async throws {
    try await endpointLoss(port: "refresh", sourceLost: false, fileBacked: true)
  }

  func testFileMonitorSourceLossBeforeReservationCanRetry() async throws {
    try await endpointLoss(port: "suspend", sourceLost: true, fileBacked: true)
  }
  func testFileMonitorTargetLossAfterStageCanRetry() async throws {
    try await endpointLoss(port: "target", sourceLost: false, fileBacked: true)
  }

  private func endpointLoss(
    port: String, sourceLost: Bool, editBeforeRetry: Bool = false, fileBacked: Bool = false
  ) async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      nativeTransferTestHook = nil
      try? FileManager.default.removeItem(at: directory)
    }
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let file = directory.appendingPathComponent("endpoint-synthetic.txt")
    let baselineText = fileBacked ? "baseline UTF16 👩🏽‍💻\r\n" : ""
    let original = try DocumentCodec.encode(
      .init(text: baselineText, encoding: .utf16LE, hasBOM: true))
    if fileBacked {
      try original.write(to: file)
      let tab = SessionTab(originalPath: file.path, encoding: .utf16LE)
      try store.save(.init(windows: [.init(tabs: [tab], selectedTabID: tab.id)]))
    }
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    var errors: [Error] = []
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, onError: { errors.append($0) })
    try await owner.start()
    let source = try XCTUnwrap(owner.windows.first)
    let target = try owner.createWindow(createDocument: false)
    let sourceWindowID = source.sessionMetadata.id
    let targetWindowID = target.sessionMetadata.id
    let id = try XCTUnwrap(source.selectedDocumentID)
    let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
    let storage = model.storage
    let undo = model.undoManager
    let authority = model.recoveryAuthority
    let insertion = "retained endpoint 👩🏽‍💻 e\u{301}\r\n"
    try XCTUnwrap(source.focusedPane).editor.insertText(
      insertion, replacementRange: NSRange(location: 0, length: 0))
    var text = insertion + baselineText
    let bridge = model.fileState
    let binding = model.fileBindingID
    let baseline = model.baselineRevision
    var fired = false
    nativeTransferTestHook = { reached in
      guard reached == port else { return }
      nativeTransferTestHook = nil
      fired = true
      (sourceLost ? source : target).window?.close()
    }
    let transfer = try owner.moveDocument(id, toWindowID: targetWindowID)
    guard case .retained = try await owner.waitForTransfer(transfer) else {
      return XCTFail("Endpoint loss must retain its exact unfinished transaction")
    }
    XCTAssertTrue(fired)
    XCTAssertTrue(owner.canRetryRecovery)
    XCTAssertTrue(owner.registry.handle(id: id) === model)
    XCTAssertTrue(model.storage === storage)
    XCTAssertTrue(model.undoManager === undo)
    XCTAssertEqual(storage.string, text)
    XCTAssertEqual(model.recoveryAuthority, authority)
    let beforeExtraEdit = text
    if editBeforeRetry {
      let editor = try XCTUnwrap(target.focusedPane).editor
      editor.breakUndoCoalescing()
      editor.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
      text = "new " + text
      XCTAssertEqual(storage.string, text, "Settled cleanup must not block ordinary edits")
    }
    do { try await owner.retryRecovery() } catch {
      return XCTFail("Retry Recovery refused: \(String(reflecting: error))")
    }
    XCTAssertFalse(owner.canRetryRecovery)
    let expectedWindow = port == "refresh" ? targetWindowID : sourceWindowID
    XCTAssertEqual(owner.registry.assignment(of: id)?.windowID, expectedWindow)
    XCTAssertTrue(owner.registry.handle(id: id) === model)
    XCTAssertEqual(storage.string, text)
    undo.undo()
    XCTAssertEqual(storage.string, editBeforeRetry ? beforeExtraEdit : baselineText)
    undo.redo()
    XCTAssertEqual(storage.string, text)
    if fileBacked {
      let retainedBridge = try XCTUnwrap(bridge)
      XCTAssertTrue(model.fileState === retainedBridge)
      XCTAssertEqual(model.fileBindingID, binding)
      XCTAssertEqual(model.baselineRevision, baseline)
      XCTAssertEqual(model.originalBytes, original)
      XCTAssertEqual(try Data(contentsOf: file), original)
      try Data("external replacement".utf8).write(to: file)
      retainedBridge.checkAgain()
      for _ in 0..<5000 {
        if retainedBridge.state.observation?.content == .differsFromBaseline { break }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      XCTAssertEqual(retainedBridge.state.observation?.content, .differsFromBaseline)
      XCTAssertEqual(storage.string, text)
    }
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.flatMap(\.tabs).map(\.id), [id])
    let restored = try RecoveryStore(directory: directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(restored.map(\.id), [id])
    XCTAssertEqual(restored.first?.text, text)
    XCTAssertEqual(model.recoveryAuthority, authority)
  }

}
