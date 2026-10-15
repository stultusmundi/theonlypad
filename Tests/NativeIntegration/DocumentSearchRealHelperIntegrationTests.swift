// SPDX-License-Identifier: MIT
import AppKit
import CryptoKit
import Darwin
import PadCore
import SearchExecution
import XCTest

@testable import NativeRouting

private enum RealHelperFailure: Error { case unavailable, unsafe }

// Thread-safe observation of the actual XCTest callback executor; no actor/readiness grant.
private final class RealHelperPredicateExecutor: @unchecked Sendable {
  private let lock = NSLock()
  private var wrongExecutor = false
  func recordWrongExecutor() {
    lock.lock()
    wrongExecutor = true
    lock.unlock()
  }
  var wasWrongExecutor: Bool {
    lock.lock()
    defer { lock.unlock() }
    return wrongExecutor
  }
}

@MainActor private final class RealHelperFixture {
  let directory: URL
  let directoryDevice: UInt64
  let directoryInode: UInt64
  let recoveryDirectory: URL
  let inputFile: URL
  let bundle: URL
  let helper: URL
  let helperDigest: String
  let store: SessionStore
  let recovery: RecoveryCoordinator
  let session: SessionCoordinator
  let bridge: NativeApplicationSearches
  let input = "😀x\nx\n"
  let output = "😀y\ny\n"
  var app: AppDelegate?
  var editor: EditorWindowController?
  var model: EditorDocument?
  var pane: EditorPane?
  var window: NSWindow?
  var panel: DocumentSearchPanelController?
  var source: (any ApplicationDocumentSearchSource)?
  var originalJoin: (@MainActor () async -> AppSearchAttemptTestFacts)?
  var returnedAttempt: AppSearchAttemptTestFacts?
  var factoryCalls = 0
  var presentations = 0
  var announcedConfigured: [Bool] = []
  var errors: [Error] = []
  var replies: [Bool] = []
  var externalCalls = 0
  var externalReturned = false
  var externalEntryFacts: AppSearchAttemptTestFacts?
  var externalEntryWasSettled = false
  var originalTaskReturned = false
  var unsafeCallback = false
  var owner: NativeApplicationDocuments? { app?.task4Owner }

