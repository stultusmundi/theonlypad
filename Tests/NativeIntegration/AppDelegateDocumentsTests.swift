import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class AppDelegateDocumentsTests: XCTestCase {
  func testStartupUsesOneOwnerAndActualManagedScratch() async throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.delegate.startDocumentsForTesting()
    let owner = try XCTUnwrap(f.delegate.documentsOwnerForTesting)
    XCTAssertEqual(f.delegate.documentWindowsForTesting.count, 1)
    XCTAssertEqual(f.decorated, 1)
    let window = try XCTUnwrap(f.delegate.documentWindowsForTesting.first)
    let id = try XCTUnwrap(window.selectedDocumentID)
    let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
    XCTAssertNotNil(model.recoveryAuthority)
    XCTAssertTrue(window.focusedPane?.document === model)
    XCTAssertTrue(f.errors.isEmpty)
    _ = try await owner.prepareQuit()
    XCTAssertEqual(try f.store.load()?.windows.first?.tabs.first?.id, id)
  }
  func testLaunchRequestsQueuedBeforeStartupUseActualFIFOAndPositions() async throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let first = f.directory.appendingPathComponent("first.txt")
    let second = f.directory.appendingPathComponent("second.txt")
    try Data("one\ntwo".utf8).write(to: first)
    try Data("ab\nxyz".utf8).write(to: second)
    f.delegate.enqueueDocumentsForTesting([
      .init(url: first, line: 2, column: 2), .init(url: second, line: 2, column: 3),
    ])
    let owner = try XCTUnwrap(f.delegate.documentsOwnerForTesting)
    XCTAssertEqual(owner.pendingExternalOpenCount, 2)
    try await f.delegate.startDocumentsForTesting()
    for _ in 0..<500 {
      if owner.pendingExternalOpenCount == 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(owner.pendingExternalOpenCount, 0)
    XCTAssertTrue(f.errors.isEmpty)
    _ = try await owner.prepareQuit()
    let tabs = try XCTUnwrap(f.store.load()).windows.flatMap(\.tabs).filter {
      $0.originalPath != nil
    }
    XCTAssertEqual(tabs.map(\.originalPath), [first.path, second.path])
    XCTAssertEqual(
      tabs.map(\.selection), [NSRange(location: 5, length: 0), NSRange(location: 5, length: 0)])
  }
  func testFinderAndLaunchRequestsShareBoundedPrestartupQueueAndQuitRefusal() throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    let url = f.directory.appendingPathComponent("synthetic.txt")
    f.delegate.enqueueDocumentsForTesting([.init(url: url)])
    f.delegate.application(NSApplication.shared, open: Array(repeating: url, count: 128))
    let owner = try XCTUnwrap(f.delegate.documentsOwnerForTesting)
    XCTAssertEqual(owner.pendingExternalOpenCount, 128)
    XCTAssertEqual(f.errors.count, 1)
    XCTAssertTrue(f.errors[0].localizedDescription.contains("1 file requests"))
    f.delegate.setDocumentQuitForTesting(true)
    f.delegate.application(NSApplication.shared, open: [url])
    XCTAssertEqual(owner.pendingExternalOpenCount, 128)
    XCTAssertEqual(f.errors.count, 2)
    XCTAssertTrue(f.errors[1].localizedDescription.contains("preparing to quit"))
  }

  func testSettingsAreAppliedAfterManagedStartupAndUnreadyToolsRefuse() async throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    XCTAssertNil(f.delegate.requireDocumentCommandForTesting())
    XCTAssertTrue(f.delegate.documentWindowsForTesting.isEmpty)
    XCTAssertEqual(f.errors.count, 1)
    f.errors.removeAll()
    var settings = EditorSettings.defaults
    settings.fontSize = 23
    f.delegate.setDocumentSettingsForTesting(settings)
    try await f.delegate.startDocumentsForTesting()
    let pane = try XCTUnwrap(f.delegate.documentWindowsForTesting.first?.focusedPane)
    XCTAssertEqual(pane.editor.font?.pointSize, 23)
    XCTAssertNotNil(f.delegate.requireDocumentCommandForTesting())
    XCTAssertTrue(f.errors.isEmpty)
    _ = try await XCTUnwrap(f.delegate.documentsOwnerForTesting).prepareQuit()
  }

  func testActualTerminationDelegateUsesOwnerFinalReceipt() async throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.delegate.startDocumentsForTesting()
    let expected = try XCTUnwrap(f.delegate.documentWindowsForTesting.first?.selectedDocumentID)
    XCTAssertEqual(f.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    for _ in 0..<500 {
      if !f.replies.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(f.replies, [true])
    XCTAssertTrue(f.errors.isEmpty)
    XCTAssertTrue(f.delegate.documentMonitoringSuspendedForTesting)
    XCTAssertEqual(try f.store.load()?.windows.first?.tabs.first?.id, expected)
  }

  func testFinalWriteFailureVetoesAndRestoresMonitoringThenCanRetry() async throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.delegate.startDocumentsForTesting()
    f.failWrites = true
    XCTAssertEqual(f.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    for _ in 0..<500 {
      if !f.replies.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(f.replies, [false])
    XCTAssertFalse(f.delegate.documentQuitForTesting)
    XCTAssertFalse(f.delegate.documentMonitoringSuspendedForTesting)
    XCTAssertFalse(f.errors.isEmpty)
    f.failWrites = false
    XCTAssertEqual(f.delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    for _ in 0..<500 {
      if f.replies.count == 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(f.replies, [false, true])
  }

  func testLargeViewerPositionRefusesBeforeAnyWindowPresentation() throws {
    let f = try AppDelegateDocumentFixture()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    XCTAssertThrowsError(
      try f.delegate.openLargeDocumentForTesting(
        .init(url: f.directory.appendingPathComponent("synthetic-large.txt"), line: 2))
    ) {
      XCTAssertTrue($0.localizedDescription.contains("not supported"))
    }
    XCTAssertEqual(f.decorated, 0)
  }

  func testResolvedImportCannotNotifyOrEraseNewerPanelAttempt() async throws {
    try await checkSupersededRepair(replacePanel: true)
  }
  func testResolvedImportCannotNotifyNewerRequestInSamePanel() async throws {
    try await checkSupersededRepair(replacePanel: false)
  }
  private func checkSupersededRepair(replacePanel: Bool) async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".txt")
    defer { try? FileManager.default.removeItem(at: missing) }
    let tab = SessionTab(
      id: UUID(), originalPath: missing.path,
      encoding: .utf8, selection: NSRange(location: 99, length: 0))
    let initial = EditorSession(windows: [.init(id: UUID(), tabs: [tab], selectedTabID: tab.id)])
    let f = try AppDelegateDocumentFixture(initialSession: initial)
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.delegate.startDocumentsForTesting()
    let entry = try XCTUnwrap(f.delegate.unresolvedForTesting.first)
    let oldPanel = f.delegate.makeSessionPanelForTesting()
    try Data("short".utf8).write(to: missing)
    let resolved = try await oldPanel.readForApplicationTesting(entry)
    XCTAssertTrue(try XCTUnwrap(resolved.resolvedViewState).selectionAdjusted)
    var newerPanel: SessionRestorationController?
    var newerAttempt: UUID?
    var newerTarget: EditorWindowController?
    f.onDecorate = { editor in
      if replacePanel {
        oldPanel.close()
        newerPanel = f.delegate.makeSessionPanelForTesting()
      } else {
        newerPanel = oldPanel
      }
      newerTarget = editor
      newerAttempt = f.delegate.setRepairAttemptForTesting(entry.metadata.id, target: editor)
    }
    try await oldPanel.acceptForApplicationTesting(entry, file: resolved)
    XCTAssertNotNil(newerPanel)
    XCTAssertEqual(f.adjusted, 0)
    XCTAssertEqual(f.delegate.repairAttemptForTesting(entry.metadata.id), newerAttempt)
    XCTAssertTrue(f.delegate.repairTargetForTesting(entry.metadata.id) === newerTarget)
    XCTAssertTrue(f.delegate.unresolvedForTesting.isEmpty)
    let owner = try XCTUnwrap(f.delegate.documentsOwnerForTesting)
    XCTAssertNotNil(owner.registry.handle(id: tab.id))
    newerPanel?.close()
    _ = try await owner.prepareQuit()
  }

}

@MainActor private final class AppDelegateDocumentFixture {
  let directory: URL
  let store: SessionStore
  var delegate: AppDelegate!
  var decorated = 0
  var adjusted = 0
  var onDecorate: ((EditorWindowController) -> Void)?
  var errors: [Error] = []
  var replies: [Bool] = []
  let writeFault = AppDelegateWriteFault()
  var failWrites: Bool {
    get { writeFault.fail }
    set { writeFault.fail = newValue }
  }
  init(initialSession: EditorSession? = nil) throws {
    _ = NSApplication.shared
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = SessionStore(directory: directory.appendingPathComponent("session"))
    if let initialSession { try store.save(initialSession) }
    let store = self.store
    let fault = writeFault
    let recovery = RecoveryCoordinator(
      directory: directory.appendingPathComponent("recovery"),
      saveCheckpointSession: {
        if fault.fail { throw NSError(domain: "SyntheticWriteFailure", code: 1) }
        try store.save($0)
      }, readCheckpointSession: { try store.load() })
    let session = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { try await recovery.claimStartup() })
    delegate = AppDelegate(
      session: session, recovery: recovery,
      presentEditorWindow: { [weak self] editor in
        self?.decorated += 1
        self?.onDecorate?(editor)
      },
      reportDocumentError: { [weak self] in self?.errors.append($0) },
      replyToTermination: { [weak self] in self?.replies.append($0) },
      presentSessionAdjustment: { [weak self] in self?.adjusted += 1 })
  }
}

private final class AppDelegateWriteFault: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var fail: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      value = newValue
    }
  }
}
