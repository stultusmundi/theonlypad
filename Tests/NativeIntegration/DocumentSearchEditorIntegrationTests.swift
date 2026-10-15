// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting
@testable import SearchExecution

@MainActor final class DocumentSearchEditorBindingTests: XCTestCase {
  func testManagedFindCapturesOriginalNativeSourceWithoutEarlyTextCapture() async throws {
    try await withBindingFixture { f in
      let editor = try XCTUnwrap(f.editors.first)
      let model = try XCTUnwrap(f.models.first)
      let pane = try XCTUnwrap(editor.focusedPane)
      let endpoint = editor.managedSearchTestFacts.endpointID
      XCTAssertEqual(f.providers, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      XCTAssertFalse(
        editor.configureManagedDocumentSearch(ownerForFind: {
          XCTFail("Rejected provider ran")
          throw BindingError.factory
        }))
      guard let panel = f.open(editor) else { return }
      XCTAssertEqual(f.providers, 1)
      XCTAssertEqual(f.factoryCalls.count, 1)
      XCTAssertEqual(f.backend.registered.count, 1)
      XCTAssertTrue(f.backend.submissions.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      XCTAssertEqual(f.presented.count, 1)
      let call = try XCTUnwrap(f.factoryCalls.first)
      XCTAssertTrue(call.owner === f.searchOwner)
      XCTAssertEqual(call.ticket, editor.managedSearchTestTicket)
      let before = try call.source.inspect()
      XCTAssertEqual(before.windowID, editor.sessionMetadata.id)
      XCTAssertEqual(before.endpointID, endpoint)
      XCTAssertEqual(before.documentID, model.id)
      XCTAssertEqual(before.paneID, pane.id)
      XCTAssertEqual(before.editRevision, model.editRevision)
      XCTAssertEqual(before.ownershipGeneration, model.ownershipGeneration)
      XCTAssertEqual(editor.managedSearchTestFacts.originDocumentID, model.id)
      XCTAssertEqual(editor.managedSearchTestFacts.originPaneID, pane.id)
      let captured = try f.result(panel)
      XCTAssertEqual(f.backend.captures, 1)
      XCTAssertEqual(captured.context, before)
      XCTAssertEqual(captured.text, "😀x\n")
      XCTAssertEqual(captured.text.utf16.count, 4)
      XCTAssertEqual(model.storage.string, "😀x\n")
      XCTAssertFalse(model.dirty)
      XCTAssertEqual(
        pane.editor.selectedRange(), NSRange(location: 0, length: 0),
        "Completion must not implicitly navigate")
    }
  }
  func testTwoManagedEditorsShareOwnerWithDistinctWindowTickets() async throws {
    try await withBindingFixture(windows: 2) { f in
      let a = f.editors[0]
      let b = f.editors[1]
      guard let pa = f.open(a), let pb = f.open(b) else { return }
      let ta = try XCTUnwrap(a.managedSearchTestTicket)
      let tb = try XCTUnwrap(b.managedSearchTestTicket)
      XCTAssertNotEqual(ta, tb)
      XCTAssertEqual(f.providers, 2)
      XCTAssertTrue(f.factoryCalls.allSatisfy { $0.owner === f.searchOwner })
      let ca = try f.result(pa)
      let cb = try f.result(pb)
      XCTAssertNotEqual(ca.context.windowID, cb.context.windowID)
      XCTAssertNotEqual(ca.context.endpointID, cb.context.endpointID)
      XCTAssertNotEqual(ca.context.documentID, cb.context.documentID)
      XCTAssertNotEqual(ca.context.paneID, cb.context.paneID)
      let originalCall = f.factoryCalls[0]
      let bRecord = b.managedSearchTestFacts.recordIdentity
      pa.close()
      XCTAssertNil(a.managedSearchTestPanel)
      XCTAssertEqual(a.managedSearchTestTicket, ta)
      XCTAssertTrue(pa.testOnlyLogicallyClosed)
      XCTAssertEqual(pa.testOnlySessionState, .closed)
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      XCTAssertEqual(b.managedSearchTestFacts.recordIdentity, bRecord)
      XCTAssertFalse(pb.testOnlyLogicallyClosed)
      XCTAssertEqual(f.backend.unregistered.count, 1)
      f.send(pb.testOnlyControls.next)
      XCTAssertEqual(pb.testOnlySessionState, .results(matchCount: 1, selectedIndex: 0))
      XCTAssertEqual(f.searchOwner.phase, .open)
      XCTAssertEqual(f.backend.shutdownCalls, 0)
      guard let newer = f.open(a) else { return }
      XCTAssertFalse(newer === pa)
      XCTAssertEqual(a.managedSearchTestTicket, ta)
      originalCall.onClose(pa)  // Negative stale parent callback, never a native close receipt.
      XCTAssertTrue(a.managedSearchTestPanel === newer)
      XCTAssertFalse(newer.testOnlyLogicallyClosed)
      XCTAssertTrue(b.managedSearchTestPanel === pb)
    }
  }
  func testTabAndFocusChangesPreserveOriginalResultBinding() async throws {
    try await withBindingFixture(tabs: 2) { f in
      let editor = f.editors[0]
      let original = f.models[0]
      let other = f.models[1]
      let originalPane = try XCTUnwrap(editor.focusedPane)
      guard let panel = f.open(editor) else { return }
      let captured = try f.result(panel)
      let source = f.factoryCalls[0].source
      try editor.splitCurrent(.sideBySide)
      let sibling = try XCTUnwrap(original.panePool.first { $0.isAttached && $0 !== originalPane })
      try editor.focusPane(id: sibling.id)
      editor.selectSessionTab(other.id)
      XCTAssertEqual(editor.selectedDocumentID, other.id)
      XCTAssertTrue(editor.managedSearchTestPanel === panel)
      XCTAssertEqual(f.factoryCalls.count, 1, "Tab/focus changes must not silently retarget Find")
      f.send(panel.testOnlyControls.next)
      XCTAssertEqual(editor.selectedDocumentID, original.id)
      XCTAssertTrue(editor.focusedPane === originalPane)
      XCTAssertEqual(originalPane.editor.selectedRange(), NSRange(location: 2, length: 1))
      XCTAssertEqual(panel.testOnlySessionState, .results(matchCount: 1, selectedIndex: 0))
      XCTAssertTrue(source.isCurrent(expected: captured.context))
      let replaced = source.replace(
        expected: captured.context, source: captured.text, replacement: "😀y\n")
      XCTAssertTrue(replaced)
      guard replaced else { return }
      XCTAssertEqual(original.storage.string, "😀y\n")
      XCTAssertTrue(original.dirty)
      XCTAssertFalse(source.isCurrent(expected: captured.context))
      let selection = originalPane.editor.selectedRange()
      f.send(panel.testOnlyControls.next)
      XCTAssertEqual(panel.testOnlySessionState, .failed(.staleSource))
      XCTAssertEqual(originalPane.editor.selectedRange(), selection)
      XCTAssertEqual(original.storage.string, "😀y\n")
      let native = original.undoManager
      XCTAssertFalse(native.isUndoing)
      XCTAssertFalse(native.isRedoing)
      XCTAssertTrue(native.canUndo)
      XCTAssertTrue(native.groupingLevel == 0 || native.groupingLevel == 1)
      guard !native.isUndoing, !native.isRedoing, native.canUndo,
        native.groupingLevel == 0 || native.groupingLevel == 1
      else { throw BindingError.unsafe }
      // The actual original manager closes its ordinary group; no group or flag writes.
      native.undo()
      XCTAssertEqual(original.storage.string, captured.text)
      XCTAssertFalse(original.dirty)
      XCTAssertGreaterThan(original.editRevision, captured.context.editRevision)
      XCTAssertFalse(
        source.isCurrent(expected: captured.context), "Text ABA must not revive old rights")
      try f.requireClean(original)
    }
  }
  func testRealOriginRemovalAndTransferRequireFreshDestinationBinding() async throws {
    // Three finite independent fixtures: actual pane collapse, real model close, actual process move.
    for variant in 0..<3 {
      try await withBindingFixture(windows: 2) { f in
        let a = f.editors[0]
        let b = f.editors[1]
        let original = f.models[0]
        let pane = try XCTUnwrap(a.focusedPane)
        guard let pa = f.open(a), let pb = f.open(b) else { return }
        let captured = try f.result(pa)
        let oldSource = f.factoryCalls[0].source
        let siblingRecord = b.managedSearchTestFacts.recordIdentity
        let siblingTicket = b.managedSearchTestTicket
        let oldGeneration = original.ownershipGeneration
        switch variant {
        case 0:
          try a.splitCurrent(.sideBySide)
          let other = try XCTUnwrap(original.panePool.first { $0.isAttached && $0 !== pane })
          try a.focusPane(id: other.id)
          try a.collapseToFocusedPane()
          XCTAssertFalse(pane.isAttached)
          XCTAssertTrue(a.focusedPane === other)
          XCTAssertTrue(f.process?.registry.handle(id: original.id) as? EditorDocument === original)
        case 1:
          try await f.closeDocument(a, original)
          XCTAssertEqual(f.process?.registry.closedHistoryCount(windowID: a.sessionMetadata.id), 1)
          XCTAssertTrue(a.managedSearchTestFacts.documentIDs.isEmpty)
        default:
          let owner = try XCTUnwrap(f.process)
          let outcome: ApplicationDocumentTransferResult
          do {
            let request = try owner.moveDocument(original.id, toWindowID: b.sessionMetadata.id)
            outcome = try await owner.waitForTransfer(request)
          } catch {
            f.cleanupRefused = true
            throw error
          }
          guard case .moved = outcome else {
            XCTFail("Actual transfer did not reach moved; destination horizon UNENTERED")
            f.cleanupRefused = true
            // Retain exact unresolved/restored fixture, never fake a move.
            throw BindingError.unsafe
          }
          XCTAssertEqual(owner.registry.assignment(of: original.id)?.windowID, b.sessionMetadata.id)
          XCTAssertNotEqual(original.ownershipGeneration, oldGeneration)
          XCTAssertFalse(a.managedSearchTestFacts.documentIDs.contains(original.id))
          XCTAssertTrue(b.managedSearchTestFacts.documentIDs.contains(original.id))
        }
        XCTAssertTrue(pa.testOnlyLogicallyClosed)
        XCTAssertEqual(pa.testOnlySessionState, .closed)
        XCTAssertNil(a.managedSearchTestPanel)
        XCTAssertTrue(b.managedSearchTestPanel === pb)
        XCTAssertFalse(pb.testOnlyLogicallyClosed)
        XCTAssertEqual(b.managedSearchTestFacts.recordIdentity, siblingRecord)
        XCTAssertEqual(b.managedSearchTestTicket, siblingTicket)
        XCTAssertThrowsError(try oldSource.inspect())
        XCTAssertThrowsError(try oldSource.capture(expected: captured.context))
        XCTAssertFalse(oldSource.isCurrent(expected: captured.context))
        XCTAssertFalse(
          oldSource.select(
            expected: captured.context, source: captured.text,
            range: NSRange(location: 2, length: 1)))
        XCTAssertFalse(
          oldSource.replace(
            expected: captured.context, source: captured.text, replacement: "unexpected Q"))
        XCTAssertEqual(original.storage.string, captured.text)
        XCTAssertFalse(original.dirty)
        if variant == 0 {
          guard let next = f.open(a) else { return }
          XCTAssertFalse(next === pa)
          let fresh = try f.result(next)
          XCTAssertEqual(fresh.context.documentID, original.id)
          XCTAssertNotEqual(fresh.context.paneID, captured.context.paneID)
        } else if variant == 2 {
          // Existing sibling result remains its own binding until explicit destination Find.
          b.selectSessionTab(original.id)
          guard let next = f.open(b) else { return }
          XCTAssertFalse(next === pb)
          XCTAssertTrue(pb.testOnlyLogicallyClosed)
          let fresh = try f.result(next)
          XCTAssertEqual(fresh.context.windowID, b.sessionMetadata.id)
          XCTAssertEqual(fresh.context.documentID, original.id)
          XCTAssertEqual(fresh.context.ownershipGeneration, original.ownershipGeneration)
          XCTAssertNotEqual(fresh.context.endpointID, captured.context.endpointID)
          XCTAssertEqual(b.managedSearchTestTicket, siblingTicket)
        }
      }
    }
  }
  func testOriginalWindowAndEndpointRetireExactlyTheirSearchTicket() async throws {
    try await withBindingFixture(windows: 2) { f in
      let a = f.editors[0]
      let b = f.editors[1]
      let original = f.models[0]
      guard let pa = f.open(a), let pb = f.open(b) else { return }
      let ticket = try XCTUnwrap(a.managedSearchTestTicket)
      let call = f.factoryCalls[0]
      let aBefore = a.managedSearchTestFacts
      let bBefore = b.managedSearchTestFacts
      a.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: try XCTUnwrap(b.window)))
      XCTAssertFalse(a.managedSearchTestFacts.windowClosed)
      XCTAssertEqual(a.managedSearchTestFacts.documentIDs, aBefore.documentIDs)
      XCTAssertEqual(a.managedSearchTestFacts.recordIdentity, aBefore.recordIdentity)
      XCTAssertTrue(a.managedSearchTestPanel === pa)
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      guard !a.managedSearchTestFacts.windowClosed, a.managedSearchTestPanel === pa,
        a.managedSearchTestFacts.documentIDs == aBefore.documentIDs
      else { throw BindingError.unsafe }
      try await f.closeDocument(a, original)
      XCTAssertTrue(pa.testOnlyLogicallyClosed)
      XCTAssertNil(a.managedSearchTestPanel)
      // Genuine exact SDK notification and Source endpoint closure before credit.
      try f.closeEmptyWindow(a)
      XCTAssertNil(a.managedSearchTestTicket)
      do {
        let accidental = try f.searchOwner.attachDocument(
          window: ticket, source: call.source, onDelivery: { _ in })
        accidental.close()
        XCTFail("Closed endpoint's exact old ticket must refuse")
      } catch let error as ApplicationDocumentSearchFailure {
        XCTAssertEqual(error, .staleWindow)
      } catch { XCTFail("Wrong old ticket refusal: \(error)") }
      let unregisterCount = f.backend.unregistered.count
      call.onClose(pa)
      call.onClose(pb)  // Negative duplicate/wrong-child callbacks, never native receipts.
      XCTAssertEqual(f.backend.unregistered.count, unregisterCount)
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      XCTAssertFalse(pb.testOnlyLogicallyClosed)
      XCTAssertEqual(b.managedSearchTestFacts.recordIdentity, bBefore.recordIdentity)
      XCTAssertFalse(b.managedSearchTestFacts.windowClosed)
      _ = try f.result(pb)
      XCTAssertEqual(f.searchOwner.phase, .open)
    }
  }
  func testFactoryAndPresentationReentryPreserveNewerConcreteChild() async throws {
    for variant in 0..<4 {
      try await withBindingFixture { f in
        let editor = f.editors[0]
        if variant == 1 {
          f.presenterHook = { [weak editor, weak f] panel in
            guard let editor, let f, f.presented.count == 1 else { return }
            panel.close()
            do { _ = try editor.managedSearchTestShow() } catch {
              XCTFail("Nested presentation Find: \(error)")
            }
          }
        } else {
          f.factoryHook = { [weak editor] index, call in
            guard index == 0, let editor else { return nil }
            if variant == 3 {
              let old = try call.construct()
              old.close()  // Genuine own-child consumer retirement before nested attachment.
              _ = try editor.managedSearchTestShow()
              return old  // Distinct stale concrete child; newer B must survive old cleanup.
            }
            let newer = try XCTUnwrap(try editor.managedSearchTestShow())
            // Real duplicate attachment must throw while B occupies this ticket.
            if variant == 2 { return try call.construct() }
            return newer  // SAME concrete child returned by stale outer factory.
          }
        }
        var returned: DocumentSearchPanelController?
        var threwExpected = false
        do { returned = try editor.managedSearchTestShow() } catch let error
          as ApplicationDocumentSearchFailure
        {
          XCTAssertEqual(error, .documentSlotOccupied)
          threwExpected = error == .documentSlotOccupied
        } catch {
          XCTFail("Unexpected real Find refusal: \(error)")
          throw error
        }
        XCTAssertEqual(f.factoryCalls.count, 2, "Bounded native reentry must reach exactly A/B")
        XCTAssertNotNil(
          editor.managedSearchTestPanel, "Inert baseline leaves reentry horizon UNENTERED")
        guard f.factoryCalls.count == 2, let newer = editor.managedSearchTestPanel else {
          print("EDITOR_BINDING reentry horizon UNENTERED")
          return
        }
        XCTAssertNil(returned)
        XCTAssertEqual(threwExpected, variant == 2)
        XCTAssertTrue(f.factoryCalls[1].panel === newer)
        XCTAssertFalse(newer.testOnlyLogicallyClosed)
        XCTAssertEqual(newer.testOnlySessionState, .idle)
        XCTAssertEqual(f.presented.filter { $0 === newer }.count, 1)
        XCTAssertEqual(f.backend.registered.count - f.backend.unregistered.count, 1)
        let record = editor.managedSearchTestFacts.recordIdentity
        f.factoryCalls[0].onClose(newer)  // Exact stale callback must not erase adopted B.
        XCTAssertTrue(editor.managedSearchTestPanel === newer)
        XCTAssertEqual(editor.managedSearchTestFacts.recordIdentity, record)
        XCTAssertFalse(editor.managedSearchTestFacts.windowClosed)
        XCTAssertEqual(editor.managedSearchTestFacts.documentIDs, [f.models[0].id])
        XCTAssertTrue(
          f.process?.registry.handle(id: f.models[0].id) as? EditorDocument === f.models[0])
        _ = try f.result(newer)
      }
    }
  }
}

