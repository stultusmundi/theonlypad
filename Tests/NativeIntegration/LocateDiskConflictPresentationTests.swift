import AppKit
import Darwin
import Foundation
import XCTest

@testable import NativeRouting
@testable import PadCore

private enum LocateCharacterizationError: Error { case missing, unsafe, bound }

// PRIVATE OBSERVATION ONLY: fixed stages and bounded dynamic type, never error values.
@MainActor private enum LocateSetupDiagnostic {
  static func mark(_ literal: StaticString) { print(literal) }
  static func threw(_ stage: StaticString, _ error: Error) {
    let name = String(reflecting: type(of: error))
    guard name.utf8.count <= 256, !name.contains("\n"), !name.contains("\r") else {
      print("LOCATE_SETUP \(stage) THREW type=UNRECORDED")
      return
    }
    print("LOCATE_SETUP \(stage) THREW type=\(name)")
  }
}

// Scheduling collaborator only: never changes a production token, result or permission.
private final class LocateDeliveryGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var armed = false
  private var released = false
  private var entries = 0
  private var expired = false
  func arm() throws {
    condition.lock()
    defer { condition.unlock() }
    guard !armed, !released, entries == 0 else { throw LocateCharacterizationError.unsafe }
    armed = true
  }
  func beforeDelivery() {
    condition.lock()
    defer { condition.unlock() }
    guard armed, !released else { return }
    guard entries < 2 else {
      expired = true
      return
    }
    entries += 1
    let deadline = Date().addingTimeInterval(8)
    while !released {
      if !condition.wait(until: deadline) {
        expired = true
        break
      }
    }
  }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
  var facts: (entries: Int, expired: Bool, released: Bool) {
    condition.lock()
    defer { condition.unlock() }
    return (entries, expired, released)
  }
}

@MainActor private enum LocateCharacterizationCustody {
  private static var fixture: LocateCharacterizationFixture?
  static func requireEmpty() throws {
    guard fixture == nil else {
      XCTFail("Previous exact fixture remains retained; next case UNENTERED")
      throw LocateCharacterizationError.unsafe
    }
  }
  static func retain(_ value: LocateCharacterizationFixture) {
    guard fixture == nil || fixture === value else {
      XCTFail("One-slot custody overflow")
      return
    }
    fixture = value
  }
}

@MainActor private final class LocateWindowCloseReceipt {
  weak var window: NSWindow?
  var count = 0
  var exact = true
  init(_ window: NSWindow) { self.window = window }
  func receive(_ note: Notification) {
    count += 1
    exact = exact && (note.object as? NSWindow) === window
    XCTAssertLessThanOrEqual(count, 1)
  }
}

@MainActor private final class LocateCharacterizationFixture {
  let directory: URL, original: URL, moved: URL, recoveryDirectory: URL
  let directoryIdentity: (device: dev_t, inode: ino_t)
  let bytes = Data("tiny managed locate\n".utf8)
  let store: SessionStore, recovery: RecoveryCoordinator, session: SessionCoordinator
  let gate: LocateDeliveryGate, service: FileMonitorService, monitoring: ApplicationFileMonitoring
  var owner: NativeApplicationDocuments?
  var editor: EditorWindowController?
  var model: EditorDocument?
  var panels: [DocumentDiskConflictController] = []
  var errors: [NSError] = []
  var chooserCalls = 0
  var expectedErrors = 0
  var chooserOriginal: URL?
  var capturedText: String?
  var capturedRevision: UInt64?
  var capturedSession: SessionWindow?
  var capturedAssignment: DocumentAssignment?
  var capturedCanUndo = false, capturedCanRedo = false
  var modelWasMoved = false

