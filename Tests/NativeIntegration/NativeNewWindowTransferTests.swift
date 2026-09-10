import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class NativeNewWindowTransferTests: XCTestCase {
  @MainActor private final class Observations {
    var configurations = 0
    var announcements = 0
    var configure: ((EditorWindowController) -> Void)?
  }
  @MainActor private final class Fixture {
    let directory: URL
    let session: SessionCoordinator
    let owner: NativeApplicationDocuments
    let documentID: UUID
    let observations = Observations()
    init(
      windows: Int, documents: Int = 1, overlap: Bool = false, rich: Bool = false,
      longContent: Bool = false
    ) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("synthetic.txt")
      let originalText =
        (rich ? "original 👩🏽‍💻 e\u{301}\r\nsecond line\r\n" : "synthetic buffer")
        + (longContent ? String(repeating: "scrollable synthetic line\n", count: 300) : "")
      try DocumentCodec.encode(
        .init(text: originalText, encoding: rich ? .utf16LE : .utf8, hasBOM: rich)
      ).write(to: file)
      let presentation: SessionPresentation? =
        rich
        ? .init(
          axis: .stacked,
          panes: [
            .init(selection: NSRange(location: 0, length: 0), scrollOrigin: .init(x: 0, y: 0)),
            .init(selection: NSRange(location: 3, length: 2), scrollOrigin: .init(x: 0, y: 0)),
          ], focusedPaneIndex: 1) : nil
      let source = SessionTab(
        originalPath: file.path, pinned: rich,
        encoding: rich ? .utf16LE : .utf8, manualLanguage: rich ? .swift : nil,
        bookmarks: rich ? [0] : [], presentation: presentation)
      documentID = source.id
      var tabs = [source]
      if rich {
        let neighbor = directory.appendingPathComponent("neighbor.txt")
        try Data("neighbor".utf8).write(to: neighbor)
        tabs.append(SessionTab(originalPath: neighbor.path))
      }
      for _ in 1..<max(1, documents) { tabs.append(SessionTab()) }
      if overlap { tabs.append(SessionTab()) }
      var saved = [SessionWindow(tabs: tabs, selectedTabID: source.id)]
      for _ in 1..<max(1, windows) {
        let missing = SessionTab()
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
      owner = try NativeApplicationDocuments(
        session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
        onWindowCreated: { _ in observations.announcements += 1 },
        configureWindow: { controller in
          observations.configurations += 1
          observations.configure?(controller)
        }, onError: { _ in })
    }
    func start() async throws {
      try await owner.start()
      newWindowFactoryCalls = 0
      newWindowAdoptionCalls = 0
    }
    func cleanup() async {
      nativeTransferTestHook = nil
      newWindowPublisherPrepareHook = nil
      newWindowCommitHook = nil
      newWindowCaptureHook = nil
      newWindowReleaseHook = nil
      newWindowFinishHook = nil
      newWindowConstructionHook = nil
      newWindowHandoffHook = nil
      newWindowDrainHook = nil
      newWindowCleanupHook = nil
      newWindowStatusHook = nil
      _ = try? await owner.prepareQuit()
      for window in owner.windows { window.window?.close() }
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func testDirtyUnicodeFileMovesSameModelWithoutAnnouncementOrScratch() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let pane = try XCTUnwrap(source.focusedPane)
    let storage = model.storage
    let undo = model.undoManager
    let authority = model.recoveryAuthority
    let bridge = model.fileState
    let baseline = model.baselineRevision
    let bytes = model.originalBytes
    let announcements = f.observations.announcements
    let text = "dirty 👩🏽‍💻 e\u{301}\r\n"
    pane.editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    let id = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: model.id))
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(id) else {
      return XCTFail("Real transfer must finish")
    }
    let target = try f.owner.movePresentation(documentID: model.id, destination: destination)
    XCTAssertEqual(f.owner.windows.count, 2)
    XCTAssertTrue(f.owner.registry.handle(id: model.id) === model)
    XCTAssertTrue(model.storage === storage)
    XCTAssertTrue(model.undoManager === undo)
    XCTAssertTrue(target.focusedPane === pane)
    XCTAssertTrue(model.fileState === bridge)
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(model.baselineRevision, baseline)
    XCTAssertEqual(model.originalBytes, bytes)
    XCTAssertEqual(storage.string, text + "synthetic buffer")
    XCTAssertNil(source.selectedDocumentID)
    XCTAssertEqual(target.selectedDocumentID, model.id)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertEqual(f.observations.announcements, announcements)
    XCTAssertFalse(target.window!.isVisible)
    XCTAssertTrue(pane.editor.isEditable)
    undo.undo()
    XCTAssertEqual(storage.string, "synthetic buffer")
    undo.redo()
    XCTAssertEqual(storage.string, text + "synthetic buffer")
    _ = try await f.owner.prepareQuit()
    let saved = try XCTUnwrap(
      SessionStore(directory: f.directory.appendingPathComponent("session")).load())
    XCTAssertEqual(saved.windows.flatMap(\.tabs).map(\.id), [model.id])
    XCTAssertEqual(saved.windows.first { $0.id == destination.windowID }?.tabs.first?.id, model.id)
    let recovered = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(recovered.map(\.id), [model.id])
    XCTAssertEqual(recovered.first?.text, storage.string)
    await f.cleanup()
  }

  func testNewWindowSourceLossBeforeMonitorReservationRetriesSameInner() async throws {
    try await newWindowEndpointLoss(port: "suspend", sourceLost: true)
  }
  func testNewWindowTargetLossAfterStagingRetriesSameInner() async throws {
    try await newWindowEndpointLoss(port: "target", sourceLost: false)
  }
  func testNewWindowTargetLossDuringFinalRefreshRetriesSameInner() async throws {
    try await newWindowEndpointLoss(port: "refresh", sourceLost: false)
  }
  func testNewWindowSourceLossDuringFinalRefreshPreservesLaterEdits() async throws {
    try await newWindowEndpointLoss(port: "refresh", sourceLost: true, edit: true)
  }
  func testSplitMoveRollbackAfterTargetLossPreservesBothCapturedPanes() async throws {
    try await newWindowEndpointLoss(port: "target", sourceLost: false, rich: true)
  }
  private func newWindowEndpointLoss(
    port: String, sourceLost: Bool, edit: Bool = false, rich: Bool = false
  )
    async throws
  {
    let f = try Fixture(windows: 1, rich: rich)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let storage = model.storage
    let baselineText = storage.string
    let undo = model.undoManager
    let bridge = try XCTUnwrap(model.fileState)
    let binding = model.fileBindingID
    let baseline = model.baselineRevision
    let authority = model.recoveryAuthority
    let text = "moved 👩🏽‍💻 e\u{301}\r\n"
    source.focusedPane?.editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    var target: EditorWindowController?
    f.observations.configure = { target = $0 }
    var fired = false
    nativeTransferTestHook = { reached in
      guard reached == port else { return }
      nativeTransferTestHook = nil
      fired = true
      (sourceLost ? source : target)?.window?.close()
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: model.id))
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Endpoint loss retains exact transfer")
    }
    XCTAssertTrue(fired)
    let inner = try XCTUnwrap(f.owner.testInnerMoveID)
    let provisionalID = try XCTUnwrap(f.owner.testNewWindowID)
    XCTAssertNotNil(
      f.owner.registry.window(id: provisionalID), "Retained rollback needs empty target")
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertThrowsError(try f.owner.createWindow(createDocument: false))
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Retained transfer vetoes quit")
    } catch {}
    var expected = text + baselineText
    if edit {
      let editor = try XCTUnwrap(target?.focusedPane?.editor)
      editor.breakUndoCoalescing()
      editor.insertText("later ", replacementRange: NSRange(location: 0, length: 0))
      expected = "later " + expected
      XCTAssertEqual(storage.string, expected)
    }
    XCTAssertEqual(f.owner.testInnerMoveID, inner)
    try await f.owner.retryRecovery()
    XCTAssertFalse(f.owner.testPreparationPending)
    XCTAssertEqual(
      f.observations.announcements, sourceLost ? 2 : 1,
      "Only recreated ordinary source announces; provisional target never announces")
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    let outcome = try await f.owner.waitForNewWindowMove(move)
    if port == "refresh" {
      guard case .moved(let destination) = outcome else {
        return XCTFail("Settled move must stay moved")
      }
      XCTAssertEqual(destination.windowID, provisionalID)
      _ = try f.owner.movePresentation(documentID: model.id, destination: destination)
    } else {
      guard case .restored = outcome else { return XCTFail("Staged failure must restore") }
      XCTAssertNil(f.owner.registry.window(id: provisionalID))
      XCTAssertEqual(f.owner.windows.count, 1)
    }
    XCTAssertTrue(f.owner.registry.handle(id: model.id) === model)
    XCTAssertTrue(model.storage === storage)
    XCTAssertTrue(model.undoManager === undo)
    XCTAssertTrue(model.fileState === bridge)
    XCTAssertEqual(model.fileBindingID, binding)
    XCTAssertEqual(model.baselineRevision, baseline)
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(storage.string, expected)
    undo.undo()
    XCTAssertEqual(storage.string, edit ? text + baselineText : baselineText)
    undo.redo()
    XCTAssertEqual(storage.string, expected)
    try Data("external replacement".utf8).write(
      to: f.directory.appendingPathComponent("synthetic.txt"))
    bridge.checkAgain()
    for _ in 0..<5000 {
      if bridge.state.observation?.content == .differsFromBaseline { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(bridge.state.observation?.content, .differsFromBaseline)
    XCTAssertEqual(storage.string, expected)
    _ = try await f.owner.prepareQuit()
    let recovered = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(recovered.map(\.id), [model.id])
    XCTAssertEqual(recovered.first?.text, expected)
    await f.cleanup()
  }

  @MainActor private final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      entered = true
      await withCheckedContinuation { continuation = $0 }
    }
    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
  private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<5000 {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
  }
  func testPairedPublisherHeldBeforeCaptureDrainsWithoutProvisionalCapture() async throws {
    try await heldPublisher(beforeCapture: true)
  }
  func testPairedPublisherHeldAfterOldCaptureDrainsBeforeRegistration() async throws {
    try await heldPublisher(beforeCapture: false)
  }
  private func heldPublisher(beforeCapture: Bool) async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    source.focusedPane?.editor.insertText(
      "publish ", replacementRange: NSRange(location: 0, length: 0))
    let gate = Gate()
    var captures: [SessionCheckpointCapture] = []
    newWindowCaptureHook = { captures.append($0) }
    if beforeCapture {
      newWindowPublisherPrepareHook = {
        newWindowPublisherPrepareHook = nil
        await gate.wait()
      }
    } else {
      newWindowCommitHook = { _ in
        newWindowCommitHook = nil
        await gate.wait()
      }
    }
    f.owner.testRequestCheckpoint()
    let entered = await eventually { gate.entered }
    XCTAssertTrue(entered)
    guard entered else {
      await f.cleanup()
      return
    }
    let count = captures.count
    XCTAssertEqual(count, beforeCapture ? 0 : 1)
    newWindowPauseAcquires = 0
    newWindowPauseReleases = 0
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: model.id))
    let provisional = try XCTUnwrap(f.owner.testNewWindowID)
    for _ in 0..<200 { await Task.yield() }
    XCTAssertNil(f.owner.registry.window(id: provisional))
    XCTAssertEqual(f.owner.testPauseCount, 1)
    XCTAssertEqual(f.owner.windows.count, 1)
    gate.release()
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Move must drain actual publisher")
    }
    XCTAssertEqual(newWindowPauseAcquires, 2)
    XCTAssertEqual(newWindowPauseReleases, 2)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    _ = try await f.owner.prepareQuit()
    XCTAssertTrue(
      captures.allSatisfy { capture in
        !capture.session.windows.contains { $0.id == provisional && $0.tabs.isEmpty }
      })
    XCTAssertEqual(
      captures.last?.session.windows.first { $0.id == destination.windowID }?.tabs.map(\.id),
      [model.id])
    XCTAssertEqual(captures.last?.recovery.first?.authority, model.recoveryAuthority)
    let saved = try XCTUnwrap(
      SessionStore(directory: f.directory.appendingPathComponent("session")).load())
    XCTAssertEqual(saved.windows.flatMap(\.tabs).map(\.id), [model.id])
    let recovery = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(recovery.map(\.id), [model.id])
    XCTAssertEqual(recovery.first?.text, model.storage.string)
    await f.cleanup()
  }
  func testCancelledMoveWaiterRetainsOuterAndInnerOwnershipUntilCompletion() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let gate = Gate()
    newWindowFinishHook = {
      newWindowFinishHook = nil
      await gate.wait()
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    let waiter = Task { try await f.owner.waitForNewWindowMove(move) }
    let entered = await eventually { gate.entered }
    XCTAssertTrue(entered)
    waiter.cancel()
    XCTAssertNotNil(f.owner.testInnerMoveID)
    XCTAssertEqual(f.owner.testPauseCount, 1, "Outer pause remains after inner settlement")
    XCTAssertThrowsError(try f.owner.createWindow(createDocument: false))
    do {
      try await f.owner.testPreparePublisher()
      XCTFail("Publisher must refuse wrapper without waiting")
    } catch {}
    let target = try XCTUnwrap(f.owner.windows.first { $0.selectedDocumentID == f.documentID })
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let undo = model.undoManager
    target.focusedPane?.editor.insertText(
      "late ", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(model.storage.string, "late synthetic buffer")
    gate.release()
    guard case .moved = try await waiter.value else {
      return XCTFail("Waiter cancellation cannot cancel move")
    }
    XCTAssertFalse(f.owner.testPreparationPending)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    XCTAssertEqual(model.storage.string, "late synthetic buffer")
    undo.undo()
    XCTAssertEqual(model.storage.string, "synthetic buffer")
    await f.cleanup()
  }
  func testOuterPauseReleaseFailureRetriesWithoutMovingOrReleasingAgain() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    newWindowPauseAcquires = 0
    newWindowPauseReleases = 0
    var calls = 0
    newWindowReleaseHook = {
      calls += 1
      if calls == 2 { throw NativeNewWindowPreparationError.changed }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Outer release must retain")
    }
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let ownership = model.ownershipGeneration
    let windowID = f.owner.registry.assignment(of: model.id)?.windowID
    XCTAssertEqual(f.owner.testPauseCount, 1)
    XCTAssertEqual(newWindowPauseReleases, 1)
    try await f.owner.retryRecovery()
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Retry must finish")
    }
    XCTAssertEqual(destination.windowID, windowID)
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(newWindowPauseAcquires, 2)
    XCTAssertEqual(newWindowPauseReleases, 2)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    await f.cleanup()
  }
  func testFailedPreparationUnregistersOnceAcrossReleaseFailureAndReentrantClose() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    f.observations.configure = { controller in controller.window?.close() }
    var releaseCalls = 0
    newWindowReleaseHook = {
      releaseCalls += 1
      if releaseCalls == 1 { throw NativeNewWindowPreparationError.changed }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    let targetID = try XCTUnwrap(f.owner.testNewWindowID)
    var removals = 0
    f.owner.registry.onChange = { _ in
      if f.owner.registry.window(id: targetID) == nil { removals += 1 }
    }
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Release failure retains cleanup")
    }
    XCTAssertNil(f.owner.registry.window(id: targetID))
    XCTAssertEqual(removals, 1)
    XCTAssertEqual(f.owner.testPauseCount, 1)
    try await f.owner.retryRecovery()
    guard case .restored = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Unused cleanup must finish")
    }
    XCTAssertEqual(removals, 1)
    XCTAssertEqual(releaseCalls, 2)
    XCTAssertEqual(f.owner.windows.count, 1)
    f.owner.registry.onChange = nil
    await f.cleanup()
  }

  func testUnrelatedProvisionalReplacementCannotBeRemovedByOldCleanup() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var target: EditorWindowController?
    f.observations.configure = { target = $0 }
    nativeTransferTestHook = { port in
      guard port == "capture" else { return }
      nativeTransferTestHook = nil
      target?.window?.close()
    }
    newWindowFinishHook = {
      newWindowFinishHook = nil
      do { try f.owner.testReplaceProvisionalEndpoint() } catch {
        XCTFail("Replacement fixture failed: \(error)")
      }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    let targetID = try XCTUnwrap(f.owner.testNewWindowID)
    guard case .retained(let error) = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Unrelated incarnation must retain cleanup")
    }
    XCTAssertTrue(error is NativeNewWindowPreparationError)
    XCTAssertNotNil(f.owner.registry.window(id: targetID))
    XCTAssertTrue(f.owner.windows.contains { $0 === target })
    XCTAssertEqual(f.owner.testPauseCount, 1)
    do {
      try await f.owner.retryRecovery()
      XCTFail("Retry cannot adopt unrelated replacement")
    } catch {}
    XCTAssertNotNil(f.owner.registry.window(id: targetID))
    XCTAssertTrue(f.owner.windows.contains { $0 === target })
    // Deliberately retained synthetic ownership stays paused for this isolated test process.
    f.observations.configure = nil
    try? FileManager.default.removeItem(at: f.directory)
  }
  func testCommittedTargetLossDuringOuterReleaseReattachesWithoutOldDescriptor() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var target: EditorWindowController?
    f.observations.configure = { target = $0 }
    newWindowStatusHook = {
      guard f.owner.testCleanupRunning, f.owner.testPauseCount == 0 else { return }
      newWindowStatusHook = nil
      target?.window?.close()
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Closed committed target retains presentation")
    }
    let oldTarget = target
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let ownership = model.ownershipGeneration
    XCTAssertEqual(f.owner.testPauseCount, 0, "Successful outer release is not repeated")
    try await f.owner.retryRecovery()
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Committed retry must move")
    }
    let actual = try f.owner.movePresentation(documentID: model.id, destination: destination)
    XCTAssertFalse(actual === oldTarget)
    XCTAssertTrue(actual === target)
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(f.observations.announcements, 1)
    await f.cleanup()
  }
  func testFinalCheckpointCallbackCanStartNextMoveWithoutOldCleanupErasingIt() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var next: NativeNewWindowMoveID?
    var callbackError: Error?
    newWindowStatusHook = {
      guard !f.owner.testPreparationPending, f.owner.windows.count == 2 else { return }
      newWindowStatusHook = nil
      do {
        next = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
      } catch { callbackError = error }
    }
    let first = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    guard case .moved = try await f.owner.waitForNewWindowMove(first) else {
      return XCTFail("First move must settle")
    }
    XCTAssertNil(callbackError)
    let second = try XCTUnwrap(next)
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(f.owner.testPreparationPending)
    guard case .moved(let destination) = try await f.owner.waitForNewWindowMove(second) else {
      return XCTFail("Reentrant second move must survive")
    }
    XCTAssertEqual(f.owner.registry.assignment(of: f.documentID)?.windowID, destination.windowID)
    XCTAssertEqual(f.owner.windows.count, 3)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    await f.cleanup()
  }

  func testPinnedUTF16BOMBookmarksAndBothPanesMoveWithNeighborSelected() async throws {
    let f = try Fixture(windows: 1, rich: true)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let original = try Data(contentsOf: f.directory.appendingPathComponent("synthetic.txt"))
    let panes = model.panePool
    let focused = source.focusedPane
    let neighbor = try XCTUnwrap(source.sessionMetadata.tabs.first { $0.id != model.id }?.id)
    let bookmarks = model.bookmarks
    let binding = model.fileBindingID
    let authority = model.recoveryAuthority
    let oldText = model.storage.string
    focused?.editor.insertText(
      "local ", replacementRange: NSRange(location: model.storage.length, length: 0))
    let expectedBookmarks = model.bookmarks
    let before = try model.captureTransferView(preparation: source.captureTransferPreparation())
    var ports: [String] = []
    nativeTransferTestHook = { ports.append($0) }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: model.id))
    let destination: NativeDocumentMoveDestination
    switch try await f.owner.waitForNewWindowMove(move) {
    case .moved(let value): destination = value
    case .retained(let error), .restored(let error):
      return XCTFail("Rich same-model move: \(String(reflecting: error)); ports: \(ports)")
    }
    nativeTransferTestHook = nil
    let target = try f.owner.movePresentation(documentID: model.id, destination: destination)
    XCTAssertEqual(source.selectedDocumentID, neighbor)
    XCTAssertEqual(
      f.owner.registry.window(id: destination.windowID)?.groups.first?.documentIDs, [model.id])
    XCTAssertTrue(model.pinned)
    XCTAssertTrue(model.manualLanguage)
    XCTAssertEqual(model.language, .swift)
    XCTAssertEqual(model.encoding, .utf16LE)
    XCTAssertTrue(model.hasBOM)
    XCTAssertEqual(model.originalBytes, original)
    XCTAssertEqual(
      try Data(contentsOf: f.directory.appendingPathComponent("synthetic.txt")), original)
    XCTAssertEqual(model.fileBindingID, binding)
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(model.bookmarks, expectedBookmarks)
    XCTAssertEqual(bookmarks, expectedBookmarks)
    XCTAssertEqual(model.panePool.count, 2)
    XCTAssertTrue(zip(model.panePool, panes).allSatisfy { $0 === $1 })
    XCTAssertTrue(target.focusedPane === focused)
    let after = try model.captureTransferView(preparation: target.captureTransferPreparation())
    XCTAssertEqual(after.axis, before.axis)
    XCTAssertEqual(after.preferredPaneID, before.preferredPaneID)
    XCTAssertEqual(after.panes.map(\.selection), before.panes.map(\.selection))
    XCTAssertEqual(after.pending?.presentation, before.pending?.presentation)
    XCTAssertEqual(model.storage.string, oldText + "local ")
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    _ = try await f.owner.prepareQuit()
    let saved = try XCTUnwrap(
      SessionStore(directory: f.directory.appendingPathComponent("session")).load())
    let tab = try XCTUnwrap(saved.windows.first { $0.id == destination.windowID }?.tabs.first)
    XCTAssertEqual(tab.id, model.id)
    XCTAssertTrue(tab.pinned)
    XCTAssertEqual(tab.encoding, .utf16LE)
    XCTAssertEqual(tab.manualLanguage, .swift)
    XCTAssertEqual(tab.bookmarks, expectedBookmarks.offsets)
    XCTAssertEqual(tab.presentation.panes.count, 2)
    let recovered = try RecoveryStore(directory: f.directory.appendingPathComponent("recovery"))
      .loadAll()
    XCTAssertEqual(recovered.map(\.id), [model.id])
    XCTAssertEqual(recovered.first?.text, model.storage.string)
    await f.cleanup()
  }

  func testFailureBeforeRegistrationLeavesNoEndpointOrPause() async throws {
    try await failedMoveBoundary("drain")
  }
  func testFailureAfterRegistrationBeforeControllerReturnCleansExactWindow() async throws {
    try await failedMoveBoundary("construct")
  }
  func testFailureImmediatelyBeforeInnerStartCleansWithoutInnerIdentity() async throws {
    try await failedMoveBoundary("handoff")
  }
  private func failedMoveBoundary(_ phase: String) async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    if phase == "drain" {
      newWindowDrainHook = {
        newWindowDrainHook = nil
        throw NativeNewWindowPreparationError.changed
      }
    }
    if phase == "construct" {
      newWindowConstructionHook = {
        newWindowConstructionHook = nil
        throw NativeNewWindowPreparationError.changed
      }
    }
    if phase == "handoff" {
      newWindowHandoffHook = {
        newWindowHandoffHook = nil
        throw NativeNewWindowPreparationError.changed
      }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    let targetID = try XCTUnwrap(f.owner.testNewWindowID)
    guard case .restored = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Unused target should clean up at \(phase)")
    }
    XCTAssertFalse(f.owner.testPreparationPending)
    XCTAssertNil(f.owner.registry.window(id: targetID))
    XCTAssertEqual(f.owner.windows.count, 1)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    await f.cleanup()
  }
  func testPopulatedProvisionalWindowRetainsItsForeignModelAndPause() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let foreign = EditorDocument(id: UUID())
    f.observations.configure = { controller in
      f.observations.configure = nil
      do {
        let window = try XCTUnwrap(f.owner.registry.window(id: controller.sessionMetadata.id))
        try f.owner.registry.registerDocument(
          foreign, metadata: .init(pinned: false),
          in: .init(windowID: window.id, groupID: window.groups[0].id), at: 0, select: true)
      } catch { XCTFail("Explicit registry fixture failed: \(error)") }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    let targetID = try XCTUnwrap(f.owner.testNewWindowID)
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Used target must be preserved")
    }
    XCTAssertEqual(f.owner.registry.assignment(of: foreign.id)?.windowID, targetID)
    XCTAssertTrue(f.owner.registry.handle(id: foreign.id) === foreign)
    XCTAssertNotNil(f.owner.registry.window(id: targetID))
    XCTAssertEqual(f.owner.testPauseCount, 1)
    do {
      try await f.owner.retryRecovery()
      XCTFail("Retry must retain used window")
    } catch {}
    XCTAssertTrue(f.owner.registry.handle(id: foreign.id) === foreign)
    // Explicit test intrusion retains its synthetic records; admission was never disabled.
    try? FileManager.default.removeItem(at: f.directory)
  }

  func testFailedOwnedSuccessorConstructionRemainsRetryableWithSameInnerID() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var target: EditorWindowController?
    f.observations.configure = { target = $0 }
    nativeTransferTestHook = { port in
      guard port == "target" else { return }
      nativeTransferTestHook = nil
      target?.window?.close()
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Target loss must retain")
    }
    let inner = try XCTUnwrap(f.owner.testInnerMoveID)
    newWindowConstructionHook = {
      newWindowConstructionHook = nil
      throw NativeNewWindowPreparationError.changed
    }
    do {
      try await f.owner.retryRecovery()
      XCTFail("First successor construction must refuse")
    } catch {}
    XCTAssertEqual(f.owner.testInnerMoveID, inner)
    try await f.owner.retryRecovery()
    guard case .restored = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Same transfer must recover after constructor refusal")
    }
    XCTAssertEqual(f.owner.windows.count, 1)
    XCTAssertEqual(f.owner.testPauseCount, 0)
    await f.cleanup()
  }

  func testCanonicalBackingOriginStillRejectsUnrelatedActualDisplacement() async throws {
    let f = try Fixture(windows: 1, rich: true, longContent: true)
    try await f.start()
    let model = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let source = try XCTUnwrap(f.owner.windows.first)
    let pane = try XCTUnwrap(model.panePool.last)
    var oldOrigin: NSPoint?
    var displaced = false
    nativeTransferTestHook = { port in
      guard port == "attach" else { return }
      nativeTransferTestHook = nil
      do {
        let preparation = try source.captureTransferPreparation()
        let before = try model.captureTransferState(preparation: preparation)
        let interaction = model.panePresentation.interaction
        let clip = pane.scroll.contentView
        oldOrigin = clip.bounds.origin
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 37))
        displaced = clip.bounds.origin != oldOrigin
        XCTAssertTrue(displaced, "Fault must persist rather than be clamped away")
        XCTAssertEqual(try model.captureTransferState(preparation: preparation), before)
        XCTAssertEqual(model.panePresentation.interaction, interaction)
      } catch { XCTFail("Origin-only fault setup failed: \(error)") }
    }
    let move = try f.owner.startMoveToNewWindow(f.owner.prepareMove(documentID: model.id))
    guard case .retained = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Strict geometry must refuse unrelated displacement")
    }
    XCTAssertTrue(displaced)
    pane.scroll.contentView.setBoundsOrigin(try XCTUnwrap(oldOrigin))
    try await f.owner.retryRecovery()
    guard case .restored = try await f.owner.waitForNewWindowMove(move) else {
      return XCTFail("Exact original geometry should permit rollback retry")
    }
    XCTAssertEqual(f.owner.windows.count, 1)
    await f.cleanup()
  }

  func testThirtyOneAggregateWindowsAdmitOneEmptyUnannouncedEndpoint() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let original = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let windowsBefore = f.owner.windows.count
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared(let destination) = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("31 aggregate windows must admit the 32nd")
    }
    XCTAssertEqual(f.owner.windows.count, windowsBefore + 1)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertEqual(f.owner.registry.window(id: destination.windowID)?.groups.first?.documentIDs, [])
    XCTAssertTrue(f.owner.registry.handle(id: f.documentID) === original)
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    XCTAssertFalse(
      try XCTUnwrap(f.owner.windows.first { $0.sessionMetadata.id == destination.windowID }).window!
        .isVisible)
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Prepared ownership must veto quit")
    } catch {}
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertNil(f.owner.registry.window(id: destination.windowID))
    XCTAssertEqual(f.owner.windows.count, windowsBefore)
    await f.cleanup()
  }

  func testThirtyTwoAggregateWindowsRefuseWithoutConstruction() async throws {
    let f = try Fixture(windows: 32)
    try await f.start()
    let before = f.owner.windows.count
    XCTAssertNotNil(f.owner.newWindowMoveRefusalReason())
    do {
      _ = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.owner.windows.count, before)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    await f.cleanup()
  }

  func testLiveUnresolvedOverlapCountsOnce() async throws {
    let f = try Fixture(windows: 31, overlap: true)
    try await f.start()
    XCTAssertNil(f.owner.newWindowMoveRefusalReason())
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Live/unresolved overlap must count once")
    }
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testExisting128DocumentIDsPermitZeroDocumentGrowth() async throws {
    let f = try Fixture(windows: 1, documents: 128)
    try await f.start()
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("New destination adds no document IDs")
    }
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    XCTAssertEqual(f.session.unresolved.count, 127)
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testOrdinaryTextEditDoesNotExpireChoiceAndSecondPreparationRefuses() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let source = try XCTUnwrap(f.owner.windows.first)
    source.focusedPane?.editor.insertText(
      "edit ", replacementRange: NSRange(location: 0, length: 0))
    let id = try f.owner.startNewWindowPreparation(choices)
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("Expected admission refusal")
    } catch {}
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Ordinary buffer editing preserves the choice")
    }
    XCTAssertEqual(
      (f.owner.registry.handle(id: f.documentID) as? EditorDocument)?.storage.string,
      "edit synthetic buffer")
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }
  func testExistingOverLimitAggregateRefusesGrowth() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let first = UUID()
    let second = UUID()
    try f.owner.registry.registerWindow(id: first, initialGroupID: UUID())
    try f.owner.registry.registerWindow(id: second, initialGroupID: UUID())
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let constructions = f.observations.configurations
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.observations.configurations, constructions)
    XCTAssertFalse(f.owner.testPreparationPending)
    try f.owner.registry.unregisterEmptyWindow(
      first, expectedRevision: f.owner.registry.workspaceRevision)
    try f.owner.registry.unregisterEmptyWindow(
      second, expectedRevision: f.owner.registry.workspaceRevision)
    await f.cleanup()
  }

  func testSelectionABAExpiresChoiceWhileForeignChoiceCreatesNothing() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    source.newDocument()
    for _ in 0..<10000 {
      if source.sessionMetadata.tabs.count == 2 { break }
      await Task.yield()
    }
    let second = try XCTUnwrap(source.selectedDocumentID)
    var settled: NativeDocumentMoveChoices?
    for _ in 0..<10000 {
      settled = try? f.owner.prepareMove(documentID: second)
      if settled != nil { break }
      await Task.yield()
    }
    let choice = try XCTUnwrap(settled)
    let assignment = try XCTUnwrap(f.owner.registry.assignment(of: second))
    try f.owner.registry.selectDocument(
      f.documentID, in: assignment, expectedRevision: f.owner.registry.workspaceRevision)
    try f.owner.registry.selectDocument(
      second, in: assignment, expectedRevision: f.owner.registry.workspaceRevision)
    let constructions = f.observations.configurations
    do {
      _ = try f.owner.startNewWindowPreparation(choice)
      XCTFail("Expected admission refusal")
    } catch {}
    let foreign = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: choice.ownershipGeneration,
      sourceWindowID: UUID(), sourceEndpointID: choice.sourceEndpointID, destinations: [],
      sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(foreign)
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.observations.configurations, constructions)
    await f.cleanup()
  }

  func testCapacityRevisionChangeAcrossHeldDrainRetainsWithoutConstruction() async throws {
    let f = try Fixture(windows: 2)
    try await f.start()
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let before = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(release)
    f.session.resolved(try XCTUnwrap(f.session.unresolved.first))
    held.resume()
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Changed capacity receipt must refuse construction")
    }
    XCTAssertEqual(f.observations.configurations, before)
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertTrue(f.owner.canRetryRecovery)
    newWindowDrainHook = nil
    try await f.owner.retryRecovery()
    XCTAssertFalse(f.owner.testPreparationPending)
    await f.cleanup()
  }

  func testConfigurationReentryCannotCreateIntakeCloseOrPublish() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choice = try f.owner.prepareMove(documentID: f.documentID)
    var reentered = false
    var provisional: EditorWindowController?
    f.observations.configure = { controller in
      reentered = true
      provisional = controller
      XCTAssertTrue(f.owner.testPreparationPending)
      do {
        _ = try f.owner.createWindow()
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        _ = try f.owner.startNewWindowPreparation(choice)
        XCTFail("Expected admission refusal")
      } catch {}
      controller.newDocument()
      do {
        try f.owner.testStartClose(f.documentID)
        XCTFail("Close must refuse during configuration")
      } catch {}
    }
    let announcements = f.observations.announcements
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(choice)
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Refused reentry must preserve preparation")
    }
    XCTAssertTrue(reentered)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertEqual(f.observations.configurations, constructions + 1)
    XCTAssertEqual(f.observations.announcements, announcements)
    XCTAssertTrue(try XCTUnwrap(provisional).sessionMetadata.tabs.isEmpty)
    do {
      try await f.owner.testPreparePublisher()
      XCTFail("Publisher preparation must refuse immediately")
    } catch {}
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Preparation must veto quit")
    } catch {}
    do {
      try await f.owner.start()
      XCTFail("Reentrant startup must refuse")
    } catch {}
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testCancelledWaiterDoesNotReleaseOwnerPauseOrDiscardPreparation() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let unrelated = try f.owner.testAcquirePause()
    try await f.owner.testDrainPause(unrelated)
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    let waiter = Task { try await f.owner.waitForNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    waiter.cancel()
    XCTAssertTrue(f.owner.testPreparationPending)
    try XCTUnwrap(release).resume()
    guard case .prepared = try await waiter.value else {
      return XCTFail("Waiter does not own cancellation")
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertFalse(f.owner.testPreparationPending)
    // Exact independently-held token must remain valid and unreleased.
    try f.owner.testReleasePause(unrelated)
    do {
      _ = try f.owner.testReleasePause(unrelated)
      XCTFail("Expected admission refusal")
    } catch {}
    await f.cleanup()
  }

  func testRegistrationNotifiesAfterOwnerReceiptAndUnderFence() async throws {
    let registry = ApplicationDocuments()
    let id = UUID()
    let group = UUID()
    var receipt: UUID?
    var notified = false
    registry.onChange = { revision in
      notified = true
      XCTAssertEqual(receipt, revision)
    }
    try registry.registerWindow(
      id: id, initialGroupID: group,
      willNotify: { revision in
        receipt = revision
        do {
          _ = try registry.registerWindow(id: UUID(), initialGroupID: UUID())
          XCTFail("Expected admission refusal")
        } catch {}
      })
    XCTAssertTrue(notified)
    registry.onChange = { _ in XCTAssertNil(registry.window(id: id)) }
    var removed = false
    try registry.unregisterEmptyWindow(
      id, expectedRevision: registry.workspaceRevision,
      willNotify: { _ in
        removed = true
        do {
          _ = try registry.registerWindow(id: id, initialGroupID: group)
          XCTFail("Expected admission refusal")
        } catch {}
      })
    XCTAssertTrue(removed)
  }

  func testUnregisterCallbackRecreationSurvivesOldCleanup() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .prepared(let destination) = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Expected provisional endpoint")
    }
    let replacementGroup = UUID()
    var replaced = false
    f.owner.registry.onChange = { _ in
      guard !replaced, f.owner.registry.window(id: destination.windowID) == nil else { return }
      replaced = true
      XCTAssertTrue(f.owner.testCleanupRunning)
      do {
        _ = try f.owner.startNewWindowPreparation(choices)
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        _ = try f.owner.createWindow()
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        try f.owner.registry.registerWindow(
          id: destination.windowID, initialGroupID: replacementGroup)
      } catch { XCTFail("Replacement fixture failed: \(error)") }
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertTrue(replaced)
    XCTAssertEqual(
      f.owner.registry.window(id: destination.windowID)?.groups.first?.id, replacementGroup)
    f.owner.registry.onChange = nil
    try f.owner.registry.unregisterEmptyWindow(
      destination.windowID, expectedRevision: f.owner.registry.workspaceRevision)
    await f.cleanup()
  }

  func testReentrantExternalOpenRetainsIntentWithoutSecondEndpoint() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let extra = f.directory.appendingPathComponent("extra-synthetic.txt")
    try Data("extra".utf8).write(to: extra)
    var result: OpenRequestAdmission?
    f.observations.configure = { _ in result = f.owner.enqueueExternal([.init(url: extra)]) }
    let before = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Pending open invalidates the preparation admission")
    }
    for _ in 0..<10000 {
      if f.owner.externalOpenFailure != nil { break }
      await Task.yield()
    }
    XCTAssertEqual(result?.acceptedCount, 1)
    XCTAssertNotNil(f.owner.externalOpenFailure)
    XCTAssertEqual(f.observations.configurations, before + 1)
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    XCTAssertEqual(
      f.owner.pendingExternalOpenCount, 1, "The accepted original request remains retryable")
    guard let originalRequestID = f.owner.testExternalRequestID else {
      XCTFail("Temporary destination refusal must retain the original queued request")
      try await f.owner.cancelNewWindowPreparation(id)
      await f.cleanup()
      return
    }
    XCTAssertEqual(f.owner.externalOpenFailure?.id, originalRequestID)
    let later = f.directory.appendingPathComponent("later-synthetic.txt")
    try Data("later".utf8).write(to: later)
    XCTAssertEqual(f.owner.enqueueExternal([.init(url: later)]).acceptedCount, 1)
    XCTAssertEqual(f.owner.pendingExternalOpenCount, 2)
    XCTAssertEqual(f.owner.testExternalRequestID, originalRequestID)
    f.observations.configure = nil
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertEqual(f.owner.windows.count, before)
    try f.owner.retryExternalOpen()
    XCTAssertEqual(
      f.owner.testExternalRequestID, originalRequestID, "Retry uses the accepted envelope")
    for _ in 0..<10000 {
      if f.owner.pendingExternalOpenCount == 0 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(f.owner.pendingExternalOpenCount, 0)
    let ordered = try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) }
    XCTAssertEqual(ordered.count, 3)
    XCTAssertEqual(ordered.first, f.documentID)
    XCTAssertEqual(
      ordered.dropFirst().compactMap { (f.owner.registry.handle(id: $0) as? EditorDocument)?.url },
      [extra, later])
    XCTAssertEqual(newWindowFactoryCalls, 2, "Original and later requests each create one model")
    XCTAssertEqual(newWindowAdoptionCalls, 2)
    XCTAssertEqual(f.observations.configurations, before + 1, "Retry creates no extra endpoint")
    XCTAssertEqual(f.owner.windows.count, before)
    await f.cleanup()
  }

  func testExplicitCancelDuringDrainReturnsCancelledToWaiter() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    let waiter = Task { try await f.owner.waitForNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    let cancel = Task { try await f.owner.cancelNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if f.owner.testCleanupRunning { break }
      await Task.yield()
    }
    try XCTUnwrap(release).resume()
    newWindowDrainHook = nil
    let result = try await waiter.value
    if case .cancelled = result {
    } else {
      XCTFail("Explicit owner cancellation must report cancelled, not a retained/prepared receipt")
    }
    try await cancel.value
    XCTAssertFalse(f.owner.testPreparationPending)
    await f.cleanup()
  }

  func testPauseReleaseRenderingCannotReenterPreparationOrConsumeTwice() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Expected prepared destination")
    }
    var releaseRendered = false
    newWindowStatusHook = {
      guard f.owner.testCleanupRunning else { return }
      releaseRendered = true
      XCTAssertTrue(f.owner.testPreparationPending)
      do {
        _ = try f.owner.startNewWindowPreparation(choices)
        XCTFail("Reentrant prepare must refuse")
      } catch {}
      do {
        _ = try f.owner.createWindow()
        XCTFail("Reentrant window must refuse")
      } catch {}
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertTrue(releaseRendered)
    XCTAssertFalse(f.owner.testPreparationPending)
    do {
      try await f.owner.cancelNewWindowPreparation(id)
      XCTFail("Exact cleanup cannot repeat")
    } catch {}
    await f.cleanup()
  }
  func testActualPendingRecoveryRemovalRefusesBeforeConstruction() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = SessionTab()
    let saved = EditorSession(windows: [.init(tabs: [tab], selectedTabID: tab.id)])
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recoveryDirectory = directory.appendingPathComponent("recovery")
    try RecoveryStore(directory: recoveryDirectory).save(
      .init(id: tab.id, text: "unresolved synthetic", encoding: .utf8, hasBOM: false))
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory, saveCheckpointSession: { try store.save($0) },
      readCheckpointSession: { try store.load() })
    var removal: CheckedContinuation<Void, Error>?
    let session = SessionCoordinator(
      loadSession: { saved }, claimRecovery: { try await recovery.claimStartup() },
      removeRecovery: { _ in
        try await withCheckedThrowingContinuation { removal = $0 }
      })
    await session.restore { _ in [tab.id: "Synthetic retained import"] }
    var constructions = 0
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, configureWindow: { _ in constructions += 1 }, onError: { _ in })
    try await owner.start()
    let source = try XCTUnwrap(owner.windows.first?.selectedDocumentID)
    let choices = try owner.prepareMove(documentID: source)
    let entry = try XCTUnwrap(session.unresolved.first)
    let task = Task { try await session.remove(entry) }
    for _ in 0..<10000 {
      if removal != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(removal)
    let before = constructions
    do {
      _ = try owner.startNewWindowPreparation(choices)
      XCTFail("Pending removal must refuse")
    } catch {}
    XCTAssertEqual(constructions, before)
    XCTAssertFalse(owner.testPreparationPending)
    XCTAssertNotNil(owner.newWindowMoveRefusalReason())
    XCTAssertEqual(try RecoveryStore(directory: recoveryDirectory).loadAll().map(\.id), [tab.id])
    held.resume(throwing: NativeNewWindowPreparationError.changed)
    do {
      try await task.value
      XCTFail("Injected removal fails")
    } catch {}
    let prepared = try owner.startNewWindowPreparation(owner.prepareMove(documentID: source))
    guard case .prepared = try await owner.waitForNewWindowPreparation(prepared) else {
      return XCTFail("Settled failed removal permits fresh admission")
    }
    try await owner.cancelNewWindowPreparation(prepared)
    _ = try await owner.prepareQuit()
    for window in owner.windows { window.window?.close() }
  }

  func testCorruptSessionPreservesBytesAndRefusesWithoutAdditionalConstructionOrIO() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Session.json")
    let corrupt = Data("{synthetic corrupt session".utf8)
    try corrupt.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let store = SessionStore(directory: directory)
    let recovery = RecoveryCoordinator(directory: directory.appendingPathComponent("recovery"))
    var reads = 0
    var constructions = 0
    let session = SessionCoordinator(
      loadSession: {
        reads += 1
        return try store.load()
      }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, configureWindow: { _ in constructions += 1 }, onError: { _ in })
    do { try await owner.start() } catch {}
    let before = constructions
    let choice = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [],
      sourceWorkspaceRevision: owner.registry.workspaceRevision)
    do {
      _ = try owner.startNewWindowPreparation(choice)
      XCTFail("Corrupt session refuses admission")
    } catch {}
    XCTAssertEqual(constructions, before)
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    XCTAssertFalse(owner.testPreparationPending)
  }
  func testRegistrationCallbackWorkspaceABAIsDetectedBeforeConstructionAndRetainsExactWindow()
    async throws
  {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    var provisional: UUID?
    f.owner.registry.onChange = { _ in
      guard provisional == nil,
        let added = f.owner.registry.windowIDs.first(where: { $0 != choices.sourceWindowID })
      else { return }
      provisional = added
      do {
        let unrelated = UUID()
        try f.owner.registry.registerWindow(id: unrelated, initialGroupID: UUID())
        try f.owner.registry.unregisterEmptyWindow(
          unrelated, expectedRevision: f.owner.registry.workspaceRevision)
      } catch { XCTFail("Fixture mutation failed: \(String(reflecting: error))") }
      do {
        _ = try f.owner.createWindow()
        XCTFail("Registration callback must remain gated")
      } catch {}
    }
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Registration callback revision ABA must invalidate the receipt")
    }
    XCTAssertEqual(f.observations.configurations, constructions)
    let windowID = try XCTUnwrap(provisional)
    XCTAssertNotNil(f.owner.registry.window(id: windowID))
    do {
      try await f.owner.cancelNewWindowPreparation(id)
      XCTFail("Unproven changed registration must be retained")
    } catch {}
    let cleanupOutcome = try await f.owner.waitForNewWindowPreparation(id)
    if case .retained(let error) = cleanupOutcome,
      case .cleanupChanged? = error as? NativeNewWindowPreparationError
    {
    } else {
      XCTFail("A failed cancellation must report its retained cleanup error, never cancelled")
    }
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertNotNil(f.owner.registry.window(id: windowID))
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Retained cleanup must veto quit")
    } catch {}
    f.owner.registry.onChange = nil
    // This intentionally retained synthetic owner remains paused until the isolated process exits.
    try? FileManager.default.removeItem(at: f.directory)
  }

  func testOwnershipABAAndForeignEndpointRefuseBeforeConstruction() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let target = try f.owner.createWindow(createDocument: false)
    let choice = try f.owner.prepareMove(documentID: f.documentID)
    let forward = try f.owner.moveDocument(f.documentID, toWindowID: target.sessionMetadata.id)
    guard case .moved = try await f.owner.waitForTransfer(forward) else {
      return XCTFail("Fixture forward transfer failed")
    }
    let reverse = try f.owner.moveDocument(f.documentID, toWindowID: choice.sourceWindowID)
    guard case .moved = try await f.owner.waitForTransfer(reverse) else {
      return XCTFail("Fixture reverse transfer failed")
    }
    let before = f.observations.configurations
    let aba = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: choice.ownershipGeneration,
      sourceWindowID: choice.sourceWindowID, sourceEndpointID: choice.sourceEndpointID,
      destinations: [], sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(aba)
      XCTFail("Old ownership must not revive")
    } catch {}
    let fresh = try f.owner.prepareMove(documentID: f.documentID)
    let foreign = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: fresh.ownershipGeneration,
      sourceWindowID: fresh.sourceWindowID, sourceEndpointID: UUID(), destinations: [],
      sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(foreign)
      XCTFail("Foreign endpoint must refuse")
    } catch {}
    XCTAssertEqual(f.observations.configurations, before)
    await f.cleanup()
  }

  func testExhaustedNewWindowCapacityPreservesExistingDestinationTransfer() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let target = try f.owner.createWindow(createDocument: false)
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let destination = try XCTUnwrap(
      choices.destinations.first { $0.windowID == target.sessionMetadata.id })
    XCTAssertNotNil(f.owner.newWindowMoveRefusalReason())
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("32 windows must refuse growth")
    } catch {}
    let transfer = try f.owner.moveDocument(choices, to: destination)
    guard case .moved = try await f.owner.waitForTransfer(transfer) else {
      return XCTFail("Existing destination remains usable without window growth")
    }
    XCTAssertEqual(
      f.owner.registry.assignment(of: f.documentID)?.windowID, target.sessionMetadata.id)
    await f.cleanup()
  }

  func testDrainFailureRetainsItsPauseUntilExactRecoveryCleanup() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let otherPause = try f.owner.testAcquirePause()
    try await f.owner.testDrainPause(otherPause)
    newWindowDrainHook = { throw NativeNewWindowPreparationError.changed }
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Drain failure must retain the exact operation")
    }
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertTrue(f.owner.canRetryRecovery)
    XCTAssertEqual(f.observations.configurations, constructions)
    newWindowDrainHook = nil
    try await f.owner.retryRecovery()
    XCTAssertFalse(f.owner.testPreparationPending)
    try f.owner.testReleasePause(otherPause)
    await f.cleanup()
  }

  func testWaiterAwaitsHeldCleanupBeforeReportingCancelled() async throws {
    try await assertWaiterAwaitingCleanup(changedRegistration: false)
  }

  func testWaiterAwaitsHeldCleanupBeforeReportingRetainedFailure() async throws {
    try await assertWaiterAwaitingCleanup(changedRegistration: true)
  }

  private func assertWaiterAwaitingCleanup(changedRegistration: Bool) async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared(let destination) = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Expected prepared destination")
    }
    var release: CheckedContinuation<Void, Never>?
    newWindowCleanupHook = { await withCheckedContinuation { release = $0 } }
    let cancel = Task { try await f.owner.cancelNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(release)
    var waiterStarted = false
    var waiterFinished = false
    let waiter = Task {
      waiterStarted = true
      let result = try await f.owner.waitForNewWindowPreparation(id)
      waiterFinished = true
      return result
    }
    for _ in 0..<10000 {
      if waiterStarted { break }
      await Task.yield()
    }
    XCTAssertTrue(waiterStarted)
    // The waiter has an already-completed preparation to observe, while actual cleanup is held.
    for _ in 0..<1000 { await Task.yield() }
    XCTAssertFalse(waiterFinished, "Cancellation intent is not a settled cleanup receipt")
    XCTAssertTrue(f.owner.testCleanupRunning)
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertNotNil(f.owner.registry.window(id: destination.windowID))
    if changedRegistration {
      let unrelated = UUID()
      try f.owner.registry.registerWindow(id: unrelated, initialGroupID: UUID())
      try f.owner.registry.unregisterEmptyWindow(
        unrelated, expectedRevision: f.owner.registry.workspaceRevision)
    }
    newWindowCleanupHook = nil
    held.resume()
    do {
      try await cancel.value
      XCTAssertFalse(changedRegistration, "Changed registration must refuse cleanup")
    } catch {
      XCTAssertTrue(
        changedRegistration, "Unchanged cleanup should settle: \(String(reflecting: error))")
    }
    let result = try await waiter.value
    if changedRegistration {
      if case .retained(let error) = result,
        case .cleanupChanged? = error as? NativeNewWindowPreparationError
      {
      } else {
        XCTFail("Waiter must report actual retained cleanup failure")
      }
      XCTAssertTrue(f.owner.testPreparationPending)
      XCTAssertTrue(f.owner.canRetryRecovery)
      XCTAssertNotNil(f.owner.registry.window(id: destination.windowID))
      do {
        _ = try await f.owner.prepareQuit()
        XCTFail("Retained cleanup must veto quit")
      } catch {}
      // Intentionally retained synthetic state remains paused until this isolated process exits.
      try? FileManager.default.removeItem(at: f.directory)
    } else {
      if case .cancelled = result {} else { XCTFail("Settled cleanup must report cancelled") }
      XCTAssertFalse(f.owner.testPreparationPending)
      XCTAssertNil(f.owner.registry.window(id: destination.windowID))
      await f.cleanup()
    }
  }
}