  init() throws {
    try RealHelperCustody.requireEmpty()
    _ = NSApplication.shared
    guard let path = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !path.isEmpty
    else { throw RealHelperFailure.unavailable }
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    try Self.requireOwnedDirectory(root)
    bundle = root.appendingPathComponent("RealHelperFixture.app", isDirectory: true)
    guard bundle.resolvingSymlinksInPath().standardizedFileURL == bundle.standardizedFileURL
    else { throw RealHelperFailure.unsafe }
    try Self.requireOwnedDirectory(bundle)
    helper = try SearchWorkerBundleResolver.candidate(in: bundle)
    _ = try SearchWorkerBundleResolver.validateForLaunch(helper)
    let attributes = try FileManager.default.attributesOfItem(atPath: helper.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
      (attributes[.size] as? NSNumber).map({ $0.intValue > 0 && $0.intValue <= 64 * 1024 * 1024 })
        == true,
      helper.resolvingSymlinksInPath().standardizedFileURL == helper.standardizedFileURL
    else { throw RealHelperFailure.unsafe }
    helperDigest = Self.digest(try Data(contentsOf: helper))
    // Root separately binds these exact bytes to its current helper build; no supplied executable URL.
    directory = root.appendingPathComponent("real-helper-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard let device = directoryAttributes[.systemNumber] as? NSNumber,
      let inode = directoryAttributes[.systemFileNumber] as? NSNumber
    else { throw RealHelperFailure.unsafe }
    directoryDevice = device.uint64Value
    directoryInode = inode.uint64Value
    recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
    inputFile = directory.appendingPathComponent("synthetic-input.txt")
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
    self.recovery = recovery
    session = SessionCoordinator(
      loadSession: { try store.load() },
      claimRecovery: { try await recovery.claimStartup() })
    bridge = NativeApplicationSearches(applicationBundle: bundle)
    app = AppDelegate(
      session: session, recovery: recovery, documentSearches: bridge,
      cancelExternalCommands: { [weak self] in
        guard let self else {
          XCTFail("Original real-helper fixture disappeared")
          return
        }
        self.externalCalls += 1
        guard self.externalCalls == 1 else {
          self.unsafeCallback = true
          XCTFail("External drain entered more than once")
          return
        }
        let facts = self.app?.task4Attempt
        self.externalEntryFacts = facts
        self.externalEntryWasSettled =
          facts?.nativeReceipt != nil
          && facts?.decision.map(Self.isActuallySettled) == true
        XCTAssertTrue(
          self.externalEntryWasSettled,
          "Actual native receipt and full actual search settlement must precede real external wait")
        await ExternalCommandController.cancelAllAndWait()
        self.externalReturned = true
      },
      makeDocumentSearchPanel: { [weak self] owner, ticket, source, onClose in
        guard let self, self.factoryCalls == 0 else { throw RealHelperFailure.unsafe }
        self.factoryCalls += 1
        XCTAssertTrue(source is EditorDocumentSearchSource)
        guard source is EditorDocumentSearchSource else { throw RealHelperFailure.unavailable }
        self.source = source
        let panel = try DocumentSearchPanelController(
          owner: owner, window: ticket,
          source: source, onClose: onClose)
        self.panel = panel
        return panel
      },
      presentDocumentSearchPanel: { [weak self] panel in
        guard let self else { return }
        self.presentations += 1
        if self.presentations != 1 || self.panel !== panel {
          self.unsafeCallback = true
          XCTFail("Presentation must use the original concrete panel exactly once")
        }
      },
      presentEditorWindow: { [weak self] editor in
        guard let self else { return }
        guard self.announcedConfigured.isEmpty else {
          self.unsafeCallback = true
          XCTFail("Only one actual native window is permitted")
          return
        }
        self.announcedConfigured.append(editor.managedSearchTestFacts.configured)
      },
      reportDocumentError: { [weak self] error in
        guard let self else { return }
        self.unsafeCallback = true
        if self.errors.count < 4 { self.errors.append(error) }
        XCTFail("Unexpected genuine managed document error")
      },
      replyToTermination: { [weak self] value in
        guard let self else { return }
        if self.replies.count < 2 { self.replies.append(value) }
        if self.replies != [true] || !self.externalReturned || !self.externalEntryWasSettled {
          self.unsafeCallback = true
          XCTFail("One positive reply must follow the real external return and actual producers")
        }
      },
      presentSessionAdjustment: { [weak self] in
        self?.unsafeCallback = true
        XCTFail("Exact synthetic positions must not require adjustment")
      })
  }

  static func digest(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
  }

  static func requireOwnedDirectory(_ url: URL) throws {
    let values = try FileManager.default.attributesOfItem(atPath: url.path)
    guard values[.type] as? FileAttributeType == .typeDirectory,
      (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
      (values[.posixPermissions] as? NSNumber)?.intValue == 0o700,
      url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
    else { throw RealHelperFailure.unsafe }
  }

  func require(_ condition: Bool, _ message: String) throws {
    XCTAssertTrue(condition, message)
    guard condition else { throw RealHelperFailure.unavailable }
  }

  func start() async throws {
    try Data(input.utf8).write(to: inputFile, options: .atomic)
    let tab = SessionTab(originalPath: inputFile.path)
    try store.save(EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)]))
    try require(bridge.phase == .notCreated, "Actual bridge must remain lazy before native start")
    try await XCTUnwrap(app).task4StartDocuments()
    let owner = try XCTUnwrap(owner)
    let windows = try owner.registry.captureReadyWindows()
    try require(
      windows.count == 1 && owner.windows.count == 1,
      "Actual managed registry must contain one window")
    let projection = try XCTUnwrap(windows.first)
    let editor = try XCTUnwrap(owner.windows.first)
    try require(projection.groups.count == 1, "One actual managed group required")
    let group = try XCTUnwrap(projection.groups.first)
    try require(group.documentIDs.count == 1, "One real imported document required")
    let id = try XCTUnwrap(group.documentIDs.first)
    let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
    let pane = try XCTUnwrap(editor.focusedPane)
    let window = try XCTUnwrap(editor.window)
    self.editor = editor
    self.model = model
    self.pane = pane
    self.window = window
    try require(
      session.restorationComplete && session.unresolved.isEmpty,
      "Real startup must settle without unresolved inputs")
    try require(
      announcedConfigured == [true] && editor.managedSearchTestFacts.configured,
      "Real App configuration must precede its window announcement")
    try require(
      pane.isAttached && pane.document === model && pane.editor.textStorage === model.storage,
      "Original pane must use actual managed model/storage")
    try require(
      editor.selectedDocumentID == id && projection.id == editor.sessionMetadata.id
        && window.windowController === editor && window.delegate as AnyObject? === editor
        && !window.isVisible && !editor.managedSearchTestFacts.windowClosed,
      "Exact hidden original native endpoint required")
    try require(
      model.storage.string == input && model.originalBytes == Data(input.utf8)
        && model.url?.standardizedFileURL == inputFile.standardizedFileURL,
      "Actual imported source and baseline bytes must match")
    try requireClean(model)
    let item = try model.captureAuthorizedRecovery()
    try require(
      item.snapshot == nil && item.authority == model.recoveryAuthority
        && item.authority.documentID == model.id && item.revision > 0
        && item.revision == model.highestIssuedRecoveryRevision,
      "Clean-file authorized recovery must be an actual absence disposition")
    try await recovery.persistAuthorizedBatch([item])
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    try require(
      report.snapshots.isEmpty && report.quarantinedCount == 0,
      "Fresh recovery reader must confirm clean-file absence")
    try require(
      bridge.phase == .notCreated && panel == nil && factoryCalls == 0,
      "Native startup must not create search service or panel")
  }

