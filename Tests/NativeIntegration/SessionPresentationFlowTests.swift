import Foundation
import XCTest

@testable import PadCore
@testable import SessionPresentationFlow

@MainActor final class SessionPresentationFlowTests: XCTestCase {
  func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func metadata(path: String? = nil) -> SessionTab {
    SessionTab(
      originalPath: path, bookmarks: [0, 2, 5],
      presentation: SessionPresentation(
        axis: .stacked,
        panes: [
          SessionPaneState(
            selection: NSRange(location: 2, length: 0),
            scrollOrigin: SessionScrollOrigin(x: 0, y: 120)),
          SessionPaneState(
            selection: NSRange(location: 90, length: 4),
            scrollOrigin: SessionScrollOrigin(x: 8, y: 240)),
        ], focusedPaneIndex: 0))
  }

  func assertResolved(
    _ state: RestoredPresentationState?, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let state = try XCTUnwrap(state, file: file, line: line)
    // A + surrogate pair + CRLF + B: six UTF-16 units; bookmarks 0 and 5 are line starts.
    XCTAssertEqual(state.presentation.axis, .stacked, file: file, line: line)
    XCTAssertEqual(state.presentation.focusedPaneIndex, 0, file: file, line: line)
    XCTAssertEqual(
      state.presentation.panes.map(\.selection),
      [NSRange(location: 1, length: 0), NSRange(location: 6, length: 0)],
      file: file, line: line)
    XCTAssertEqual(
      state.presentation.panes.map(\.scrollOrigin),
      [SessionScrollOrigin(x: 0, y: 120), SessionScrollOrigin(x: 8, y: 240)],
      file: file, line: line)
    XCTAssertEqual(state.adjustedPaneIndices, [0, 1], file: file, line: line)
    XCTAssertEqual(state.bookmarks.offsets, [0, 5], file: file, line: line)
    XCTAssertEqual(state.invalidBookmarks, [2], file: file, line: line)
  }

  func testActualFileReadResolvesBothPanesAgainstCurrentBytes() async throws {
    let file = try directory().appendingPathComponent("synthetic.txt")
    let bytes = Data("A🐱\r\nB".utf8)
    try bytes.write(to: file)
    let tab = metadata(path: file.path)
    let result = try await Task.detached { try SessionCoordinator.read(tab, at: file) }.value
    try assertResolved(result.resolvedPresentation)
    XCTAssertEqual(result.originalBytes, bytes)
    XCTAssertEqual(result.url, file)
    XCTAssertEqual(result.resolvedViewState?.selection, NSRange(location: 1, length: 0))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testRecoveryStartupAndRetryRetainSplitButNeverAdoptHistoricalPath() async throws {
    let tab = metadata(path: "/synthetic/never-read.txt")
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let snapshot = RecoverySnapshot(
      id: tab.id, text: "A🐱\r\nB", encoding: .utf8, hasBOM: false,
      originalPath: tab.originalPath)
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [snapshot], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Reading must not publish") },
      readFile: { _, _ in throw FileStoreError.injectedFailure })
    var prepared: PreparedSessionTab?
    await coordinator.restore {
      prepared = $0.tabs.first
      return [tab.id: "Synthetic closed import target"]
    }
    try assertResolved(prepared?.resolvedPresentation)
    XCTAssertNil(prepared?.url)
    XCTAssertNil(prepared?.originalBytes)
    XCTAssertEqual(prepared?.decoded.text, "A🐱\r\nB")
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    XCTAssertEqual(entry.metadata.presentation, tab.presentation)
    let retry = try await coordinator.retry(entry)
    try assertResolved(retry.resolvedPresentation)
    XCTAssertNil(retry.url)
    XCTAssertNil(retry.originalBytes)
    XCTAssertEqual(retry.decoded.text, "A🐱\r\nB")
  }

  func testFileStartupCarriesBothPanesIntoPreparedWindow() async throws {
    let file = try directory().appendingPathComponent("startup.txt")
    try Data("A🐱\r\nB".utf8).write(to: file)
    let tab = metadata(path: file.path)
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Reading must not publish") })
    var prepared: PreparedSessionTab?
    await coordinator.restore {
      prepared = $0.tabs.first
      return [:]
    }
    try assertResolved(prepared?.resolvedPresentation)
    XCTAssertTrue(coordinator.unresolved.isEmpty)
    XCTAssertEqual(coordinator.warnings.count, 1)
  }