private enum BindingError: Error { case missing, bound, unsafe, factory }
@MainActor private enum BindingCustody {
  private static var retained: BindingFixture?
  static func requireEmpty() throws {
    guard retained == nil else {
      XCTFail("Previous exact managed fixture remains in custody")
      throw BindingError.unsafe
    }
  }
  static func retain(_ fixture: BindingFixture) {
    guard retained == nil || retained === fixture else {
      XCTFail("One-slot custody overflow")
      return
    }
    retained = fixture
  }
}
@MainActor private final class BindingCloseReceipt {
  weak var window: NSWindow?
  var count = 0, exact = true
  init(_ window: NSWindow) { self.window = window }
  func receive(_ note: Notification) {
    count += 1
    exact = exact && (note.object as? NSWindow) === window
    XCTAssertLessThanOrEqual(count, 1)
  }
}
@MainActor private final class BindingFactoryCall {
  let owner: ApplicationSearchOwner, ticket: ApplicationSearchWindowID
  let source: any ApplicationDocumentSearchSource
  let onClose: @MainActor (DocumentSearchPanelController) -> Void
  var panel: DocumentSearchPanelController?
  init(
    _ owner: ApplicationSearchOwner, _ ticket: ApplicationSearchWindowID,
    _ source: any ApplicationDocumentSearchSource,
    _ onClose: @escaping @MainActor (DocumentSearchPanelController) -> Void
  ) {
    self.owner = owner
    self.ticket = ticket
    self.source = source
    self.onClose = onClose
  }
  func construct() throws -> DocumentSearchPanelController {
    let value = try DocumentSearchPanelController(
      owner: owner, window: ticket, source: source, onClose: onClose)
    panel = value
    value.testOnlyControls.query.stringValue = "x"
    value.testOnlyControls.replacement.stringValue = "y"
    return value
  }
}
@MainActor private final class BindingFixture {
  let directory: URL, recoveryDirectory: URL
  let store: SessionStore, recovery: RecoveryCoordinator, session: SessionCoordinator
  let monitoring = ApplicationFileMonitoring(), backend = BindingBackend()
  lazy var searchOwner = ApplicationSearchOwner(backend: backend)
  var process: NativeApplicationDocuments?
  var editors: [EditorWindowController] = [], models: [EditorDocument] = []
  var files: [(URL, Data)] = []
  var factoryCalls: [BindingFactoryCall] = [], presented: [DocumentSearchPanelController] = []
  var providers = 0, errors = 0
  var cleanupRefused = false  // Test-only resource custody, never native or registry authority.
  var factoryHook: (@MainActor (Int, BindingFactoryCall) throws -> DocumentSearchPanelController?)?
  var presenterHook: (@MainActor (DocumentSearchPanelController) -> Void)?
  init() throws {
    try BindingCustody.requireEmpty()
    _ = NSApplication.shared
    guard let state = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !state.isEmpty
    else {
      XCTFail("Root runner must supply its exact owned synthetic state directory")
      throw BindingError.missing
    }
    directory = URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent(
      "editor-binding-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    self.recovery = recovery
    session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
  }
  func start(windows: Int = 1, tabs: Int = 1) async throws {
    precondition((1...2).contains(windows) && (1...2).contains(tabs) && windows * tabs <= 2)
    var sessions: [SessionWindow] = []
    for wi in 0..<windows {
      var values: [SessionTab] = []
      for ti in 0..<tabs {
        let text = wi + ti == 0 ? "😀x\n" : "😀q\n"
        let file = directory.appendingPathComponent("synthetic-\(wi)-\(ti).txt")
        let data = Data(text.utf8)
        try data.write(to: file, options: .atomic)
        files.append((file, data))
        values.append(SessionTab(originalPath: file.path))
      }
      sessions.append(SessionWindow(tabs: values, selectedTabID: values[0].id))
    }
    try store.save(EditorSession(windows: sessions))
    let process = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: monitoring,
      onWindowCreated: { _ in },
      onError: { [weak self] _ in
        guard let self else { return }
        self.errors += 1
        XCTFail("Unexpected real native process error")
      })
    self.process = process
    try await process.start()
    let projections = try process.registry.captureReadyWindows()
    XCTAssertEqual(projections.count, windows)
    XCTAssertEqual(process.windows.count, windows)
    guard projections.count == windows, process.windows.count == windows,
      session.restorationComplete,
      session.unresolved.isEmpty
    else { throw BindingError.missing }
    for spec in sessions {
      let editor = try XCTUnwrap(process.windows.first { $0.sessionMetadata.id == spec.id })
      let projection = try XCTUnwrap(projections.first { $0.id == spec.id })
      XCTAssertEqual(projection.groups.count, 1)
      guard projection.groups.count == 1, let group = projection.groups.first else {
        throw BindingError.missing
      }
      let window = try XCTUnwrap(editor.window)
      XCTAssertFalse(window.isVisible)
      XCTAssertFalse(editor.managedSearchTestFacts.windowClosed)
      XCTAssertEqual(editor.managedSearchTestFacts.documentIDs, group.documentIDs)
      guard !window.isVisible, !editor.managedSearchTestFacts.windowClosed,
        projection.groups.count == 1, editor.managedSearchTestFacts.endpointID != nil,
        editor.managedSearchTestFacts.documentIDs == group.documentIDs
      else { throw BindingError.missing }
      editors.append(editor)
      for id in group.documentIDs {
        let model = try XCTUnwrap(process.registry.handle(id: id) as? EditorDocument)
        models.append(model)
        try requireClean(model)
        let item = try model.captureAuthorizedRecovery()
        XCTAssertNil(item.snapshot)
        XCTAssertEqual(item.authority.documentID, model.id)
        XCTAssertEqual(item.authority, model.recoveryAuthority)
        guard item.snapshot == nil, item.authority.documentID == model.id,
          item.authority == model.recoveryAuthority, item.revision > 0,
          item.revision == model.highestIssuedRecoveryRevision
        else { throw BindingError.unsafe }
        try await recovery.persistAuthorizedBatch([item])
      }
      configure(editor)
    }
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    XCTAssertTrue(report.snapshots.isEmpty)
    XCTAssertEqual(report.quarantinedCount, 0)
    guard report.snapshots.isEmpty, report.quarantinedCount == 0 else { throw BindingError.unsafe }
  }
  func configure(_ editor: EditorWindowController) {
    let accepted = editor.configureManagedDocumentSearch(
      ownerForFind: { [weak self] in
        guard let self else { throw BindingError.missing }
        self.providers += 1
        guard self.providers <= 4 else { throw BindingError.bound }
        return self.searchOwner
      },
      makePanel: { [weak self] owner, ticket, source, onClose in
        guard let self, self.factoryCalls.count < 4 else { throw BindingError.bound }
        XCTAssertTrue(owner === self.searchOwner)
        XCTAssertTrue(
          source is EditorDocumentSearchSource, "Only the actual native Source factory is admitted")
        let call = BindingFactoryCall(owner, ticket, source, onClose)
        self.factoryCalls.append(call)
        let index = self.factoryCalls.count - 1
        if let value = try self.factoryHook?(index, call) {
          call.panel = value
          return value
        }
        return try call.construct()
      },
      presentPanel: { [weak self] panel in
        guard let self else { return }
        guard self.presented.count < 4 else {
          XCTFail("Presenter cap")
          return
        }
        self.presented.append(panel)
        self.presenterHook?(panel)  // Explicit hidden presenter, never showWindow.
      })
    XCTAssertTrue(accepted)
    XCTAssertTrue(editor.managedSearchTestFacts.configured)
  }
  func open(_ editor: EditorWindowController) -> DocumentSearchPanelController? {
    let before = factoryCalls.count
    // Configured real command; inert baseline never enters legacy showSearch.
    editor.execute("edit.find")
    XCTAssertEqual(
      factoryCalls.count, before + 1, "Managed Find must call the concrete native factory")
    XCTAssertNotNil(
      editor.managedSearchTestPanel, "Missing managed child is behavioral declaration RED")
    guard factoryCalls.count == before + 1, let panel = editor.managedSearchTestPanel else {
      print("EDITOR_BINDING later Source/action horizon UNENTERED")
      return nil
    }
    XCTAssertTrue(factoryCalls.last?.panel === panel)
    XCTAssertNotNil(editor.managedSearchTestTicket)
    XCTAssertNotNil(editor.managedSearchTestFacts.recordIdentity)
    XCTAssertFalse(panel.window?.isVisible ?? true)
    return panel
  }
  func send(_ control: NSControl) {
    guard let action = control.action, let target = control.target else {
      XCTFail("Missing real panel action")
      return
    }
    XCTAssertTrue(NSApp.sendAction(action, to: target, from: control))
  }
  func result(_ panel: DocumentSearchPanelController) throws -> SearchAdmissionCapture<
    DocumentSearchCredential
  > {
    let index = backend.submissions.count
    send(panel.testOnlyControls.find)
    XCTAssertEqual(backend.submissions.count, index + 1)
    guard backend.submissions.count == index + 1 else { throw BindingError.missing }
    let capture = try backend.capture(index)
    let lease = backend.install(
      capture, matches: [NSRange(location: 2, length: 1)], replacement: nil)
    backend.deliver(index, .completed(lease))
    XCTAssertEqual(panel.testOnlySessionState, .results(matchCount: 1, selectedIndex: nil))
    return capture
  }
  func requireClean(_ model: EditorDocument) throws {
    let state = try model.captureCloseState()
    XCTAssertFalse(model.dirty)
    XCTAssertFalse(state.isDirty)
    let native = model.undoManager
    guard !model.dirty, !state.isDirty, !state.hasPendingPublication, !state.hasPendingTextEdits,
      !state.isComposing, state.operationID == nil, !native.isUndoing, !native.isRedoing,
      native.groupingLevel == 0
    else { throw BindingError.unsafe }
  }
  func closeDocument(_ editor: EditorWindowController, _ model: EditorDocument) async throws {
    let owner = try XCTUnwrap(process)
    try requireClean(model)
    guard owner.registry.handle(id: model.id) as? EditorDocument === model,
      editor.managedSearchTestFacts.documentIDs.contains(model.id)
    else { throw BindingError.unsafe }
    editor.selectSessionTab(model.id)
    guard editor.selectedDocumentID == model.id else { throw BindingError.unsafe }
    let text = model.storage.string
    let revision = model.editRevision
    let state = try model.captureCloseState()
    editor.execute("file.close")
    let status = try XCTUnwrap(owner.managedSearchTestCloseStatus)
    let joined = try await owner.managedSearchTestWaitClose(status.id)
    let settled = try XCTUnwrap(joined.status)
    guard case .completed(let ids) = joined.result else {
      XCTFail("Real close must complete clean input")
      throw BindingError.unsafe
    }
    XCTAssertEqual(ids, [model.id])
    XCTAssertEqual(settled.id, status.id)
    XCTAssertEqual(settled.stage, .settled)
    XCTAssertFalse(settled.recoveryPaused)
    XCTAssertNil(settled.error)
    XCTAssertNil(owner.registry.handle(id: model.id))
    XCTAssertEqual(model.storage.string, text)
    XCTAssertEqual(model.editRevision, revision)
    XCTAssertEqual(try model.captureCloseState(), state)
    guard ids == [model.id], settled.id == status.id, settled.stage == .settled,
      !settled.recoveryPaused, settled.error == nil, owner.registry.handle(id: model.id) == nil,
      !editor.managedSearchTestFacts.documentIDs.contains(model.id), model.storage.string == text,
      model.editRevision == revision, try model.captureCloseState() == state
    else { throw BindingError.unsafe }
  }
  func closeEmptyWindow(_ editor: EditorWindowController) throws {
    let owner = try XCTUnwrap(process)
    let window = try XCTUnwrap(editor.window)
    let id = editor.sessionMetadata.id
    guard editor.managedSearchTestFacts.documentIDs.isEmpty, editor.sessionMetadata.tabs.isEmpty,
      owner.registry.window(id: id) != nil
    else { throw BindingError.unsafe }
    for model in models { try requireClean(model) }
    let receipt = BindingCloseReceipt(window)
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window, queue: nil
    ) { [weak receipt] note in
      MainActor.assumeIsolated { receipt?.receive(note) }
    }
    window.close()
    NotificationCenter.default.removeObserver(observer)
    XCTAssertEqual(receipt.count, 1)
    XCTAssertTrue(receipt.exact)
    XCTAssertTrue(editor.managedSearchTestFacts.windowClosed)
    XCTAssertNil(owner.registry.window(id: id))
    XCTAssertEqual(owner.registry.closedHistoryCount(windowID: id), 0)
    guard receipt.count == 1, receipt.exact, editor.managedSearchTestFacts.windowClosed,
      owner.registry.window(id: id) == nil, owner.registry.closedHistoryCount(windowID: id) == 0
    else { throw BindingError.unsafe }
  }
  func finish() async throws {
    factoryHook = nil
    presenterHook = nil
    backend.clearHooks()
    var closed: Set<ObjectIdentifier> = []
    for call in factoryCalls {
      if let panel = call.panel, closed.insert(ObjectIdentifier(panel)).inserted { panel.close() }
    }
    backend.finishPending()
    let owner = try XCTUnwrap(process)
    for editor in editors where !editor.managedSearchTestFacts.windowClosed {
      let ids = editor.managedSearchTestFacts.documentIDs
      for id in ids {
        try await closeDocument(
          editor, try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument))
      }
      try closeEmptyWindow(editor)
    }
    XCTAssertTrue(owner.windows.isEmpty)
    XCTAssertTrue(try owner.registry.captureReadyWindows().isEmpty)
    XCTAssertEqual(Set(backend.registered), Set(backend.unregistered))
    XCTAssertEqual(backend.registered.count, backend.unregistered.count)
    XCTAssertEqual(backend.pendingTerminalCount, 0)
    XCTAssertTrue(backend.payloads.isEmpty)
    XCTAssertEqual(backend.borrowDepth, 0)
    XCTAssertEqual(backend.shutdownCalls, 0)
    XCTAssertEqual(errors, 0)
    let receipt = try await owner.prepareQuit()
    let fresh = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    XCTAssertTrue(receipt.recoveryAuthorities.isEmpty)
    XCTAssertTrue(receipt.recoveryRevisions.isEmpty)
    XCTAssertTrue(fresh.windows.isEmpty)
    XCTAssertTrue(report.snapshots.isEmpty)
    XCTAssertEqual(report.quarantinedCount, 0)
    guard owner.windows.isEmpty, try owner.registry.captureReadyWindows().isEmpty,
      Set(backend.registered) == Set(backend.unregistered),
      backend.registered.count == backend.unregistered.count,
      backend.pendingTerminalCount == 0, backend.payloads.isEmpty, backend.borrowDepth == 0,
      backend.shutdownCalls == 0, errors == 0, receipt.recoveryAuthorities.isEmpty,
      receipt.recoveryRevisions.isEmpty, fresh.windows.isEmpty, report.snapshots.isEmpty,
      report.quarantinedCount == 0
    else { throw BindingError.unsafe }
    for (file, bytes) in files {
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      guard try Data(contentsOf: file) == bytes else { throw BindingError.unsafe }
    }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    guard permissions?.intValue == 0o700 else { throw BindingError.unsafe }
    // Only the fresh owned UUID directory, after actual producer joins/fresh readers/safe native close.
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}
@MainActor private func withBindingFixture(
  windows: Int = 1, tabs: Int = 1,
  body: @MainActor (BindingFixture) async throws -> Void
) async throws {
  let fixture = try BindingFixture()
  do { try await fixture.start(windows: windows, tabs: tabs) } catch {
    BindingCustody.retain(fixture)
    throw error
  }
  var primary: Error?
  do { try await body(fixture) } catch { primary = error }
  if fixture.cleanupRefused {
    BindingCustody.retain(fixture)
    XCTFail("Actual transfer prerequisite unresolved; cleanup UNENTERED and exact fixture retained")
    throw primary ?? BindingError.unsafe
  }
  do { try await fixture.finish() } catch {
    BindingCustody.retain(fixture)
    XCTFail("Separate real managed cleanup refusal; exact fixture retained")
    throw primary ?? error
  }
  if let primary { throw primary }
}