  init() throws {
    try LocateCharacterizationCustody.requireEmpty()
    _ = NSApplication.shared
    guard let root = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !root.isEmpty
    else { throw LocateCharacterizationError.missing }
    var rootInfo = stat()
    guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
      rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o777 == 0o700
    else { throw LocateCharacterizationError.unsafe }
    directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(
      "locate-token-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    var created = stat()
    guard lstat(directory.path, &created) == 0, created.st_mode & S_IFMT == S_IFDIR,
      created.st_uid == getuid(), created.st_mode & 0o777 == 0o700
    else { throw LocateCharacterizationError.unsafe }
    directoryIdentity = (created.st_dev, created.st_ino)
    original = directory.appendingPathComponent("original.txt")
    moved = directory.appendingPathComponent("moved.txt")
    recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    self.recovery = recovery
    session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    let gate = LocateDeliveryGate()
    self.gate = gate
    var hooks = MonitorHooks()
    hooks.beforeDelivery = { gate.beforeDelivery() }
    let service = FileMonitorService(hooks: hooks)
    self.service = service
    monitoring = ApplicationFileMonitoring(service: service)
  }

  func wait(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    let traceInitialSleep = label == "Real initial accepted monitor observation"
    var firstSleepObserved = false
    while !predicate(), Date() < deadline {
      let traceThisSleep = traceInitialSleep && !firstSleepObserved
      if traceThisSleep {
        LocateSetupDiagnostic.mark("LOCATE_SETUP monitorSleep BEGIN")
        firstSleepObserved = true
      }
      do { try await Task.sleep(for: .milliseconds(2)) } catch {
        if traceInitialSleep { LocateSetupDiagnostic.threw("monitorSleep", error) }
        throw error
      }
      if traceThisSleep { LocateSetupDiagnostic.mark("LOCATE_SETUP monitorSleep END") }
    }
    XCTAssertTrue(predicate(), label)
    guard predicate() else { throw LocateCharacterizationError.missing }
  }

  func start() async throws {
    try bytes.write(to: original, options: .atomic)
    let tab = SessionTab(originalPath: original.path)
    let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
    try store.save(EditorSession(windows: [window]))
    let process = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: monitoring,
      onWindowCreated: { _ in },
      onError: { [weak self] error in
        guard let self else { return }
        self.errors.append(error as NSError)
        XCTAssertLessThanOrEqual(self.errors.count, 4, "Bounded actual error callback")
      })
    owner = process
    LocateSetupDiagnostic.mark("LOCATE_SETUP processStart BEGIN")
    do {
      try await process.start()
    } catch {
      LocateSetupDiagnostic.threw("processStart", error)
      throw error
    }
    LocateSetupDiagnostic.mark("LOCATE_SETUP processStart END")
    let projections = try process.registry.captureReadyWindows()
    XCTAssertEqual(projections.count, 1)
    XCTAssertEqual(process.windows.count, 1)
    guard projections.count == 1, process.windows.count == 1,
      session.restorationComplete, session.unresolved.isEmpty,
      let projection = projections.first, projection.groups.count == 1,
      let group = projection.groups.first, group.documentIDs == [tab.id],
      let controller = process.windows.first
    else { throw LocateCharacterizationError.missing }
    editor = controller
    let document = try XCTUnwrap(process.registry.handle(id: tab.id) as? EditorDocument)
    model = document
    let nativeWindow = try XCTUnwrap(controller.window)
    XCTAssertFalse(nativeWindow.isVisible)
    XCTAssertNotNil(controller.managedSearchTestFacts.endpointID)
    XCTAssertEqual(controller.managedSearchTestFacts.documentIDs, [document.id])
    guard !nativeWindow.isVisible, controller.managedSearchTestFacts.endpointID != nil,
      controller.managedSearchTestFacts.documentIDs == [document.id],
      !controller.managedSearchTestFacts.windowClosed
    else { throw LocateCharacterizationError.unsafe }
    try requireClean(document)
    let initial = try document.captureAuthorizedRecovery()
    XCTAssertNil(initial.snapshot)
    guard initial.snapshot == nil, initial.authority == document.recoveryAuthority,
      initial.revision > 0, initial.revision == document.highestIssuedRecoveryRevision
    else { throw LocateCharacterizationError.unsafe }
    LocateSetupDiagnostic.mark("LOCATE_SETUP initialRecoveryPersist BEGIN")
    do {
      try await recovery.persistAuthorizedBatch([initial])
    } catch {
      LocateSetupDiagnostic.threw("initialRecoveryPersist", error)
      throw error
    }
    LocateSetupDiagnostic.mark("LOCATE_SETUP initialRecoveryPersist END")
    let bridge = try XCTUnwrap(document.fileState)
    LocateSetupDiagnostic.mark("LOCATE_SETUP initialMonitorWait BEGIN")
    do {
      try await wait("Real initial accepted monitor observation") {
        bridge.state.observation?.content == .matchesBaseline && self.monitorSettled(bridge)
      }
    } catch {
      LocateSetupDiagnostic.threw("initialMonitorWait", error)
      throw error
    }
    LocateSetupDiagnostic.mark("LOCATE_SETUP initialMonitorWait END")
    // Real native mutation and Undo establish an actual redo receipt; no group repair or flag writes.
    LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoPreparation BEGIN")
    let native = document.undoManager
    do {
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeBeginUndoGrouping BEGIN")
      native.beginUndoGrouping()
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeBeginUndoGrouping END")
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeInsertText BEGIN")
      document.editor.insertText(
        "!", replacementRange: NSRange(location: document.storage.length, length: 0))
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeInsertText END")
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeEndUndoGrouping BEGIN")
      native.endUndoGrouping()
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeEndUndoGrouping END")
      XCTAssertTrue(native.canUndo)
      guard native.canUndo else {
        LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoAdmission REFUSED canUndoFalse")
        throw LocateCharacterizationError.unsafe
      }
      guard !native.isUndoing else {
        LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoAdmission REFUSED isUndoing")
        throw LocateCharacterizationError.unsafe
      }
      guard !native.isRedoing else {
        LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoAdmission REFUSED isRedoing")
        throw LocateCharacterizationError.unsafe
      }
      let diagnosticGroupingLevel = native.groupingLevel
      guard diagnosticGroupingLevel == 0 || diagnosticGroupingLevel == 1 else {
        LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoAdmission REFUSED groupLevelOther")
        throw LocateCharacterizationError.unsafe
      }
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndo BEGIN")
      native.undo()
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndo END")
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeRequireClean BEGIN")
      try requireClean(document)
      LocateSetupDiagnostic.mark("LOCATE_SETUP nativeRequireClean END")
      XCTAssertTrue(native.canRedo)
      XCTAssertEqual(document.storage.string, String(decoding: bytes, as: UTF8.self))
      guard native.canRedo, document.storage.string == String(decoding: bytes, as: UTF8.self) else {
        throw LocateCharacterizationError.unsafe
      }
    } catch {
      LocateSetupDiagnostic.threw("nativeUndoPreparation", error)
      throw error
    }
    LocateSetupDiagnostic.mark("LOCATE_SETUP nativeUndoPreparation END")
    LocateSetupDiagnostic.mark("LOCATE_SETUP moveItem BEGIN")
    do {
      try FileManager.default.moveItem(at: original, to: moved)
    } catch {
      LocateSetupDiagnostic.threw("moveItem", error)
      throw error
    }
    LocateSetupDiagnostic.mark("LOCATE_SETUP moveItem END")
    modelWasMoved = true
    service.requestCheck(documentID: document.id)
    try await wait("Real missing observation and idle callback boundary") {
      bridge.state.observation?.locationProblem == .missing && self.monitorSettled(bridge)
        && bridge.captureAction(.locate) != nil
    }
    capturedText = document.storage.string
    capturedRevision = document.editRevision
    capturedSession = controller.sessionMetadata
    capturedAssignment = process.registry.assignment(of: document.id)
    capturedCanUndo = native.canUndo
    capturedCanRedo = native.canRedo
    controller.chooseDiskLocation = { [weak self] suggested in
      guard let self else { return nil }
      self.chooserCalls += 1
      self.chooserOriginal = suggested
      XCTAssertLessThanOrEqual(self.chooserCalls, 1)
      return nil  // Existing chooser collaborator: Cancel, no modal UI or filesystem adoption.
    }
    try assertPreserved()
  }