  func open() throws -> DocumentSearchPanelController {
    let editor = try XCTUnwrap(editor)
    try require(
      editor.managedSearchTestFacts.configured,
      "Missing App configuration: legacy Find must remain UNENTERED")
    editor.execute("edit.find")
    let panel = try XCTUnwrap(panel)
    try require(
      editor.managedSearchTestPanel === panel && factoryCalls == 1 && presentations == 1
        && editor.managedSearchTestTicket != nil && bridge.phase == .open
        && !panel.testOnlyLogicallyClosed && panel.window?.isVisible == false,
      "Actual configured native Find must create the one real hidden panel")
    return panel
  }

  func send(_ control: NSControl) throws {
    let action = try XCTUnwrap(control.action)
    let target = try XCTUnwrap(control.target)
    try require(
      NSApp.sendAction(action, to: target, from: control),
      "Actual configured panel target/action must accept the control")
  }

  // Full actual raw predicate; no constructed shutdown report or injected charge/counter.
  static func isActuallySettled(_ value: NativeApplicationSearchQuitResult) -> Bool {
    guard case .terminal(_, let first, let latest, .settled) = value,
      case .observed(.observed(let firstObservation)) = first,
      case .observed(.observed(let observation)) = latest,
      firstObservation.parent == observation.parent,
      case .completed(let parent) = observation.parent,
      parent.ownership == .admitted, parent.laneStop == .acknowledged,
      parent.shutdown.parentLaneSettled, parent.shutdown.retainedParentLanes == 0,
      parent.shutdown.child.stopped, parent.shutdown.child.channelsClosed,
      observation.driverSettlement == .settled(admissionClosed: true),
      observation.retainedActiveJobs == 0, observation.retainedLeases == 0,
      observation.retainedCharge == 0, observation.reservedRetainedCharge == 0,
      observation.activeCharge == SearchAdmissionProductionAccounting().resident
    else { return false }
    switch parent.shutdown.child.cleanup {
    case .noChild, .reaped: return true
    case .pendingLaunch, .stopping, .stopUnconfirmed: return false
    }
  }

  func verifyNativeReceipt(_ receipt: SessionCheckpointReceipt) throws {
    let model = try XCTUnwrap(model)
    let stored = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    try require(
      stored.windows.count == 1
        && stored.windows.flatMap(\.tabs).map(\.id) == [model.id],
      "Fresh actual session reader must preserve the original document")
    try require(
      receipt.generation > 0 && Set(receipt.recoveryRevisions.keys) == [model.id]
        && Set(receipt.recoveryAuthorities.keys) == [model.id]
        && receipt.recoveryAuthorities[model.id] == model.recoveryAuthority,
      "Actual native receipt must name the original model/authority")
    let revision = try XCTUnwrap(receipt.recoveryRevisions[model.id])
    try require(
      revision > 0 && revision <= model.highestIssuedRecoveryRevision,
      "Actual receipt revision must be producer-issued")
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    try require(
      report.snapshots.isEmpty && report.quarantinedCount == 0,
      "Clean-file recovery absence must survive fresh readback")
    try require(
      try Data(contentsOf: inputFile) == Data(input.utf8),
      "Original synthetic file bytes must remain unchanged")
  }

  func requireClean(_ model: EditorDocument) throws {
    let state = try model.captureCloseState()
    let manager = model.undoManager
    try require(
      !model.dirty && !state.isDirty && !state.hasPendingPublication
        && !state.hasPendingTextEdits && !state.isComposing && state.operationID == nil
        && !manager.isUndoing && !manager.isRedoing && manager.groupingLevel == 0,
      "Actual clean/idle native close prerequisites required; no rescue edit or grouping repair")
  }