  func testAdjustmentInUnfocusedPaneStillReportsWarning() async throws {
    let original = metadata()
    let tab = SessionTab(
      presentation: SessionPresentation(
        axis: .stacked,
        panes: [
          SessionPaneState(
            selection: NSRange(location: 0, length: 0),
            scrollOrigin: SessionScrollOrigin(x: 0, y: 0)),
          original.presentation.panes[1],
        ], focusedPaneIndex: 0))
    let snapshot = RecoverySnapshot(
      id: tab.id, text: "A🐱\r\nB", encoding: .utf8, hasBOM: false, originalPath: nil)
    let coordinator = SessionCoordinator(
      loadSession: {
        EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)])
      },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [snapshot], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Reading must not publish") })
    var prepared: PreparedSessionTab?
    await coordinator.restore {
      prepared = $0.tabs.first
      return [:]
    }
    XCTAssertEqual(prepared?.resolvedPresentation?.adjustedPaneIndices, [1])
    XCTAssertEqual(prepared?.viewState.selectionAdjusted, false)
    XCTAssertEqual(
      coordinator.warnings.count, 1,
      "Warning must include adjustments in the pane which does not currently own focus")
  }

  func testUnresolvedCapturePreservesBothPaneRecordsThenLocateResolvesNewContent() async throws {
    let base = try directory()
    let tab = metadata(path: base.appendingPathComponent("missing.txt").path)
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let store = SessionStore(directory: base.appendingPathComponent("Session"))
    try store.save(EditorSession(windows: [window]))
    let coordinator = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { try store.save($0) })
    await coordinator.restore { _ in
      XCTFail("Missing file must remain unresolved")
      return [:]
    }
    let captured = try coordinator.captureSession(windows: [])
    XCTAssertEqual(captured.windows, [window])
    try await coordinator.persist(windows: [])
    XCTAssertEqual(try store.load()?.windows, [window])
    let replacement = base.appendingPathComponent("located.txt")
    try Data("A🐱\r\nB".utf8).write(to: replacement)
    let entry = try XCTUnwrap(coordinator.unresolved.first)
    let located = try await coordinator.locate(entry, url: replacement)
    try assertResolved(located.resolvedPresentation)
    XCTAssertEqual(located.url, replacement)
    XCTAssertEqual(
      coordinator.unresolved.first?.metadata, tab,
      "A successful read alone cannot remove unresolved metadata")
  }

  func testCanceledStartupCannotImportLateSplitReadOrPublishTrimmedSession() async throws {
    let file = try directory().appendingPathComponent("late.txt")
    try Data("A🐱\r\nB".utf8).write(to: file)
    let tab = metadata(path: file.path)
    var resume: CheckedContinuation<Void, Never>?
    let coordinator = SessionCoordinator(
      loadSession: {
        EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)])
      },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Canceled startup must not publish") },
      readFile: { metadata, url in
        await withCheckedContinuation { resume = $0 }
        return try await Task.detached { try SessionCoordinator.read(metadata, at: url) }.value
      })
    var imported = false
    let task = Task {
      await coordinator.restore { _ in
        imported = true
        return [:]
      }
    }
    while resume == nil { await Task.yield() }
    coordinator.cancelRestoration()
    resume?.resume()
    await task.value
    XCTAssertFalse(imported)
    XCTAssertFalse(coordinator.restorationComplete)
    XCTAssertThrowsError(try coordinator.captureSession(windows: []))
    XCTAssertEqual(try Data(contentsOf: file), Data("A🐱\r\nB".utf8))
  }

  func testLegacySingleRangeReaderCannotSilentlyDropSavedSecondPane() async throws {
    let tab = metadata(path: "/synthetic/legacy-adapter.txt")
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Reading must not publish") },
      readFile: { metadata, url in
        let text = "A🐱\r\nB"
        return SessionResolvedFile(
          url: url, originalBytes: Data(text.utf8),
          decoded: DecodedDocument(text: text, encoding: .utf8, hasBOM: false),
          resolvedViewState: try RestoredViewState.resolve(
            selection: metadata.selection, bookmarks: metadata.bookmarks, in: text))
      })
    var imported = false
    await coordinator.restore { _ in
      imported = true
      return [:]
    }
    XCTAssertFalse(imported, "Two saved ranges require a validated two-pane payload")
    XCTAssertEqual(coordinator.unresolved.first?.metadata, tab)
    XCTAssertEqual(try coordinator.captureSession(windows: []).windows, [window])
  }

  func testLegacyReaderCannotSilentlyDropSinglePaneScrollPosition() async throws {
    let tab = SessionTab(
      originalPath: "/synthetic/legacy-scroll.txt",
      presentation: SessionPresentation(
        axis: .sideBySide,
        panes: [
          SessionPaneState(
            selection: NSRange(location: 0, length: 0),
            scrollOrigin: SessionScrollOrigin(x: 0, y: 240))
        ], focusedPaneIndex: 0))
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    let coordinator = SessionCoordinator(
      loadSession: { EditorSession(windows: [window]) },
      claimRecovery: { RecoveryCoordinator.Startup(snapshots: [], quarantinedCount: 0) },
      saveSession: { _ in XCTFail("Reading must not publish") },
      readFile: { metadata, url in
        let text = "line\n"
        return SessionResolvedFile(
          url: url, originalBytes: Data(text.utf8),
          decoded: DecodedDocument(text: text, encoding: .utf8, hasBOM: false),
          resolvedViewState: try RestoredViewState.resolve(
            selection: metadata.selection, bookmarks: metadata.bookmarks, in: text))
      })
    var imported = false
    await coordinator.restore { _ in
      imported = true
      return [:]
    }
    XCTAssertFalse(imported, "A legacy range-only adapter cannot supply saved scroll position")
    XCTAssertEqual(coordinator.unresolved.first?.metadata, tab)
    XCTAssertEqual(try coordinator.captureSession(windows: []).windows, [window])
  }

  func testCheckpointFailurePreservesV1ThenRetryPublishesRecoveryAndSplitTogether() async throws {
    let base = try directory()
    let store = SessionStore(directory: base.appendingPathComponent("Session"))
    try store.save(EditorSession(windows: []))
    let file = store.directory.appendingPathComponent("Session.json")
    let legacy = Data("{\"version\":1,\"windows\":[]}".utf8)
    try legacy.write(to: file)
    let recoveryDirectory = base.appendingPathComponent("Recovery")
    let firstWrite = FirstCheckpointWrite()
    let owner = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { session in
        let saved = try RecoveryStore(directory: recoveryDirectory).loadAll()
        guard saved.count == 1, saved[0].text == "A🐱\r\nB",
          saved[0].id == session.windows.first?.tabs.first?.id
        else {
          throw FileStoreError.injectedFailure
        }
        try store.save(session, fault: firstWrite.consume() ? .beforeReplace : nil)
      })
    let tab = metadata()
    let session = EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)])
    let snapshot = RecoverySnapshot(
      id: tab.id, text: "A🐱\r\nB", encoding: .utf8, hasBOM: false)
    func capture(_ generation: UInt64) -> SessionCheckpointCapture {
      SessionCheckpointCapture(
        generation: generation, liveTabIDs: [tab.id],
        recovery: [RecoveryCheckpointItem(id: tab.id, revision: generation, snapshot: snapshot)],
        session: session)
    }
    do {
      _ = try await owner.commitSessionCheckpoint(capture(1))
      XCTFail("An unpublished session cannot receive a successful checkpoint receipt")
    } catch SessionStoreError.ioFailure {}
    XCTAssertEqual(try Data(contentsOf: file), legacy)
    XCTAssertEqual(try RecoveryStore(directory: recoveryDirectory).loadAll(), [snapshot])
    let receipt = try await owner.commitSessionCheckpoint(capture(2))
    XCTAssertEqual(receipt.generation, 2)
    XCTAssertEqual(receipt.recoveryRevisions, [tab.id: 2])
    XCTAssertEqual(try store.load(), session)
    XCTAssertEqual(try RecoveryStore(directory: recoveryDirectory).loadAll(), [snapshot])
    let wire = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    XCTAssertEqual(wire["version"] as? Int, 2)
  }
}

private final class FirstCheckpointWrite: @unchecked Sendable {
  private let lock = NSLock()
  private var first = true
  func consume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = first
    first = false
    return value
  }
}