@MainActor private final class BindingBackend: ApplicationSearchBackend {
  final class Submission {
    let consumer: SearchConsumerID, job: SearchJobID
    let descriptor: SearchAdmissionDescriptor
    var capture: (@MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>)?
    var completion: (@MainActor (SearchAdmissionDelivery) -> Void)?
    var delivered = false
    init(
      consumer: SearchConsumerID, job: SearchJobID, descriptor: SearchAdmissionDescriptor,
      capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
      completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
    ) {
      self.consumer = consumer
      self.job = job
      self.descriptor = descriptor
      self.capture = capture
      self.completion = completion
    }
  }
  struct Payload {
    let captured: SearchAdmissionCapture<DocumentSearchCredential>
    let output: SearchExecutionOutput
  }
  var registered: [SearchConsumerID] = [], unregistered: [SearchConsumerID] = []
  var cancelled: [SearchJobID] = [], released: [SearchResultLeaseID] = []
  var submissions: [Submission] = [], payloads: [SearchResultLeaseID: Payload] = [:]
  var onSubmit: (@MainActor (Int) -> Void)?
  var onCancel: (@MainActor (SearchJobID) -> Void)?,
    onRelease: (@MainActor (SearchResultLeaseID) -> Void)?
  var throwAfterSubmit: SearchAdmissionFailure?
  var borrowDepth = 0, shutdownCalls = 0, captures = 0
  var pendingTerminalCount: Int { submissions.filter { !$0.delivered }.count }
  func registration(_ index: Int) throws -> SearchConsumerID {
    guard registered.indices.contains(index) else {
      XCTFail("Missing real registration")
      throw BindingError.missing
    }
    return registered[index]
  }
  func submission(_ index: Int) throws -> Submission {
    guard submissions.indices.contains(index) else {
      XCTFail("Missing real submission")
      throw BindingError.missing
    }
    return submissions[index]
  }
  func register() -> SearchConsumerID {
    precondition(registered.count < 8)
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func unregister(_ consumer: SearchConsumerID) {
    XCTAssertTrue(registered.contains(consumer))
    XCTAssertFalse(unregistered.contains(consumer))
    guard unregistered.count < 8 else {
      XCTFail("Unregister cap")
      return
    }
    unregistered.append(consumer)
  }
  func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<DocumentSearchCredential>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    guard submissions.count < 8 else {
      XCTFail("Submission cap")
      throw BindingError.bound
    }
    let job = SearchJobID()
    submissions.append(
      Submission(
        consumer: consumer, job: job, descriptor: descriptor,
        capture: capture, completion: completion))
    let callback = onSubmit
    onSubmit = nil
    callback?(submissions.count - 1)
    if let throwAfterSubmit { throw throwAfterSubmit }
    return job
  }
  func cancel(_ id: SearchJobID) {
    XCTAssertFalse(cancelled.contains(id))
    guard cancelled.count < 16 else {
      XCTFail("Cancel cap")
      return
    }
    cancelled.append(id)
    let callback = onCancel
    onCancel = nil
    callback?(id)
  }
  func release(_ id: SearchResultLeaseID) {
    XCTAssertFalse(released.contains(id))
    guard released.count < 16 else {
      XCTFail("Release cap")
      return
    }
    released.append(id)
    payloads.removeValue(forKey: id)
    let callback = onRelease
    onRelease = nil
    callback?(id)
  }
  func withResult(
    _ id: SearchResultLeaseID,
    _ body: (DocumentSearchCredential, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    guard let payload = payloads[id], borrowDepth == 0 else { return false }
    borrowDepth += 1
    defer { borrowDepth -= 1 }
    body(payload.captured.context, payload.captured.text, payload.output)
    return true
  }
  func capture(_ index: Int) throws -> SearchAdmissionCapture<DocumentSearchCredential> {
    let request = try submission(index)
    let callback = try XCTUnwrap(request.capture)
    captures += 1
    return try callback()
  }
  func install(
    _ captured: SearchAdmissionCapture<DocumentSearchCredential>, matches: [NSRange],
    replacement: String?
  ) -> SearchResultLeaseID {
    precondition(matches.count <= 4 && payloads.count < 16)
    let id = SearchResultLeaseID()
    payloads[id] = Payload(
      captured: captured, output: SearchExecutionOutput(matches: matches, replacement: replacement))
    return id
  }
  func deliver(_ index: Int, _ delivery: SearchAdmissionDelivery) {
    guard submissions.indices.contains(index), !submissions[index].delivered else {
      XCTFail("Missing/duplicate actual scripted terminal completion")
      return
    }
    let request = submissions[index]
    request.delivered = true
    let callback = request.completion
    request.completion = nil
    request.capture = nil
    callback?(delivery)
  }
  func finishPending() {
    for index in submissions.indices where !submissions[index].delivered {
      deliver(index, .failed(.cancelled))
    }
  }
  func clearHooks() {
    onSubmit = nil
    onCancel = nil
    onRelease = nil
    throwAfterSubmit = nil
  }
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    shutdownCalls += 1
    return .callerRefused(.unsupportedDriver)
  }
}