  func monitorSettled(_ bridge: DocumentFileStateController) -> Bool {
    let d = service.diagnostics
    return d.workers == 0 && d.pendingCallbacks == 0 && d.pendingManualCallbacks == 0
      && bridge.state.token != nil
      && bridge.state.token == bridge.monitorHarnessReceipt?.currentToken
  }

  func requireClean(_ document: EditorDocument) throws {
    let state = try document.captureCloseState()
    let native = document.undoManager
    XCTAssertFalse(document.dirty)
    guard !document.dirty, !state.isDirty, !state.hasPendingPublication,
      !state.hasPendingTextEdits, !state.isComposing, state.operationID == nil,
      !native.isUndoing, !native.isRedoing, native.groupingLevel == 0
    else { throw LocateCharacterizationError.unsafe }
  }

  func assertPreserved() throws {
    let document = try XCTUnwrap(model)
    let controller = try XCTUnwrap(editor)
    let process = try XCTUnwrap(owner)
    try requireClean(document)
    XCTAssertEqual(document.storage.string, capturedText)
    XCTAssertEqual(document.editRevision, capturedRevision)
    XCTAssertEqual(document.originalBytes, bytes)
    XCTAssertEqual(document.url, original)
    XCTAssertEqual(document.undoManager.canUndo, capturedCanUndo)
    XCTAssertEqual(document.undoManager.canRedo, capturedCanRedo)
    XCTAssertEqual(controller.sessionMetadata, capturedSession)
    XCTAssertEqual(process.registry.assignment(of: document.id), capturedAssignment)
    XCTAssertTrue(process.registry.handle(id: document.id) as? EditorDocument === document)
    XCTAssertEqual(try Data(contentsOf: moved), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    XCTAssertFalse(controller.window?.isVisible ?? true)
    guard document.storage.string == capturedText, document.editRevision == capturedRevision,
      document.originalBytes == bytes, document.url == original,
      document.undoManager.canUndo == capturedCanUndo,
      document.undoManager.canRedo == capturedCanRedo,
      controller.sessionMetadata == capturedSession,
      process.registry.assignment(of: document.id) == capturedAssignment,
      process.registry.handle(id: document.id) as? EditorDocument === document,
      try Data(contentsOf: moved) == bytes,
      !FileManager.default.fileExists(atPath: original.path), controller.window?.isVisible == false
    else { throw LocateCharacterizationError.unsafe }
  }

  func panelAndButton() throws -> (DocumentDiskConflictController, NSButton) {
    guard panels.count < 3 else { throw LocateCharacterizationError.bound }
    let controller = try XCTUnwrap(editor)
    let document = try XCTUnwrap(model)
    let panel = try XCTUnwrap(controller.monitorHarnessDiskConflict(document))
    panels.append(panel)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let content = try XCTUnwrap(panel.window?.contentView)
    let buttons = descendants(content).compactMap { $0 as? NSButton }
      .filter { $0.accessibilityIdentifier() == "document.locateFile" }
    XCTAssertEqual(buttons.count, 1)
    guard buttons.count == 1, let button = buttons.first, button.isEnabled,
      panel.window?.isVisible == false
    else { throw LocateCharacterizationError.missing }
    return (panel, button)
  }

  func checkErrors(_ expected: Int) throws {
    XCTAssertEqual(errors.count, expected)
    XCTAssertTrue(errors.allSatisfy { $0.domain == "TheOnlyPad" && $0.code == 24 })
    guard errors.count == expected,
      errors.allSatisfy({ $0.domain == "TheOnlyPad" && $0.code == 24 })
    else { throw LocateCharacterizationError.unsafe }
  }

  func finish() async throws {
    gate.release()  // Release before every stop/retirement, including failures.
    for panel in panels { panel.close() }
    let process = try XCTUnwrap(owner)
    let controller = try XCTUnwrap(editor)
    let document = try XCTUnwrap(model)
    controller.chooseDiskLocation = nil
    try requireClean(document)
    try checkErrors(expectedErrors)
    // Independently exercise the preserved real inverse before normal clean close.
    let native = document.undoManager
    XCTAssertTrue(native.canRedo)
    guard native.canRedo else { throw LocateCharacterizationError.unsafe }
    native.redo()
    XCTAssertEqual(document.storage.string, String(decoding: bytes, as: UTF8.self) + "!")
    guard document.storage.string == String(decoding: bytes, as: UTF8.self) + "!",
      native.canUndo, !native.isUndoing, !native.isRedoing
    else { throw LocateCharacterizationError.unsafe }
    let finishUndoGroupingLevel = native.groupingLevel
    guard finishUndoGroupingLevel == 0 || finishUndoGroupingLevel == 1 else {
      throw LocateCharacterizationError.unsafe
    }
    native.undo()
    try requireClean(document)
    XCTAssertEqual(document.storage.string, String(decoding: bytes, as: UTF8.self))
    guard document.storage.string == String(decoding: bytes, as: UTF8.self) else {
      throw LocateCharacterizationError.unsafe
    }
    controller.selectSessionTab(document.id)
    guard controller.selectedDocumentID == document.id,
      process.registry.handle(id: document.id) as? EditorDocument === document
    else { throw LocateCharacterizationError.unsafe }
    let text = document.storage.string
    let revision = document.editRevision
    let state = try document.captureCloseState()
    controller.execute("file.close")
    let started = try XCTUnwrap(process.managedSearchTestCloseStatus)
    let joined = try await process.managedSearchTestWaitClose(started.id)
    let settled = try XCTUnwrap(joined.status)
    guard case .completed(let ids) = joined.result else { throw LocateCharacterizationError.unsafe }
    XCTAssertEqual(ids, [document.id])
    XCTAssertNil(process.registry.handle(id: document.id))
    XCTAssertEqual(document.storage.string, text)
    XCTAssertEqual(document.editRevision, revision)
    XCTAssertEqual(try document.captureCloseState(), state)
    guard ids == [document.id], settled.id == started.id, settled.stage == .settled,
      !settled.recoveryPaused, settled.error == nil,
      process.registry.handle(id: document.id) == nil,
      controller.managedSearchTestFacts.documentIDs.isEmpty,
      controller.sessionMetadata.tabs.isEmpty,
      document.storage.string == text, document.editRevision == revision,
      try document.captureCloseState() == state
    else { throw LocateCharacterizationError.unsafe }
    let window = try XCTUnwrap(controller.window)
    let windowID = controller.sessionMetadata.id
    guard process.registry.window(id: windowID) != nil else {
      throw LocateCharacterizationError.unsafe
    }
    let receipt = LocateWindowCloseReceipt(window)
    let observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: nil
    ) { [weak receipt] note in MainActor.assumeIsolated { receipt?.receive(note) } }
    window.close()
    NotificationCenter.default.removeObserver(observer)
    XCTAssertEqual(receipt.count, 1)
    XCTAssertTrue(receipt.exact)
    guard receipt.count == 1, receipt.exact, controller.managedSearchTestFacts.windowClosed,
      process.registry.window(id: windowID) == nil,
      process.registry.closedHistoryCount(windowID: windowID) == 0, process.windows.isEmpty,
      try process.registry.captureReadyWindows().isEmpty
    else { throw LocateCharacterizationError.unsafe }
    let final = try await process.prepareQuit()
    let fresh = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    XCTAssertTrue(fresh.windows.isEmpty)
    XCTAssertTrue(report.snapshots.isEmpty)
    guard final.recoveryAuthorities.isEmpty, final.recoveryRevisions.isEmpty,
      fresh.windows.isEmpty, report.snapshots.isEmpty, report.quarantinedCount == 0
    else { throw LocateCharacterizationError.unsafe }
    monitoring.stop()
    try await wait("Real monitor cleanup after released delivery gate") {
      let d = self.service.diagnostics
      return d.workers == 0 && d.watchReservations == 0
        && d.pendingCallbacks == 0 && d.pendingManualCallbacks == 0
    }
    try checkErrors(expectedErrors)
    guard modelWasMoved, try Data(contentsOf: moved) == bytes,
      !FileManager.default.fileExists(atPath: original.path)
    else { throw LocateCharacterizationError.unsafe }
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
      info.st_dev == directoryIdentity.device, info.st_ino == directoryIdentity.inode
    else { throw LocateCharacterizationError.unsafe }
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}

@MainActor private func withLocateCharacterization(
  _ body: @MainActor (LocateCharacterizationFixture) async throws -> Void
) async throws {
  let fixture = try LocateCharacterizationFixture()
  do { try await fixture.start() } catch {
    fixture.gate.release()
    LocateCharacterizationCustody.retain(fixture)
    throw error
  }
  var primary: Error?
  do { try await body(fixture) } catch { primary = error }
  fixture.gate.release()
  do { try await fixture.finish() } catch {
    LocateCharacterizationCustody.retain(fixture)
    XCTFail("Separate actual managed cleanup refused; exact fixture and files retained")
    throw primary ?? error
  }
  if let primary { throw primary }
}

@MainActor final class ManagedLocateTokenCharacterizationTests: XCTestCase {
  func testManagedUnchangedTokenLocateCancelPreservesDocument() async throws {
    try await withLocateCharacterization { f in
      let bridge = try XCTUnwrap(f.model?.fileState)
      let context = try XCTUnwrap(bridge.captureAction(.locate))
      let (panel, button) = try f.panelAndButton()
      XCTAssertTrue(bridge.isCurrent(context))
      guard bridge.isCurrent(context) else { throw LocateCharacterizationError.missing }
      let expectedHint = bridge.state.observation?.movedCandidate ?? f.original
      button.performClick(nil)
      XCTAssertEqual(f.chooserOriginal, expectedHint)
      XCTAssertEqual(f.chooserCalls, 1)
      XCTAssertFalse(panel.window?.isVisible ?? true)
      try f.checkErrors(0)
      guard f.chooserCalls == 1 else { throw LocateCharacterizationError.missing }
      try f.assertPreserved()
      print("LOCATE_TOKEN unchanged actualManagedChooserCancelReached")
    }
  }

