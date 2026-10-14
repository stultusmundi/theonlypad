import AppKit
import PadCore
import XCTest

@testable import NativeRouting

// FOLDER-CONTROLLER-ACCESS-BEGIN
extension EditorWindowController {
  var folderTestCurrent: EditorDocument? { current }
  func folderTestDocument(_ text: String, url: URL? = nil) -> EditorDocument {
    newDocument()
    let document = current!
    document.storage.mutableString.setString(text)
    document.url = url
    return document
  }
  func folderTestPanel() -> FolderSearchController? {
    execute("edit.findFolder")
    return folderSearch
  }
  func folderTestDisplay(_ document: EditorDocument) { display(document) }
  func folderTestCleanup() {
    onOpenedURL = nil
    folderSearch?.close()
    folderSearch = nil
    window?.orderOut(nil)
  }
  func folderTestOpenedModel(_ target: EditorOpenedDocument) -> EditorDocument { target.document }
}
// FOLDER-CONTROLLER-ACCESS-END

// FOLDER-PANEL-ACCESS-BEGIN
extension FolderSearchController {
  func folderTestStop() { stop() }
  func folderTestCloseGeneration() {
    windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
  }
  func folderTestOpen(_ url: URL, range: NSRange, snapshot: String) {
    onOpen(
      FolderSearchNavigationRequest(
        url: url, range: range, snapshot: snapshot, owner: self, generation: generation))
  }
}
// FOLDER-PANEL-ACCESS-END

@MainActor final class FolderNavigationTests: XCTestCase {
  func testCancelRootChangeCloseAndPanelReplacementRevokeNavigation() throws {
    for action in 0..<4 {
      try checkRefusal(expectError: false) { controller, panel, _ in
        switch action {
        case 0: panel.folderTestStop()
        case 1: panel.setRoot(FileManager.default.temporaryDirectory)
        case 2: panel.folderTestCloseGeneration()
        default: _ = controller.folderTestPanel()
        }
      }
    }
  }

  func testOwnershipOperationAndEditRestoreChangesRefuseCapturedTarget() throws {
    for action in 0..<3 {
      try checkRefusal(expectError: true) { _, _, document in
        switch action {
        case 0: _ = document.rotateTransferOwnership()
        case 1: _ = document.beginFileOperation()
        default:
          let text = document.storage.string
          document.storage.mutableString.setString("changed")
          document.storage.mutableString.setString(text)
        }
      }
    }
  }

  func testSupplementaryAndCombiningScalarRanges() throws {
    for (text, range) in [
      ("a😀b", NSRange(location: 1, length: 2)),
      ("ae\u{301}z", NSRange(location: 2, length: 1)),
    ] {
      // AppKit expands a selection inside a composed grapheme; preserve that native policy.
      let control = NSTextView()
      control.string = text
      control.setSelectedRange(range)
      let expected = text == "ae\u{301}z" ? NSRange(location: 1, length: 2) : range
      XCTAssertEqual(control.selectedRange(), expected)
      try checkNavigation(
        changeFocusInRecentCallback: true, text: text, range: range,
        expectedSelection: expected)
    }
  }

  func testSurrogateSplitRefusesWithoutSelection() throws {
    try checkRefusal(expectError: true, text: "a😀b", range: NSRange(location: 2, length: 1)) {
      _, _, _ in
    }
  }

