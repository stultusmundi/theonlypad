import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class NativeApplicationDocumentsTests: XCTestCase {
  func testEmptyStartupCreatesOneActualManagedScratchWindow() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sessionStore = SessionStore(directory: directory.appendingPathComponent("session"))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try sessionStore.save($0) },
      readCheckpointSession: { try sessionStore.load() })
    let session = SessionCoordinator(
      loadSession: { try sessionStore.load() },
      claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    let windows = try owner.registry.captureReadyWindows()
    XCTAssertEqual(windows.count, 1)
    XCTAssertEqual(owner.windows.count, 1)
    let id = try XCTUnwrap(windows.first?.groups.first?.documentIDs.first)
    let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
    XCTAssertEqual(model.storage.length, 0)
    XCTAssertNil(model.url)
    XCTAssertNotNil(model.recoveryAuthority)
    XCTAssertEqual(owner.windows.first?.sessionMetadata.selectedTabID, id)
    XCTAssertTrue(session.restorationComplete)
    XCTAssertTrue(session.unresolved.isEmpty)
    XCTAssertEqual(owner.windows.first?.focusedPane?.editor.isEditable, true)
    _ = try await owner.prepareQuit()
    let persisted = try XCTUnwrap(sessionStore.load())
    XCTAssertEqual(persisted.windows.first?.tabs.first?.id, id)
  }
  func testRestoresFilesInOrderAndSelectedPinThroughFinalCheckpoint() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.swift")
    try Data("first 👩🏽‍💻\r\n".utf8).write(to: first)
    try Data("let second = 2\n".utf8).write(to: second)
    let tabs = [
      SessionTab(originalPath: first.path, pinned: true), SessionTab(originalPath: second.path),
    ]
    let original = SessionWindow(tabs: tabs, selectedTabID: tabs[0].id)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    try store.save(.init(windows: [original]))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    XCTAssertTrue(session.unresolved.isEmpty)
    XCTAssertEqual(owner.windows.first?.sessionMetadata.tabs.map(\.id), tabs.map(\.id))
    XCTAssertEqual(owner.windows.first?.sessionMetadata.selectedTabID, tabs[0].id)
    XCTAssertEqual(owner.registry.metadata(id: tabs[0].id)?.pinned, true)
    let model = try XCTUnwrap(owner.registry.handle(id: tabs[0].id) as? EditorDocument)
    XCTAssertEqual(model.storage.string, "first 👩🏽‍💻\r\n")
    XCTAssertFalse(model.dirty)
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.first?.tabs.map(\.id), tabs.map(\.id))
  }

  func testRetryDuringHeldStartupCannotCreateCompetingScratch() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    var release: CheckedContinuation<EditorSession?, Never>?
    let session = SessionCoordinator(
      loadSession: {
        await withCheckedContinuation { release = $0 }
      }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    let start = Task { try await owner.start() }
    for _ in 0..<1000 where release == nil { await Task.yield() }
    XCTAssertNotNil(release)
    do {
      try await owner.retryStartup()
      XCTFail("Concurrent startup retry accepted")
    } catch { XCTAssertEqual(error as? DocumentIntakeError, .busy) }
    XCTAssertTrue(owner.windows.isEmpty)
    release?.resume(returning: nil)
    try await start.value
    XCTAssertEqual(owner.windows.count, 1)
    _ = try await owner.prepareQuit()
  }

  func testNativeCloseAndReopenCommandsUseOneOwnerAndFreshRecoveryAuthority() async throws {
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
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    let controller = try XCTUnwrap(owner.windows.first)
    let originalID = try XCTUnwrap(controller.selectedDocumentID)
    let source = try XCTUnwrap(owner.registry.handle(id: originalID) as? EditorDocument)
    let sourceAuthority = source.recoveryAuthority
    controller.execute("file.close")
    for _ in 0..<500 where controller.selectedDocumentID != nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(owner.registry.handle(id: originalID))
    XCTAssertEqual(owner.registry.closedHistoryCount(windowID: controller.sessionMetadata.id), 1)
    controller.execute("file.reopenClosed")
    for _ in 0..<500 where controller.selectedDocumentID == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let reopenedID = try XCTUnwrap(controller.selectedDocumentID)
    XCTAssertNotEqual(reopenedID, originalID)
    let reopened = try XCTUnwrap(owner.registry.handle(id: reopenedID) as? EditorDocument)
    XCTAssertFalse(reopened === source)
    XCTAssertNotEqual(reopened.recoveryAuthority, sourceAuthority)
    XCTAssertEqual(owner.registry.closedHistoryCount(windowID: controller.sessionMetadata.id), 0)
    XCTAssertEqual(controller.focusedPane?.editor.isEditable, true)
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.first?.tabs.map(\.id), [reopenedID])
  }

  func testUnresolvedFileRetryUsesManagedClaimAndNewWindowUsesSamePublisher() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("later.txt")
    let tab = SessionTab(originalPath: missing.path)
    let saved = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    try store.save(.init(windows: [saved]))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    try await owner.start()
    let entry = try XCTUnwrap(session.unresolved.first)
    XCTAssertEqual(entry.metadata.id, tab.id)
    try Data("available now\n".utf8).write(to: missing)
    let prepared = try await session.retry(entry)
    try await owner.acceptSession(entry, file: prepared)
    XCTAssertTrue(session.unresolved.isEmpty)
    XCTAssertEqual(owner.registry.assignment(of: tab.id)?.windowID, saved.id)
    XCTAssertEqual(
      (owner.registry.handle(id: tab.id) as? EditorDocument)?.storage.string, "available now\n")
    let newWindow = try owner.createWindow()
    for _ in 0..<500 where newWindow.selectedDocumentID == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(newWindow.selectedDocumentID)
    _ = try await owner.prepareQuit()
    let persisted = try XCTUnwrap(store.load())
    XCTAssertEqual(persisted.windows.count, 3)
    XCTAssertEqual(Set(persisted.windows.flatMap { $0.tabs.map(\.id) }).count, 3)
  }

  func testExternalFIFOQueuesBeforeStartupAndPositionsEachExactDocument() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("queued-first.txt")
    let second = directory.appendingPathComponent("queued-second.txt")
    try Data("a\nβc\n".utf8).write(to: first)
    try Data("first\nlast\n".utf8).write(to: second)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { XCTFail("Unexpected \($0)") })
    let admission = owner.enqueueExternal([
      .init(url: first, line: 2, column: 2), .init(url: second, line: 2, column: 3),
    ])
    XCTAssertEqual(admission.acceptedCount, 2)
    XCTAssertTrue(owner.windows.isEmpty)
    try await owner.start()
    for _ in 0..<500 where owner.pendingExternalOpenCount > 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(owner.pendingExternalOpenCount, 0)
    let windows = try owner.registry.captureReadyWindows()
    XCTAssertEqual(windows.count, 1)
    let ids = windows[0].groups[0].documentIDs
    XCTAssertEqual(ids.count, 3)
    let firstModel = try XCTUnwrap(owner.registry.handle(id: ids[1]) as? EditorDocument)
    let secondModel = try XCTUnwrap(owner.registry.handle(id: ids[2]) as? EditorDocument)
    XCTAssertEqual(firstModel.url, first)
    XCTAssertEqual(secondModel.url, second)
    XCTAssertEqual(
      firstModel.panePool.first?.editor.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertEqual(
      secondModel.panePool.first?.editor.selectedRange(), NSRange(location: 8, length: 0))
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.first?.tabs.map(\.id), ids)
  }

  func testWindowCapacityIncludesUnresolvedReservationsBeforeCreatingEndpoint() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let saved = (0..<32).map { index -> SessionWindow in
      let tab = SessionTab(
        originalPath: directory.appendingPathComponent("missing-\(index).txt").path)
      return SessionWindow(tabs: [tab], selectedTabID: tab.id)
    }
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    try store.save(.init(windows: saved))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    var errors: [Error] = []
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { errors.append($0) })
    try await owner.start()
    XCTAssertTrue(errors.isEmpty)
    XCTAssertEqual(session.unresolved.count, 32)
    let originalIDs = Set(saved.map(\.id))
    XCTAssertEqual(owner.windows.count, 1)
    XCTAssertTrue(originalIDs.contains(try XCTUnwrap(owner.windows.first?.sessionMetadata.id)))
    do {
      _ = try owner.createWindow(createDocument: false)
      XCTFail("Created an over-capacity endpoint")
    } catch {
      guard case SessionStoreError.limit = error else {
        return XCTFail("Unexpected capacity error: \(error)")
      }
    }
    XCTAssertEqual(owner.windows.count, 1)
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.count, 32)
  }

  func testFullUnresolvedDocumentBudgetDoesNotAllocateAnotherScratch() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tabs = (0..<128).map {
      SessionTab(originalPath: directory.appendingPathComponent("missing-\($0).txt").path)
    }
    let saved = SessionWindow(tabs: tabs, selectedTabID: tabs[0].id)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    try store.save(.init(windows: [saved]))
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    var errors: [Error] = []
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in },
      onError: { errors.append($0) })
    try await owner.start()
    XCTAssertEqual(errors.count, 1)
    guard case SessionStoreError.limit = try XCTUnwrap(errors.first) else {
      return XCTFail("Expected capacity notice")
    }
    XCTAssertTrue(owner.windows.isEmpty)
    XCTAssertEqual(session.unresolved.count, 128)
    do {
      _ = try owner.createWindow()
      XCTFail("Allocated extra scratch")
    } catch {
      guard case SessionStoreError.limit = error else { return XCTFail("Unexpected error") }
    }
    XCTAssertTrue(owner.windows.isEmpty)
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows, [saved])
  }

  func testCheckpointRetryRecreatesLostEndpointWithoutReplacingDirtyModel() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recoveryDirectory = directory.appendingPathComponent("recovery")
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery,
      monitoring: ApplicationFileMonitoring(), onWindowCreated: { _ in }, onError: { _ in })
    try await owner.start()
    let controller = try XCTUnwrap(owner.windows.first)
    let id = try XCTUnwrap(controller.selectedDocumentID)
    let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
    let authority = model.recoveryAuthority
    controller.focusedPane!.editor.insertText(
      "retained endpoint 👩🏽‍💻\n", replacementRange: NSRange(location: 0, length: 0))
    controller.close()
    XCTAssertTrue(owner.windows.isEmpty)
    XCTAssertTrue(owner.registry.handle(id: id) === model)
    owner.requestCheckpoint()
    for _ in 0..<500 where owner.lastCheckpointError == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(owner.lastCheckpointError)
    try await owner.retryRecovery()
    XCTAssertEqual(owner.windows.count, 1)
    XCTAssertTrue(owner.registry.handle(id: id) === model)
    XCTAssertEqual(model.recoveryAuthority, authority)
    XCTAssertEqual(owner.windows.first?.focusedPane?.editor.string, "retained endpoint 👩🏽‍💻\n")
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try store.load()?.windows.first?.tabs.first?.id, id)
    XCTAssertEqual(
      try RecoveryStore(directory: recoveryDirectory).loadAll().first { $0.id == id }?.text,
      model.storage.string)
  }

}