  func replay(redo: Bool, expected: String) throws {
    let model = try XCTUnwrap(model)
    let manager = model.undoManager
    let grouping = manager.groupingLevel
    try require(
      !manager.isUndoing && !manager.isRedoing
        && (redo ? grouping == 0 : (grouping == 0 || grouping == 1))
        && (redo ? manager.canRedo : manager.canUndo),
      "Only the original factual legal native replay state may enter")
    let revision = model.editRevision
    if redo { manager.redo() } else { manager.undo() }
    try require(
      model.storage.string == expected && model.editRevision > revision
        && !manager.isUndoing && !manager.isRedoing && manager.groupingLevel == 0,
      "Genuine native replay must preserve exact text and advance actual revision")
  }

  func quit() async throws {
    let app = try XCTUnwrap(app)
    try require(
      app.applicationShouldTerminate(NSApplication.shared) == .terminateLater,
      "Actual App quit must reserve asynchronous work")
    let before = try XCTUnwrap(app.task4Attempt)
    try require(
      before.hasTask && before.hasPreparation,
      "Exact original task/preparation must exist before callback/yield")
    let original = try app.task4CaptureCurrentAttemptJoin()
    originalJoin = original
    try require(
      app.applicationShouldTerminate(NSApplication.shared) == .terminateLater
        && app.task4Attempt?.id == before.id, "Repeated Quit must preserve the same actual attempt")
    let returned = await original()
    originalTaskReturned = true
    returnedAttempt = returned
    try require(
      returned.id == before.id && returned.replyConsumed && replies == [true]
        && externalCalls == 1 && externalReturned && externalEntryWasSettled
        && externalEntryFacts?.id == before.id && !unsafeCallback && errors.isEmpty,
      "One real external wait and one positive reply must belong to the original returned task")
    let receipt = try XCTUnwrap(returned.nativeReceipt)
    let decision = try XCTUnwrap(returned.decision)
    try require(
      Self.isActuallySettled(decision), "Actual complete nested helper join predicate required")
    let atExternal = try XCTUnwrap(externalEntryFacts?.nativeReceipt)
    try require(
      atExternal.generation == receipt.generation
        && atExternal.recoveryRevisions == receipt.recoveryRevisions
        && atExternal.recoveryAuthorities == receipt.recoveryAuthorities,
      "External entry must observe the same actual retained native publication receipt")
    try verifyNativeReceipt(receipt)
    if case .terminal(_, _, .observed(.observed(let observation)), _) = decision,
      case .completed(let parent) = observation.parent
    {
      print(
        "REAL_HELPER actual child cleanup=\(parent.shutdown.child.cleanup); noChild denotes settled absence, not a literal per-generation reap receipt"
      )
    }
  }