  func testNewOpenReportsExactModelAfterLegacyCallbackChangesFocus() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("loaded 😀".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected error: \($0)") }, onSessionChange: {})
    defer { controller.folderTestCleanup() }
    let other = controller.folderTestDocument("other")
    let done = expectation(description: "typed open completion")
    var order: [String] = []
    controller.onOpenedURL = { _ in order.append("recent") }
    controller.open(
      url,
      onFailure: {
        XCTFail("Open failed: \($0)")
        done.fulfill()
      },
      onOpened: {
        order.append("legacy")
        controller.folderTestDisplay(other)
      },
      onOpenedDocument: { target in
        order.append("typed")
        let document = controller.folderTestOpenedModel(target)
        XCTAssertFalse(document === other)
        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.storage.string, "loaded 😀")
        done.fulfill()
      })
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(order, ["recent", "legacy", "typed"])
  }

  func testFailedOpenNeverPublishesTypedOrLegacySuccess() async throws {
    _ = NSApplication.shared
    let controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected error: \($0)") }, onSessionChange: {})
    defer { controller.folderTestCleanup() }
    let done = expectation(description: "failed open")
    var successes = 0
    controller.open(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      onFailure: { _ in done.fulfill() }, onOpened: { successes += 1 },
      onOpenedDocument: { _ in successes += 1 })
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(successes, 0)
  }

  func testByteViewerCannotReportTypedTextOpen() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: 100_000_001)
    try file.close()
    let done = expectation(description: "text positioning refused for byte viewer")
    var errors = 0
    let controller = EditorWindowController(
      restoreStartup: false,
      onError: { _ in
        errors += 1
        done.fulfill()
      }, onSessionChange: {})
    defer { controller.folderTestCleanup() }
    var viewers = 0
    var typed = 0
    controller.onOpenLargeFile = { opened in
      XCTAssertEqual(opened, url)
      viewers += 1
    }
    controller.open(url, onOpenedDocument: { _ in typed += 1 })
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(viewers, 1)
    XCTAssertEqual(errors, 1)
    XCTAssertEqual(typed, 0)
  }

  private func checkRefusal(
    expectError: Bool, text: String = "alpha needle omega",
    range: NSRange = NSRange(location: 6, length: 6),
    change: (EditorWindowController, FolderSearchController, EditorDocument) -> Void
  ) throws {
    _ = NSApplication.shared
    var errors: [Error] = []
    let controller = EditorWindowController(
      restoreStartup: false, onError: { errors.append($0) }, onSessionChange: {})
    defer { controller.folderTestCleanup() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let document = controller.folderTestDocument(text, url: url)
    let pane = document.panePool[0]
    pane.editor.setSelectedRange(NSRange(location: 0, length: 0))
    let panel = try XCTUnwrap(controller.folderTestPanel())
    var selectionAfterCallback = pane.editor.selectedRange()
    // The callback is synchronous; retaining the test closure ends with this helper.
    withoutActuallyEscaping(change) { change in
      controller.onOpenedURL = { _ in
        change(controller, panel, document)
        selectionAfterCallback = pane.editor.selectedRange()
      }
      panel.folderTestOpen(url, range: range, snapshot: text)
      controller.onOpenedURL = nil
    }
    // The deliberate edit may itself move the caret. Result navigation must add no selection.
    XCTAssertEqual(pane.editor.selectedRange(), selectionAfterCallback)
    XCTAssertEqual(errors.count, expectError ? 1 : 0)
  }
  func testRecentFileCallbackCannotRedirectResultIntoSameTextDocument() throws {
    try checkNavigation(changeFocusInRecentCallback: true)
  }

  func testValidResultNavigatesToItsOpenedDocument() throws {
    try checkNavigation(changeFocusInRecentCallback: false)
  }

  func testEncodingOpenNeverReloadsAnotherDocumentAfterAdmissionChangesFocus() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected error: \($0)") },
      onSessionChange: {})
    defer { controller.folderTestCleanup() }
    let firstURL = directory.appendingPathComponent("first.txt")
    let otherURL = directory.appendingPathComponent("other.txt")
    try Data("first disk".utf8).write(to: firstURL)
    try Data("other disk".utf8).write(to: otherURL)
    let first = controller.folderTestDocument("first saved", url: firstURL)
    let other = controller.folderTestDocument("other saved", url: otherURL)
    for document in [first, other] {
      document.savedText = document.storage.string
      document.originalBytes = Data(document.savedText.utf8)
    }
    XCTAssertFalse(first.dirty)
    XCTAssertFalse(other.dirty)
    let done = expectation(description: "one actual open outcome")
    var admissions = 0
    var outcomes = 0
    controller.open(
      firstURL, encoding: .utf8,
      shouldAccept: {
        admissions += 1
        if admissions == 2 { controller.folderTestDisplay(other) }
        return true
      },
      onFailure: { _ in
        outcomes += 1
        done.fulfill()
      },
      onOpenedDocument: { _ in
        outcomes += 1
        done.fulfill()
      })
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(outcomes, 1)
    XCTAssertGreaterThanOrEqual(admissions, 2)
    XCTAssertEqual(other.storage.string, "other saved")
    XCTAssertEqual(other.originalBytes, Data("other saved".utf8))
  }

  private func checkNavigation(
    changeFocusInRecentCallback: Bool, text: String = "alpha needle omega",
    range: NSRange = NSRange(location: 6, length: 6), expectedSelection: NSRange? = nil
  ) throws {
    _ = NSApplication.shared
    let controller = EditorWindowController(
      restoreStartup: false, onError: { XCTFail("Unexpected error: \($0)") },
      onSessionChange: {})
    defer { controller.folderTestCleanup() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = controller.folderTestDocument(text, url: url)
    let other = controller.folderTestDocument(text)
    let targetPane = target.panePool[0]
    let otherPane = other.panePool[0]
    let initial = NSRange(location: 0, length: 0)
    targetPane.editor.setSelectedRange(initial)
    otherPane.editor.setSelectedRange(initial)
    let panel = try XCTUnwrap(controller.folderTestPanel())
    var recentCallbacks = 0
    controller.onOpenedURL = { opened in
      XCTAssertEqual(opened, url)
      recentCallbacks += 1
      if changeFocusInRecentCallback { controller.folderTestDisplay(other) }
    }
    panel.folderTestOpen(url, range: range, snapshot: text)
    XCTAssertEqual(recentCallbacks, 1)
    XCTAssertEqual(targetPane.editor.selectedRange(), expectedSelection ?? range)
    XCTAssertEqual(otherPane.editor.selectedRange(), initial)
    XCTAssertTrue(controller.folderTestCurrent === target)
  }
}