  func testManagedRetainedTokenRefusesBeforeAndAfterDeliveryFreshPanelCancels() async throws {
    try await withLocateCharacterization { f in
      let document = try XCTUnwrap(f.model)
      let bridge = try XCTUnwrap(document.fileState)
      let first = try XCTUnwrap(bridge.captureAction(.locate))
      let (_, beforeButton) = try f.panelAndButton()
      let (_, afterButton) = try f.panelAndButton()
      XCTAssertTrue(bridge.isCurrent(first))
      guard bridge.isCurrent(first) else { throw LocateCharacterizationError.missing }
      try f.gate.arm()
      f.service.requestCheck(documentID: document.id)
      try await f.wait("Actual second service delivery held, before bridge adoption") {
        f.gate.facts.entries == 1 && !f.gate.facts.expired
          && bridge.monitorHarnessReceipt?.currentToken != first.token
      }
      let second = try XCTUnwrap(bridge.monitorHarnessReceipt?.currentToken)
      XCTAssertEqual(bridge.state.token, first.token)
      XCTAssertNotEqual(second, first.token)
      XCTAssertFalse(bridge.isCurrent(first))
      guard bridge.state.token == first.token, second != first.token,
        !bridge.isCurrent(first), !f.gate.facts.expired
      else { throw LocateCharacterizationError.missing }
      f.expectedErrors = 1
      beforeButton.performClick(nil)
      try f.checkErrors(1)
      XCTAssertEqual(f.chooserCalls, 0)
      guard f.chooserCalls == 0, bridge.state.token == first.token,
        bridge.monitorHarnessReceipt?.currentToken == second, !f.gate.facts.expired
      else { throw LocateCharacterizationError.unsafe }
      try f.assertPreserved()
      print("LOCATE_TOKEN held actualOldPanelRefusedBeforeDelivery")
      f.gate.release()
      try await f.wait("The same second token accepted after genuine delivery") {
        bridge.state.token == second && f.monitorSettled(bridge)
      }
      let freshContext = try XCTUnwrap(bridge.captureAction(.locate))
      XCTAssertEqual(freshContext.live, first.live)
      XCTAssertEqual(freshContext.authorityID, first.authorityID)
      XCTAssertEqual(freshContext.token, second)
      XCTAssertFalse(bridge.isCurrent(first))
      guard freshContext.live == first.live, freshContext.authorityID == first.authorityID,
        freshContext.token == second, !bridge.isCurrent(first), !f.gate.facts.expired,
        f.gate.facts.entries == 1
      else { throw LocateCharacterizationError.missing }
      f.expectedErrors = 2
      afterButton.performClick(nil)
      try f.checkErrors(2)
      XCTAssertEqual(f.chooserCalls, 0)
      guard f.chooserCalls == 0 else { throw LocateCharacterizationError.unsafe }
      try f.assertPreserved()
      let (_, freshButton) = try f.panelAndButton()
      guard bridge.isCurrent(freshContext) else { throw LocateCharacterizationError.missing }
      let expectedHint = bridge.state.observation?.movedCandidate ?? f.original
      freshButton.performClick(nil)
      XCTAssertEqual(f.chooserOriginal, expectedHint)
      XCTAssertEqual(f.chooserCalls, 1)
      try f.checkErrors(2)
      guard f.chooserCalls == 1 else { throw LocateCharacterizationError.missing }
      try f.assertPreserved()
      print("LOCATE_TOKEN delivered oldPanelRefusedAndFreshManagedChooserCancelReached")
    }
  }
}

// New owner-presentation tests. Old two methods/fixture above remain byte-for-byte accepted.
@MainActor private struct LocatePresentationRecoveryFacts {
  let authority: RecoveryWriteAuthority?
  let revision: UInt64
  init(_ document: EditorDocument) {
    authority = document.recoveryAuthority
    revision = document.highestIssuedRecoveryRevision
  }
  func assertUnchanged(_ document: EditorDocument) {
    XCTAssertEqual(document.recoveryAuthority, authority)
    XCTAssertEqual(document.highestIssuedRecoveryRevision, revision)
  }
}

// An actual-notification receipt; its one-shot guard only bounds callback recursion.
@MainActor private final class LocatePresentationCloseReentry {
  private(set) var handled = false
  private(set) var successor: DocumentDiskConflictController?
  private let fixture: LocateCharacterizationFixture
  private let controller: EditorWindowController
  private let document: EditorDocument
  init(
    _ fixture: LocateCharacterizationFixture, controller: EditorWindowController,
    document: EditorDocument
  ) {
    self.fixture = fixture
    self.controller = controller
    self.document = document
  }
  func receive() {
    guard !handled else { return }
    handled = true
    successor = controller.locatePresentationTestInstallNoShow(document)
    if let successor { fixture.panels.append(successor) }
  }
}

@MainActor final class LocateDiskConflictPresentationTests: XCTestCase {
  private let staleNotice =
    "The file status changed. No file action was applied. Use Check Again, then close and reopen Resolve for current actions."

