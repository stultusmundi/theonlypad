import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class DocumentMoveDestinationTests: XCTestCase {
  private func controls(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { controls($0) }
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
    var picked: [NativeDocumentMoveDestination] = []
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
    XCTAssertEqual(picked, [target])
    XCTAssertEqual(cancellations, 0)
    let cancelChooser = DocumentMoveDestinationController(
      choices: choices, onChoose: { picked.append($0) }, onCancel: { cancellations += 1 })
    let cancel = try XCTUnwrap(
      controls(cancelChooser.window?.contentView).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "document.move.cancel"
      })
    cancel.performClick(nil)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(picked, [target])
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
        $0.stringValue.contains("Open another window")
      })
  }
}