  func finish() async throws {
    guard originalTaskReturned, let returnedAttempt, returnedAttempt.replyConsumed,
      returnedAttempt.decision.map(Self.isActuallySettled) == true,
      replies == [true], externalCalls == 1, externalReturned, externalEntryWasSettled,
      !unsafeCallback, errors.isEmpty
    else { throw RealHelperFailure.unsafe }
    let owner = try XCTUnwrap(owner)
    let editor = try XCTUnwrap(editor)
    let model = try XCTUnwrap(model)
    let window = try XCTUnwrap(window)
    // Qualified cleanup rollback only AFTER actual publication, terminal join and original task/reply.
    owner.cancelPreparedQuit()
    panel?.close()
    try require(
      panel?.testOnlyLogicallyClosed == true && panel?.testOnlySessionState == .closed,
      "Actual panel consumer must already be retired")
    try requireClean(model)
    try require(
      model.storage.string == input
        && owner.registry.handle(id: model.id) as? EditorDocument === model,
      "Exact original clean model required before genuine close")
    let text = model.storage.string
    let revision = model.editRevision
    let state = try model.captureCloseState()
    editor.execute("file.close")
    let status = try XCTUnwrap(owner.managedSearchTestCloseStatus)
    let joined = try await owner.managedSearchTestWaitClose(status.id)
    let settled = try XCTUnwrap(joined.status)
    guard case .completed(let ids) = joined.result else { throw RealHelperFailure.unsafe }
    try require(
      ids == [model.id] && settled.id == status.id && settled.stage == .settled
        && !settled.recoveryPaused && settled.error == nil
        && owner.registry.handle(id: model.id) == nil
        && editor.managedSearchTestFacts.documentIDs.isEmpty && editor.sessionMetadata.tabs.isEmpty
        && model.storage.string == text && model.editRevision == revision
        && (try model.captureCloseState()) == state,
      "Exact producer close/status/wait/settled and unchanged model data required")
    try requireClean(model)
    let receipt = RealHelperWindowCloseReceipt(window)
    let observation = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window, queue: nil
    ) { [weak receipt] note in
      guard Thread.isMainThread else {
        XCTFail("Actual empty-window close notification was not on the main thread")
        return
      }
      MainActor.assumeIsolated { receipt?.receive(note) }
    }
    window.close()
    NotificationCenter.default.removeObserver(observation)
    try require(
      receipt.count == 1 && receipt.exact && editor.managedSearchTestFacts.windowClosed
        && owner.registry.window(id: editor.sessionMetadata.id) == nil
        && owner.registry.closedHistoryCount(windowID: editor.sessionMetadata.id) == 0,
      "Genuine exact empty SDK window close and actual Source retirement required")
    let final = try await owner.prepareQuit()
    let fresh = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    try require(
      owner.windows.isEmpty && (try owner.registry.captureReadyWindows()).isEmpty
        && final.recoveryAuthorities.isEmpty && final.recoveryRevisions.isEmpty
        && fresh.windows.isEmpty && report.snapshots.isEmpty && report.quarantinedCount == 0,
      "Final actual empty publication/fresh readers required before owned deletion")
    try require(
      try Data(contentsOf: inputFile) == Data(input.utf8), "Original disk data must remain exact")
    try require(
      Self.digest(try Data(contentsOf: helper)) == helperDigest,
      "Root-owned fixed helper artifact must remain byte-identical")
    try Self.requireOwnedDirectory(directory)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    try require(
      (directoryAttributes[.systemNumber] as? NSNumber)?.uint64Value == directoryDevice
        && (directoryAttributes[.systemFileNumber] as? NSNumber)?.uint64Value == directoryInode,
      "Only the original owned fixture directory identity may be removed")
    try FileManager.default.removeItem(at: directory)
    try require(
      !FileManager.default.fileExists(atPath: directory.path),
      "Exact owned fixture cleanup must finish")
    // The Root-owned synthetic helper bundle is deliberately outside the deleted fixture.
  }
}

@MainActor private final class RealHelperWindowCloseReceipt {
  weak var window: NSWindow?
  var count = 0
  var exact = true
  init(_ window: NSWindow) { self.window = window }
  func receive(_ note: Notification) {
    count += 1
    exact = exact && (note.object as? NSWindow) === window
  }
}

@MainActor private enum RealHelperCustody {
  private static var fixture: RealHelperFixture?
  static func requireEmpty() throws {
    guard fixture == nil else { throw RealHelperFailure.unsafe }
  }
  static func retain(_ value: RealHelperFixture) {
    guard fixture == nil || fixture === value else {
      XCTFail("Single real-helper fixture custody slot is occupied")
      return
    }
    fixture = value
  }
}

final class DocumentSearchRealHelperIntegrationTests: XCTestCase {
  @MainActor private func waitForActualState(
    _ panel: DocumentSearchPanelController,
    stage: String, accepts: @escaping @MainActor (DocumentSearchSessionState) -> Bool
  ) async throws {
    let executor = RealHelperPredicateExecutor()
    let predicate = NSPredicate { [weak panel, executor] _, _ in
      guard Thread.isMainThread else {
        executor.recordWrongExecutor()
        return true  // Wake the waiter to report unavailable; never read actor state here.
      }
      return MainActor.assumeIsolated {
        guard let panel, let value = panel.testOnlySessionState else { return true }
        if case .failed = value { return true }
        if case .closed = value { return true }
        return accepts(value) && panel.testOnlyRenderedState == value
      }
    }
    let expected = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    let outcome = await XCTWaiter.fulfillment(of: [expected], timeout: 15)
    XCTAssertFalse(
      executor.wasWrongExecutor,
      "Actual XCTest predicate executor unavailable at \(stage); fixture must be retained")
    guard !executor.wasWrongExecutor else { throw RealHelperFailure.unavailable }
    XCTAssertEqual(outcome, .completed, "Actual helper state horizon missing at \(stage)")
    guard outcome == .completed, let state = panel.testOnlySessionState else {
      throw RealHelperFailure.unavailable
    }
    XCTAssertTrue(accepts(state), "Actual helper state refused at \(stage)")
    guard accepts(state), panel.testOnlyRenderedState == state else {
      throw RealHelperFailure.unavailable
    }
  }