  private func installed(_ f: LocateCharacterizationFixture) throws
    -> DocumentDiskConflictController
  {
    let controller = try XCTUnwrap(f.editor)
    let document = try XCTUnwrap(f.model)
    XCTAssertLessThan(f.panels.count, 3)
    guard f.panels.count < 3 else { throw LocateCharacterizationError.bound }
    let panel = try XCTUnwrap(controller.locatePresentationTestInstallNoShow(document))
    f.panels.append(panel)
    XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === panel)
    XCTAssertEqual(controller.locatePresentationTestOwnerFacts.documentID, document.id)
    XCTAssertEqual(
      controller.locatePresentationTestOwnerFacts.token, document.fileState?.state.token)
    XCTAssertNotNil(controller.locatePresentationTestOwnerFacts.binding)
    XCTAssertFalse(panel.window?.isVisible ?? true)
    return panel
  }

  // A real extra scratch intake and real managed close, never a selectedID field write.
  // All body outcomes, including failed inert transition assertions, finish this cleanup.
  private func withAnotherSelectedTab(
    _ f: LocateCharacterizationFixture,
    _ body: @MainActor (EditorDocument) async throws -> Void
  ) async throws {
    let controller = try XCTUnwrap(f.editor)
    let original = try XCTUnwrap(f.model)
    let process = try XCTUnwrap(f.owner)
    controller.newDocument()
    try await f.wait("Actual second scratch adoption and selection") {
      controller.monitorHarnessDocuments.count == 2
        && controller.monitorHarnessCurrent?.id != original.id
        && controller.monitorHarnessCurrent != nil
    }
    let foreign = try XCTUnwrap(controller.monitorHarnessCurrent)
    XCTAssertTrue(foreign !== original)
    XCTAssertTrue(process.registry.handle(id: foreign.id) as? EditorDocument === foreign)
    guard foreign !== original,
      process.registry.handle(id: foreign.id) as? EditorDocument === foreign
    else {
      throw LocateCharacterizationError.unsafe
    }
    var primary: Error?
    do {
      let readyIDs = try process.registry.captureReadyWindows().flatMap { $0.groups }.flatMap {
        $0.documentIDs
      }
      XCTAssertEqual(readyIDs.count, 2)
      XCTAssertEqual(Set(readyIDs), Set([original.id, foreign.id]))
      try await body(foreign)
    } catch { primary = error }
    f.gate.release()  // Also release a held monitor callback on every thrown body path.
    // Close exactly the real extra document, then join the actual managed close.
    controller.selectSessionTab(foreign.id)
    let previous = process.managedSearchTestCloseStatus?.id
    controller.execute("file.close")
    let started = try XCTUnwrap(process.managedSearchTestCloseStatus)
    XCTAssertNotEqual(started.id, previous)
    guard started.id != previous else { throw LocateCharacterizationError.unsafe }
    let joined = try await process.managedSearchTestWaitClose(started.id)
    guard case .completed(let ids) = joined.result else { throw LocateCharacterizationError.unsafe }
    XCTAssertEqual(ids, [foreign.id])
    XCTAssertNil(process.registry.handle(id: foreign.id))
    XCTAssertEqual(controller.monitorHarnessDocuments.map(\.id), [original.id])
    let remainingIDs = try process.registry.captureReadyWindows().flatMap { $0.groups }.flatMap {
      $0.documentIDs
    }
    XCTAssertEqual(remainingIDs, [original.id])
    controller.selectSessionTab(original.id)
    try f.assertPreserved()
    if let primary { throw primary }
  }

