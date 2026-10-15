// SPDX-License-Identifier: MIT
// STAGED CONTRACT ONLY: NOT AN EXECUTABLE/FROZEN ACCEPTANCE PACKAGE. See API.md dependency gates.
import AppKit
import Foundation
import PadCore
import XCTest

@testable import NativeRouting
@testable import SearchExecution

@MainActor final class DocumentSearchAppRoutingTests: XCTestCase {
  private let native: [(String, String)] = [
    ("edit.undo", "undo:"), ("edit.redo", "redo:"), ("edit.cut", "cut:"),
    ("edit.copy", "copy:"), ("edit.paste", "paste:"), ("edit.selectAll", "selectAll:"),
  ]
  private let refused = [
    "file.save", "file.saveAs", "file.saveAll", "edit.uppercase", "edit.line.delete",
    "macro.start", "macro.manage", "tool.extensions", "tool.externalCommand", "file.moveToWindow",
    "file.recent", "file.retrySession", "file.restoreSession", "document.encoding",
  ]

  func testCapturedSearchPanelClaimsOnlyCloseAndSixNativeEditingSelectors() async throws {
    try await withAppRoutingFixture(windows: 2) { f in
      guard let panels = try f.openPanels() else { return }
      let app = try XCTUnwrap(f.app)
      let a = panels[0]
      let b = panels[1]
      let captured = try XCTUnwrap(a.window)
      let other = try XCTUnwrap(b.window)
      XCTAssertTrue(captured.windowController === a)
      XCTAssertTrue(a.window === captured)
      let before = appRoutingNativeSnapshot(f)
      var sends: [String] = []
      for (id, selector) in native {
        let handled = app.task4DispatchCaptured(id, window: captured) { action, sender in
          sends.append(NSStringFromSelector(action))
          XCTAssertTrue(sender as AnyObject? === app)
          return false  // Native responder absence must still claim this exact scope.
        }
        XCTAssertTrue(handled)
        XCTAssertEqual(sends.last, selector)
        guard handled else {
          print("APP_SEARCH native-policy horizon UNENTERED")
          return
        }
      }
      XCTAssertEqual(sends, native.map(\.1))
      let actualIDs = Set(app.task4RegisteredCommandIDs)
      for id in refused {
        XCTAssertTrue(
          actualIDs.contains(id), "Only real registered refusal IDs discriminate scope ordering")
        XCTAssertTrue(
          app.task4DispatchCaptured(id, window: captured) { _, _ in
            XCTFail("Refused command leaked native action")
            return false
          })
        XCTAssertEqual(appRoutingNativeSnapshot(f), before)
      }
      XCTAssertTrue(b.window === other)
      XCTAssertFalse(b.testOnlyLogicallyClosed)
      XCTAssertEqual(f.externalCalls, 0)
      XCTAssertTrue(f.errors.isEmpty)
      XCTAssertTrue(
        app.task4DispatchCaptured("file.close", window: captured) { _, _ in
          XCTFail("Close leaked native action")
          return false
        })
      XCTAssertTrue(a.testOnlyLogicallyClosed)
      XCTAssertEqual(a.testOnlySessionState, .closed)
      XCTAssertNil(f.editors[0].managedSearchTestPanel)
      XCTAssertEqual(f.backend.unregistered.count, 1)
      XCTAssertFalse(b.testOnlyLogicallyClosed)
      XCTAssertTrue(
        app.task4DispatchCaptured("file.close", window: captured) { _, _ in
          XCTFail("Repeated close leaked")
          return false
        })
      XCTAssertEqual(f.backend.unregistered.count, 1)
      XCTAssertTrue(f.editors[1].managedSearchTestPanel === b)
      XCTAssertEqual(appRoutingNativeSnapshot(f), before)
    }
  }
  func testCapturedSearchAvailabilityAndDispatchShareIdentityAndRefusalPolicy() async throws {
    try await withAppRoutingFixture(windows: 2) { f in
      guard let panels = try f.openPanels() else { return }
      let app = try XCTUnwrap(f.app)
      let panel = panels[0]
      let captured = try XCTUnwrap(panel.window)
      XCTAssertEqual(app.task4Availability("edit.copy", window: captured), true)
      guard app.task4Availability("edit.copy", window: captured) == true else { return }
      let before = appRoutingNativeSnapshot(f)
      for id in ["file.close"] + native.map(\.0) {
        XCTAssertEqual(app.task4Availability(id, window: captured), true)
      }
      for id in refused {
        XCTAssertTrue(Set(app.task4RegisteredCommandIDs).contains(id))
        XCTAssertEqual(app.task4Availability(id, window: captured), false)
        XCTAssertTrue(
          app.task4DispatchCaptured(id, window: captured) { _, _ in
            XCTFail("Refusal forwarded native action")
            return false
          })
      }
      let plain = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
      let mismatch = NSPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
      plain.isReleasedWhenClosed = false
      mismatch.isReleasedWhenClosed = false
      // Real public negative association, like the established preview identity test. Never a positive ownership receipt.
      mismatch.windowController = panel
      defer {
        mismatch.windowController = nil
        mismatch.close()
        plain.close()
      }
      XCTAssertTrue(mismatch.windowController === panel)
      XCTAssertFalse(panel.window === mismatch)
      for candidate in [nil, f.editors[0].window, plain, mismatch] as [NSWindow?] {
        for id in ["file.close", "file.save", "edit.undo"] {
          XCTAssertNil(app.task4Availability(id, window: candidate))
          XCTAssertFalse(
            app.task4DispatchCaptured(id, window: candidate) { _, _ in
              XCTFail("Unclaimed window forwarded native action")
              return false
            })
        }
      }
      XCTAssertFalse(panel.testOnlyLogicallyClosed)
      XCTAssertFalse(panels[1].testOnlyLogicallyClosed)
      XCTAssertTrue(f.editors[0].managedSearchTestPanel === panel)
      XCTAssertEqual(appRoutingNativeSnapshot(f), before)
      XCTAssertEqual(f.externalCalls, 0)
      XCTAssertEqual(f.backend.unregistered.count, 0)
    }
  }
  func testActualManagedConfigurationStaysSearchLazyAndAppGuardsPrecedeScope() async throws {
    try await withAppRoutingFixture(shortcuts: false) { f in
      let app = try XCTUnwrap(f.app)
      XCTAssertFalse(app.task4RegistryReady)
      XCTAssertEqual(f.ownerFactories, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      XCTAssertEqual(f.bridge.phase, .notCreated)
      let item = NSMenuItem(title: "Synthetic Copy", action: nil, keyEquivalent: "")
      item.representedObject = "edit.copy"
      XCTAssertFalse(app.validateMenuItem(item))
      // Actual public early registry guard, no key-window substitution.
      XCTAssertFalse(
        app.task4DispatchCaptured("edit.copy", window: f.editors[0].window) { _, _ in
          XCTFail("Not-ready leaked action")
          return false
        })
      try await f.loadShortcuts()
      XCTAssertTrue(app.task4RegistryReady)
      XCTAssertNotNil(f.shortcutOwner?.state.composition)
      XCTAssertEqual(f.ownerFactories, 0)
      XCTAssertTrue(f.factoryCalls.isEmpty)
      guard let panels = try f.openPanels() else { return }
      let panel = panels[0]
      let captured = try XCTUnwrap(panel.window)
      XCTAssertEqual(f.ownerFactories, 1)
      XCTAssertEqual(f.factoryCalls.count, 1)
      let published = try XCTUnwrap(app.task4PublishedKeys["edit.find"])
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil,
          characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
      XCTAssertTrue(
        NativeCommandKeyAdmission.shouldReject(
          sender: published.item, snapshot: published,
          publication: app.task4CommandPublication, scopedEvent: event, currentEvent: event))
      // Unposted argument control only; original public command(sender) ordering is separately byte-protected.
      let before = appRoutingNativeSnapshot(f)
      f.writer.arm()
      guard let join = try f.beginQuit() else { return }
      await f.writer.waitForEntry()
      XCTAssertTrue(app.task4PreparingQuit)
      XCTAssertTrue(app.task4MonitoringSuspended)
      XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
      XCTAssertEqual(f.replies, [])
      XCTAssertEqual(f.backend.joinCalls, 0)
      XCTAssertEqual(f.externalCalls, 0)
      for id in [
        "file.close", "file.recent", "file.retrySession", "file.restoreSession", "edit.copy",
        "app.shortcuts",
      ] {
        XCTAssertEqual(app.task4Availability(id, window: captured), false)
        XCTAssertFalse(
          app.task4DispatchCaptured(id, window: captured) { _, _ in
            XCTFail("Preparing Quit leaked scope action")
            return false
          })
      }
      XCTAssertEqual(appRoutingNativeSnapshot(f), before)
      f.writer.release()
      let completed = await join()
      XCTAssertTrue(completed.replyConsumed)
      XCTAssertEqual(f.replies, [true])
      try f.assertFreshNativeReceipt(try XCTUnwrap(completed.nativeReceipt))
      XCTAssertEqual(f.externalCalls, 1)
    }
  }
  func testActualQuitPublishesNativeReceiptThenJoinsSearchAndExternalExactlyOnceAcrossVetoAndRetry()
    async throws
  {
    // Four independently owned finite variants; no physical Quit/App termination or actual helper process.
    for variant in 0..<4 {
      try await withAppRoutingFixture { f in
        guard f.configurationReached() else { return }
        let app = try XCTUnwrap(f.app)
        var panel: DocumentSearchPanelController?
        var approval: DocumentSearchApprovalToken?
        if variant == 1 || variant == 2 {
          guard let panels = try f.openPanels() else { return }
          panel = panels[0]
          approval = try f.approval(panels[0])
        }
        if variant == 1 {
          let original = appRoutingRow("parentLane")
          f.backend.joinValues = [original, appRoutingSameParentWithNoResidual(original)]
        }
        let searchGate = AppRoutingGate()
        if variant == 1 || variant == 2 { f.backend.joinHold = searchGate }
        let external = AppRoutingGate()
        f.externalGate = external
        f.writer.arm(failing: variant == 0)
        guard let join = try f.beginQuit() else { return }
        let firstID = try XCTUnwrap(app.task4Attempt?.id)
        await f.writer.waitForEntry()
        XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(app.task4Attempt?.id, firstID)
        XCTAssertEqual(f.replies, [])
        XCTAssertEqual(f.backend.joinCalls, 0)
        XCTAssertEqual(f.externalCalls, 0)
        XCTAssertNil(app.task4Attempt?.nativeReceipt)
        if let panel, let approval {
          XCTAssertNil(panel.testOnlyDisplayedApproval)
          XCTAssertTrue(panel.testOnlyControls.approvalRow.isHidden)
          XCTAssertFalse(panel.testOnlyRespondToApproval(approval, approved: true))
          XCTAssertEqual(f.models[0].storage.string, "😀x\n")
        }
        if variant == 0 {
          f.permitsPublicationErrors = true
          var reentered: (@MainActor () async -> AppSearchAttemptTestFacts)?
          f.replyHook = { [weak f, weak app] accepted in
            guard let f, let app, !accepted, f.replies.count == 1 else { return }
            XCTAssertFalse(app.task4PreparingQuit)
            XCTAssertNil(
              app.task4Attempt,
              "False reply permits a fresh attempt only after exact prior slot release")
            f.writer.restoreWrites()
            f.writer.arm()
            do { reentered = try f.beginQuit() } catch {
              XCTFail("Actual callback reentry failed: \(error)")
            }
          }
          f.writer.release()
          let failed = await join()
          XCTAssertNil(failed.nativeReceipt)
          XCTAssertNil(failed.decision)
          XCTAssertTrue(failed.replyConsumed)
          XCTAssertEqual(f.replies, [false])
          XCTAssertEqual(f.backend.joinCalls, 0)
          XCTAssertEqual(f.externalCalls, 0)
          XCTAssertEqual(
            f.bridge.phase, .prepared,
            "New reentrant absence preparation must survive returning old frame")
          XCTAssertNotEqual(app.task4Attempt?.id, firstID)
          guard let secondJoin = reentered else { throw AppRoutingError.missing }
          await f.writer.waitForEntry()
          XCTAssertFalse(f.errors.isEmpty)
          XCTAssertTrue(f.errors.allSatisfy { ($0 as? AppRoutingError) == .publication })
          f.writer.release()
          await external.entered.wait()
          XCTAssertEqual(f.replies, [false])
          XCTAssertEqual(f.externalCalls, 1)
          XCTAssertNotNil(app.task4Attempt?.nativeReceipt)
          external.release()
          let second = await secondJoin()
          XCTAssertNotEqual(second.id, firstID)
          XCTAssertEqual(second.decision, .noSearchOwner)
          XCTAssertEqual(f.replies, [false, true])
          XCTAssertTrue(second.replyConsumed)
          try f.assertFreshNativeReceipt(try XCTUnwrap(second.nativeReceipt))
          XCTAssertEqual(f.ownerFactories, 0)
        } else {
          f.writer.release()
          if variant == 1 || variant == 2 {
            await searchGate.entered.wait()
            XCTAssertNotNil(app.task4Attempt?.nativeReceipt)
            XCTAssertEqual(f.replies, [])
            XCTAssertEqual(f.externalCalls, 0)
            XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            searchGate.release()
          }
          if variant == 1 {
            let first = await join()
            let firstReceipt = try XCTUnwrap(first.nativeReceipt)
            try f.assertFreshNativeReceipt(firstReceipt)
            guard let firstDecision = first.decision,
              case .terminal(let oldJoin, let firstRaw, _, .unsettled) = firstDecision
            else { throw AppRoutingError.missing }
            XCTAssertEqual(f.replies, [false])
            XCTAssertEqual(f.externalCalls, 0)
            XCTAssertFalse(app.task4PreparingQuit)
            XCTAssertFalse(app.task4MonitoringSuspended)
            XCTAssertEqual(f.bridge.phase, .terminal)
            do {
              _ = try f.bridge.ownerForFind()
              XCTFail("Terminal owner must not reopen")
            } catch let failure as NativeApplicationSearchRefusal {
              XCTAssertEqual(failure, .terminal)
            } catch { XCTFail("Wrong actual terminal refusal: \(error)") }
            f.backend.joinHold = nil
            // The first real mock call already returned; no task or SDK cancellation.
            f.writer.arm()
            guard let secondJoin = try f.beginQuit() else { return }
            await f.writer.waitForEntry()
            XCTAssertNotEqual(app.task4Attempt?.id, firstID)
            f.writer.release()
            let second = await secondJoin()
            let receipt = try XCTUnwrap(second.nativeReceipt)
            XCTAssertGreaterThan(receipt.generation, firstReceipt.generation)
            try f.assertFreshNativeReceipt(receipt)
            for id in firstReceipt.recoveryRevisions.keys {
              XCTAssertGreaterThan(
                try XCTUnwrap(receipt.recoveryRevisions[id]),
                try XCTUnwrap(firstReceipt.recoveryRevisions[id]))
            }
            guard let secondDecision = second.decision,
              case .terminal(let latestJoin, let preservedFirst, _, .unsettled) = secondDecision
            else { throw AppRoutingError.missing }
            XCTAssertEqual(latestJoin, oldJoin)
            XCTAssertEqual(preservedFirst, firstRaw)
            XCTAssertEqual(f.replies, [false, false])
            XCTAssertEqual(f.externalCalls, 0)
            XCTAssertEqual(f.backend.joinCalls, 2)
            XCTAssertEqual(f.ownerFactories, 1)
          } else {
            await external.entered.wait()
            XCTAssertEqual(f.replies, [])
            XCTAssertEqual(f.externalCalls, 1)
            XCTAssertNotNil(app.task4Attempt?.nativeReceipt)
            XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            external.release()
            let completed = await join()
            try f.assertFreshNativeReceipt(try XCTUnwrap(completed.nativeReceipt))
            if variant == 3 {
              XCTAssertEqual(completed.decision, .noSearchOwner)
              XCTAssertEqual(f.ownerFactories, 0)
              XCTAssertEqual(f.backend.joinCalls, 0)
            } else {
              guard let decision = completed.decision, case .terminal(_, _, _, .settled) = decision
              else { throw AppRoutingError.missing }
              XCTAssertEqual(f.backend.joinCalls, 1)
              XCTAssertEqual(f.ownerFactories, 1)
            }
            XCTAssertEqual(f.replies, [true])
            XCTAssertTrue(completed.replyConsumed)
            XCTAssertEqual(app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            XCTAssertEqual(f.replies, [true])
            XCTAssertEqual(f.externalCalls, 1)
          }
        }
      }
    }
  }
}

private enum AppRoutingError: Error, Equatable { case missing, unsafe, bound, publication }
// Explicit service collaborator; synchronization is Test-owned, not a native/SDK completion receipt.
private final class AppRoutingStoreControl: @unchecked Sendable {
  private let condition = NSCondition()
  private let store: SessionStore
  private var holdNext = false, entered = false, released = false, failWrites = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var writes = 0
  init(_ store: SessionStore) { self.store = store }
  func arm(failing: Bool = false) {
    condition.lock()
    defer { condition.unlock() }
    precondition(!holdNext && waiter == nil)
    holdNext = true
    entered = false
    released = false
    failWrites = failing
  }
  func save(_ session: EditorSession) throws {
    condition.lock()
    writes += 1
    guard writes <= 16 else {
      condition.unlock()
      throw AppRoutingError.bound
    }
    if holdNext {
      holdNext = false
      entered = true
      let pending = waiter
      waiter = nil
      pending?.resume()
      while !released { condition.wait() }
    }
    let fail = failWrites
    condition.unlock()
    if fail { throw AppRoutingError.publication }
    try store.save(session)
    // Actual synthetic SessionStore; no receipt or native result is constructed.
  }
  func waitForEntry() async {
    await withCheckedContinuation { continuation in
      condition.lock()
      defer { condition.unlock() }
      if entered {
        continuation.resume()
      } else {
        precondition(waiter == nil)
        waiter = continuation
      }
    }
  }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
  func restoreWrites() {
    condition.lock()
    failWrites = false
    condition.unlock()
  }
  var hasUnreleasedArm: Bool {
    condition.lock()
    defer { condition.unlock() }
    return holdNext || (entered && !released)
  }
}
@MainActor private final class AppRoutingSignal<Value> {
  private var value: Value?, waiter: CheckedContinuation<Value, Never>?
  func send(_ incoming: Value) {
    guard case .none = value else { return }
    value = incoming
    let continuation = waiter
    waiter = nil
    continuation?.resume(returning: incoming)
  }
  func wait() async -> Value {
    if let value { return value }
    return await withCheckedContinuation { continuation in
      precondition(waiter == nil)
      waiter = continuation
    }
  }
}
@MainActor private final class AppRoutingGate {
  let entered = AppRoutingSignal<Void>()
  private let released = AppRoutingSignal<Void>()
  var calls = 0, returns = 0
  func enter() async {
    calls += 1
    precondition(calls == 1)
    entered.send(())
    await released.wait()
    returns += 1
  }
  func release() { released.send(()) }
}

@MainActor private enum AppRoutingCustody {
  private static var retained: AppRoutingFixture?
  static func requireEmpty() throws {
    guard retained == nil else {
      XCTFail("Previous exact managed fixture remains in custody")
      throw AppRoutingError.unsafe
    }
  }
  static func retain(_ fixture: AppRoutingFixture) {
    guard retained == nil || retained === fixture else {
      XCTFail("One-slot custody overflow")
      return
    }
    retained = fixture
  }
}
@MainActor private final class AppRoutingCloseReceipt {
  weak var window: NSWindow?
  var count = 0, exact = true
  init(_ window: NSWindow) { self.window = window }
  func receive(_ note: Notification) {
    count += 1
    exact = exact && (note.object as? NSWindow) === window
    XCTAssertLessThanOrEqual(count, 1)
  }
}
@MainActor private final class AppRoutingFactoryCall {
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

@MainActor private final class AppRoutingFixture {
  let directory: URL, recoveryDirectory: URL
  let store: SessionStore, recovery: RecoveryCoordinator, session: SessionCoordinator
  let writer: AppRoutingStoreControl, backend = AppRoutingBackend()
  lazy var searchOwner = ApplicationSearchOwner(backend: backend)
  lazy var bridge = NativeApplicationSearches(ownerFactory: { [weak self] in
    guard let self else { throw AppRoutingError.missing }
    self.ownerFactories += 1
    guard self.ownerFactories == 1 else { throw AppRoutingError.bound }
    return self.searchOwner
  })
  var app: AppDelegate?
  var process: NativeApplicationDocuments? { app?.task4Owner }
  var editors: [EditorWindowController] = [], models: [EditorDocument] = []
  var files: [(URL, Data)] = []
  var factoryCalls: [AppRoutingFactoryCall] = [], presented: [DocumentSearchPanelController] = []
  var configuredAtAnnouncement: [Bool] = []
  var ownerFactories = 0, externalCalls = 0
  var errors: [Error] = [], replies: [Bool] = []
  var replyHook: (@MainActor (Bool) -> Void)?
  var externalGate: AppRoutingGate?
  var cleanupRefused = false
  var permitsPublicationErrors = false
  var startedAttempts = 0, joinedAttempts = 0
  var shortcutOwner: ApplicationShortcuts?
  let originalMenu: NSMenu?
  init() throws {
    try AppRoutingCustody.requireEmpty()
    _ = NSApplication.shared
    originalMenu = NSApp.mainMenu
    guard let state = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !state.isEmpty
    else { throw AppRoutingError.missing }
    directory = URL(fileURLWithPath: state, isDirectory: true).appendingPathComponent(
      "app-search-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    self.store = store
    let writer = AppRoutingStoreControl(store)
    self.writer = writer
    recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try writer.save($0) }, readCheckpointSession: { try store.load() })
    self.recovery = recovery
    session = SessionCoordinator(
      loadSession: { try store.load() }, claimRecovery: { try await recovery.claimStartup() })
    app = AppDelegate(
      session: session, recovery: recovery, documentSearches: bridge,
      cancelExternalCommands: { [weak self] in
        guard let self else { return }
        self.externalCalls += 1
        precondition(self.externalCalls <= 1)
        if let gate = self.externalGate { await gate.enter() }
        await ExternalCommandController.cancelAllAndWait()
        // REAL empty-domain production method after the Test-owned order gate.
      },
      makeDocumentSearchPanel: { [weak self] owner, ticket, source, onClose in
        guard let self, self.factoryCalls.count < 2 else { throw AppRoutingError.bound }
        XCTAssertTrue(owner === self.searchOwner)
        XCTAssertTrue(source is EditorDocumentSearchSource)
        let call = AppRoutingFactoryCall(owner, ticket, source, onClose)
        self.factoryCalls.append(call)
        return try call.construct()
      }, presentDocumentSearchPanel: { [weak self] panel in self?.presented.append(panel) },
      presentEditorWindow: { [weak self] editor in
        self?.configuredAtAnnouncement.append(editor.managedSearchTestFacts.configured)
      },
      reportDocumentError: { [weak self] error in
        guard let self else { return }
        guard self.errors.count < 4 else {
          XCTFail("Bounded error callback overflow")
          self.cleanupRefused = true
          return
        }
        self.errors.append(error)
      },
      replyToTermination: { [weak self] value in
        guard let self else { return }
        guard self.replies.count < 3 else {
          XCTFail("Bounded reply callback overflow")
          self.cleanupRefused = true
          return
        }
        self.replies.append(value)
        XCTAssertLessThanOrEqual(self.replies.count, 2)
        self.replyHook?(value)
      },
      presentSessionAdjustment: { XCTFail("Synthetic fixed positions should not need adjustment") })
  }
  func start(windows: Int) async throws {
    precondition((1...2).contains(windows))
    var stored: [SessionWindow] = []
    for wi in 0..<windows {
      let file = directory.appendingPathComponent("synthetic-\(wi).txt")
      let bytes = Data((wi == 0 ? "😀x\n" : "😀q\n").utf8)
      try bytes.write(to: file, options: .atomic)
      files.append((file, bytes))
      let tab = SessionTab(originalPath: file.path)
      stored.append(SessionWindow(tabs: [tab], selectedTabID: tab.id))
    }
    try store.save(EditorSession(windows: stored))
    try await XCTUnwrap(app).task4StartDocuments()
    let owner = try XCTUnwrap(process)
    let windowsNow = try owner.registry.captureReadyWindows()
    XCTAssertEqual(windowsNow.count, windows)
    XCTAssertEqual(owner.windows.count, windows)
    guard windowsNow.count == windows, owner.windows.count == windows, session.restorationComplete,
      session.unresolved.isEmpty
    else { throw AppRoutingError.missing }
    for spec in stored {
      let editor = try XCTUnwrap(owner.windows.first { $0.sessionMetadata.id == spec.id })
      let projection = try XCTUnwrap(windowsNow.first { $0.id == spec.id })
      XCTAssertEqual(projection.groups.count, 1)
      guard projection.groups.count == 1, let group = projection.groups.first else {
        throw AppRoutingError.missing
      }
      XCTAssertEqual(group.documentIDs.count, 1)
      guard group.documentIDs.count == 1, let id = group.documentIDs.first else {
        throw AppRoutingError.missing
      }
      let model = try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument)
      let pane = try XCTUnwrap(editor.focusedPane)
      let window = try XCTUnwrap(editor.window)
      editors.append(editor)
      models.append(model)
      XCTAssertTrue(pane.isAttached)
      XCTAssertTrue(pane.document === model)
      XCTAssertEqual(editor.selectedDocumentID, model.id)
      XCTAssertFalse(window.isVisible)
      guard pane.isAttached, pane.document === model, editor.selectedDocumentID == model.id,
        window.windowController === editor, window.delegate as AnyObject? === editor,
        !window.isVisible, !editor.managedSearchTestFacts.windowClosed
      else { throw AppRoutingError.unsafe }
      try requireClean(model)
      let item = try model.captureAuthorizedRecovery()
      XCTAssertNil(item.snapshot)
      XCTAssertEqual(item.authority, model.recoveryAuthority)
      guard item.snapshot == nil, item.authority == model.recoveryAuthority,
        item.authority.documentID == model.id, item.revision == model.highestIssuedRecoveryRevision
      else { throw AppRoutingError.unsafe }
      try await recovery.persistAuthorizedBatch([item])
    }
    let fresh = try RecoveryStore(directory: recoveryDirectory).loadReport(quarantineInvalid: false)
    guard fresh.snapshots.isEmpty, fresh.quarantinedCount == 0 else { throw AppRoutingError.unsafe }
  }
  func loadShortcuts() async throws {
    let actual = ApplicationShortcuts(
      services: ShortcutServices(
        store: ShortcutStore(directory: directory.appendingPathComponent("shortcuts"))),
      catalog: try AppCommands.registry().commands)
    shortcutOwner = actual
    try await actual.load()
    guard actual.state.composition != nil, actual.state.canQuit else {
      throw AppRoutingError.missing
    }
    try XCTUnwrap(app).task4InstallLoadedShortcuts(actual)
    XCTAssertTrue(try XCTUnwrap(app).task4RegistryReady)
  }
  func configurationReached() -> Bool {
    XCTAssertEqual(configuredAtAnnouncement.count, editors.count)
    for editor in editors {
      XCTAssertTrue(
        editor.managedSearchTestFacts.configured,
        "Actual App configureEditor must install lazy managed Find")
    }
    XCTAssertTrue(
      configuredAtAnnouncement.allSatisfy { $0 },
      "Configuration must return before genuine announcement")
    guard !editors.isEmpty, configuredAtAnnouncement.count == editors.count,
      configuredAtAnnouncement.allSatisfy({ $0 }),
      editors.allSatisfy({ $0.managedSearchTestFacts.configured })
    else {
      print("APP_SEARCH Source/quit horizons UNENTERED; missing actual App installation")
      return false  // Never fall through to unconfigured legacy Find or legacy asynchronous Quit.
    }
    return true
  }
  func openPanels() throws -> [DocumentSearchPanelController]? {
    guard configurationReached() else { return nil }
    var panels: [DocumentSearchPanelController] = []
    for editor in editors {
      editor.execute("edit.find")
      XCTAssertNotNil(editor.managedSearchTestPanel)
      guard let panel = editor.managedSearchTestPanel else { return nil }
      panels.append(panel)
      XCTAssertFalse(panel.window?.isVisible ?? true)
    }
    XCTAssertEqual(factoryCalls.count, editors.count)
    XCTAssertEqual(backend.registered.count, editors.count)
    return panels
  }
  func send(_ control: NSControl) {
    guard let action = control.action, let target = control.target else {
      XCTFail("Missing real panel action")
      return
    }
    XCTAssertTrue(NSApp.sendAction(action, to: target, from: control))
  }
  func approval(_ panel: DocumentSearchPanelController) throws -> DocumentSearchApprovalToken {
    let index = backend.submissions.count
    send(panel.testOnlyControls.replace)
    XCTAssertEqual(backend.submissions.count, index + 1)
    guard backend.submissions.count == index + 1 else { throw AppRoutingError.missing }
    let captured = try backend.capture(index)
    let lease = backend.install(
      captured, matches: [NSRange(location: 2, length: 1)], replacement: "😀y\n")
    backend.deliver(index, .completed(lease))
    guard let state = panel.testOnlySessionState,
      case .awaitingApproval(let token, let count) = state
    else { throw AppRoutingError.missing }
    XCTAssertEqual(count, 1)
    XCTAssertEqual(panel.testOnlyDisplayedApproval, token)
    return token
  }
  func beginQuit() throws -> (@MainActor () async -> AppSearchAttemptTestFacts)? {
    let app = try XCTUnwrap(app)
    let answer = app.applicationShouldTerminate(NSApplication.shared)
    XCTAssertEqual(answer, .terminateLater)
    XCTAssertNotNil(app.task4Attempt, "Actual app must reserve its owned attempt before any effect")
    XCTAssertEqual(app.task4Attempt?.hasPreparation, true)
    guard answer == .terminateLater, app.task4Attempt?.hasTask == true else {
      cleanupRefused = true
      // Any entered legacy/unowned continuation is unknown; no forced drain or deletion.
      print("APP_SEARCH canonical-attempt horizon UNENTERED")
      return nil
    }
    let original = try app.task4CaptureCurrentAttemptJoin()
    // Exact synchronous capture before any release.
    let id = try XCTUnwrap(app.task4Attempt?.id)
    startedAttempts += 1
    return { [self] in
      let value = await original()
      XCTAssertEqual(value.id, id)
      joinedAttempts += 1
      return value
    }
  }
  func assertFreshNativeReceipt(_ receipt: SessionCheckpointReceipt) throws {
    let actual = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    XCTAssertEqual(Set(actual.windows.flatMap(\.tabs).map(\.id)), Set(models.map(\.id)))
    XCTAssertEqual(Set(receipt.recoveryRevisions.keys), Set(models.map(\.id)))
    XCTAssertEqual(Set(receipt.recoveryAuthorities.keys), Set(models.map(\.id)))
    for model in models {
      XCTAssertEqual(receipt.recoveryAuthorities[model.id], model.recoveryAuthority)
      let revision = try XCTUnwrap(receipt.recoveryRevisions[model.id])
      XCTAssertGreaterThan(revision, 0)
      XCTAssertLessThanOrEqual(revision, model.highestIssuedRecoveryRevision)
    }
    let recovery = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    XCTAssertTrue(recovery.snapshots.isEmpty)
    XCTAssertEqual(recovery.quarantinedCount, 0)
    for (file, bytes) in files { XCTAssertEqual(try Data(contentsOf: file), bytes) }
  }
  func requireClean(_ model: EditorDocument) throws {
    let state = try model.captureCloseState()
    XCTAssertFalse(model.dirty)
    XCTAssertFalse(state.isDirty)
    let native = model.undoManager
    guard !model.dirty, !state.isDirty, !state.hasPendingPublication, !state.hasPendingTextEdits,
      !state.isComposing, state.operationID == nil, !native.isUndoing, !native.isRedoing,
      native.groupingLevel == 0
    else { throw AppRoutingError.unsafe }
  }
  func closeDocument(_ editor: EditorWindowController, _ model: EditorDocument) async throws {
    let owner = try XCTUnwrap(process)
    try requireClean(model)
    guard owner.registry.handle(id: model.id) as? EditorDocument === model,
      editor.managedSearchTestFacts.documentIDs.contains(model.id)
    else { throw AppRoutingError.unsafe }
    editor.selectSessionTab(model.id)
    guard editor.selectedDocumentID == model.id else { throw AppRoutingError.unsafe }
    let text = model.storage.string
    let revision = model.editRevision
    let state = try model.captureCloseState()
    editor.execute("file.close")
    let status = try XCTUnwrap(owner.managedSearchTestCloseStatus)
    let joined = try await owner.managedSearchTestWaitClose(status.id)
    let settled = try XCTUnwrap(joined.status)
    guard case .completed(let ids) = joined.result else {
      XCTFail("Real close must complete clean input")
      throw AppRoutingError.unsafe
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
    else { throw AppRoutingError.unsafe }
  }
  func closeEmptyWindow(_ editor: EditorWindowController) throws {
    let owner = try XCTUnwrap(process)
    let window = try XCTUnwrap(editor.window)
    let id = editor.sessionMetadata.id
    guard editor.managedSearchTestFacts.documentIDs.isEmpty, editor.sessionMetadata.tabs.isEmpty,
      owner.registry.window(id: id) != nil
    else { throw AppRoutingError.unsafe }
    for model in models { try requireClean(model) }
    let receipt = AppRoutingCloseReceipt(window)
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
    else { throw AppRoutingError.unsafe }
  }
  func finish() async throws {
    guard !cleanupRefused, startedAttempts == joinedAttempts, replies.count == startedAttempts,
      !writer.hasUnreleasedArm,
      externalGate.map({ $0.calls == $0.returns }) ?? true,
      backend.joinHold.map({ $0.calls == $0.returns }) ?? true
    else { throw AppRoutingError.unsafe }
    replyHook = nil
    writer.restoreWrites()
    backend.clearHooks()
    // Explicitly qualified native cleanup rollback AFTER all tested replies/original task joins.
    let owner = try XCTUnwrap(process)
    if try XCTUnwrap(app).task4PreparingQuit {
      guard !replies.isEmpty else { throw AppRoutingError.unsafe }
      owner.cancelPreparedQuit()
      // True producer action, never a private preparing/registry/SDK setter.
    }
    for call in factoryCalls { call.panel?.close() }
    backend.finishPending()
    for editor in editors where !editor.managedSearchTestFacts.windowClosed {
      for id in editor.managedSearchTestFacts.documentIDs {
        try await closeDocument(
          editor, try XCTUnwrap(owner.registry.handle(id: id) as? EditorDocument))
      }
      try closeEmptyWindow(editor)
    }
    let final = try await owner.prepareQuit()
    let fresh = try XCTUnwrap(
      SessionStore(directory: directory.appendingPathComponent("session")).load())
    let report = try RecoveryStore(directory: recoveryDirectory).loadReport(
      quarantineInvalid: false)
    XCTAssertTrue(owner.windows.isEmpty)
    XCTAssertTrue(try owner.registry.captureReadyWindows().isEmpty)
    XCTAssertTrue(final.recoveryAuthorities.isEmpty)
    XCTAssertTrue(final.recoveryRevisions.isEmpty)
    XCTAssertTrue(fresh.windows.isEmpty)
    XCTAssertTrue(report.snapshots.isEmpty)
    XCTAssertEqual(report.quarantinedCount, 0)
    XCTAssertEqual(Set(backend.registered), Set(backend.unregistered))
    XCTAssertEqual(backend.registered.count, backend.unregistered.count)
    XCTAssertEqual(backend.pendingTerminalCount, 0)
    XCTAssertTrue(backend.payloads.isEmpty)
    XCTAssertEqual(backend.borrowDepth, 0)
    XCTAssertTrue(
      errors.allSatisfy { permitsPublicationErrors && ($0 as? AppRoutingError) == .publication })
    guard owner.windows.isEmpty, try owner.registry.captureReadyWindows().isEmpty,
      final.recoveryAuthorities.isEmpty, final.recoveryRevisions.isEmpty, fresh.windows.isEmpty,
      report.snapshots.isEmpty, report.quarantinedCount == 0,
      Set(backend.registered) == Set(backend.unregistered),
      backend.registered.count == backend.unregistered.count,
      backend.pendingTerminalCount == 0, backend.payloads.isEmpty, backend.borrowDepth == 0,
      errors.allSatisfy({ permitsPublicationErrors && ($0 as? AppRoutingError) == .publication })
    else { throw AppRoutingError.unsafe }
    for (file, bytes) in files {
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      guard try Data(contentsOf: file) == bytes else { throw AppRoutingError.unsafe }
    }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    guard permissions?.intValue == 0o700 else { throw AppRoutingError.unsafe }
    // Scripted backend has no actual driver/child. Its uncertainty metadata is neither repaired nor a shutdown certificate.
    // Every actually entered native/app/backend gate must have been joined by its body before reaching this cleanup.
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    NSApp.mainMenu = originalMenu
    // Exact Test-owned publication restore, after all task/action callouts have returned.
  }
}
@MainActor private func withAppRoutingFixture(
  windows: Int = 1, shortcuts: Bool = true,
  body: @MainActor (AppRoutingFixture) async throws -> Void
) async throws {
  let f = try AppRoutingFixture()
  do {
    try await f.start(windows: windows)
    if shortcuts { try await f.loadShortcuts() }
  } catch {
    AppRoutingCustody.retain(f)
    throw error
  }
  var primary: Error?
  do { try await body(f) } catch { primary = error }
  do { try await f.finish() } catch {
    AppRoutingCustody.retain(f)
    XCTFail("Separate exact app/native cleanup refusal; fixture and directory retained")
    throw primary ?? error
  }
  if let primary { throw primary }
}
@MainActor private func appRoutingNativeSnapshot(_ f: AppRoutingFixture) -> [String] {
  f.models.map { "\($0.id)|\($0.editRevision)|\($0.storage.string)" }
}

@MainActor private final class AppRoutingBackend: ApplicationSearchBackend {
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
  var borrowDepth = 0
  var pendingTerminalCount: Int { submissions.filter { !$0.delivered }.count }
  func registration(_ index: Int) throws -> SearchConsumerID {
    guard registered.indices.contains(index) else {
      XCTFail("Missing real registration")
      throw AppRoutingError.missing
    }
    return registered[index]
  }
  func submission(_ index: Int) throws -> Submission {
    guard submissions.indices.contains(index) else {
      XCTFail("Missing real submission")
      throw AppRoutingError.missing
    }
    return submissions[index]
  }
  func register() -> SearchConsumerID {
    precondition(registered.count < 4)
    let id = SearchConsumerID()
    registered.append(id)
    return id
  }
  func unregister(_ consumer: SearchConsumerID) {
    XCTAssertTrue(registered.contains(consumer))
    XCTAssertFalse(unregistered.contains(consumer))
    guard unregistered.count < 4 else {
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
    guard submissions.count < 4 else {
      XCTFail("Submission cap")
      throw AppRoutingError.bound
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
    return try callback()
  }
  func install(
    _ captured: SearchAdmissionCapture<DocumentSearchCredential>, matches: [NSRange],
    replacement: String?
  ) -> SearchResultLeaseID {
    precondition(matches.count <= 4 && payloads.count < 4)
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
  var joinValues: [SearchAdmissionJoinedShutdownResult] = [appRoutingSuccess()]
  var joinHold: AppRoutingGate?
  var joinCalls = 0
  var joinedTaskCancelled = false
  func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    guard joinCalls < 2, joinValues.indices.contains(joinCalls) else {
      XCTFail("Unexpected joined observation count")
      return .callerRefused(.unsupportedDriver)
    }
    let index = joinCalls
    joinCalls += 1
    if let joinHold {
      await joinHold.enter()
    }
    joinedTaskCancelled = Task.isCancelled
    return joinValues[index]
  }
}

private func appRoutingSuccess() -> SearchAdmissionJoinedShutdownResult {
  .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: .completed(
        SearchParentJoinedShutdownCompletion(
          shutdown: SearchParentWireShutdown(
            child: SearchChildShutdown(cleanup: .noChild, channelsClosed: true),
            parentLaneSettled: true, retainedParentLanes: 0), ownership: .admitted,
          laneStop: .acknowledged)),
      driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0, retainedLeases: 0,
      activeCharge: SearchAdmissionProductionAccounting().resident, retainedCharge: 0,
      reservedRetainedCharge: 0))
}

// Injected protocol observations only; never a concrete child/process completion claim.
private func appRoutingRow(_ row: String) -> SearchAdmissionJoinedShutdownResult {
  if row == "admissionRefused" { return .callerRefused(.synchronousCallbackActive) }
  var ownership: SearchParentJoinedOwnership = .admitted
  switch row {
  case "ownershipStale": ownership = .refused(.staleHandle)
  case "ownershipRequest": ownership = .refused(.requestActive)
  case "ownershipObserver": ownership = .refused(.observerPresent)
  case "ownershipReceipt": ownership = .refused(.receiptUnconsumed)
  case "ownershipAbandoned": ownership = .refused(.abandoned)
  default: break
  }
  let generation = UUID()
  let cleanup: SearchChildCleanup
  switch row {
  case "childPending": cleanup = .pendingLaunch(generation: generation)
  case "childStopping": cleanup = .stopping(generation: generation)
  case "childUnconfirmed": cleanup = .stopUnconfirmed(generation: generation)
  default: cleanup = .noChild
  }
  let parent: SearchParentJoinedShutdownResult =
    row == "parentRefused"
    ? .callerRefused(.differentJoinOwner)
    : .completed(
      SearchParentJoinedShutdownCompletion(
        shutdown: SearchParentWireShutdown(
          child: SearchChildShutdown(cleanup: cleanup, channelsClosed: row != "channels"),
          parentLaneSettled: row != "parentLane",
          retainedParentLanes: row == "parentRetained" ? 1 : 0),
        ownership: ownership, laneStop: row == "laneStop" ? .failed : .acknowledged))
  let settlement: SearchParentWireSettlement =
    row == "driverPending" ? .pending : .settled(admissionClosed: row != "driverOpen")
  let resident = SearchAdmissionProductionAccounting().resident
  let active: UInt64 = row == "activeZero" ? 0 : (row == "activeExtra" ? resident + 1 : resident)
  return .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: parent, driverSettlement: settlement,
      retainedActiveJobs: row == "jobs" ? 1 : 0, retainedLeases: row == "leases" ? 1 : 0,
      activeCharge: active, retainedCharge: row == "retained" ? 1 : 0,
      reservedRetainedCharge: row == "reserved" ? 1 : 0))
}
private func appRoutingSameParentWithNoResidual(_ raw: SearchAdmissionJoinedShutdownResult)
  -> SearchAdmissionJoinedShutdownResult
{
  guard case .observed(let original) = raw else { return raw }
  return .observed(
    SearchAdmissionJoinedShutdownObservation(
      parent: original.parent,
      driverSettlement: .settled(admissionClosed: true), retainedActiveJobs: 0, retainedLeases: 0,
      activeCharge: SearchAdmissionProductionAccounting().resident, retainedCharge: 0,
      reservedRetainedCharge: 0))
}