  @MainActor func testRealBundledHelperFindReplaceUndoAndApplicationJoinedQuit() async throws {
    let f = try RealHelperFixture()
    do {
      try await f.start()
      let panel = try f.open()
      let model = try XCTUnwrap(f.model)
      let pane = try XCTUnwrap(f.pane)
      let source = try XCTUnwrap(f.source)
      let original = try source.inspect()
      let revision = model.editRevision
      let controls = panel.testOnlyControls
      controls.query.stringValue = "x"
      try f.send(controls.find)  // First genuine request, no scripted completion or output.
      try await waitForActualState(panel, stage: "actual find result") {
        $0 == .results(matchCount: 2, selectedIndex: nil)
      }
      try f.require(
        model.storage.string == f.input && model.editRevision == revision && !model.dirty,
        "Real helper Find must preserve original model bytes/revision")
      try f.require(
        controls.next.isEnabled && controls.previous.isEnabled,
        "Actual result rendering must enable the native navigation controls")
      for (action, location) in [(controls.next, 2), (controls.next, 4), (controls.previous, 2)] {
        try f.send(action)
        try f.require(
          pane.editor.selectedRange() == NSRange(location: location, length: 1)
            && f.window?.firstResponder === pane.editor,
          "Real panel navigation must focus/select exact native scalar range")
      }
      controls.replacement.stringValue = "y"
      try f.send(controls.replace)  // Second and final genuine request.
      try await waitForActualState(panel, stage: "actual replacement approval") {
        if case .awaitingApproval(_, 2) = $0 { return true }
        return false
      }
      guard let approvalState = panel.testOnlySessionState,
        case .awaitingApproval(let token, 2) = approvalState
      else {
        throw RealHelperFailure.unavailable
      }
      try f.require(
        panel.testOnlyDisplayedApproval == token && !controls.approvalRow.isHidden
          && controls.approve.isEnabled && model.storage.string == f.input,
        "Actual helper replacement must await genuine panel approval without editing")
      try f.send(controls.approve)
      try f.require(
        panel.testOnlySessionState == .replaced(matchCount: 2)
          && model.storage.string == f.output && model.editRevision > revision && model.dirty,
        "Real helper output must enter exactly the native replacement")
      try f.require(
        try Data(contentsOf: f.inputFile) == Data(f.input.utf8),
        "Replacement must not save the original file")
      try f.replay(redo: false, expected: f.input)
      try f.replay(redo: true, expected: f.output)
      try f.replay(redo: false, expected: f.input)
      try f.requireClean(model)
      try f.require(
        !source.isCurrent(expected: original), "Text ABA must not revive the original credential")
      do {
        _ = try source.capture(expected: original)
        XCTFail("Old source credential must refuse after genuine native replay")
        throw RealHelperFailure.unsafe
      } catch is ApplicationDocumentSearchFailure {
        // Genuine stale Source refusal; no captured payload supplied by the Test.
      }
      let stableRevision = model.editRevision
      try f.require(
        !panel.testOnlyRespondToApproval(token, approved: true)
          && model.storage.string == f.input && model.editRevision == stableRevision,
        "Consumed old approval cannot edit after native replay")
      try await f.quit()
      try await f.finish()
    } catch {
      RealHelperCustody.retain(f)
      XCTFail(
        "Real-helper horizon/cleanup unavailable; exact live chain, task and owned state retained")
      throw error
    }
  }
}