  func testUntouchedInstalledPanelStalesOnAcceptedT2DespiteDifferentSelectedTabAndReopensFresh()
    async throws
  {
    try await withLocateCharacterization { f in
      let document = try XCTUnwrap(f.model)
      let controller = try XCTUnwrap(f.editor)
      let bridge = try XCTUnwrap(document.fileState)
      let firstContext = try XCTUnwrap(bridge.captureAction(.locate))
      let first = try installed(f)
      let initial = first.locatePresentationTestFacts
      XCTAssertGreaterThan(initial.contextHandlers, 0)
      XCTAssertEqual(initial.contextHandlers, initial.contextButtons)
      XCTAssertEqual(initial.contextEnabled, initial.contextButtons)
      XCTAssertEqual(initial.monitorHandlers, 3)
      XCTAssertEqual(initial.monitorEnabled, 3)
      XCTAssertTrue(initial.closeEnabled)
      XCTAssertFalse(initial.consumed)
      var staleObserved = false
      try await withAnotherSelectedTab(f) { foreign in
        XCTAssertEqual(controller.selectedDocumentID, foreign.id)
        XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === first)
        XCTAssertEqual(first.locatePresentationTestFacts.contextHandlers, initial.contextHandlers)
        try await f.wait("Original monitor idle before held delivery") { f.monitorSettled(bridge) }
        try await f.wait(
          "Actual extra-tab checkpoint acknowledged before observation-only interval"
        ) {
          f.owner?.locatePresentationTestCheckpointIdle == true
        }
        let recovery = LocatePresentationRecoveryFacts(document)
        let sessionBefore = try f.store.load()
        let recoveryBefore = try RecoveryStore(directory: f.recoveryDirectory).loadReport(
          quarantineInvalid: false)
        XCTAssertEqual(recoveryBefore.quarantinedCount, 0)
        try f.gate.arm()
        f.service.requestCheck(documentID: document.id)
        try await f.wait("Actual T2 held with untouched owner-installed T1 panel") {
          f.gate.facts.entries == 1 && !f.gate.facts.expired
            && bridge.monitorHarnessReceipt?.currentToken != firstContext.token
        }
        let second = try XCTUnwrap(bridge.monitorHarnessReceipt?.currentToken)
        XCTAssertEqual(bridge.state.token, firstContext.token)
        XCTAssertFalse(bridge.isCurrent(firstContext))
        XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === first)
        XCTAssertEqual(first.locatePresentationTestFacts.contextEnabled, initial.contextEnabled)
        XCTAssertEqual(f.chooserCalls, 0)
        recovery.assertUnchanged(document)
        f.gate.release()
        // Wait for actual monitor acceptance, never wait for the inert stale hook to succeed.
        try await f.wait("Actual accepted T2 while another tab remains selected") {
          bridge.state.token == second && f.monitorSettled(bridge)
        }
        XCTAssertEqual(controller.selectedDocumentID, foreign.id)
        let facts = first.locatePresentationTestFacts
        XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === first)
        XCTAssertEqual(controller.locatePresentationTestOwnerFacts.documentID, document.id)
        XCTAssertEqual(controller.locatePresentationTestOwnerFacts.token, firstContext.token)
        XCTAssertFalse(facts.consumed)
        XCTAssertEqual(facts.contextButtons, initial.contextButtons)
        XCTAssertEqual(
          facts.contextHandlers, 0, "Actual retained handlers, not just disabled clicks")
        XCTAssertEqual(facts.contextEnabled, 0)
        XCTAssertEqual(facts.monitorHandlers, initial.monitorHandlers)
        XCTAssertEqual(facts.monitorEnabled, initial.monitorEnabled)
        XCTAssertTrue(facts.closeEnabled)
        XCTAssertEqual(facts.notice, staleNotice)
        XCTAssertFalse(first.window?.isVisible ?? true)
        // Rendering again must be idempotent, not restore callbacks or replace the panel.
        controller.monitorHarnessRenderDiskStatus()
        let again = first.locatePresentationTestFacts
        XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === first)
        XCTAssertEqual(again.contextHandlers, facts.contextHandlers)
        XCTAssertEqual(again.contextEnabled, facts.contextEnabled)
        XCTAssertEqual(again.monitorHandlers, facts.monitorHandlers)
        XCTAssertEqual(again.notice, facts.notice)
        XCTAssertEqual(f.chooserCalls, 0)
        recovery.assertUnchanged(document)
        XCTAssertEqual(try f.store.load(), sessionBefore)
        let recoveryAfter = try RecoveryStore(directory: f.recoveryDirectory).loadReport(
          quarantineInvalid: false)
        XCTAssertEqual(recoveryAfter.snapshots, recoveryBefore.snapshots)
        XCTAssertEqual(recoveryAfter.quarantinedCount, 0)
        staleObserved =
          facts.contextHandlers == 0 && facts.contextEnabled == 0
          && facts.notice == staleNotice && !facts.consumed
      }
      // Real extra-tab cleanup precedes this ordinary guard; inert behavior never hangs or leaks it.
      guard staleObserved else { return }
      try f.assertPreserved()
      try f.checkErrors(0)
      first.close()
      XCTAssertTrue(first.locatePresentationTestFacts.consumed)
      let freshContext = try XCTUnwrap(bridge.captureAction(.locate))
      XCTAssertNotEqual(freshContext.token, firstContext.token)
      let fresh = try installed(f)
      XCTAssertFalse(fresh === first)
      let current = fresh.locatePresentationTestFacts
      XCTAssertGreaterThan(current.contextHandlers, 0)
      XCTAssertEqual(current.contextHandlers, current.contextEnabled)
      XCTAssertNotEqual(current.notice, staleNotice)
      let content = try XCTUnwrap(fresh.window?.contentView)
      @MainActor func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
      }
      let locate = try XCTUnwrap(
        descendants(content).compactMap { $0 as? NSButton }
          .first { $0.accessibilityIdentifier() == "document.locateFile" })
      try await f.wait("Actual cleanup paired checkpoint idle before fresh chooser") {
        f.owner?.locatePresentationTestCheckpointIdle == true
      }
      let afterManagedCleanup = LocatePresentationRecoveryFacts(document)
      let sessionBeforeCancel = try f.store.load()
      let recoveryBeforeCancel = try RecoveryStore(directory: f.recoveryDirectory).loadReport(
        quarantineInvalid: false)
      let expectedHint = bridge.state.observation?.movedCandidate ?? f.original
      locate.performClick(nil)
      XCTAssertEqual(f.chooserCalls, 1)
      XCTAssertEqual(f.chooserOriginal, expectedHint)
      XCTAssertTrue(fresh.locatePresentationTestFacts.consumed)
      afterManagedCleanup.assertUnchanged(document)
      XCTAssertEqual(try f.store.load(), sessionBeforeCancel)
      let recoveryAfterCancel = try RecoveryStore(directory: f.recoveryDirectory).loadReport(
        quarantineInvalid: false)
      XCTAssertEqual(recoveryAfterCancel.snapshots, recoveryBeforeCancel.snapshots)
      XCTAssertEqual(recoveryAfterCancel.quarantinedCount, 0)
      try f.assertPreserved()
      try f.checkErrors(0)
      print("LOCATE_PRESENTATION actualOwnedUntouchedStaleThenFreshT2Cancel")
    }
  }

  func testCloseNotificationReentryCannotOverwriteExactInstalledSuccessor() async throws {
    try await withLocateCharacterization { f in
      let controller = try XCTUnwrap(f.editor)
      let document = try XCTUnwrap(f.model)
      let first = try installed(f)
      let window = try XCTUnwrap(first.window)
      let reentry = LocatePresentationCloseReentry(f, controller: controller, document: document)
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
      ) { [weak reentry] _ in
        MainActor.assumeIsolated {
          reentry?.receive()
        }
      }
      defer { NotificationCenter.default.removeObserver(observer) }
      let abandoned = controller.locatePresentationTestInstallNoShow(document)
      if let abandoned, !f.panels.contains(where: { $0 === abandoned }) {
        f.panels.append(abandoned)
      }
      XCTAssertTrue(reentry.handled, "Actual exact panel close notification must be reached")
      XCTAssertNotNil(reentry.successor)
      XCTAssertNil(
        abandoned, "Superseded outer installation must not return a panel for showWindow")
      guard let successor = reentry.successor else { return }
      XCTAssertFalse(successor === first)
      XCTAssertTrue(controller.locatePresentationTestOwnerFacts.panel === successor)
      XCTAssertEqual(controller.locatePresentationTestOwnerFacts.documentID, document.id)
      XCTAssertFalse(successor.locatePresentationTestFacts.consumed)
      XCTAssertGreaterThan(successor.locatePresentationTestFacts.contextHandlers, 0)
      XCTAssertFalse(successor.window?.isVisible ?? true)
      XCTAssertEqual(f.chooserCalls, 0)
      try f.assertPreserved()
      try f.checkErrors(0)
      print("LOCATE_PRESENTATION actualCloseReentryPreservesSuccessor")
    }
  }
}
