// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting

private enum ManagedStartupPrerequisite: Error { case noReach, cleanupUnsettled }
@MainActor private final class ManagedStartupObservations {
  var errors: [Error] = []
  var configured: [ObjectIdentifier] = []
  var created: [ObjectIdentifier] = []
}
@MainActor private final class ManagedStartupFixture {
  let directory: URL
  let file: URL?
  let bytes: Data
  let text: String
  let expectedSelection: NSRange
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let session: SessionCoordinator
  let monitoring: ApplicationFileMonitoring
  let observations = ManagedStartupObservations()
  let owner: NativeApplicationDocuments
  private var finalReceipt: SessionCheckpointReceipt?

  init(restoreFile: Bool) throws {
    _ = NSApplication.shared
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      text = restoreFile ? "public startup 😀 e\u{301}\r\n" : ""
      bytes = Data(text.utf8)
      expectedSelection = NSRange(location: 0, length: restoreFile ? 2 : 0)
      file = restoreFile ? directory.appendingPathComponent("synthetic-plain.txt") : nil
      store = SessionStore(directory: directory.appendingPathComponent("session"))
      if let file {
        try bytes.write(to: file)
        let tab = SessionTab(
          originalPath: file.path, pinned: true, encoding: .utf8, selection: expectedSelection)
        try store.save(.init(windows: [.init(tabs: [tab], selectedTabID: tab.id)]))
      }
      let actualStore = store
      recovery = RecoveryCoordinator(
        directory: directory.appendingPathComponent("recovery"),
        saveCheckpointSession: { try actualStore.save($0) },
        readCheckpointSession: { try actualStore.load() })
      let actualRecovery = recovery
      session = SessionCoordinator(
        loadSession: { try actualStore.load() },
        claimRecovery: { try await actualRecovery.claimStartup() })
      monitoring = ApplicationFileMonitoring()
      let observed = observations
      owner = try NativeApplicationDocuments(
        session: session, recovery: recovery, monitoring: monitoring,
        onWindowCreated: { observed.created.append(ObjectIdentifier($0)) },
        configureWindow: {
          // The real AppDelegate configureEditor path, during endpoint construction.
          // No post-start route installation or model action is performed here.
          $0.applySettings(.defaults)
          observed.configured.append(ObjectIdentifier($0))
        },
        onError: { observed.errors.append($0) })
    } catch {
      let primary = error
      do { try FileManager.default.removeItem(at: directory) } catch {
        XCTFail("Actual startup constructor cleanup failed separately: \(error)")
      }
      throw primary
    }
  }
  func finalCheckpoint() async throws -> EditorSession {
    if finalReceipt == nil { finalReceipt = try await owner.prepareQuit() }
    return try XCTUnwrap(store.load(), "Actual paired session checkpoint must be readable")
  }
  func cleanup() async throws {
    var firstError: Error?
    func report(_ error: Error) {
      XCTFail("Actual startup cleanup failed separately: \(error)")
      if firstError == nil { firstError = error }
    }
    do { _ = try await finalCheckpoint() } catch { report(error) }
    monitoring.stop()
    let previousErrors = observations.errors.count
    let windows = owner.windows
    for controller in windows {
      controller.close()
      if !controller.nativeManagedAdmissionWindowIsClosed {
        report(ManagedStartupPrerequisite.cleanupUnsettled)
      }
    }
    do { try await EditorWindowController.drainPendingCloses() } catch { report(error) }
    for error in observations.errors.dropFirst(previousErrors) { report(error) }
    do { try FileManager.default.removeItem(at: directory) } catch { report(error) }
    if let firstError { throw firstError }
  }
}