// Real private native transfer/close control; no managed Find or search-owner invocation.
@MainActor final class DocumentSearchTransferCloseNoSearchTests: XCTestCase {
  func testRealTransferThenCloseWithoutAnySearchInvocation() async throws {
    var completedFixture: BindingFixture?
    try await withBindingFixture(windows: 2) { f in
      let source = try XCTUnwrap(f.editors.first)
      let target = try XCTUnwrap(f.editors.last)
      let model = try XCTUnwrap(f.models.first)
      let owner = try XCTUnwrap(f.process)
      XCTAssertFalse(source === target)
      XCTAssertEqual(f.editors.count, 2)
      XCTAssertEqual(f.models.count, 2)
      XCTAssertEqual(f.files.count, 2)
      XCTAssertEqual(f.providers, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertTrue(f.presented.isEmpty)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertTrue(f.backend.submissions.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      XCTAssertNil(source.managedSearchTestPanel)
      XCTAssertNil(target.managedSearchTestPanel)
      XCTAssertNil(source.managedSearchTestTicket)
      XCTAssertNil(target.managedSearchTestTicket)
      let originalOwnership = model.ownershipGeneration
      let originalText = model.storage.string
      XCTAssertEqual(owner.registry.assignment(of: model.id)?.windowID, source.sessionMetadata.id)
      let outcome: ApplicationDocumentTransferResult
      do {
        let request = try owner.moveDocument(model.id, toWindowID: target.sessionMetadata.id)
        outcome = try await owner.waitForTransfer(request)
      } catch {
        f.cleanupRefused = true
        throw error
      }
      guard case .moved = outcome else {
        XCTFail("Real no-search control did not reach moved; close horizon UNENTERED")
        f.cleanupRefused = true
        throw BindingError.unsafe
      }
      XCTAssertTrue(owner.registry.handle(id: model.id) as? EditorDocument === model)
      XCTAssertEqual(owner.registry.assignment(of: model.id)?.windowID, target.sessionMetadata.id)
      XCTAssertNotEqual(model.ownershipGeneration, originalOwnership)
      XCTAssertFalse(source.managedSearchTestFacts.documentIDs.contains(model.id))
      XCTAssertTrue(target.managedSearchTestFacts.documentIDs.contains(model.id))
      XCTAssertEqual(model.storage.string, originalText)
      XCTAssertFalse(model.dirty)
      guard owner.registry.handle(id: model.id) as? EditorDocument === model,
        owner.registry.assignment(of: model.id)?.windowID == target.sessionMetadata.id,
        model.ownershipGeneration != originalOwnership,
        !source.managedSearchTestFacts.documentIDs.contains(model.id),
        target.managedSearchTestFacts.documentIDs.contains(model.id),
        model.storage.string == originalText, !model.dirty
      else {
        f.cleanupRefused = true
        throw BindingError.unsafe
      }
      try f.requireClean(model)
      XCTAssertEqual(f.providers, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertTrue(f.presented.isEmpty)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertTrue(f.backend.submissions.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      XCTAssertNil(source.managedSearchTestPanel)
      XCTAssertNil(target.managedSearchTestPanel)
      XCTAssertNil(source.managedSearchTestTicket)
      XCTAssertNil(target.managedSearchTestTicket)
      // Existing finish performs actual clean-document close/status/wait/settle,
      // exact empty-window SDK close, final native publication and fresh readers.
      completedFixture = f
    }
    let f = try XCTUnwrap(completedFixture)
    XCTAssertEqual(f.providers, 0)
    XCTAssertTrue(f.factoryCalls.isEmpty)
    XCTAssertTrue(f.presented.isEmpty)
    XCTAssertTrue(f.backend.registered.isEmpty)
    XCTAssertTrue(f.backend.unregistered.isEmpty)
    XCTAssertTrue(f.backend.submissions.isEmpty)
    XCTAssertEqual(f.backend.captures, 0)
    XCTAssertEqual(f.backend.shutdownCalls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
  }
}

// DFC collaborator evidence: these tests exercise the real bridge, not native SDK history.
@MainActor final class FileStateDetachmentPhaseTests: XCTestCase {
  func testRealDetachPhasePreservesOuterScopeAcrossRecursiveRefusal() throws {
    let f = RepairBridgeFixture()
    defer { f.bridge.invalidate() }
    f.bridge.adoptBaseline(bytes: Data([0x78]))
    XCTAssertEqual(f.client.registrations, 1)
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    f.bridge.checkAgain()
    XCTAssertEqual(f.client.requests, 1, "Positive open bridge check reaches actual collaborator")
    var callbacks = 0
    f.onContext = { [weak f] in
      guard let f else {
        XCTFail("Missing actual bridge fixture")
        return
      }
      callbacks += 1
      XCTAssertTrue(f.bridge.isDetachingEndpoint, "Real admitted detach must expose its phase")
      do {
        _ = try f.bridge.detachEndpoint()
        XCTFail("Recursive detach must refuse")
      } catch {
        guard let failure = error as? FileStateEndpointError, case .unavailable = failure else {
          XCTFail("Wrong recursive error: \(error)")
          return
        }
      }
      XCTAssertTrue(
        f.bridge.isDetachingEndpoint, "Rejected recursive frame cannot clear outer phase")
      f.bridge.reconcileEligibility()
      for action in FileConflictAction.allCases { XCTAssertNil(f.bridge.captureAction(action)) }
      let registrations = f.client.registrations
      let requests = f.client.requests
      f.bridge.adoptBaseline(bytes: Data([0x79]))
      f.bridge.retryRegistration()
      f.bridge.checkAgain()
      XCTAssertEqual(f.client.registrations, registrations)
      XCTAssertEqual(f.client.requests, requests)
    }
    let token = try f.bridge.detachEndpoint()
    XCTAssertEqual(callbacks, 1)
    XCTAssertFalse(f.bridge.isDetachingEndpoint, "Only outer return clears its phase")
    do {
      _ = try f.bridge.detachEndpoint()
      XCTFail("Detached bridge must reject another entry")
    } catch {
      guard let failure = error as? FileStateEndpointError, case .unavailable = failure else {
        XCTFail("Wrong detached error: \(error)")
        return
      }
    }
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    f.onContext = nil
    try f.bridge.reattachEndpoint(
      token, expectedBinding: token.binding,
      liveContext: { [weak f] in f?.live }, onChange: {})
    XCTAssertFalse(f.bridge.isDetachingEndpoint, "Attachment is not detach phase")
    XCTAssertEqual(f.client.registrations, 2)
  }

  func testRealIdentityGuardErrorClearsPhaseAndPreservesRetry() throws {
    let f = RepairBridgeFixture()
    defer { f.bridge.invalidate() }
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    do {
      _ = try f.bridge.detachEndpoint()
      XCTFail("Unbound bridge cannot admit detach")
    } catch {
      guard let failure = error as? FileStateEndpointError, case .unavailable = failure else {
        XCTFail("Wrong unbound error: \(error)")
        return
      }
    }
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    f.bridge.adoptBaseline(bytes: Data([0x78]))
    let original = f.live
    var observed = 0
    f.onContext = { [weak f] in
      guard let f else {
        XCTFail("Missing bridge")
        return
      }
      observed += 1
      XCTAssertTrue(f.bridge.isDetachingEndpoint)
      // DTO collaborator mutation only: no native model or registry authority is changed.
      f.live.bindingID = UUID()
    }
    do {
      _ = try f.bridge.detachEndpoint()
      XCTFail("Changed actual callback identity must refuse")
    } catch {
      guard let failure = error as? FileStateEndpointError, case .stale = failure else {
        XCTFail("Wrong identity error: \(error)")
        return
      }
    }
    XCTAssertEqual(observed, 1)
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    XCTAssertEqual(f.client.registrations, 1)
    XCTAssertEqual(f.client.handle.cancellations, 0)
    f.onContext = nil
    f.live = original
    let token = try f.bridge.detachEndpoint()
    XCTAssertEqual(token.binding.documentID, original.documentID)
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    XCTAssertEqual(f.client.handle.cancellations, 1)
  }

  func testRealCancellationInvalidationThrowsAndClearsAdmittedPhase() throws {
    let f = RepairBridgeFixture()
    defer { f.bridge.invalidate() }
    f.bridge.adoptBaseline(bytes: Data([0x78]))
    let log = RepairCancellationLog()
    f.client.handle.onCancel = { [weak f] in
      MainActor.assumeIsolated {
        guard let f else {
          XCTFail("Missing cancellation fixture")
          return
        }
        log.count += 1
        XCTAssertTrue(f.bridge.isDetachingEndpoint)
        f.bridge.invalidate()  // Actual terminal bridge action; final issuer guard must still fail.
        XCTAssertTrue(f.bridge.isDetachingEndpoint, "Invalidation cannot clear caller-owned scope")
      }
    }
    do {
      _ = try f.bridge.detachEndpoint()
      XCTFail("Cancellation invalidation must invalidate final receipt")
    } catch {
      guard let failure = error as? FileStateEndpointError, case .stale = failure else {
        XCTFail("Wrong final error: \(error)")
        return
      }
    }
    XCTAssertEqual(log.count, 1)
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    do {
      _ = try f.bridge.detachEndpoint()
      XCTFail("Invalidated bridge cannot issue another token")
    } catch {
      guard let failure = error as? FileStateEndpointError, case .unavailable = failure else {
        XCTFail("Wrong invalidated error: \(error)")
        return
      }
    }
    XCTAssertFalse(f.bridge.isDetachingEndpoint)
    XCTAssertEqual(f.client.registrations, 1)
  }
}

@MainActor final class ManagedTransferCloseRetirementTests: XCTestCase {
  func testRealRetiringBoundarySuspensionPreservesExactMovedBridgeUntilDetach() async throws {
    try await withBindingFixture(windows: 2) { f in
      let source = try XCTUnwrap(f.editors.first)
      let target = try XCTUnwrap(f.editors.last)
      let model = try XCTUnwrap(f.models.first)
      let owner = try XCTUnwrap(f.process)
      let endpoint = try XCTUnwrap(target.managedSearchTestFacts.endpointID)
      let bridge = try XCTUnwrap(model.fileState)
      let original = model.storage.string
      let generation = model.ownershipGeneration
      let request: ApplicationDocumentTransferID
      let outcome: ApplicationDocumentTransferResult
      do {
        request = try owner.moveDocument(model.id, toWindowID: target.sessionMetadata.id)
        outcome = try await owner.waitForTransfer(request)
      } catch {
        f.cleanupRefused = true
        throw error
      }
      guard case .moved = outcome else {
        XCTFail("Real moved prerequisite missing; retiring horizon UNENTERED")
        f.cleanupRefused = true
        throw BindingError.unsafe
      }
      XCTAssertTrue(owner.registry.handle(id: model.id) as? EditorDocument === model)
      XCTAssertEqual(owner.registry.assignment(of: model.id)?.windowID, target.sessionMetadata.id)
      XCTAssertNotEqual(model.ownershipGeneration, generation)
      XCTAssertFalse(source.managedSearchTestFacts.documentIDs.contains(model.id))
      XCTAssertTrue(target.managedSearchTestFacts.documentIDs.contains(model.id))
      guard owner.registry.handle(id: model.id) as? EditorDocument === model,
        owner.registry.assignment(of: model.id)?.windowID == target.sessionMetadata.id,
        model.ownershipGeneration != generation,
        !source.managedSearchTestFacts.documentIDs.contains(model.id),
        target.managedSearchTestFacts.documentIDs.contains(model.id), model.fileState === bridge,
        model.storage.string == original, !model.dirty
      else {
        f.cleanupRefused = true
        throw BindingError.unsafe
      }
      let assignment = try XCTUnwrap(owner.registry.assignment(of: model.id))
      let log = RepairRetirementLog()
      let previousMonitoring = f.monitoring.onStateChange
      f.monitoring.onStateChange = { [weak f] in
        previousMonitoring?()
        guard let f else { return }
        log.monitorNotifications += 1
        for editor in f.editors { editor.reconcileFileMonitoring() }
      }
      defer { f.monitoring.onStateChange = previousMonitoring }
      let stop = owner.repairTestObserveClosing {
        [weak f, weak owner, weak target, weak model, weak bridge] status in
        guard status.stage == .retiring, status.documentID == model?.id else { return }
        log.retiring += 1
        guard let f, let owner, let target, let model, let bridge else {
          XCTFail("Exact retiring fixture lost")
          log.unsafe = true
          return
        }
        let snapshot = RepairRetirementSnapshot(
          id: status.id, documentID: model.id,
          registryAbsent: owner.registry.handle(id: model.id) == nil
            && owner.registry.assignment(of: model.id) == nil,
          originalMember: target.managedSearchTestFacts.documentIDs.contains(model.id)
            && target.focusedPane?.document === model,
          originalBridge: model.fileState === bridge,
          originalEndpoint: target.managedSearchTestFacts.endpointID == endpoint
            && (try? target.requireEndpointIdentity(endpointID: endpoint, assignment: assignment))
              != nil,
          phase: bridge.isDetachingEndpoint,
          ordinaryNil: target.ordinaryFileStateContext(model) == nil,
          originalData: model.storage.string == original && !model.dirty)
        log.snapshots.append(snapshot)
        XCTAssertEqual(log.retiring, 1)
        XCTAssertEqual(owner.managedSearchTestCloseStatus?.id, status.id)
        XCTAssertTrue(snapshot.registryAbsent)
        XCTAssertTrue(snapshot.originalMember)
        XCTAssertTrue(snapshot.originalBridge)
        XCTAssertTrue(snapshot.originalEndpoint)
        XCTAssertFalse(snapshot.phase)
        XCTAssertTrue(snapshot.ordinaryNil)
        XCTAssertTrue(snapshot.originalData)
        guard log.retiring == 1, owner.managedSearchTestCloseStatus?.id == status.id,
          snapshot.registryAbsent, snapshot.originalMember, snapshot.originalBridge,
          snapshot.originalEndpoint, !snapshot.phase, snapshot.ordinaryNil, snapshot.originalData
        else {
          log.unsafe = true
          return
        }
        // Actual monitor transition invokes the chained controller reconciliation.
        f.monitoring.suspend()
        XCTAssertTrue(f.monitoring.isSuspended)
        XCTAssertEqual(log.monitorNotifications, 1)
        XCTAssertNil(target.ordinaryFileStateContext(model))
        XCTAssertFalse(bridge.isDetachingEndpoint)
        for action in FileConflictAction.allCases { XCTAssertNil(bridge.captureAction(action)) }
        XCTAssertTrue(model.fileState === bridge)
        XCTAssertEqual(model.storage.string, original)
        log.suspendReturned = true
      }
      defer { stop() }
      do { try await f.closeDocument(target, model) } catch {
        f.cleanupRefused = true
        throw error
      }
      XCTAssertEqual(log.retiring, 1)
      XCTAssertEqual(log.snapshots.count, 1)
      XCTAssertTrue(log.suspendReturned)
      XCTAssertFalse(log.unsafe)
      XCTAssertEqual(log.monitorNotifications, 1)
      XCTAssertFalse(bridge.isDetachingEndpoint)
      XCTAssertNil(
        target.ordinaryFileStateContext(model),
        "Removed native member never exposes closed identity")
      XCTAssertEqual(model.storage.string, original)
      XCTAssertEqual(f.providers, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertTrue(f.presented.isEmpty)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertTrue(f.backend.submissions.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      guard log.retiring == 1, log.snapshots.count == 1, log.suspendReturned, !log.unsafe,
        log.monitorNotifications == 1, !bridge.isDetachingEndpoint,
        target.ordinaryFileStateContext(model) == nil, model.storage.string == original
      else {
        f.cleanupRefused = true
        throw BindingError.unsafe
      }
      // Original withBindingFixture finish retains all other close/SDK/publication/fresh-reader gates.
    }
  }
}

@MainActor private final class RepairCancellationLog { var count = 0 }
@MainActor private final class RepairRetirementLog {
  var retiring = 0, monitorNotifications = 0
  var snapshots: [RepairRetirementSnapshot] = []
  var suspendReturned = false, unsafe = false
}
private struct RepairRetirementSnapshot {
  let id: DocumentClosingID, documentID: UUID
  let registryAbsent: Bool, originalMember: Bool, originalBridge: Bool, originalEndpoint: Bool
  let phase: Bool, ordinaryNil: Bool, originalData: Bool
}
@MainActor private final class RepairBridgeFixture {
  let client = RepairMonitorClient()
  var live = FileStateLiveContext(
    documentID: UUID(), ownershipGeneration: UUID(),
    bindingID: UUID(), baselineRevision: 1, url: URL(fileURLWithPath: "/synthetic/repair-phase"))
  var onContext: (() -> Void)?
  lazy var bridge = DocumentFileStateController(
    documentID: live.documentID, client: client,
    liveContext: { [weak self] in
      guard let self else { return nil }
      self.onContext?()
      return self.live
    }, onChange: {})
}
private final class RepairMonitorHandle: MonitorHandle, ManualHandle, @unchecked Sendable {
  var documentID = UUID(), baselineRevision: UInt64 = 1
  var cancellations = 0
  var onCancel: (@Sendable () -> Void)?
  var snapshot: MonitorSnapshot {
    .init(
      currentToken: nil, cancelled: cancellations > 0, documentID: documentID,
      epoch: 1, baselineRevision: baselineRevision, boundIdentity: nil)
  }
  func cancel() { _ = cancelAndSnapshot() }
  func cancelAndSnapshot() -> MonitorSnapshot {
    cancellations += 1
    let value = snapshot
    onCancel?()
    return value
  }
}
@MainActor private final class RepairMonitorClient: MonitorClient {
  var registrations = 0, requests = 0
  var handle = RepairMonitorHandle()
  func register(
    id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> any MonitorHandle {
    registrations += 1
    handle = RepairMonitorHandle()
    handle.documentID = id
    handle.baselineRevision = revision
    return handle
  }
  func rebind(id: UUID, url: URL, baseline: Data, revision: UInt64) throws {}
  func requestCheck(id: UUID) { requests += 1 }
  func checkOnce(
    requestID: UUID, id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void
  ) -> any ManualHandle {
    XCTFail("Unexpected manual check")
    return RepairMonitorHandle()
  }
}

// Additive Task4 prerequisite only: no App quit, transfer, helper or visible presentation.
@MainActor final class DocumentSearchQuitPresentationTests: XCTestCase {
  func testQuitPresentationRetirementWithoutChildStaysLazy() async throws {
    try await withBindingFixture { f in
      let editor = try XCTUnwrap(f.editors.first)
      let model = try XCTUnwrap(f.models.first)
      let before = editor.managedSearchTestFacts
      let state = try model.captureCloseState()
      let text = model.storage.string
      let revision = model.editRevision
      editor.retireManagedDocumentSearchForQuit()
      editor.retireManagedDocumentSearchForQuit()
      XCTAssertEqual(f.providers, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertTrue(f.presented.isEmpty)
      XCTAssertTrue(f.backend.registered.isEmpty)
      XCTAssertTrue(f.backend.unregistered.isEmpty)
      XCTAssertTrue(f.backend.submissions.isEmpty)
      XCTAssertEqual(f.backend.captures, 0)
      XCTAssertNil(editor.managedSearchTestPanel)
      XCTAssertNil(editor.managedSearchTestTicket)
      XCTAssertNil(editor.managedSearchTestFacts.recordIdentity)
      XCTAssertEqual(editor.managedSearchTestFacts.endpointID, before.endpointID)
      XCTAssertEqual(editor.managedSearchTestFacts.documentIDs, before.documentIDs)
      XCTAssertFalse(editor.managedSearchTestFacts.windowClosed)
      XCTAssertTrue(f.process?.registry.handle(id: model.id) as? EditorDocument === model)
      XCTAssertEqual(model.storage.string, text)
      XCTAssertEqual(model.editRevision, revision)
      XCTAssertEqual(try model.captureCloseState(), state)
      try f.requireClean(model)
      guard let panel = f.open(editor) else { return }
      _ = try f.result(panel)
      XCTAssertEqual(f.providers, 1)
      XCTAssertEqual(f.factoryCalls.count, 1)
      XCTAssertEqual(f.backend.registered.count, 1)
      XCTAssertEqual(f.backend.captures, 1)
    }
  }

  func testQuitPresentationRetiresOnlyOriginalChildAndPreservesLiveWindowTickets() async throws {
    try await withBindingFixture(windows: 2) { f in
      let a = try XCTUnwrap(f.editors.first)
      let b = try XCTUnwrap(f.editors.dropFirst().first)
      let ma = try XCTUnwrap(f.models.first)
      let mb = try XCTUnwrap(f.models.dropFirst().first)
      let sa = try ma.captureCloseState()
      let sb = try mb.captureCloseState()
      let ra = ma.editRevision
      let rb = mb.editRevision
      let taText = ma.storage.string
      let tbText = mb.storage.string
      guard let pa = f.open(a), let pb = f.open(b) else { return }
      let ta = try XCTUnwrap(a.managedSearchTestTicket)
      let tb = try XCTUnwrap(b.managedSearchTestTicket)
      let aRecord = try XCTUnwrap(a.managedSearchTestFacts.recordIdentity)
      let bRecord = try XCTUnwrap(b.managedSearchTestFacts.recordIdentity)
      let aCall = try XCTUnwrap(f.factoryCalls.first)
      let bCall = try XCTUnwrap(f.factoryCalls.dropFirst().first)
      let aRegistration = try f.backend.registration(0)
      let bRegistration = try f.backend.registration(1)
      let request = f.backend.submissions.count
      f.send(pa.testOnlyControls.replace)
      XCTAssertEqual(f.backend.submissions.count, request + 1)
      guard f.backend.submissions.count == request + 1 else { throw BindingError.missing }
      let captured = try f.backend.capture(request)
      XCTAssertEqual(captured.text, "😀x\n")
      let lease = f.backend.install(
        captured, matches: [NSRange(location: 2, length: 1)], replacement: "😀y\n")
      f.backend.deliver(request, .completed(lease))
      let approval = try XCTUnwrap(pa.testOnlyDisplayedApproval)
      XCTAssertEqual(pa.testOnlySessionState, .awaitingApproval(token: approval, matchCount: 1))
      let bCaptured = try f.result(pb)
      let bState = pb.testOnlySessionState
      let released = f.backend.released.count
      a.retireManagedDocumentSearchForQuit()
      // Required missing-behavior assertions precede all dependent later horizons.
      XCTAssertTrue(
        pa.testOnlyLogicallyClosed, "Quit presentation retirement must close the actual child")
      XCTAssertEqual(pa.testOnlySessionState, .closed)
      XCTAssertEqual(pa.testOnlyRenderedState, .closed)
      XCTAssertNil(pa.testOnlyDisplayedApproval)
      XCTAssertTrue(pa.testOnlyControls.approvalRow.isHidden)
      XCTAssertFalse(pa.testOnlyControls.find.isEnabled)
      XCTAssertFalse(pa.testOnlyControls.approve.isEnabled)
      XCTAssertNil(a.managedSearchTestPanel)
      XCTAssertNil(a.managedSearchTestFacts.originDocumentID)
      XCTAssertNil(a.managedSearchTestFacts.originPaneID)
      XCTAssertEqual(a.managedSearchTestFacts.recordIdentity, aRecord)
      XCTAssertEqual(a.managedSearchTestTicket, ta)
      XCTAssertEqual(f.backend.unregistered.filter { $0 == aRegistration }.count, 1)
      XCTAssertFalse(f.backend.unregistered.contains(bRegistration))
      XCTAssertEqual(f.backend.released.count, released + 1)
      XCTAssertTrue(f.backend.released.contains(lease))
      XCTAssertNil(f.backend.payloads[lease])
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      XCTAssertFalse(pb.testOnlyLogicallyClosed)
      XCTAssertEqual(b.managedSearchTestFacts.recordIdentity, bRecord)
      XCTAssertEqual(b.managedSearchTestTicket, tb)
      XCTAssertEqual(pb.testOnlySessionState, bState)
      XCTAssertTrue(bCall.source.isCurrent(expected: bCaptured.context))
      XCTAssertEqual(f.searchOwner.phase, .open)
      XCTAssertEqual(f.backend.shutdownCalls, 0)
      guard pa.testOnlyLogicallyClosed, pa.testOnlySessionState == .closed,
        a.managedSearchTestPanel == nil, pa.testOnlyDisplayedApproval == nil,
        f.backend.unregistered.filter({ $0 == aRegistration }).count == 1
      else {
        print("QUIT_PRESENTATION retirement missing; approval/reopen horizon UNENTERED")
        return
      }
      XCTAssertFalse(pa.testOnlyRespondToApproval(approval, approved: true))
      let afterClose = f.backend.unregistered.count
      let afterRelease = f.backend.released.count
      a.retireManagedDocumentSearchForQuit()
      XCTAssertEqual(f.backend.unregistered.count, afterClose)
      XCTAssertEqual(f.backend.released.count, afterRelease)
      XCTAssertEqual(a.managedSearchTestTicket, ta)
      XCTAssertEqual(a.managedSearchTestFacts.recordIdentity, aRecord)
      guard let fresh = f.open(a) else { return }
      XCTAssertFalse(fresh === pa)
      XCTAssertEqual(a.managedSearchTestTicket, ta)
      XCTAssertEqual(a.managedSearchTestFacts.recordIdentity, aRecord)
      let freshCall = try XCTUnwrap(f.factoryCalls.last)
      XCTAssertTrue(freshCall.owner === aCall.owner)
      XCTAssertEqual(freshCall.ticket, aCall.ticket)
      XCTAssertFalse((freshCall.source as AnyObject) === (aCall.source as AnyObject))
      XCTAssertNil(fresh.testOnlyDisplayedApproval)
      XCTAssertEqual(fresh.testOnlySessionState, .idle)
      aCall.onClose(pa)  // Deliberate stale callback probe, never an SDK close receipt.
      XCTAssertTrue(a.managedSearchTestPanel === fresh)
      XCTAssertFalse(fresh.testOnlyLogicallyClosed)
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      XCTAssertEqual(pb.testOnlySessionState, bState)
      XCTAssertEqual(f.providers, 3)
      XCTAssertEqual(f.factoryCalls.count, 3)
      XCTAssertEqual(f.presented.count, 3)
      XCTAssertEqual(ma.storage.string, taText)
      XCTAssertEqual(mb.storage.string, tbText)
      XCTAssertEqual(ma.editRevision, ra)
      XCTAssertEqual(mb.editRevision, rb)
      XCTAssertEqual(try ma.captureCloseState(), sa)
      XCTAssertEqual(try mb.captureCloseState(), sb)
      try f.requireClean(ma)
      try f.requireClean(mb)
    }
  }

  func testQuitPresentationCloseAndConstructorReentryCannotAdoptAChild() async throws {
    // Two finite separately cleaned fixtures; no asynchronous endpoint-close claim.
    for variant in 0..<2 {
      try await withBindingFixture { f in
        let editor = try XCTUnwrap(f.editors.first)
        let model = try XCTUnwrap(f.models.first)
        let text = model.storage.string
        let revision = model.editRevision
        let state = try model.captureCloseState()
        if variant == 0 {
          guard let panel = f.open(editor) else { return }
          _ = try f.result(panel)
          let ticket = try XCTUnwrap(editor.managedSearchTestTicket)
          let record = try XCTUnwrap(editor.managedSearchTestFacts.recordIdentity)
          let registration = try f.backend.registration(0)
          let providers = f.providers
          let factories = f.factoryCalls.count
          var entered = 0
          var clearedAtCallback = false
          var callbackClosed = false
          var sameRecordAtCallback = false
          var workUnchangedAtCallback = false
          var typedRefusal: ApplicationDocumentSearchFailure?
          var unexpected: Error?
          var returnedNormally = false
          f.backend.onRelease = { [weak editor, weak f, weak panel] _ in
            guard let editor, let f, let panel else {
              XCTFail("Actual callback lost owned fixture")
              return
            }
            entered += 1
            // Immutable factual snapshots at real release entry, before our reentry calls.
            clearedAtCallback =
              editor.managedSearchTestPanel == nil
              && editor.managedSearchTestFacts.originDocumentID == nil
              && editor.managedSearchTestFacts.originPaneID == nil
            callbackClosed =
              panel.testOnlyLogicallyClosed && panel.testOnlySessionState == .closed
              && panel.testOnlyRenderedState == .closed && panel.testOnlyDisplayedApproval == nil
            sameRecordAtCallback =
              editor.managedSearchTestFacts.recordIdentity == record
              && editor.managedSearchTestTicket == ticket
            // Recursive call may not release outer token.
            editor.retireManagedDocumentSearchForQuit()
            do {
              _ = try editor.managedSearchTestShow()
              returnedNormally = true
            } catch let error as ApplicationDocumentSearchFailure { typedRefusal = error } catch {
              unexpected = error
            }
            workUnchangedAtCallback = f.providers == providers && f.factoryCalls.count == factories
          }
          editor.retireManagedDocumentSearchForQuit()
          XCTAssertEqual(entered, 1, "Must enter the real backend release callback exactly once")
          XCTAssertTrue(clearedAtCallback)
          XCTAssertTrue(callbackClosed)
          XCTAssertTrue(sameRecordAtCallback)
          XCTAssertTrue(workUnchangedAtCallback)
          XCTAssertFalse(returnedNormally)
          XCTAssertEqual(typedRefusal, .sourceUnavailable)
          XCTAssertNil(unexpected)
          XCTAssertTrue(panel.testOnlyLogicallyClosed)
          XCTAssertNil(editor.managedSearchTestPanel)
          XCTAssertEqual(f.backend.unregistered.filter { $0 == registration }.count, 1)
          XCTAssertEqual(editor.managedSearchTestTicket, ticket)
          XCTAssertEqual(editor.managedSearchTestFacts.recordIdentity, record)
          guard entered == 1, clearedAtCallback, callbackClosed, sameRecordAtCallback,
            workUnchangedAtCallback, typedRefusal == .sourceUnavailable, unexpected == nil,
            panel.testOnlyLogicallyClosed, editor.managedSearchTestPanel == nil
          else {
            print("QUIT_PRESENTATION actual release/reentry horizon UNENTERED")
            return
          }
          guard let fresh = f.open(editor) else { return }
          XCTAssertFalse(fresh === panel)
          XCTAssertEqual(editor.managedSearchTestTicket, ticket)
          XCTAssertEqual(f.providers, providers + 1)
          XCTAssertEqual(f.factoryCalls.count, factories + 1)
          XCTAssertEqual(f.presented.count, 2)
        } else {
          f.factoryHook = { [weak editor] index, call in
            guard index == 0, let editor else { return nil }
            let child = try call.construct()  // Actual child/consumer, never a lifecycle stand-in.
            editor.retireManagedDocumentSearchForQuit()
            return child
          }
          let returned = try editor.managedSearchTestShow()
          XCTAssertEqual(f.factoryCalls.count, 1)
          let call = try XCTUnwrap(f.factoryCalls.first)
          let child = try XCTUnwrap(call.panel)
          let ticket = try XCTUnwrap(editor.managedSearchTestTicket)
          let record = try XCTUnwrap(editor.managedSearchTestFacts.recordIdentity)
          XCTAssertNil(returned, "Retirement must burn the still-executing factory attempt")
          XCTAssertNil(editor.managedSearchTestPanel)
          XCTAssertTrue(child.testOnlyLogicallyClosed)
          XCTAssertEqual(child.testOnlySessionState, .closed)
          XCTAssertTrue(f.presented.isEmpty)
          XCTAssertEqual(f.backend.unregistered.count, 1)
          guard returned == nil, editor.managedSearchTestPanel == nil,
            child.testOnlyLogicallyClosed,
            child.testOnlySessionState == .closed, f.presented.isEmpty
          else {
            print("QUIT_PRESENTATION constructor retirement missing; later Find horizon UNENTERED")
            return
          }
          f.factoryHook = nil
          guard let fresh = f.open(editor) else { return }
          XCTAssertFalse(fresh === child)
          XCTAssertEqual(editor.managedSearchTestTicket, ticket)
          XCTAssertEqual(editor.managedSearchTestFacts.recordIdentity, record)
          XCTAssertEqual(f.providers, 2)
          XCTAssertEqual(f.factoryCalls.count, 2)
          XCTAssertEqual(f.presented.count, 1)
        }
        XCTAssertEqual(model.storage.string, text)
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertEqual(try model.captureCloseState(), state)
        try f.requireClean(model)
        XCTAssertEqual(f.searchOwner.phase, .open)
        XCTAssertEqual(f.backend.shutdownCalls, 0)
      }
    }
  }

  func testQuitPresentationRetiredEndpointCannotBeRevivedByLateCallbacks() async throws {
    try await withBindingFixture(windows: 2) { f in
      let a = try XCTUnwrap(f.editors.first)
      let b = try XCTUnwrap(f.editors.dropFirst().first)
      let original = try XCTUnwrap(f.models.first)
      let sibling = try XCTUnwrap(f.models.dropFirst().first)
      let siblingState = try sibling.captureCloseState()
      let siblingRevision = sibling.editRevision
      guard let pa = f.open(a), let pb = f.open(b) else { return }
      let ticket = try XCTUnwrap(a.managedSearchTestTicket)
      let call = try XCTUnwrap(f.factoryCalls.first)
      let bRecord = try XCTUnwrap(b.managedSearchTestFacts.recordIdentity)
      let bTicket = try XCTUnwrap(b.managedSearchTestTicket)
      let bResult = try f.result(pb)
      let bState = pb.testOnlySessionState
      _ = try f.result(pa)
      a.retireManagedDocumentSearchForQuit()
      XCTAssertTrue(pa.testOnlyLogicallyClosed)
      XCTAssertEqual(pa.testOnlySessionState, .closed)
      XCTAssertNil(a.managedSearchTestPanel)
      XCTAssertEqual(a.managedSearchTestTicket, ticket)
      guard pa.testOnlyLogicallyClosed, pa.testOnlySessionState == .closed,
        a.managedSearchTestPanel == nil, a.managedSearchTestTicket == ticket
      else {
        print("QUIT_PRESENTATION retirement missing; real endpoint-close horizon UNENTERED")
        return
      }
      try await f.closeDocument(a, original)  // Real clean managed close/status/join, no transfer.
      // Real empty-window SDK notification and actual Source endpoint retirement.
      try f.closeEmptyWindow(a)
      XCTAssertNil(a.managedSearchTestTicket)
      XCTAssertNil(a.managedSearchTestFacts.recordIdentity)
      XCTAssertTrue(a.managedSearchTestFacts.windowClosed)
      let unregisterCount = f.backend.unregistered.count
      call.onClose(pa)
      call.onClose(pb)  // Saved stale/wrong-child callbacks only after actual endpoint closure.
      a.retireManagedDocumentSearchForQuit()
      a.retireManagedDocumentSearchForQuit()
      XCTAssertNil(a.managedSearchTestPanel)
      XCTAssertNil(a.managedSearchTestTicket)
      XCTAssertNil(a.managedSearchTestFacts.recordIdentity)
      XCTAssertEqual(f.backend.unregistered.count, unregisterCount)
      do {
        let accidental = try f.searchOwner.attachDocument(
          window: ticket, source: call.source, onDelivery: { _ in })
        accidental.close()
        XCTFail("Genuinely closed endpoint must reject its old actual ticket")
      } catch let error as ApplicationDocumentSearchFailure {
        XCTAssertEqual(error, .staleWindow)
      } catch {
        XCTFail("Wrong old-ticket refusal: \(error)")
        throw error
      }
      XCTAssertTrue(b.managedSearchTestPanel === pb)
      XCTAssertFalse(pb.testOnlyLogicallyClosed)
      XCTAssertEqual(b.managedSearchTestFacts.recordIdentity, bRecord)
      XCTAssertEqual(b.managedSearchTestTicket, bTicket)
      XCTAssertEqual(pb.testOnlySessionState, bState)
      let liveB = try XCTUnwrap(f.factoryCalls.dropFirst().first)
      XCTAssertTrue(liveB.source.isCurrent(expected: bResult.context))
      XCTAssertEqual(sibling.storage.string, bResult.text)
      XCTAssertEqual(sibling.editRevision, siblingRevision)
      XCTAssertEqual(try sibling.captureCloseState(), siblingState)
      try f.requireClean(sibling)
      XCTAssertFalse(b.managedSearchTestFacts.windowClosed)
      XCTAssertEqual(f.searchOwner.phase, .open)
      XCTAssertEqual(f.backend.shutdownCalls, 0)
    }
  }
}