// Additive real-helper failures: original fixture, executor guard, task join and cleanup unchanged.
extension DocumentSearchRealHelperIntegrationTests {
  @MainActor func testRealHelperMalformedRegexRefusesAndSamePanelCanRetryThenJoinedQuit()
    async throws
  {
    let f = try RealHelperFixture()
    do {
      try await f.start()
      let panel = try f.open()
      let model = try XCTUnwrap(f.model)
      let pane = try XCTUnwrap(f.pane)
      let window = try XCTUnwrap(f.window)
      let editor = try XCTUnwrap(f.editor)
      let source = try XCTUnwrap(f.source)
      let original = try source.inspect()
      let ticket = try XCTUnwrap(editor.managedSearchTestTicket)
      let revision = model.editRevision
      let controls = panel.testOnlyControls
      try f.require(
        f.input.utf16.count == 6 && model.storage.length == 6,
        "Fixed tiny malformed-regex fixture must remain six UTF16 units")
      controls.mode.selectItem(at: 2)
      controls.query.stringValue = "("
      // First actual request; failure must arrive through the real helper.
      try f.send(controls.find)
      let expected: DocumentSearchSessionState = .failed(.admission(.semantic(.invalidPattern)))
      try await waitForActualState(panel, stage: "actual helper invalidPattern") { $0 == expected }
      try f.require(
        panel.testOnlySessionState == expected && panel.testOnlyRenderedState == expected
          && panel.testOnlyDisplayedApproval == nil && controls.approvalRow.isHidden
          && !controls.approve.isEnabled && !controls.reject.isEnabled
          && !controls.next.isEnabled && !controls.previous.isEnabled,
        "Exact semantic invalidPattern must retire result/approval presentation")
      try f.require(
        model.storage.string == f.input && model.editRevision == revision
          && source.isCurrent(expected: original) && (try source.inspect()) == original
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8),
        "Real malformed regex must preserve original text, revision, credential and disk")
      try f.requireClean(model)
      try f.require(
        editor.managedSearchTestPanel === panel
          && editor.managedSearchTestTicket == ticket && editor.window === window
          && pane.isAttached && pane.document === model && pane.editor.textStorage === model.storage
          && !panel.testOnlyLogicallyClosed && f.bridge.phase == .open
          && f.factoryCalls == 1 && f.presentations == 1,
        "Failure must preserve the original live panel, ticket, endpoint and actual owner")

      controls.mode.selectItem(at: 0)
      controls.query.stringValue = "x"
      try f.send(controls.find)  // Second and final actual request, on the SAME panel/owner.
      let result: DocumentSearchSessionState = .results(matchCount: 2, selectedIndex: nil)
      try await waitForActualState(panel, stage: "actual valid retry after invalidPattern") {
        $0 == result
      }
      try f.require(
        panel.testOnlySessionState == result && panel.testOnlyRenderedState == result
          && controls.next.isEnabled && controls.previous.isEnabled
          && panel.testOnlyDisplayedApproval == nil && controls.approvalRow.isHidden,
        "Actual valid retry must replace the error with the real two-match result")
      try f.send(controls.next)
      try f.require(
        pane.editor.selectedRange() == NSRange(location: 2, length: 1)
          && window.firstResponder === pane.editor
          && panel.testOnlySessionState == .results(matchCount: 2, selectedIndex: 0),
        "Retry result must navigate/focus the original native pane")
      try f.require(
        model.storage.string == f.input && model.editRevision == revision
          && source.isCurrent(expected: original) && (try source.inspect()) == original
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8)
          && editor.managedSearchTestPanel === panel && editor.managedSearchTestTicket == ticket
          && f.factoryCalls == 1 && f.presentations == 1 && f.errors.isEmpty && !f.unsafeCallback,
        "Two actual requests must preserve original data, authority and one presentation")
      try f.requireClean(model)
      try await f.quit()
      try await f.finish()
    } catch {
      RealHelperCustody.retain(f)
      XCTFail(
        "Malformed-regex/retry horizon or cleanup unavailable; exact live fixture/task retained")
      throw error
    }
  }

  @MainActor func testRealHelperReplacementApprovalRefusesAfterNativeEditUndoABAThenJoinedQuit()
    async throws
  {
    let f = try RealHelperFixture()
    do {
      try await f.start()
      let panel = try f.open()
      let model = try XCTUnwrap(f.model)
      let pane = try XCTUnwrap(f.pane)
      let window = try XCTUnwrap(f.window)
      let editor = try XCTUnwrap(f.editor)
      let source = try XCTUnwrap(f.source)
      let original = try source.inspect()
      let ticket = try XCTUnwrap(editor.managedSearchTestTicket)
      let revision = model.editRevision
      let controls = panel.testOnlyControls
      try f.require(
        f.input.utf16.count == 6 && model.storage.length == 6,
        "Fixed tiny stale-approval fixture must remain six UTF16 units before its one edit")
      controls.mode.selectItem(at: 0)
      controls.query.stringValue = "x"
      controls.replacement.stringValue = "y"
      try f.send(controls.replace)  // Sole real helper request in this case.
      try await waitForActualState(panel, stage: "actual replacement before native ABA") {
        if case .awaitingApproval(_, 2) = $0 { return true }
        return false
      }
      let approvalState = try XCTUnwrap(panel.testOnlySessionState)
      guard case .awaitingApproval(let token, 2) = approvalState else {
        throw RealHelperFailure.unavailable
      }
      try f.require(
        panel.testOnlyRenderedState == approvalState
          && panel.testOnlyDisplayedApproval == token && !controls.approvalRow.isHidden
          && controls.approve.isEnabled && model.storage.string == f.input
          && model.editRevision == revision
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8),
        "Genuine helper output must remain held behind its actual approval before native editing")
      try f.requireClean(model)
      try f.require(
        pane.isAttached && pane.document === model && pane.editor.textStorage === model.storage
          && pane.editor.isEditable && !pane.editor.isComposingText && !pane.editor.hasMarkedText()
          && editor.window === window && editor.managedSearchTestPanel === panel
          && editor.managedSearchTestTicket == ticket && !panel.testOnlyLogicallyClosed,
        "Only the original actual editable, noncomposing native endpoint may enter")
      try f.require(
        window.makeFirstResponder(pane.editor) && window.firstResponder === pane.editor,
        "Genuine hidden native first-responder admission required before the sole edit")
      pane.editor.insertText("!", replacementRange: NSRange(location: 6, length: 0))
      let insertedRevision = model.editRevision
      try f.require(
        model.storage.string == f.input + "!" && model.storage.length == 7
          && insertedRevision > revision && model.dirty
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8),
        "Actual native insertion must produce precisely seven units without saving disk")
      // This undo is the planned ABA oracle, not an error cleanup or SDK grouping repair.
      try f.replay(redo: false, expected: f.input)
      try f.requireClean(model)
      try f.require(
        model.storage.string == f.input && model.storage.length == 6
          && model.editRevision > insertedRevision && model.editRevision > revision
          && !source.isCurrent(expected: original),
        "Native Undo must restore bytes without reviving the old Source revision authority")
      do {
        _ = try source.capture(expected: original)
        XCTFail("Old helper-source credential must refuse after actual native text ABA")
        throw RealHelperFailure.unsafe
      } catch is ApplicationDocumentSearchFailure {
        // Only the genuine typed Source refusal is accepted; unrelated failures escape to custody.
      }
      try f.require(
        editor.managedSearchTestPanel === panel && editor.managedSearchTestTicket == ticket
          && !panel.testOnlyLogicallyClosed && panel.testOnlySessionState == approvalState
          && panel.testOnlyRenderedState == approvalState
          && panel.testOnlyDisplayedApproval == token
          && !controls.approvalRow.isHidden && controls.approve.isEnabled,
        "The SAME genuine approval must still be held; otherwise the stale-response horizon is UNENTERED"
      )
      let stableRevision = model.editRevision
      let stableSelection = pane.editor.selectedRange()
      let canUndo = model.undoManager.canUndo
      let canRedo = model.undoManager.canRedo
      try f.require(
        !panel.testOnlyRespondToApproval(token, approved: true),
        "Actual helper output must not replace the native document after text ABA")
      let stale: DocumentSearchSessionState = .failed(.staleSource)
      try f.require(
        panel.testOnlySessionState == stale && panel.testOnlyRenderedState == stale
          && panel.testOnlyDisplayedApproval == nil && controls.approvalRow.isHidden
          && !controls.approve.isEnabled && !controls.reject.isEnabled
          && !controls.next.isEnabled && !controls.previous.isEnabled,
        "Stale actual result must publish exact staleSource and consume approval/navigation rights")
      try f.require(
        model.storage.string == f.input && model.editRevision == stableRevision
          && pane.editor.selectedRange() == stableSelection
          && model.undoManager.canUndo == canUndo && model.undoManager.canRedo == canRedo
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8),
        "Denied old result must preserve text, revision, native selection/history facts and disk")
      try f.require(
        !panel.testOnlyRespondToApproval(token, approved: true)
          && panel.testOnlySessionState == stale && panel.testOnlyRenderedState == stale
          && panel.testOnlyDisplayedApproval == nil && controls.approvalRow.isHidden
          && !controls.approve.isEnabled && !controls.reject.isEnabled
          && !controls.next.isEnabled && !controls.previous.isEnabled
          && model.storage.string == f.input && model.editRevision == stableRevision
          && pane.editor.selectedRange() == stableSelection
          && model.undoManager.canUndo == canUndo && model.undoManager.canRedo == canRedo
          && (try Data(contentsOf: f.inputFile)) == Data(f.input.utf8)
          && f.factoryCalls == 1 && f.presentations == 1 && f.errors.isEmpty && !f.unsafeCallback,
        "Consumed approval cannot regain authority or alter the genuine failure/data state")
      try f.requireClean(model)
      try await f.quit()
      try await f.finish()
    } catch {
      RealHelperCustody.retain(f)
      XCTFail(
        "Native ABA/stale-helper-approval horizon or cleanup unavailable; exact fixture/task retained"
      )
      throw error
    }
  }
}