@MainActor final class NativeManagedAdmissionStartupTests: XCTestCase {
  private func withFixture(
    restoreFile: Bool, _ body: (ManagedStartupFixture) async throws -> Void
  ) async throws {
    let f = try ManagedStartupFixture(restoreFile: restoreFile)
    var primary: Error?
    do { try await body(f) } catch { primary = error }
    var cleanup: Error?
    do { try await f.cleanup() } catch { cleanup = error }
    if let primary { throw primary }
    if let cleanup { throw cleanup }
  }
  private func verifyActualStartup(_ f: ManagedStartupFixture) async throws {
    try await f.owner.start()
    let windows = try f.owner.registry.captureReadyWindows()
    XCTAssertEqual(windows.count, 1)
    XCTAssertEqual(f.owner.windows.count, 1)
    XCTAssertTrue(f.session.restorationComplete)
    XCTAssertTrue(f.session.unresolved.isEmpty)
    XCTAssertTrue(f.observations.errors.isEmpty)
    guard windows.count == 1, f.owner.windows.count == 1,
      f.session.restorationComplete, f.session.unresolved.isEmpty, f.observations.errors.isEmpty
    else { throw ManagedStartupPrerequisite.noReach }
    let snapshot = windows[0]
    let controller = f.owner.windows[0]
    let id = try XCTUnwrap(snapshot.groups.first?.documentIDs.first)
    let model = try XCTUnwrap(f.owner.registry.handle(id: id) as? EditorDocument)
    let assignment = try XCTUnwrap(f.owner.registry.assignment(of: id))
    let pane = try XCTUnwrap(controller.focusedPane)
    let window = try XCTUnwrap(controller.window)
    let storage = model.storage
    let manager = model.undoManager
    XCTAssertEqual(snapshot.groups.count, 1)
    XCTAssertEqual(snapshot.groups[0].documentIDs, [id])
    XCTAssertEqual(assignment.windowID, snapshot.id)
    XCTAssertEqual(assignment.groupID, snapshot.groups[0].id)
    XCTAssertEqual(controller.selectedDocumentID, id)
    XCTAssertTrue(pane.document === model)
    XCTAssertEqual(f.owner.registry.closeStatus(documentID: id), .open)
    XCTAssertEqual(f.owner.registry.adoptionStatus(documentID: id), .active)
    XCTAssertNotNil(model.recoveryAuthority)
    XCTAssertNil(model.operationID)
    XCTAssertFalse(model.saving)
    XCTAssertNil(model.nativeConfigurationToken)
    XCTAssertNil(model.composingPaneID)
    XCTAssertTrue(pane.isAttached)
    XCTAssertTrue(pane.editor.window === window)
    XCTAssertTrue(pane.editor.textStorage === storage)
    XCTAssertTrue(pane.editor.documentUndo === manager)
    XCTAssertTrue(pane.editor.delegate === controller)
    XCTAssertTrue(pane.editor.isEditable)
    XCTAssertTrue(pane.editor.isSelectable)
    XCTAssertTrue(storage.string.utf16.elementsEqual(f.text.utf16))
    XCTAssertTrue(model.savedText.utf16.elementsEqual(f.text.utf16))
    XCTAssertFalse(model.dirty)
    XCTAssertEqual(model.encoding, .utf8)
    XCTAssertEqual(model.url, f.file)
    XCTAssertEqual(pane.editor.selectedRange(), f.expectedSelection)
    XCTAssertEqual(f.observations.configured, [ObjectIdentifier(controller)])
    XCTAssertEqual(f.observations.created, [ObjectIdentifier(controller)])
    guard snapshot.groups.count == 1, snapshot.groups[0].documentIDs == [id],
      assignment.windowID == snapshot.id, assignment.groupID == snapshot.groups[0].id,
      controller.selectedDocumentID == id, pane.document === model,
      f.owner.registry.closeStatus(documentID: id) == .open,
      f.owner.registry.adoptionStatus(documentID: id) == .active,
      model.recoveryAuthority != nil, model.operationID == nil, !model.saving,
      model.nativeConfigurationToken == nil, model.composingPaneID == nil,
      pane.isAttached, pane.editor.window === window, pane.editor.textStorage === storage,
      pane.editor.documentUndo === manager, pane.editor.delegate === controller,
      pane.editor.isEditable, pane.editor.isSelectable,
      storage.string.utf16.elementsEqual(f.text.utf16),
      model.savedText.utf16.elementsEqual(f.text.utf16), !model.dirty,
      model.encoding == .utf8, model.url == f.file,
      pane.editor.selectedRange() == f.expectedSelection,
      f.observations.configured == [ObjectIdentifier(controller)],
      f.observations.created == [ObjectIdentifier(controller)]
    else { throw ManagedStartupPrerequisite.noReach }

    let state = try model.captureCloseState()
    let geometry = model.captureCloseGeometry()
    let mutation = model.closeMutationGeneration
    let revision = model.editRevision
    let ownership = model.ownershipGeneration
    let beforeMetadata = controller.sessionMetadata
    // Raw map observation: missing/invalid leftovers cannot be hidden by a route predicate.
    let route = controller.nativeManagedAdmissionRawRoute(pane)
    let history = manager.nativeManagedAdmissionHistoryRoute
    XCTAssertNotNil(route, "Actual public startup must retain its installed association")
    XCTAssertNotNil(history, "Actual public startup must retain its history association")
    XCTAssertTrue(pane.editor.approvedViewOwner === controller)
    XCTAssertTrue(pane.editor.approvedViewStorage === storage)
    XCTAssertTrue(pane.editor.approvedViewWindow === window)
    XCTAssertTrue(manager.nativeManagedAdmissionHistoryOwner === controller)
    XCTAssertTrue(route.map { pane.editor.approvedViewRoute == $0 } ?? false)
    XCTAssertTrue(route.map { history == $0 } ?? false)
    if let route {
      XCTAssertEqual(route.lease.documentID, id)
      XCTAssertEqual(route.lease.documentObjectID, ObjectIdentifier(model))
      XCTAssertEqual(route.lease.storageID, ObjectIdentifier(storage))
      XCTAssertEqual(route.lease.ownershipGeneration, ownership)
      XCTAssertEqual(route.lease.assignment, assignment)
      XCTAssertEqual(route.viewID, ObjectIdentifier(pane.editor))
      XCTAssertEqual(route.paneID, pane.id)
      XCTAssertEqual(route.windowID, ObjectIdentifier(window))
      XCTAssertEqual(route.managerID, ObjectIdentifier(manager))
    }

    XCTAssertTrue(model.storage === storage)
    XCTAssertTrue(model.undoManager === manager)
    XCTAssertEqual(model.editRevision, revision)
    XCTAssertEqual(model.closeMutationGeneration, mutation)
    XCTAssertEqual(model.ownershipGeneration, ownership)
    XCTAssertEqual(try model.captureCloseState(), state)
    XCTAssertEqual(model.captureCloseGeometry(), geometry)
    XCTAssertEqual(controller.sessionMetadata, beforeMetadata)
    XCTAssertTrue(storage.string.utf16.elementsEqual(f.text.utf16))
    if let file = f.file { XCTAssertEqual(try Data(contentsOf: file), f.bytes) }
    let persisted = try await f.finalCheckpoint()
    XCTAssertEqual(persisted.windows.count, 1)
    let finalWindow = try XCTUnwrap(persisted.windows.first)
    XCTAssertEqual(finalWindow.tabs.map(\.id), [id])
    XCTAssertEqual(finalWindow.selectedTabID, id)
    let finalTab = try XCTUnwrap(finalWindow.tabs.first)
    XCTAssertEqual(finalTab.originalPath, f.file?.path)
    XCTAssertEqual(finalTab.encoding, .utf8)
    XCTAssertEqual(finalTab.selection, f.expectedSelection)
    if let file = f.file { XCTAssertEqual(try Data(contentsOf: file), f.bytes) }
    XCTAssertTrue(f.observations.errors.isEmpty)
  }
  func testActualEmptyOwnerStartupRetainsViewAndHistoryRouting() async throws {
    try await withFixture(restoreFile: false) { try await self.verifyActualStartup($0) }
  }
  func testActualPlainFileOwnerStartupRetainsViewAndHistoryRouting() async throws {
    try await withFixture(restoreFile: true) { try await self.verifyActualStartup($0) }
  }
}
