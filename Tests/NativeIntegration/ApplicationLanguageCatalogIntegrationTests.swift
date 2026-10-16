// SPDX-License-Identifier: MIT
// STAGED CONTRACT ONLY: NOT AN EXECUTABLE/FROZEN ACCEPTANCE PACKAGE. See API.md dependency gates.
import AppKit
import Darwin
import Foundation
import PadCore
import XCTest

@testable import NativeRouting
@testable import PadCore
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

// APPLICATION CATALOG FIRST-SLICE CONTRACT. The complete original App routing file above is exact.
@MainActor private final class ApplicationCatalogJoinedAttempt {
  let handle: ApplicationCatalogAttemptTestHandle
  unowned let native: AppRoutingFixture
  private(set) var result: AppSearchAttemptTestFacts?
  init(_ handle: ApplicationCatalogAttemptTestHandle, native: AppRoutingFixture) {
    self.handle = handle
    self.native = native
  }
  func join() async -> AppSearchAttemptTestFacts {
    if let result { return result }
    let value = await handle.join()
    XCTAssertEqual(value.id, handle.id)
    result = value
    native.joinedAttempts += 1
    return value
  }
}

@MainActor private final class ApplicationCatalogFixture {
  let native: AppRoutingFixture
  let directory: URL
  let control: MutationControl?
  let catalog: NativeLanguageCatalogOwner?
  var reports: [Error] = []
  var reportHook: (@MainActor (Error) -> Void)?
  var attempts: [ApplicationCatalogJoinedAttempt] = []
  private init(
    native: AppRoutingFixture, directory: URL, control: MutationControl?,
    catalog: NativeLanguageCatalogOwner?
  ) {
    self.native = native
    self.directory = directory
    self.control = control
    self.catalog = catalog
    // The original, unused delegate has not started documents or a catalog. This constructor
    // is the genuine application boundary; no owner field or prepared ID is injected later.
    native.app = AppDelegate(
      session: native.session, recovery: native.recovery, documentSearches: native.bridge,
      languageCatalogOwner: catalog,
      cancelExternalCommands: { [weak native] in
        guard let native else { return }
        native.externalCalls += 1
        XCTAssertLessThanOrEqual(native.externalCalls, 1)
        if let gate = native.externalGate { await gate.enter() }
        await ExternalCommandController.cancelAllAndWait()
      },
      makeDocumentSearchPanel: { [weak native] owner, ticket, source, onClose in
        guard let native, native.factoryCalls.count < 2 else { throw AppRoutingError.bound }
        XCTAssertTrue(owner === native.searchOwner)
        XCTAssertTrue(source is EditorDocumentSearchSource)
        let call = AppRoutingFactoryCall(owner, ticket, source, onClose)
        native.factoryCalls.append(call)
        return try call.construct()
      }, presentDocumentSearchPanel: { [weak native] panel in native?.presented.append(panel) },
      presentEditorWindow: { [weak native] editor in
        native?.configuredAtAnnouncement.append(editor.managedSearchTestFacts.configured)
      },
      reportDocumentError: { [weak self, weak native] error in
        guard let self, let native else { return }
        guard self.reports.count < 8 else {
          XCTFail("Bounded actual application error report overflow")
          native.cleanupRefused = true
          return
        }
        self.reports.append(error)
        if (error as? AppRoutingError) == .publication { native.errors.append(error) }
        self.reportHook?(error)
      },
      replyToTermination: { [weak native] accepted in
        guard let native else { return }
        guard native.replies.count < 3 else {
          XCTFail("Bounded actual termination reply overflow")
          native.cleanupRefused = true
          return
        }
        native.replies.append(accepted)
        native.replyHook?(accepted)
      }, presentSessionAdjustment: { XCTFail("Fixed synthetic positions require no adjustment") })
  }
  static func create(withCatalog: Bool = true) async throws -> ApplicationCatalogFixture {
    let native = try AppRoutingFixture()
    let directory = native.directory.appendingPathComponent("Languages", isDirectory: true)
      .resolvingSymlinksInPath()
    if withCatalog {
      do {
        try await Task.detached(priority: .utility) {
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
          let file = directory.appendingPathComponent("Profiles.json")
          try CatalogTestFixture.originalBytes.write(to: file)
          guard chmod(file.path, 0o600) == 0 else { throw MutationFixtureError.selectedReadFailure }
          _ = try CustomLanguageStore(directory: directory).load()
        }.value
      } catch {
        // No body or feature horizon entered. Preserve the exact partially seeded capsule.
        AppRoutingCustody.retain(native)
        throw error
      }
      let control = MutationControl(directory: directory)
      return .init(
        native: native, directory: directory, control: control,
        catalog: NativeLanguageCatalogOwner(services: control.services))
    }
    return .init(native: native, directory: directory, control: nil, catalog: nil)
  }
  var app: AppDelegate { native.app! }  // Genuine successful constructor assigned once above.
  func startDocuments() async throws { try await native.start(windows: 1) }
  func beginQuit() -> ApplicationCatalogJoinedAttempt? {
    let answer = app.applicationShouldTerminate(NSApplication.shared)
    XCTAssertEqual(answer, .terminateLater)
    let handle = app.applicationCatalogTestCaptureAttempt()
    XCTAssertNotNil(handle, "Real application task must be captured before any dependent wait")
    guard answer == .terminateLater, let handle else {
      native.cleanupRefused = true
      print("APPLICATION_CATALOG actual-attempt horizon UNENTERED")
      return nil
    }
    let attempt = ApplicationCatalogJoinedAttempt(handle, native: native)
    native.startedAttempts += 1
    attempts.append(attempt)
    return attempt
  }
  func wait(_ label: String, _ predicate: @MainActor () -> Bool) async -> Bool {
    let limit = Date().addingTimeInterval(3)
    while !predicate(), Date() < limit {
      do { try await Task.sleep(nanoseconds: 5_000_000) } catch {
        XCTFail("Unexpected Test-owned finite observation cancellation")
        return false
      }
    }
    let reached = predicate()
    XCTAssertTrue(reached, label)
    if !reached { print("APPLICATION_CATALOG deeper horizon UNENTERED: " + label) }
    return reached
  }
  func load() async -> Bool {
    guard let catalog else {
      XCTFail("Actual supplied catalog required")
      return false
    }
    let admission = app.applicationCatalogTestStart()
    let id: UUID?
    if case .started(let value)? = admission { id = value } else { id = nil }
    XCTAssertNotNil(id, "Actual startup read admission precedes any missing producer wait")
    guard let id else { return false }
    guard await settle(id) else { return false }
    XCTAssertNotNil(
      app.applicationCatalogTestFacts.state?.current,
      "App must receive actual owner state without replacing its observer")
    XCTAssertEqual(app.applicationCatalogTestFacts.state?.current?.id, catalog.state.current?.id)
    return app.applicationCatalogTestFacts.state?.current != nil
  }
  func settle(_ id: UUID) async -> Bool {
    guard let catalog else {
      XCTFail("Actual owner missing")
      return false
    }
    return await wait("actual admitted catalog settlement") {
      catalog.state.lastSettledRequestID == id && catalog.mutationState.activeOperation == nil
    }
  }
  func requestID(_ admission: NativeLanguageCatalogMutationAdmission) -> UUID? {
    if case .started(let id) = admission { return id }
    XCTFail("Actual component admission must precede any operation wait")
    return nil
  }
  func draft(_ name: String) throws -> NativeLanguageCatalogDraft {
    try .init(definitions: [CatalogTestFixture.definition(name: name)], overrides: [])
  }
  func apply(_ name: String) async throws -> UUID? {
    guard let catalog, let publication = catalog.state.current else {
      XCTFail("Actual last-good publication required before Apply")
      return nil
    }
    guard
      let id = requestID(
        catalog.requestApply(
          try draft(name), expectedPublication: .current(publication.id)))
    else { return nil }
    guard await settle(id) else { return nil }
    return id
  }
  func bytes() throws -> Data {
    try Data(contentsOf: directory.appendingPathComponent("Profiles.json"))
  }
  func fresh() async throws -> LoadedLanguageCatalog {
    let directory = directory
    return try await Task.detached(priority: .utility) {
      try CustomLanguageStore(directory: directory).load()
    }.value
  }
  func requireReservation() -> UUID? {
    let facts = app.applicationCatalogTestFacts
    XCTAssertTrue(facts.hasCatalogPreparation)
    XCTAssertTrue(facts.reservedOwner === catalog)
    XCTAssertNotNil(facts.quitID, "Real catalog reservation precedes native-writer waits")
    guard let id = facts.quitID, facts.reservedOwner === catalog else { return nil }
    XCTAssertEqual(catalog?.mutationState.preparedQuitID, id)
    return id
  }
  func finish() async throws {
    reportHook = nil
    native.replyHook = nil
    // Release before any join, even after an ordinary missing-feature assertion or thrown setup.
    control?.release()
    control?.failReads(false)
    control?.mode(.clean)
    native.writer.restoreWrites()
    native.writer.release()
    native.externalGate?.release()
    native.backend.joinHold?.release()
    for attempt in attempts { _ = await attempt.join() }
    if let catalog {
      if let id = catalog.mutationState.preparedQuitID {
        // Qualified real cleanup action after all tested replies; no reservation field writes.
        XCTAssertTrue(catalog.cancelPreparedQuit(id))
      }
      if let unresolved = catalog.mutationState.unresolved {
        let admission: NativeLanguageCatalogMutationAdmission
        switch unresolved {
        case .failedAttempt(let id, _, _): admission = catalog.requestRetryFailedAttempt(id)
        case .pending(_, let recovery, .publicationUncertain, _):
          admission = catalog.requestRetryPending(recovery)
        case .pending(_, let recovery, .readbackUnconfirmed, _):
          admission = catalog.requestDiscardAndReload(
            .pending(recovery), confirmation: .discardAttemptAndReload)
        }
        guard let id = requestID(admission), await settle(id),
          catalog.mutationState.unresolved == nil
        else {
          throw AppRoutingError.unsafe
        }
      }
      await catalog.invalidateAndWait()
      guard catalog.mutationState.activeOperation == nil else { throw AppRoutingError.unsafe }
    }
    try await native.finish()
  }
}
extension AppRoutingStoreControl {
  fileprivate var applicationCatalogEntered: Bool {
    condition.lock()
    defer { condition.unlock() }
    return entered
  }
}
@MainActor private enum ApplicationCatalogCustody {
  static var retained: ApplicationCatalogFixture?
}
@MainActor private func withApplicationCatalog(
  withCatalog: Bool = true,
  _ body: @MainActor (ApplicationCatalogFixture) async throws -> Void
) async throws {
  guard ApplicationCatalogCustody.retained == nil else {
    XCTFail("Prior application/catalog fixture remains in custody")
    throw AppRoutingError.unsafe
  }
  let f = try await ApplicationCatalogFixture.create(withCatalog: withCatalog)
  var primary: Error?
  do {
    try await f.startDocuments()
    try await body(f)
  } catch { primary = error }
  do { try await f.finish() } catch {
    ApplicationCatalogCustody.retained = f
    AppRoutingCustody.retain(f.native)
    XCTFail("Separate genuine application/catalog cleanup refusal; exact fixture retained")
    throw primary ?? error
  }
  if let primary { throw primary }
}

@MainActor final class ApplicationLanguageCatalogTests: XCTestCase {
  func testApplicationCatalogStartupRemainsLazyAndStartsOneActualRead() async throws {
    try await withApplicationCatalog { f in
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      XCTAssertTrue(f.app.applicationCatalogTestFacts.owner === owner)
      XCTAssertTrue(
        control.calls.isEmpty, "Delegate construction/document startup must not read catalog")
      XCTAssertNil(owner.state.current)
      XCTAssertNil(owner.state.activeRequestID)
      let gate = control.hold(.read)
      let result = f.app.applicationCatalogTestStart()
      let id: UUID?
      if case .started(let actual)? = result { id = actual } else { id = nil }
      XCTAssertNotNil(id, "Real helper admission precedes held-read entry wait")
      guard let id else { return }
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.activeRequestID, id)
      await fulfillment(of: [gate.entered], timeout: 3)
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertNil(f.app.applicationCatalogTestStart(), "Repeated startup must request no new read")
      XCTAssertEqual(owner.state.activeRequestID, id)
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertEqual(f.native.process?.windows.count, 1)
      XCTAssertTrue(f.native.session.restorationComplete)
      gate.release()
      guard await f.settle(id) else { return }
      let expected = try await f.fresh()
      XCTAssertNotNil(f.app.applicationCatalogTestFacts.state?.current)
      guard let published = f.app.applicationCatalogTestFacts.state?.current else { return }
      XCTAssertEqual(published.id, owner.state.current?.id)
      XCTAssertEqual(published.requestID, id)
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(published.catalog),
        try LanguageCatalogCodec.encode(expected.snapshot))
      XCTAssertNil(f.app.applicationCatalogTestStart())
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertTrue(control.calls.allSatisfy { !$0.onMain })
      XCTAssertEqual(control.maximum, 1)
      XCTAssertTrue(f.reports.isEmpty)
    }
  }

  func testApplicationCatalogFailureRetainsLastConfirmedPublicationAndDocumentStartup() async throws
  {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      let old = try XCTUnwrap(owner.state.current)
      let model = try XCTUnwrap(f.native.models.first)
      let documentState = try model.captureCloseState()
      let bytes = try f.bytes()
      f.control?.failReads(true)
      guard case .started(let id) = owner.requestLoad() else {
        return XCTFail("Actual collaborator reload must start")
      }
      guard await f.settle(id) else { return }
      XCTAssertEqual(owner.state.failure?.requestID, id)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.failure?.requestID, id)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.lastReportedFailureID, id)
      XCTAssertEqual(f.reports.count, 1)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.current?.id, old.id)
      guard let published = f.app.applicationCatalogTestFacts.state?.current else {
        return XCTFail("Actual prior publication must remain installed")
      }
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(published.catalog),
        try LanguageCatalogCodec.encode(old.catalog))
      XCTAssertEqual(try f.bytes(), bytes)
      XCTAssertTrue(f.native.process?.registry.handle(id: model.id) as? EditorDocument === model)
      XCTAssertEqual(try model.captureCloseState(), documentState)
      XCTAssertTrue(f.native.session.restorationComplete)
      XCTAssertFalse(f.app.task4PreparingQuit)
    }
  }

  func testApplicationCatalogErrorPresentationReentryCannotClobberSuccessorState() async throws {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      let oldID = try XCTUnwrap(owner.state.current?.id)
      let control = try XCTUnwrap(f.control)
      var successor: UUID?
      var successorGate: MutationGate?
      var callbackCount = 0
      f.reportHook = { _ in
        callbackCount += 1
        guard callbackCount == 1 else { return XCTFail("Failure report must be once-only") }
        control.failReads(false)
        successorGate = control.hold(.read)
        if case .started(let id) = owner.requestLoad() {
          successor = id
        } else {
          XCTFail("Real reentrant successor must be admitted")
        }
      }
      control.failReads(true)
      guard case .started(let failedID) = owner.requestLoad() else {
        return XCTFail("Actual failing read must be admitted")
      }
      guard await f.wait("actual application error callback", { callbackCount == 1 }) else {
        return
      }
      XCTAssertNotNil(successor, "Callback must actually admit successor before held-read wait")
      guard let successor, let successorGate else { return }
      XCTAssertNotEqual(successor, failedID)
      await fulfillment(of: [successorGate.entered], timeout: 3)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.activeRequestID, successor)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.current?.id, oldID)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.lastReportedFailureID, failedID)
      successorGate.release()
      guard await f.settle(successor) else { return }
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.lastSettledRequestID, successor)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.current?.requestID, successor)
      XCTAssertNil(f.app.applicationCatalogTestFacts.state?.failure)
      XCTAssertEqual(callbackCount, 1)
      XCTAssertEqual(control.count(.read), 3)
    }
  }

  func testQuitBeforeCatalogStartupNeverConstructsOrReadsCatalog() async throws {
    try await withApplicationCatalog(withCatalog: false) { f in
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(f.app.applicationCatalogTestFacts.state)
      let external = AppRoutingGate()
      f.native.externalGate = external
      f.native.writer.arm()
      guard let attempt = f.beginQuit() else { return }
      // This absent/lazy control can pass baseline and earns no missing-feature RED credit.
      guard
        await f.wait(
          "actual native final writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(f.app.applicationCatalogTestFacts.state)
      XCTAssertEqual(f.native.ownerFactories, 0)
      f.native.writer.release()
      guard await f.wait("actual external drain entry", { external.calls == 1 }) else { return }
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(f.app.applicationCatalogTestFacts.state)
      XCTAssertEqual(f.native.replies, [])
      external.release()
      let done = await attempt.join()
      XCTAssertEqual(done.decision, .noSearchOwner)
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(done.nativeReceipt))
      XCTAssertTrue(done.replyConsumed)
      XCTAssertEqual(f.native.externalCalls, 1)
      XCTAssertEqual(f.native.replies, [true])
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(
        f.app.applicationCatalogTestStart(), "Successful reserved quit cannot start catalog")
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertTrue(f.reports.isEmpty)
    }
  }

  func testBusyCatalogQuitVetoDoesNotInvalidateAndReleasedReadSettles() async throws {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let last = try XCTUnwrap(owner.state.current)
      let gate = control.hold(.read)
      guard case .started(let active) = owner.requestLoad() else {
        return XCTFail("Real busy read must be admitted")
      }
      await fulfillment(of: [gate.entered], timeout: 3)
      guard let attempt = f.beginQuit() else { return }
      guard
        await f.wait(
          "busy quit veto before any held read release",
          {
            f.native.replies == [false]
          })
      else { return }
      let done = await attempt.join()
      XCTAssertEqual(f.native.replies, [false])
      XCTAssertNil(done.nativeReceipt)
      XCTAssertNil(done.decision)
      XCTAssertEqual(f.native.backend.joinCalls, 0)
      XCTAssertEqual(f.native.externalCalls, 0)
      if case .active = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must remain active")
      }
      XCTAssertEqual(owner.state.activeRequestID, active)
      XCTAssertEqual(owner.state.current?.id, last.id)
      XCTAssertNil(owner.mutationState.preparedQuitID)
      XCTAssertFalse(f.app.task4PreparingQuit)
      XCTAssertFalse(f.app.task4MonitoringSuspended)
      gate.release()
      guard await f.settle(active) else { return }
      XCTAssertEqual(f.app.applicationCatalogTestFacts.state?.current?.requestID, active)
      if case .active = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must remain active")
      }
      XCTAssertEqual(control.maximum, 1)
      XCTAssertEqual(f.reports.count, 1)
    }
  }

  func testActualUnresolvedWriteBlocksQuitWithoutAcknowledgingOrDiscarding() async throws {
    for mode in [MutationFaultMode.prepublication, .uncertain] {
      try await withApplicationCatalog { f in
        guard await f.load() else { return }
        let owner = try XCTUnwrap(f.catalog)
        let control = try XCTUnwrap(f.control)
        let previous = try XCTUnwrap(owner.state.current)
        control.mode(mode)
        guard try await f.apply("Actual unresolved synthetic") != nil else { return }
        let attemptID: UUID
        let pendingID: UUID?
        switch (mode, owner.mutationState.unresolved) {
        case (.prepublication, .failedAttempt(let id, .apply, _)?):
          attemptID = id
          pendingID = nil
        case (.uncertain, .pending(let id, let recovery, .publicationUncertain, _)?):
          attemptID = id
          pendingID = recovery
          XCTAssertTrue(control.error is CustomLanguagePublicationUncertain)
        default:
          XCTFail("Actual typed Store fault provenance not reached")
          print("APPLICATION_CATALOG typed-unresolved horizon NO_REACH")
          return
        }
        let wire = try f.bytes()
        let callCount = control.calls.count
        guard let attempt = f.beginQuit() else { return }
        let done = await attempt.join()
        XCTAssertEqual(f.native.replies, [false])
        XCTAssertNil(done.nativeReceipt)
        XCTAssertNil(done.decision)
        XCTAssertEqual(f.native.backend.joinCalls, 0)
        XCTAssertEqual(f.native.externalCalls, 0)
        XCTAssertEqual(control.calls.count, callCount, "Quit cannot retry, verify or discard")
        XCTAssertEqual(try f.bytes(), wire)
        XCTAssertEqual(owner.state.current?.id, previous.id)
        if case .active = owner.state.lifetime {
        } else {
          XCTFail("Actual catalog must remain active")
        }
        XCTAssertNil(owner.mutationState.preparedQuitID)
        XCTAssertFalse(owner.mutationState.canPrepareQuit)
        switch owner.mutationState.unresolved {
        case .failedAttempt(let id, .apply, _)?:
          XCTAssertEqual(id, attemptID)
          XCTAssertNil(pendingID)
        case .pending(let id, let recovery, .publicationUncertain, _)?:
          XCTAssertEqual(id, attemptID)
          XCTAssertEqual(recovery, pendingID)
        default: XCTFail("Quit must preserve actual original unresolved IDs")
        }
        // Cleanup below uses only genuine accepted retry on this same capsule, after oracles.
        control.mode(.clean)
        let retry =
          pendingID.map { owner.requestRetryPending($0) }
          ?? owner.requestRetryFailedAttempt(attemptID)
        guard let id = f.requestID(retry), await f.settle(id) else { return }
        XCTAssertNil(owner.mutationState.unresolved)
        XCTAssertTrue(owner.mutationState.canPrepareQuit)
        XCTAssertEqual(
          f.reports.count, 2, "Actual write failure and Quit refusal are both reported once")
        let fresh = try await f.fresh()
        XCTAssertEqual(
          try LanguageCatalogCodec.encode(fresh.snapshot),
          try LanguageCatalogCodec.encode(try XCTUnwrap(owner.state.current).catalog))
      }
    }
  }

  func testNativeVetoRollsBackOnlyActualCatalogReservationAndKeepsSuccessfulCatalogWrite()
    async throws
  {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      guard try await f.apply("Catalog survives native veto") != nil else { return }
      let confirmed = try XCTUnwrap(owner.state.current)
      let wire = try f.bytes()
      f.native.permitsPublicationErrors = true
      f.native.writer.arm(failing: true)
      guard let attempt = f.beginQuit(), let quitID = f.requireReservation() else { return }
      guard
        await f.wait(
          "actual native final writer after exact catalog reservation",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      XCTAssertEqual(owner.mutationState.preparedQuitID, quitID)
      XCTAssertEqual(f.native.externalCalls, 0)
      f.native.writer.release()
      let done = await attempt.join()
      XCTAssertEqual(f.native.replies, [false])
      XCTAssertNil(done.nativeReceipt)
      XCTAssertNil(done.decision)
      XCTAssertNil(owner.mutationState.preparedQuitID)
      if case .active = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must remain active")
      }
      XCTAssertEqual(owner.state.current?.id, confirmed.id)
      XCTAssertEqual(owner.mutationState.writeReceiptPublicationID, confirmed.id)
      XCTAssertEqual(try f.bytes(), wire)
      XCTAssertEqual(f.native.externalCalls, 0)
      XCTAssertEqual(f.native.backend.joinCalls, 0)
      XCTAssertFalse(f.app.task4PreparingQuit)
      XCTAssertFalse(f.app.task4MonitoringSuspended)
      XCTAssertEqual(f.reports.count, 1)
      XCTAssertTrue(f.reports.allSatisfy { ($0 as? AppRoutingError) == .publication })
      f.native.writer.restoreWrites()
      guard try await f.apply("A real later catalog write") != nil else { return }
      XCTAssertNotEqual(owner.state.current?.id, confirmed.id)
      let fresh = try await f.fresh()
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(fresh.snapshot),
        try LanguageCatalogCodec.encode(try XCTUnwrap(owner.state.current).catalog))
    }
  }

  func testUnsettledSearchVetoReleasesCatalogWithoutReopeningTerminalSearch() async throws {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      guard try f.native.openPanels() != nil else { return }
      let owner = try XCTUnwrap(f.catalog)
      let raw = appRoutingRow("parentLane")
      f.native.backend.joinValues = [raw, appRoutingSameParentWithNoResidual(raw)]
      let search = AppRoutingGate()
      f.native.backend.joinHold = search
      f.native.writer.arm()
      guard let attempt = f.beginQuit(), let quitID = f.requireReservation() else { return }
      guard
        await f.wait(
          "actual native writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      f.native.writer.release()
      guard await f.wait("actual joined search entry", { search.calls == 1 }) else { return }
      XCTAssertEqual(owner.mutationState.preparedQuitID, quitID)
      XCTAssertNotNil(f.app.task4Attempt?.nativeReceipt)
      XCTAssertEqual(f.native.externalCalls, 0)
      search.release()
      let done = await attempt.join()
      guard case .terminal(_, let first, _, .unsettled)? = done.decision else {
        return XCTFail("Actual unsettled search decision required")
      }
      XCTAssertEqual(first, .observed(raw))
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(done.nativeReceipt))
      XCTAssertEqual(f.native.replies, [false])
      XCTAssertEqual(f.native.bridge.phase, .terminal)
      if case .active = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must remain active")
      }
      XCTAssertNil(owner.mutationState.preparedQuitID)
      XCTAssertFalse(f.app.task4PreparingQuit)
      XCTAssertFalse(f.app.task4MonitoringSuspended)
      XCTAssertEqual(f.native.externalCalls, 0)
      do {
        _ = try f.native.bridge.ownerForFind()
        XCTFail("Terminal search must stay unavailable")
      } catch let refusal as NativeApplicationSearchRefusal { XCTAssertEqual(refusal, .terminal) }
      f.native.backend.joinHold = nil
      f.native.writer.arm()
      guard let second = f.beginQuit(), let nextQuit = f.requireReservation() else { return }
      XCTAssertNotEqual(nextQuit, quitID)
      guard
        await f.wait(
          "second actual native writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      f.native.writer.release()
      let secondDone = await second.join()
      guard case .terminal(_, let preserved, _, .unsettled)? = secondDone.decision else {
        return XCTFail("Terminal first observation must survive later clean residuals")
      }
      XCTAssertEqual(preserved, first)
      XCTAssertEqual(f.native.replies, [false, false])
      XCTAssertEqual(f.native.backend.joinCalls, 2)
      XCTAssertEqual(f.native.externalCalls, 0)
      XCTAssertNil(owner.mutationState.preparedQuitID)
      XCTAssertTrue(f.reports.isEmpty)
    }
  }

  func testSuccessfulQuitReservesThenJoinsAndInvalidatesActualCatalogBeforeSingleReply()
    async throws
  {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      let external = AppRoutingGate()
      f.native.externalGate = external
      f.native.writer.arm()
      guard let attempt = f.beginQuit(), let quitID = f.requireReservation() else { return }
      guard
        await f.wait(
          "actual final native writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      if case .active = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must remain active")
      }
      XCTAssertEqual(owner.mutationState.preparedQuitID, quitID)
      XCTAssertNil(f.app.task4Attempt?.nativeReceipt)
      XCTAssertEqual(f.native.externalCalls, 0)
      f.native.writer.release()
      guard await f.wait("irreversible actual external drain entry", { external.calls == 1 })
      else { return }
      if case .invalidated = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must be invalidated")
      }
      XCTAssertNil(owner.mutationState.activeOperation)
      if case .invalidated? = f.app.applicationCatalogTestFacts.state?.lifetime {
      } else {
        XCTFail("App cache must retain actual invalidated state")
      }
      XCTAssertNotNil(f.app.task4Attempt?.nativeReceipt)
      XCTAssertEqual(f.app.task4Attempt?.decision, .noSearchOwner)
      XCTAssertEqual(f.native.replies, [])
      XCTAssertEqual(f.native.externalCalls, 1)
      // Cancel the captured real attempt AFTER irreversible retirement. It must finish joins/success.
      attempt.handle.cancel()
      XCTAssertEqual(f.app.applicationShouldTerminate(NSApplication.shared), .terminateLater)
      external.release()
      let done = await attempt.join()
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(done.nativeReceipt))
      XCTAssertTrue(done.replyConsumed)
      XCTAssertEqual(f.native.replies, [true])
      XCTAssertEqual(f.native.externalCalls, 1)
      XCTAssertEqual(external.calls, 1)
      XCTAssertEqual(external.returns, 1)
      XCTAssertTrue(f.app.task4PreparingQuit)
      XCTAssertTrue(f.reports.isEmpty)
      if case .invalidated = owner.requestLoad() {
      } else {
        XCTFail("Actual retired catalog cannot resume after committed quit")
      }
    }
  }

  func testFalseReplyReentryPreservesNewAttemptAndItsNewCatalogReservation() async throws {
    try await withApplicationCatalog { f in
      guard await f.load() else { return }
      let owner = try XCTUnwrap(f.catalog)
      f.native.permitsPublicationErrors = true
      f.native.writer.arm(failing: true)
      var successor: ApplicationCatalogJoinedAttempt?
      var successorQuitID: UUID?
      var didReenter = false
      f.native.replyHook = { accepted in
        guard !accepted, !didReenter else { return }
        didReenter = true
        XCTAssertFalse(f.app.task4PreparingQuit)
        XCTAssertNil(f.app.task4Attempt)
        XCTAssertNil(owner.mutationState.preparedQuitID)
        f.native.writer.restoreWrites()
        f.native.writer.arm()
        successor = f.beginQuit()
        successorQuitID = f.requireReservation()
      }
      guard let first = f.beginQuit(), let firstQuit = f.requireReservation() else { return }
      guard
        await f.wait(
          "first actual native writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      f.native.writer.release()
      let failed = await first.join()
      XCTAssertNil(failed.nativeReceipt)
      XCTAssertEqual(f.native.replies, [false])
      XCTAssertTrue(didReenter)
      XCTAssertNotNil(successor, "Actual callback successor admission precedes its producer wait")
      XCTAssertNotNil(successorQuitID)
      guard let successor, let successorQuitID else { return }
      XCTAssertNotEqual(successor.handle.id, first.handle.id)
      XCTAssertNotEqual(successorQuitID, firstQuit)
      XCTAssertEqual(f.app.task4Attempt?.id, successor.handle.id)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.quitID, successorQuitID)
      XCTAssertEqual(owner.mutationState.preparedQuitID, successorQuitID)
      guard
        await f.wait(
          "successor actual native writer",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      f.native.writer.release()
      let done = await successor.join()
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(done.nativeReceipt))
      XCTAssertEqual(f.native.replies, [false, true])
      XCTAssertEqual(f.native.externalCalls, 1)
      XCTAssertEqual(f.app.task4Attempt?.id, successor.handle.id)
      XCTAssertEqual(f.reports.count, 1)
      XCTAssertTrue(f.reports.allSatisfy { ($0 as? AppRoutingError) == .publication })
      if case .invalidated = owner.state.lifetime {
      } else {
        XCTFail("Actual catalog must be invalidated")
      }
    }
  }
}

// Read-only manager contract. Reuses the exact real application fixture above.
@MainActor private func withReadOnlyLanguageManager(
  _ body: @MainActor (ApplicationCatalogFixture) async throws -> Void
) async throws {
  try await withApplicationCatalog { fixture in
    defer { fixture.app.languageManagerTestFacts.controller?.close() }
    try await body(fixture)
  }
}

@MainActor private final class LanguageManagerCloseReentry {
  let fixture: ApplicationCatalogFixture
  let original: NativeLanguageManagerController
  var successor: NativeLanguageManagerController?
  var calls = 0
  init(_ fixture: ApplicationCatalogFixture, _ original: NativeLanguageManagerController) {
    self.fixture = fixture
    self.original = original
  }
  func receive() {
    guard calls == 0 else { return }
    calls += 1
    XCTAssertNil(
      fixture.app.languageManagerTestFacts.controller,
      "Exact original slot retires before native close notification")
    XCTAssertFalse(original.languageManagerTestFacts.session.isAttached)
    successor = fixture.app.languageManagerTestMake()
  }
}

@MainActor final class LanguageManagerReadOnlyTests: XCTestCase {
  private func manager(_ f: ApplicationCatalogFixture) -> NativeLanguageManagerController? {
    let result = f.app.languageManagerTestMake()
    XCTAssertNotNil(result, "Real application manager admission precedes every panel/producer wait")
    guard let result else {
      print("LANGUAGE_MANAGER_UNENTERED: real factory admission absent")
      return nil
    }
    XCTAssertNotNil(result.window, "Actual hidden native window required")
    guard let window = result.window else { return nil }
    XCTAssertFalse(window.isVisible)
    let session = result.languageManagerTestFacts.session
    XCTAssertTrue(session.isAttached)
    XCTAssertNotNil(session.snapshot, "Factory must install a real initial delivery")
    guard session.isAttached, session.snapshot != nil else { return nil }
    XCTAssertTrue(f.app.languageManagerTestFacts.controller === result)
    XCTAssertTrue(f.app.languageManagerTestFacts.session === session)
    return result
  }

  private func started(_ value: NativeLanguageCatalogAdmission) -> UUID? {
    if case .started(let id) = value { return id }
    XCTFail("Actual owner load admission required before producer wait")
    return nil
  }

  func testManagerConstructionKeepsOneApplicationCatalogAuthority() async throws {
    try await withApplicationCatalog(withCatalog: false) { f in
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(f.app.languageManagerTestMake())
      XCTAssertNil(f.app.applicationCatalogTestFacts.owner)
      XCTAssertNil(f.app.languageManagerTestFacts.controller)
    }
    try await withReadOnlyLanguageManager { f in
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      XCTAssertTrue(control.calls.isEmpty)
      guard let first = manager(f) else { return }
      XCTAssertTrue(first.languageManagerTestFacts.session.languageManagerTestOwner === owner)
      XCTAssertTrue(f.app.languageManagerTestMake() === first)
      XCTAssertTrue(control.calls.isEmpty, "Panel construction cannot force an extra read")
      guard await f.load() else { return }
      XCTAssertTrue(f.app.languageManagerTestMake() === first)
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertEqual(
        first.languageManagerTestFacts.session.snapshot?.read.current?.id,
        owner.state.current?.id)
      XCTAssertTrue(first.languageManagerTestFacts.close.isEnabled)
      first.languageManagerTestFacts.close.performClick(nil)
      XCTAssertNil(f.app.languageManagerTestFacts.controller)
      XCTAssertFalse(first.languageManagerTestFacts.session.isAttached)
      if case .unavailable = first.languageManagerTestFacts.session.requestRefresh() {
      } else {
        XCTFail("Detached session cannot admit a new read")
      }
      guard let second = manager(f) else { return }
      XCTAssertFalse(second === first)
      XCTAssertTrue(second.languageManagerTestFacts.session.languageManagerTestOwner === owner)
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertTrue(f.app.applicationCatalogTestFacts.owner === owner)
      XCTAssertTrue(control.calls.allSatisfy { !$0.onMain })
    }
  }

  func testActualTableAndDetailsUseCompleteConfirmedCatalog() async throws {
    try await withReadOnlyLanguageManager { f in
      // Real save at this fixture's ONE capsule; no forged LoadedLanguageCatalog/revisions.
      let directory = f.directory
      try await Task.detached(priority: .utility) {
        let store = CustomLanguageStore(directory: directory)
        let loaded = try store.load()
        let definition = try LiteralLanguageDefinition(
          id: CatalogTestFixture.id, name: "Atlas Ω", fileExtensions: ["atlas", "ax"],
          keywords: ["café", "cafe\u{301}"], lineComment: "//",
          blockComment: BlockCommentDelimiters(opening: "/*", closing: "*/"),
          quotes: [
            LiteralQuoteRule(opening: "\"", closing: "\"", escape: "\\", multiline: false),
            LiteralQuoteRule(opening: "'", closing: "'", escape: nil, multiline: true),
          ], highlightDecimalNumbers: false, indentation: .spaces(width: 4))
        let other = try LiteralLanguageDefinition(
          id: CatalogTestFixture.otherID, name: "Beta", fileExtensions: ["beta"],
          keywords: ["return"], lineComment: "#", blockComment: nil, quotes: [],
          highlightDecimalNumbers: true, indentation: .tabs(width: 2))
        let extra = try BuiltInLanguageOverride(
          language: .python, lineComment: .literal("#!"), blockComment: .disabled,
          indentation: .spaces(width: 2))
        let candidate = try LanguageCatalogSnapshot(
          definitions: [definition, other], overrides: loaded.snapshot.overrides + [extra],
          generation: loaded.snapshot.generation)
        _ = try store.save(candidate, expected: loaded)
      }.value
      guard await f.load(), let panel = manager(f) else { return }
      let expected = try await f.fresh()
      let facts = panel.languageManagerTestFacts
      let snapshot = facts.session.snapshot
      XCTAssertNotNil(snapshot)
      guard let current = snapshot?.read.current else {
        return XCTFail("Confirmed publication required before table assertions")
      }
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(current.catalog),
        try LanguageCatalogCodec.encode(expected.snapshot))
      XCTAssertEqual(facts.renderedDefinitions, expected.snapshot.definitions)
      XCTAssertEqual(facts.renderedOverrides, expected.snapshot.overrides)
      XCTAssertEqual(facts.table.numberOfRows, 2)
      XCTAssertEqual(facts.table.tableColumns.count, 1)
      guard facts.table.numberOfRows == expected.snapshot.definitions.count,
        facts.table.tableColumns.count == 1
      else { return }
      for row in 0..<facts.table.numberOfRows {
        let cell =
          facts.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        XCTAssertNotNil(cell?.textField)
        XCTAssertEqual(cell?.textField?.stringValue, expected.snapshot.definitions[row].name)
      }
      facts.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      XCTAssertEqual(
        panel.languageManagerTestFacts.selectedDefinition,
        expected.snapshot.definitions.first)
      XCTAssertEqual(
        facts.details.string,
        """
        Name: Atlas Ω
        ID: 00000000-0000-4000-8000-000000000004
        Extensions: atlas, ax
        Keywords: café, cafe\u{301}
        Line comment: //
        Block comment: /* → */
        Quotes:
          " → "; escape: \\; multiline: no
          ' → '; escape: none; multiline: yes
        Decimal numbers: no
        Indentation: spaces 4
        """)
      XCTAssertEqual(
        facts.overrides.string,
        """
        swift: line comment disabled; block comment inherited; indentation tabs 3
        python: line comment #!; block comment disabled; indentation spaces 2
        """)
      XCTAssertFalse(facts.details.isEditable)
      XCTAssertFalse(facts.overrides.isEditable)
      XCTAssertFalse(try XCTUnwrap(panel.window).isVisible)
      let before = current.id
      guard let operation = try await f.apply("Replacement") else { return }
      XCTAssertEqual(facts.session.snapshot?.read.lastSettledRequestID, operation)
      XCTAssertNotEqual(facts.session.snapshot?.read.current?.id, before)
      XCTAssertEqual(
        panel.languageManagerTestFacts.selectedDefinition?.id, CatalogTestFixture.id,
        "Selection follows actual definition UUID across a new publication")
      XCTAssertEqual(
        panel.languageManagerTestFacts.details.string.components(separatedBy: "\n").first,
        "Name: Replacement")
    }
  }

  func testHeldRefreshUsesExistingProducerAndTruthfulBusyState() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let facts = panel.languageManagerTestFacts
      let original = owner.state.current?.id
      XCTAssertTrue(facts.refresh.isEnabled)
      let gate = control.hold(.read)
      defer { gate.release() }
      facts.refresh.performClick(nil)
      let id = owner.state.activeRequestID
      XCTAssertNotNil(id, "Button must admit actual read before held-producer expectation")
      guard let id else { return }
      await fulfillment(of: [gate.entered], timeout: 3)
      XCTAssertEqual(facts.session.snapshot?.read.activeRequestID, id)
      XCTAssertEqual(facts.session.snapshot?.mutation.activeOperation?.id, id)
      XCTAssertFalse(facts.refresh.isEnabled)
      XCTAssertFalse(facts.status.stringValue.isEmpty)
      facts.refresh.performClick(nil)
      if case .unavailable = facts.session.requestRefresh() {
      } else {
        XCTFail("Disabled presentation must refuse locally")
      }
      if case .busy(let actual) = owner.requestLoad() {
        XCTAssertEqual(actual, id)
      } else {
        XCTFail("Actual sole producer must report its existing busy ID")
      }
      XCTAssertEqual(control.count(.read), 2)
      XCTAssertEqual(control.maximum, 1)
      XCTAssertEqual(owner.state.current?.id, original)
      gate.release()
      guard await f.settle(id) else { return }
      XCTAssertEqual(facts.session.snapshot?.read.lastSettledRequestID, id)
      XCTAssertEqual(
        panel.languageManagerTestFacts.renderedDefinitions,
        owner.state.current?.catalog.definitions)
      XCTAssertNotEqual(owner.state.current?.id, original)
      XCTAssertNil(owner.state.activeRequestID)
      XCTAssertEqual(
        control.count(.read), 2,
        "Finite settled window; Source review must additionally prohibit a queued refresh")
      XCTAssertTrue(facts.refresh.isEnabled)
      XCTAssertTrue(control.calls.allSatisfy { !$0.onMain })
    }
  }

  func testReloadFailurePreservesConfirmedRowsAndAppErrorObserver() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let old = try XCTUnwrap(owner.state.current)
      let oldWire = try LanguageCatalogCodec.encode(old.catalog)
      let rows = panel.languageManagerTestFacts.renderedDefinitions
      control.failReads(true)
      guard let id = started(owner.requestLoad()), await f.settle(id) else { return }
      let facts = panel.languageManagerTestFacts
      XCTAssertEqual(facts.session.snapshot?.read.failure?.requestID, id)
      XCTAssertEqual(f.app.applicationCatalogTestFacts.lastReportedFailureID, id)
      XCTAssertEqual(
        f.reports.count, 1, "App retains its actual sole owner observer/error reporter")
      XCTAssertEqual(facts.renderedDefinitions, rows)
      XCTAssertEqual(facts.table.numberOfRows, rows.count)
      XCTAssertEqual(facts.session.snapshot?.read.current?.id, old.id)
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(
          try XCTUnwrap(
            facts.session.snapshot?.read.current
          ).catalog), oldWire)
      XCTAssertTrue(facts.refresh.isEnabled)
      XCTAssertFalse(facts.status.stringValue.isEmpty)
      let failedDelivery = try XCTUnwrap(facts.session.snapshot?.deliveryID)
      guard case .prepared(let reservation) = owner.prepareQuit() else {
        return XCTFail("Real idle reservation required")
      }
      XCTAssertEqual(facts.session.snapshot?.read.failure?.requestID, id)
      XCTAssertNotEqual(facts.session.snapshot?.deliveryID, failedDelivery)
      XCTAssertEqual(f.reports.count, 1, "Same failure notification remains deduplicated")
      XCTAssertTrue(owner.cancelPreparedQuit(reservation))
    }
  }

  func testSamePublicationQuitNotificationsUpdatePresentation() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let facts = panel.languageManagerTestFacts
      let first = try XCTUnwrap(facts.session.snapshot)
      let status = facts.status.stringValue
      guard case .prepared(let id) = owner.prepareQuit() else {
        return XCTFail("Actual owner must issue the reservation")
      }
      let prepared = try XCTUnwrap(facts.session.snapshot)
      XCTAssertEqual(prepared.read.current?.id, first.read.current?.id)
      XCTAssertNotEqual(prepared.deliveryID, first.deliveryID)
      XCTAssertEqual(prepared.mutation.preparedQuitID, id)
      XCTAssertFalse(facts.session.isCurrentDelivery(first.deliveryID))
      XCTAssertTrue(facts.session.isCurrentDelivery(prepared.deliveryID))
      XCTAssertNotEqual(facts.status.stringValue, status)
      XCTAssertFalse(facts.refresh.isEnabled)
      if case .unavailable = facts.session.requestRefresh() {
      } else {
        XCTFail("Reserved owner must not receive a presentation refresh")
      }
      XCTAssertTrue(owner.cancelPreparedQuit(id))
      let resumed = try XCTUnwrap(facts.session.snapshot)
      XCTAssertNotEqual(resumed.deliveryID, prepared.deliveryID)
      XCTAssertNil(resumed.mutation.preparedQuitID)
      XCTAssertEqual(resumed.read.current?.id, first.read.current?.id)
      XCTAssertEqual(facts.status.stringValue, status)
      XCTAssertTrue(facts.refresh.isEnabled)
      XCTAssertEqual(control.count(.read), 1)
    }
  }

  func testReentrantDeliveryCannotOverwriteSuccessorPublication() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let session = panel.languageManagerTestFacts.session
      let renderer = session.onChange
      XCTAssertNotNil(renderer, "Actual controller must observe the presentation session")
      guard let renderer else { return }
      var successor: UUID?
      var successorGate: MutationGate?
      var rejectedOldDelivery: UUID?
      var calls = 0
      session.onChange = { snapshot in
        if snapshot.read.failure != nil, snapshot.read.activeRequestID == nil, calls == 0 {
          calls += 1
          rejectedOldDelivery = snapshot.deliveryID
          control.failReads(false)
          successorGate = control.hold(.read)
          successor = self.started(owner.requestLoad())
        }
        // Deliberately deliver old render AFTER nested real admission delivered its new snapshot.
        renderer(snapshot)
      }
      defer {
        session.onChange = renderer
        successorGate?.release()
      }
      control.failReads(true)
      guard let first = started(owner.requestLoad()) else { return }
      guard await f.wait("one-shot actual presentation reentry", { calls == 1 }) else { return }
      XCTAssertNotNil(successor, "Successor admission must precede its producer wait")
      XCTAssertNotNil(successorGate)
      guard let successor, let gate = successorGate else { return }
      await fulfillment(of: [gate.entered], timeout: 3)
      XCTAssertEqual(session.snapshot?.read.activeRequestID, successor)
      XCTAssertEqual(owner.state.activeRequestID, successor)
      XCTAssertNotEqual(successor, first)
      if let rejectedOldDelivery { XCTAssertFalse(session.isCurrentDelivery(rejectedOldDelivery)) }
      XCTAssertEqual(f.app.languageManagerTestFacts.deliveryID, session.snapshot?.deliveryID)
      XCTAssertTrue(
        f.reports.isEmpty,
        "App must fence its old failure-report frame after nested manager admission")
      gate.release()
      guard await f.settle(successor) else { return }
      XCTAssertEqual(session.snapshot?.read.current?.id, owner.state.current?.id)
      XCTAssertEqual(session.snapshot?.read.lastSettledRequestID, successor)
      XCTAssertNil(session.snapshot?.read.failure)
      XCTAssertEqual(
        panel.languageManagerTestFacts.renderedDefinitions,
        owner.state.current?.catalog.definitions)
      XCTAssertTrue(panel.languageManagerTestFacts.refresh.isEnabled)
      XCTAssertEqual(control.count(.read), 3)
      XCTAssertEqual(control.maximum, 1)
    }
  }

  func testNativeCloseReentryPreservesExactNewManager() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let first = manager(f) else { return }
      let window = try XCTUnwrap(first.window)
      let reentry = LanguageManagerCloseReentry(f, first)
      let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
      ) { [weak reentry] _ in
        MainActor.assumeIsolated { reentry?.receive() }
      }
      window.close()
      NotificationCenter.default.removeObserver(observer)
      XCTAssertEqual(reentry.calls, 1)
      XCTAssertNotNil(reentry.successor, "Native notification must construct the real successor")
      guard let successor = reentry.successor else { return }
      XCTAssertFalse(successor === first)
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === successor)
      XCTAssertTrue(successor.languageManagerTestFacts.session.isAttached)
      first.close()
      first.close()
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === successor)
      XCTAssertTrue(successor.languageManagerTestFacts.session.isAttached)
      let control = try XCTUnwrap(f.control)
      control.failReads(true)
      guard let owner = f.catalog, let id = started(owner.requestLoad()), await f.settle(id)
      else { return }
      XCTAssertEqual(
        successor.languageManagerTestFacts.session.snapshot?.read.failure?.requestID, id)
      XCTAssertEqual(f.reports.count, 1)
      XCTAssertEqual(control.count(.read), 2)
      XCTAssertFalse(try XCTUnwrap(successor.window).isVisible)
    }
  }

  func testApplicationVetoKeepsManagerAndOriginalCatalogReservationRules() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let session = panel.languageManagerTestFacts.session
      let originalPublication = owner.state.current?.id
      f.native.permitsPublicationErrors = true
      f.native.writer.arm(failing: true)
      var successor: ApplicationCatalogJoinedAttempt?
      var successorQuit: UUID?
      var didReenter = false
      f.native.replyHook = { accepted in
        guard !accepted, !didReenter else { return }
        didReenter = true
        XCTAssertTrue(session.isAttached)
        XCTAssertNil(session.snapshot?.mutation.preparedQuitID)
        XCTAssertTrue(panel.languageManagerTestFacts.refresh.isEnabled)
        XCTAssertTrue(f.app.languageManagerTestMake() === panel)
        f.native.writer.restoreWrites()
        f.native.writer.arm()
        successor = f.beginQuit()
        successorQuit = f.requireReservation()
      }
      guard let first = f.beginQuit(), let firstQuit = f.requireReservation() else { return }
      guard
        await f.wait(
          "actual first native publication entry",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      XCTAssertEqual(session.snapshot?.mutation.preparedQuitID, firstQuit)
      XCTAssertFalse(panel.languageManagerTestFacts.refresh.isEnabled)
      f.native.writer.release()
      let refused = await first.join()
      XCTAssertNil(refused.nativeReceipt)
      XCTAssertEqual(f.native.replies, [false])
      XCTAssertTrue(didReenter)
      XCTAssertNotNil(successor, "Real false-reply successor admission precedes writer wait")
      XCTAssertNotNil(successorQuit)
      guard let successor, let successorQuit else { return }
      XCTAssertNotEqual(successorQuit, firstQuit)
      XCTAssertEqual(f.app.task4Attempt?.id, successor.handle.id)
      XCTAssertEqual(owner.mutationState.preparedQuitID, successorQuit)
      XCTAssertEqual(session.snapshot?.mutation.preparedQuitID, successorQuit)
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === panel)
      XCTAssertTrue(session.isAttached)
      XCTAssertEqual(owner.state.current?.id, originalPublication)
      guard
        await f.wait(
          "actual successor native publication entry",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      f.native.writer.release()
      let committed = await successor.join()
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(committed.nativeReceipt))
      XCTAssertEqual(f.native.replies, [false, true])
      XCTAssertEqual(f.reports.count, 1)
      XCTAssertTrue(f.reports.allSatisfy { ($0 as? AppRoutingError) == .publication })
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertFalse(session.isAttached)
      XCTAssertNil(f.app.languageManagerTestFacts.controller)
    }
  }

  func testCommittedQuitDetachesPresentationAfterActualOwnerJoin() async throws {
    try await withReadOnlyLanguageManager { f in
      guard await f.load(), let panel = manager(f) else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let session = panel.languageManagerTestFacts.session
      let originalWindow = try XCTUnwrap(panel.window)
      let external = AppRoutingGate()
      f.native.externalGate = external
      f.native.writer.arm()
      guard let attempt = f.beginQuit(), let reservation = f.requireReservation() else { return }
      guard
        await f.wait(
          "actual final native publication entry",
          {
            f.native.writer.applicationCatalogEntered
          })
      else { return }
      XCTAssertTrue(session.isAttached)
      XCTAssertEqual(session.snapshot?.mutation.preparedQuitID, reservation)
      XCTAssertNil(f.app.task4Attempt?.nativeReceipt)
      f.native.writer.release()
      guard await f.wait("actual external drain after catalog owner join", { external.calls == 1 })
      else { return }
      if case .invalidated = owner.state.lifetime {
      } else {
        XCTFail("Real owner invalidation must precede manager retirement")
      }
      XCTAssertNil(owner.mutationState.activeOperation)
      XCTAssertFalse(session.isAttached)
      XCTAssertNil(session.onChange)
      XCTAssertNil(f.app.languageManagerTestFacts.controller)
      XCTAssertNil(f.app.languageManagerTestFacts.session)
      XCTAssertFalse(originalWindow.isVisible)
      XCTAssertNotNil(f.app.task4Attempt?.nativeReceipt)
      XCTAssertEqual(f.native.replies, [])
      XCTAssertNil(f.app.languageManagerTestMake(), "Committed lifetime cannot recreate a panel")
      external.release()
      let done = await attempt.join()
      try f.native.assertFreshNativeReceipt(try XCTUnwrap(done.nativeReceipt))
      XCTAssertEqual(done.decision, .noSearchOwner)
      XCTAssertTrue(done.replyConsumed)
      XCTAssertEqual(f.native.replies, [true])
      XCTAssertEqual(external.calls, 1)
      XCTAssertEqual(external.returns, 1)
      XCTAssertEqual(control.count(.read), 1)
      XCTAssertEqual(control.maximum, 1)
      XCTAssertTrue(f.reports.isEmpty)
    }
  }
}

// Editable manager slice: real owner, original private fixture, no shown windows or forged authority.
@MainActor private func withEditableLanguageManager(
  _ body: @MainActor (ApplicationCatalogFixture) async throws -> Void
) async throws {
  try await withApplicationCatalog { f in
    var primary: Error?
    do { try await body(f) } catch { primary = error }
    // Release all genuine producers before joining, including every early assertion return.
    f.control?.release()
    f.control?.mode(.clean)
    f.control?.failReads(false)
    f.native.writer.restoreWrites()
    f.native.writer.release()
    f.native.externalGate?.release()
    f.native.backend.joinHold?.release()
    for attempt in f.attempts { _ = await attempt.join() }
    if let owner = f.catalog, case .active = owner.state.lifetime {
      if let id = owner.mutationState.activeOperation?.id {
        guard await f.settle(id) else { throw AppRoutingError.unsafe }
      }
      if let id = owner.mutationState.preparedQuitID { XCTAssertTrue(owner.cancelPreparedQuit(id)) }
      if let unresolved = owner.mutationState.unresolved {
        let admission: NativeLanguageCatalogMutationAdmission
        switch unresolved {
        case .failedAttempt(let id, _, _): admission = owner.requestRetryFailedAttempt(id)
        case .pending(_, let id, .publicationUncertain, _):
          admission = owner.requestRetryPending(id)
        case .pending(_, let id, .readbackUnconfirmed, _):
          admission = owner.requestDiscardAndReload(
            .pending(id), confirmation: .discardAttemptAndReload)
        }
        guard let id = f.requestID(admission), await f.settle(id),
          owner.mutationState.unresolved == nil
        else { throw AppRoutingError.unsafe }
      }
    }
    if let panel = f.app.languageManagerTestFacts.controller {
      let session = panel.languageManagerTestFacts.session
      if let handle = session.editState?.activeForm?.handle {
        guard case .accepted = session.discardFormChanges(handle: handle) else {
          XCTFail("Actual form cleanup refused; retain exact fixture")
          ApplicationCatalogCustody.retained = f
          AppRoutingCustody.retain(f.native)
          throw primary ?? AppRoutingError.unsafe
        }
      }
      if let state = session.editState, state.isDirty || state.isStale {
        guard
          case .accepted = session.discardDraft(
            expectedDraftID: state.draftID, expectedEpoch: state.rawEpoch)
        else {
          XCTFail("Actual local draft cleanup refused; retain exact fixture")
          ApplicationCatalogCustody.retained = f
          AppRoutingCustody.retain(f.native)
          throw primary ?? AppRoutingError.unsafe
        }
      }
      panel.close()
      XCTAssertNil(f.app.languageManagerTestFacts.controller, "Genuine clean presentation cleanup")
    }
    if let primary { throw primary }
  }
}

@MainActor private final class ManagerEditCloseObservation {
  let fixture: ApplicationCatalogFixture
  let original: NativeLanguageManagerController
  let terminal: Bool
  var count = 0
  var successor: NativeLanguageManagerController?
  init(
    _ fixture: ApplicationCatalogFixture, _ original: NativeLanguageManagerController,
    terminal: Bool
  ) {
    self.fixture = fixture
    self.original = original
    self.terminal = terminal
  }
  func receive() {
    count += 1
    XCTAssertEqual(count, 1)
    XCTAssertNil(fixture.app.languageManagerTestFacts.controller)
    XCTAssertFalse(original.languageManagerTestFacts.session.isAttached)
    guard count == 1 else { return }
    successor = fixture.app.languageManagerTestMake()
    if terminal { XCTAssertNil(successor) } else { XCTAssertNotNil(successor) }
  }
}

@MainActor private final class ManagerQuitFlushResponder: NSView {
  var onResign: (@MainActor () -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func resignFirstResponder() -> Bool {
    let action = onResign
    onResign = nil  // One-shot actual native callback; nested flush cannot recurse.
    action?()
    return true
  }
}

@MainActor final class LanguageManagerEditSaveTests: XCTestCase {
  private func ready(_ f: ApplicationCatalogFixture) async
    -> (NativeLanguageManagerController, NativeLanguageManagerSession)?
  {
    guard await f.load() else { return nil }
    let panel = f.app.languageManagerTestMake()
    XCTAssertNotNil(panel, "Actual read-only manager remains prerequisite")
    guard let panel else { return nil }
    let session = panel.languageManagerTestFacts.session
    XCTAssertNotNil(session.editState, "Real editable workspace must exist before deeper horizons")
    guard session.editState != nil else { return nil }
    XCTAssertNotNil(panel.window, "Actual hidden native window required")
    guard let window = panel.window else { return nil }
    XCTAssertFalse(window.isVisible)
    return (panel, session)
  }
  private func accepted(
    _ value: NativeLanguageManagerEditAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    if case .accepted = value { return true }
    XCTFail("Real local edit admission required", file: file, line: line)
    return false
  }
  private func opened(
    _ value: NativeLanguageManagerFormAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> NativeLanguageManagerFormHandle? {
    if case .opened(let handle) = value { return handle }
    XCTFail(
      "Actual session-issued form required before dependent UI access", file: file, line: line)
    return nil
  }
  private func started(_ value: NativeLanguageManagerSaveAdmission) -> UUID? {
    if case .started(let id) = value { return id }
    XCTFail("Actual Save admission required before producer wait")
    return nil
  }
  private func definition(_ session: NativeLanguageManagerSession)
    -> NativeLanguageManagerRawDefinition?
  {
    guard case .definition(let value)? = session.editState?.activeForm?.raw else {
      XCTFail("Actual definition form payload required")
      return nil
    }
    return value
  }
  private func edit(_ session: NativeLanguageManagerSession, _ id: UUID)
    -> NativeLanguageManagerFormHandle?
  {
    guard let s = session.editState else {
      XCTFail("Workspace absent")
      return nil
    }
    return opened(
      session.beginEdit(
        target: .definition(id), expectedDraftID: s.draftID,
        expectedEpoch: s.rawEpoch))
  }
  private func expectInvalidSave(_ session: NativeLanguageManagerSession) {
    guard let s = session.editState else {
      XCTFail("Workspace absent")
      return
    }
    if case .refused(.invalid(let issues)) = session.requestSave(
      expectedDraftID: s.draftID, expectedEpoch: s.rawEpoch)
    {
      XCTAssertFalse(issues.isEmpty)
    } else {
      XCTFail("Invalid raw must refuse with actual field issues")
    }
  }
  private func sameUnits(
    _ a: String, _ b: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(a.utf16.elementsEqual(b.utf16), file: file, line: line)
  }

  func testNewAndEditKeepExactBoundedRawFieldsAndStableIDs() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f) else { return }
      let original = try XCTUnwrap(s.editState)
      XCTAssertEqual(
        original.definitions.map(\.id), f.catalog?.state.current?.catalog.definitions.map(\.id))
      panel.languageManagerEditingTestFacts.new.performClick(nil)
      XCTAssertNotNil(
        s.editState?.activeForm, "Actual New button must open the same real session form")
      guard let form = s.editState?.activeForm, var raw = definition(s) else { return }
      let handle = form.handle
      let freshID = raw.id
      XCTAssertNotEqual(freshID, CatalogTestFixture.id)
      XCTAssertEqual(handle.target, .definition(freshID))
      raw.name = "cafe\u{301}\0"
      raw.extensionsText = ""
      raw.keywordsText = "café\ncafe\u{301}"
      raw.lineEnabled = false
      raw.lineText = "\0uncommitted\n"
      raw.blockEnabled = false
      raw.blockOpening = "decomposed e\u{301}"
      raw.blockClosing = "trailing "
      raw.quotes = [
        .init(
          rowID: UUID(), opening: "\"", closing: "\"",
          escapeEnabled: false, escapeText: "raw\0", multiline: true)
      ]
      raw.indentationKind = .spaces
      raw.widthText = "not a number"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        let retained = definition(s)
      else { return }
      sameUnits(retained.name, raw.name)
      sameUnits(retained.keywordsText, raw.keywordsText)
      sameUnits(retained.lineText, raw.lineText)
      sameUnits(retained.blockOpening, raw.blockOpening)
      sameUnits(retained.blockClosing, raw.blockClosing)
      XCTAssertEqual(retained.quotes.count, 1)
      guard retained.quotes.count == 1 else { return }
      sameUnits(retained.quotes[0].escapeText, raw.quotes[0].escapeText)
      sameUnits(retained.widthText, raw.widthText)
      XCTAssertEqual(retained.id, freshID)
      XCTAssertEqual(s.editState?.activeForm?.handle.id, handle.id)
      let beforeEpoch = s.editState?.rawEpoch
      for oversized in [
        String(repeating: "x", count: 65537),
        (0..<17).map { "e\($0)" }.joined(separator: "\n"),
        (0..<1025).map { "k\($0)" }.joined(separator: "\n"),
      ] {
        var refused = raw
        if oversized.count > 65536 {
          refused.name = oversized
        } else if oversized.hasPrefix("e") {
          refused.extensionsText = oversized
        } else {
          refused.keywordsText = oversized
        }
        if case .refused(.boundExceeded) = s.updateForm(handle: handle, raw: .definition(refused)) {
        } else {
          XCTFail("Raw bound must refuse without truncation")
        }
        XCTAssertEqual(s.editState?.rawEpoch, beforeEpoch)
        sameUnits(try XCTUnwrap(definition(s)).name, raw.name)
      }
      var tooManyQuotes = raw
      tooManyQuotes.quotes = (0..<5).map { _ in
        .init(
          rowID: UUID(), opening: "q", closing: "z",
          escapeEnabled: false, escapeText: "", multiline: false)
      }
      if case .refused(.boundExceeded) = s.updateForm(
        handle: handle, raw: .definition(tooManyQuotes))
      {
      } else {
        XCTFail("Quote count bound must refuse without truncation")
      }
      XCTAssertEqual(s.editState?.rawEpoch, beforeEpoch)
      XCTAssertEqual(f.control?.count(.save), 0)
      guard accepted(s.discardFormChanges(handle: handle)) else { return }
      XCTAssertNil(s.editState?.activeForm)
      XCTAssertFalse(try XCTUnwrap(s.editState).definitions.contains { $0.id == freshID })
      guard let again = opened(s.beginNewDefinition()), let second = definition(s) else { return }
      XCTAssertNotEqual(second.id, freshID)
      XCTAssertNotEqual(again.id, handle.id)
      _ = accepted(s.discardFormChanges(handle: again))
    }
  }

  func testValidationRejectsFieldAndCatalogCollisionsBeforeStoreAdmission() async throws {
    try await withEditableLanguageManager { f in
      guard let (_, s) = await ready(f), let handle = opened(s.beginNewDefinition()),
        var raw = definition(s)
      else { return }
      let before = try f.bytes()
      let beforeCalls = f.control?.count(.save)
      let valid = raw
      for value in ["Bad\nName", "", String(repeating: "n", count: 81)] {
        raw = valid
        raw.name = value
        guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
        expectInvalidSave(s)
      }
      for ext in ["demo", "UPPER", "a\n", "a\n\nb"] {
        raw = valid
        raw.name = "Draft"
        raw.extensionsText = ext
        guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
        expectInvalidSave(s)
      }
      for width in ["0", "9", "NaN"] {
        raw = valid
        raw.indentationKind = .spaces
        raw.widthText = width
        guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
        expectInvalidSave(s)
      }
      raw = valid
      raw.quotes = [
        .init(
          rowID: UUID(), opening: "", closing: "\"",
          escapeEnabled: true, escapeText: "xy", multiline: false)
      ]
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
      expectInvalidSave(s)
      let wrong = NativeLanguageManagerRawDefinition(
        id: CatalogTestFixture.id,
        name: valid.name, extensionsText: "fresh", keywordsText: "", lineEnabled: false,
        lineText: "", blockEnabled: false, blockOpening: "", blockClosing: "", quotes: [],
        highlightDecimalNumbers: false, indentationKind: .legacy, widthText: "")
      if case .refused = s.updateForm(handle: handle, raw: .definition(wrong)) {
      } else {
        XCTFail("An opaque form cannot be retargeted to a conflicting UUID")
      }
      XCTAssertEqual(try f.bytes(), before)
      XCTAssertEqual(f.control?.count(.save), beforeCalls)
      // Duplicate names are legal; only extensions/UUIDs collide in Core.
      raw = valid
      raw.name = "Demo"
      raw.extensionsText = "fresh"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.finishForm(handle: handle))
      else { return }
      XCTAssertTrue(try XCTUnwrap(s.editState).isDirty)
      XCTAssertEqual(f.control?.count(.save), beforeCalls)
    }
  }

  func testDeleteAndRevertAreDraftOnlyUntilActualSave() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f) else { return }
      let before = try f.bytes()
      let initial = try XCTUnwrap(s.editState)
      panel.languageManagerTestFacts.table.selectRowIndexes(
        IndexSet(integer: 0), byExtendingSelection: false)
      panel.languageManagerEditingTestFacts.delete.performClick(nil)
      XCTAssertFalse(
        try XCTUnwrap(s.editState).definitions.contains { $0.id == CatalogTestFixture.id })
      XCTAssertTrue(try XCTUnwrap(s.editState).isDirty)
      XCTAssertEqual(try f.bytes(), before)
      let deleted = try XCTUnwrap(s.editState)
      XCTAssertEqual(deleted.draftID, initial.draftID)
      panel.languageManagerEditingTestFacts.revert.performClick(nil)
      XCTAssertEqual(s.editState?.definitions.map(\.id), initial.definitions.map(\.id))
      XCTAssertFalse(try XCTUnwrap(s.editState).isDirty)
      guard let handle = opened(s.beginNewDefinition()), var raw = definition(s) else { return }
      raw.name = "Staged"
      raw.extensionsText = "staged"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.finishForm(handle: handle))
      else { return }
      let staged = try XCTUnwrap(s.editState)
      guard
        accepted(
          s.revertChange(
            target: .definition(raw.id), expectedDraftID: staged.draftID,
            expectedEpoch: staged.rawEpoch))
      else { return }
      XCTAssertFalse(try XCTUnwrap(s.editState).definitions.contains { $0.id == raw.id })
      XCTAssertFalse(try XCTUnwrap(s.editState).isDirty)
      XCTAssertEqual(try f.bytes(), before)
      XCTAssertEqual(f.control?.count(.save), 0)
    }
  }

  func testChildEditorNeverRetargetsSelectionOrForeignHistory() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f) else { return }
      let model = try XCTUnwrap(f.native.models.first)
      let undo = model.undoManager
      let originalText = model.storage.string
      undo.beginUndoGrouping()
      model.editor.insertText(
        "!", replacementRange: NSRange(location: model.storage.length, length: 0))
      undo.endUndoGrouping()
      XCTAssertTrue(
        undo.canUndo, "Actual foreign native history must exist before child construction")
      XCTAssertTrue(undo.groupingLevel == 0 || undo.groupingLevel == 1)
      guard undo.canUndo, !undo.isUndoing, !undo.isRedoing,
        undo.groupingLevel == 0 || undo.groupingLevel == 1
      else { return }
      undo.undo()
      try f.native.requireClean(model)
      XCTAssertTrue(undo.canRedo, "Nonempty original history makes a foreign clear observable")
      guard undo.canRedo else { return }
      XCTAssertEqual(model.storage.string, originalText)
      let beforeString = model.storage.string
      let beforeUndo = undo.canUndo
      let beforeRedo = undo.canRedo
      let beforeGrouping = undo.groupingLevel
      panel.languageManagerTestFacts.table.selectRowIndexes(
        IndexSet(integer: 0), byExtendingSelection: false)
      panel.languageManagerEditingTestFacts.edit.performClick(nil)
      XCTAssertNotNil(s.editState?.activeForm, "Actual Edit button must construct a bound form")
      guard let handle = s.editState?.activeForm?.handle else { return }
      let first = panel.languageManagerEditingTestFacts.editor
      XCTAssertNotNil(first, "Actual child editor must be installed by the real render/action path")
      guard let first, let window = first.window else {
        XCTFail("Actual child window absent")
        return
      }
      XCTAssertTrue(window.parent === panel.window)
      XCTAssertFalse(window.isVisible)
      XCTAssertFalse(panel.languageManagerTestFacts.details.isEditable)
      let controls = first.languageDefinitionEditingTestFacts
      XCTAssertEqual(controls.handle.id, handle.id)
      controls.name.stringValue = "Changed by actual field delegate"
      first.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: controls.name))
      sameUnits(try XCTUnwrap(definition(s)).name, controls.name.stringValue)
      panel.languageManagerTestFacts.table.deselectAll(nil)
      XCTAssertTrue(panel.languageManagerEditingTestFacts.editor === first)
      XCTAssertEqual(s.editState?.activeForm?.handle.target, .definition(CatalogTestFixture.id))
      if case .refused(.formInProgress) = s.beginNewDefinition() {
      } else {
        XCTFail("Cannot retarget live form")
      }
      window.close()
      XCTAssertTrue(panel.languageManagerEditingTestFacts.editor === first)
      XCTAssertNotNil(s.editState?.activeForm)
      XCTAssertEqual(model.storage.string, beforeString)
      XCTAssertEqual(undo.canUndo, beforeUndo)
      XCTAssertEqual(undo.canRedo, beforeRedo)
      XCTAssertEqual(undo.groupingLevel, beforeGrouping)
      controls.discard.performClick(nil)
      XCTAssertNil(s.editState?.activeForm)
      XCTAssertNil(panel.languageManagerEditingTestFacts.editor)
      guard let next = edit(s, CatalogTestFixture.id),
        let second = panel.languageManagerEditingTestFacts.editor
      else { return }
      XCTAssertFalse(second === first)
      XCTAssertFalse(second.window === window)
      XCTAssertNotEqual(next.id, handle.id)
      second.languageDefinitionEditingTestFacts.done.performClick(nil)
      XCTAssertNil(s.editState?.activeForm)
      // Exercise the genuine preserved inverse, with the API-valid top-level 0/1 precondition.
      guard undo.canRedo else {
        XCTFail("Manager must preserve foreign redo")
        return
      }
      undo.redo()
      XCTAssertEqual(model.storage.string, originalText + "!")
      XCTAssertTrue(undo.groupingLevel == 0 || undo.groupingLevel == 1)
      guard undo.canUndo, !undo.isUndoing, !undo.isRedoing,
        undo.groupingLevel == 0 || undo.groupingLevel == 1
      else { return }
      undo.undo()
      try f.native.requireClean(model)
      XCTAssertEqual(model.storage.string, originalText)
    }
  }

  func testActualSaveUsesOriginalOwnerAndCompleteFreshReader() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      let owner = try XCTUnwrap(f.catalog)
      let original = try await f.fresh()
      raw.name = "Saved café"
      raw.extensionsText = "one\ntwo"
      raw.keywordsText = "café\ncafe\u{301}"
      raw.lineEnabled = true
      raw.lineText = "//"
      raw.blockEnabled = true
      raw.blockOpening = "/*"
      raw.blockClosing = "*/"
      raw.quotes = [
        .init(
          rowID: UUID(), opening: "\"", closing: "\"",
          escapeEnabled: true, escapeText: "\\", multiline: true)
      ]
      raw.highlightDecimalNumbers = false
      raw.indentationKind = .tabs
      raw.widthText = "4"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.finishForm(handle: handle))
      else { return }
      let st = try XCTUnwrap(s.editState)
      guard
        let overrideHandle = opened(
          s.beginEdit(
            target: .builtIn(.swift),
            expectedDraftID: st.draftID, expectedEpoch: st.rawEpoch))
      else { return }
      let overrideRaw = NativeLanguageManagerRawOverride(
        language: .swift, lineKind: .literal,
        lineText: "#override", blockKind: .disabled, blockOpening: "retained", blockClosing: "raw",
        indentationKind: .spaces, widthText: "2")
      guard accepted(s.updateForm(handle: overrideHandle, raw: .builtIn(overrideRaw))),
        accepted(s.finishForm(handle: overrideHandle))
      else { return }
      panel.languageManagerEditingTestFacts.save.performClick(nil)
      let operation = s.editState?.saveOperationID
      XCTAssertNotNil(operation, "Actual Save button must admit the original owner's producer")
      guard let operation, await f.settle(operation) else { return }
      let loaded = try await f.fresh()
      let current = try XCTUnwrap(owner.state.current)
      XCTAssertEqual(
        try LanguageCatalogCodec.encode(current.catalog),
        try LanguageCatalogCodec.encode(loaded.snapshot))
      XCTAssertEqual(loaded.snapshot.generation, original.snapshot.generation + 1)
      let expected = try LiteralLanguageDefinition(
        id: CatalogTestFixture.id, name: raw.name,
        fileExtensions: ["one", "two"], keywords: ["café", "cafe\u{301}"], lineComment: "//",
        blockComment: BlockCommentDelimiters(opening: "/*", closing: "*/"),
        quotes: [LiteralQuoteRule(opening: "\"", closing: "\"", escape: "\\", multiline: true)],
        highlightDecimalNumbers: false, indentation: .tabs(width: 4))
      XCTAssertEqual(loaded.snapshot.definitions, [expected])
      XCTAssertEqual(
        loaded.snapshot.overrides,
        [
          try BuiltInLanguageOverride(
            language: .swift,
            lineComment: .literal("#override"), blockComment: .disabled,
            indentation: .spaces(width: 2))
        ])
      XCTAssertEqual(CatalogTestFixture.profile(loaded.snapshot).definitionRevision, 4)
      XCTAssertEqual(s.editState?.basePublicationID, current.id)
      XCTAssertFalse(try XCTUnwrap(s.editState).isDirty)
      XCTAssertNil(s.editState?.saveOperationID)
      XCTAssertTrue(s.languageManagerTestOwner === owner)
      XCTAssertEqual(f.control?.count(.save), 1)
      XCTAssertEqual(f.control?.maximum, 1)
      XCTAssertTrue(try XCTUnwrap(f.control).calls.allSatisfy { !$0.onMain })
    }
  }

  func testRefusedSaveKeepsRawBaseAndNoAdditionalProducer() async throws {
    try await withEditableLanguageManager { f in
      guard let (_, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      raw.name = "Retain after real failure"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.finishForm(handle: handle))
      else { return }
      let before = try XCTUnwrap(s.editState)
      let bytes = try f.bytes()
      if case .refused(.wrongEpoch) = s.requestSave(
        expectedDraftID: before.draftID, expectedEpoch: UUID())
      {
      } else {
        XCTFail("Stale UI Save cannot write")
      }
      XCTAssertEqual(f.control?.count(.save), 0)
      let control = try XCTUnwrap(f.control)
      control.mode(.prepublication)
      guard
        let id = started(
          s.requestSave(expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch)),
        await f.settle(id)
      else { return }
      XCTAssertEqual(try f.bytes(), bytes)
      XCTAssertEqual(s.editState?.basePublicationID, before.basePublicationID)
      XCTAssertEqual(s.editState?.rawEpoch, before.rawEpoch)
      sameUnits(try XCTUnwrap(s.editState?.definitions.first).name, raw.name)
      guard case .failedAttempt(let attempt, .apply, _)? = f.catalog?.mutationState.unresolved
      else {
        XCTFail("Actual failed Store attempt must remain unresolved")
        return
      }
      let saved = control.count(.save)
      let now = try XCTUnwrap(s.editState)
      if case .refused = s.requestSave(expectedDraftID: now.draftID, expectedEpoch: now.rawEpoch) {
      } else {
        XCTFail("Unresolved real write cannot be silently replaced")
      }
      if case .refused = s.discardDraft(expectedDraftID: now.draftID, expectedEpoch: now.rawEpoch) {
      } else {
        XCTFail("Local reset cannot acknowledge actual Store intent")
      }
      guard case .failedAttempt(let retained, _, _)? = f.catalog?.mutationState.unresolved else {
        XCTFail("Actual attempt disappeared")
        return
      }
      XCTAssertEqual(retained, attempt)
      XCTAssertEqual(control.count(.save), saved)
      XCTAssertEqual(s.editState?.rawEpoch, before.rawEpoch)
      XCTAssertFalse(s.canDepart)
      XCTAssertEqual(f.reports.count, 1)
    }
  }

  func testSaveCompletionPreservesNewerRawInput() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      raw.name = "Submitted"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
      let original = try XCTUnwrap(s.editState)
      let control = try XCTUnwrap(f.control)
      let gate = control.hold(.save)
      defer { gate.release() }
      guard
        let id = started(
          s.requestSave(expectedDraftID: original.draftID, expectedEpoch: original.rawEpoch))
      else { return }
      await fulfillment(of: [gate.entered], timeout: 4)
      guard await f.wait("real held Save entered", { control.count(.save) == 1 }) else { return }
      raw.name = "Newer local"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
      let newer = try XCTUnwrap(s.editState)
      XCTAssertNotEqual(newer.rawEpoch, original.rawEpoch)
      if case .refused(.busy) = s.requestSave(
        expectedDraftID: newer.draftID, expectedEpoch: newer.rawEpoch)
      {
      } else {
        XCTFail("No second Save/queue during actual producer")
      }
      panel.close()
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === panel)
      XCTAssertEqual(control.count(.save), 1)
      gate.release()
      guard await f.settle(id) else { return }
      let saved = try await f.fresh()
      XCTAssertEqual(saved.snapshot.definitions.first?.name, "Submitted")
      sameUnits(try XCTUnwrap(definition(s)).name, "Newer local")
      XCTAssertTrue(try XCTUnwrap(s.editState).isDirty)
      XCTAssertEqual(s.editState?.basePublicationID, f.catalog?.state.current?.id)
      XCTAssertNil(s.editState?.saveOperationID)
      // Discarding form input now returns the actual SAVED baseline, not pre-Save Demo.
      guard accepted(s.discardFormChanges(handle: handle)) else { return }
      sameUnits(try XCTUnwrap(s.editState?.definitions.first).name, "Submitted")
      XCTAssertFalse(try XCTUnwrap(s.editState).isDirty)
      XCTAssertEqual(control.maximum, 1)
    }
  }

  func testExternalPublicationMarksDirtyDraftStaleWithoutOverwrite() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      raw.name = "Keep local"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.finishForm(handle: handle))
      else { return }
      let before = try XCTUnwrap(s.editState)
      guard try await f.apply("Actual unrelated publication") != nil else { return }
      XCTAssertTrue(try XCTUnwrap(s.editState).isStale)
      XCTAssertEqual(s.editState?.basePublicationID, before.basePublicationID)
      XCTAssertEqual(s.editState?.rawEpoch, before.rawEpoch)
      sameUnits(try XCTUnwrap(s.editState?.definitions.first).name, raw.name)
      let writes = f.control?.count(.save)
      if case .refused(.staleBase) = s.requestSave(
        expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch)
      {
      } else {
        XCTFail("No fresh publication substitution for dirty stale raw")
      }
      if case .unavailable = s.requestRefresh() {} else { XCTFail("Refresh must not destroy raw") }
      XCTAssertEqual(f.control?.count(.save), writes)
      panel.languageManagerEditingTestFacts.discard.performClick(nil)
      XCTAssertFalse(try XCTUnwrap(s.editState).isDirty)
      XCTAssertFalse(try XCTUnwrap(s.editState).isStale)
      XCTAssertNotEqual(s.editState?.draftID, before.draftID)
      XCTAssertEqual(s.editState?.basePublicationID, f.catalog?.state.current?.id)
      sameUnits(try XCTUnwrap(s.editState?.definitions.first).name, "Actual unrelated publication")
      XCTAssertEqual(f.control?.count(.save), writes)
    }
  }

  func testDirtyAndInvalidActualCloseKeepsManagerAndChild() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      let window = try XCTUnwrap(panel.window)
      raw.name = ""
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
      let child = panel.languageManagerEditingTestFacts.editor
      for close in [
        { panel.close() }, { window.close() },
        { panel.languageManagerTestFacts.close.performClick(nil) },
      ] {
        close()
        XCTAssertTrue(f.app.languageManagerTestFacts.controller === panel)
        XCTAssertTrue(s.isAttached)
        XCTAssertTrue(panel.languageManagerEditingTestFacts.editor === child)
        sameUnits(try XCTUnwrap(definition(s)).name, "")
      }
      guard accepted(s.discardFormChanges(handle: handle)) else { return }
      let observation = ManagerEditCloseObservation(f, panel, terminal: false)
      let token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window, queue: nil
      ) { [weak observation] _ in
        MainActor.assumeIsolated { observation?.receive() }
      }
      window.close()
      NotificationCenter.default.removeObserver(token)
      XCTAssertEqual(
        observation.count, 1, "Refused close must not permanently consume native close guard")
      guard let successor = observation.successor else { return }
      panel.close()
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === successor)
      let successorWindow = try XCTUnwrap(successor.window)
      let terminal = ManagerEditCloseObservation(f, successor, terminal: true)
      let terminalToken = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: successorWindow, queue: nil
      ) { [weak terminal] _ in
        MainActor.assumeIsolated { terminal?.receive() }
      }
      defer { NotificationCenter.default.removeObserver(terminalToken) }
      let external = AppRoutingGate()
      f.native.externalGate = external
      defer { external.release() }
      f.native.writer.arm()
      guard let attempt = f.beginQuit(), f.requireReservation() != nil else { return }
      guard
        await f.wait(
          "actual terminal native publication", { f.native.writer.applicationCatalogEntered })
      else { return }
      f.native.writer.release()
      guard await f.wait("actual terminal retire before external drain", { external.calls == 1 })
      else { return }
      XCTAssertEqual(terminal.count, 1, "Committed close must work after actual detach")
      XCTAssertFalse(successor.languageManagerTestFacts.session.isAttached)
      XCTAssertNil(f.app.languageManagerTestFacts.controller)
      XCTAssertNil(terminal.successor)
      successor.close()
      XCTAssertEqual(terminal.count, 1)
      external.release()
      let result = await attempt.join()
      XCTAssertNotNil(result.nativeReceipt)
      XCTAssertEqual(f.native.replies, [true])
    }
  }

  func testDirtyQuitVetoPrecedesCatalogSearchAndNativePreparation() async throws {
    var completedReservationAndRollback = false
    try await withEditableLanguageManager { f in
      guard let (_, s) = await ready(f), let handle = edit(s, CatalogTestFixture.id),
        var raw = definition(s)
      else { return }
      let owner = try XCTUnwrap(f.catalog)
      raw.name = "Dirty"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))) else { return }
      let before = try XCTUnwrap(s.editState)
      XCTAssertEqual(f.app.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
      XCTAssertNil(f.app.applicationCatalogTestCaptureAttempt())
      XCTAssertNil(owner.mutationState.preparedQuitID)
      XCTAssertEqual(f.native.ownerFactories, 0)
      XCTAssertFalse(f.native.writer.applicationCatalogEntered)
      // Owner reserve notifies synchronously, with a current renderable delivery.
      let renderer = s.onChange
      var reentries = 0
      s.onChange = { snapshot in
        if let actualQuit = snapshot.mutation.preparedQuitID, reentries == 0 {
          reentries += 1
          func expect(_ value: NativeLanguageManagerEditAdmission) {
            if case .refused(.catalog(.quitPrepared(let id))) = value {
              XCTAssertEqual(id, actualQuit)
            } else {
              XCTFail("Reserved catalog delivery cannot mutate local raw")
            }
          }
          if case .refused(.catalog(.quitPrepared(let id))) = s.beginNewDefinition() {
            XCTAssertEqual(id, actualQuit)
          } else {
            XCTFail("Reserved New admission")
          }
          if case .refused(.catalog(.quitPrepared(let id))) = s.beginEdit(
            target: .definition(raw.id),
            expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch)
          {
            XCTAssertEqual(id, actualQuit)
          } else {
            XCTFail("Reserved Edit admission")
          }
          expect(s.updateForm(handle: handle, raw: .definition(raw)))
          expect(s.finishForm(handle: handle))
          expect(s.discardFormChanges(handle: handle))
          expect(
            s.stageDelete(
              profileID: raw.id, expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch))
          expect(
            s.revertChange(
              target: .definition(raw.id), expectedDraftID: before.draftID,
              expectedEpoch: before.rawEpoch))
          expect(s.discardDraft(expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch))
          if case .refused(.catalog(.quitPrepared(let id))) = s.requestSave(
            expectedDraftID: before.draftID, expectedEpoch: before.rawEpoch)
          {
            XCTAssertEqual(id, actualQuit)
          } else {
            XCTFail("Reserved Save admission")
          }
          XCTAssertEqual(s.editState?.rawEpoch, before.rawEpoch)
          XCTAssertEqual(s.editState?.activeForm?.handle.id, handle.id)
        }
        renderer?(snapshot)
      }
      let reservation = owner.prepareQuit()
      XCTAssertEqual(reentries, 1)
      guard case .prepared(let id) = reservation else {
        XCTFail("Real reservation absent")
        return
      }
      XCTAssertTrue(owner.cancelPreparedQuit(id))
      s.onChange = renderer
      raw.name = "After real cancel"
      guard accepted(s.updateForm(handle: handle, raw: .definition(raw))),
        accepted(s.discardFormChanges(handle: handle))
      else { return }
      // Real App rollback, then positive local admission (no injected reservation).
      f.native.permitsPublicationErrors = true
      f.native.writer.arm(failing: true)
      guard let attempt = f.beginQuit(), f.requireReservation() != nil else { return }
      guard await f.wait("actual rollback writer", { f.native.writer.applicationCatalogEntered })
      else { return }
      f.native.writer.release()
      _ = await attempt.join()
      XCTAssertEqual(f.native.replies, [false])
      guard let after = opened(s.beginNewDefinition()) else { return }
      guard accepted(s.discardFormChanges(handle: after)) else { return }
      completedReservationAndRollback = true
    }
    guard completedReservationAndRollback else { return }
    // Native flush reentry installs a genuine nested attempt; outer frame cannot replace it.
    try await withEditableLanguageManager { f in
      guard let (panel, _) = await ready(f), let window = panel.window else { return }
      let responder = ManagerQuitFlushResponder(frame: .zero)
      window.contentView?.addSubview(responder)
      let installed = window.makeFirstResponder(responder)
      XCTAssertTrue(
        installed, "Actual hidden native first-responder admission precedes flush horizon")
      guard installed else { return }
      var nested: ApplicationCatalogJoinedAttempt?
      responder.onResign = { nested = f.beginQuit() }
      f.native.writer.arm()
      let answer = f.app.applicationShouldTerminate(NSApplication.shared)
      XCTAssertEqual(answer, .terminateLater)
      XCTAssertNotNil(nested, "Real flush callback must install nested attempt")
      guard let nested else { return }
      XCTAssertEqual(f.app.task4Attempt?.id, nested.handle.id)
      XCTAssertEqual(f.native.startedAttempts, 1)
      guard f.requireReservation() != nil,
        await f.wait("nested original writer", { f.native.writer.applicationCatalogEntered })
      else { return }
      f.native.writer.release()
      _ = await nested.join()
      XCTAssertEqual(f.native.replies, [true])
    }
  }
}

// Four bounded regressions for the independently held five-file Source V1.
// All production authority remains in the actual existing owner/Store fixture above.
@MainActor private enum ManagerRegressionFailureCustody {
  static var unclosedCandidate: NativeLanguageManagerController?
}

@MainActor private final class ManagerCandidateCloseObservation {
  let fixture: ApplicationCatalogFixture
  let installed: NativeLanguageManagerController
  weak var candidate: NativeLanguageManagerController?
  var retirementCalls = 0
  var nativeCloseCalls = 0
  init(_ fixture: ApplicationCatalogFixture, installed: NativeLanguageManagerController) {
    self.fixture = fixture
    self.installed = installed
  }
  func retired(_ value: NativeLanguageManagerController) {
    retirementCalls += 1
    XCTAssertTrue(value === candidate)
    XCTAssertEqual(retirementCalls, 1)
    XCTAssertTrue(fixture.app.languageManagerTestFacts.controller === installed)
  }
  func nativeClosed() {
    nativeCloseCalls += 1
    XCTAssertEqual(nativeCloseCalls, 1)
    XCTAssertFalse(candidate?.languageManagerTestFacts.session.isAttached ?? true)
    XCTAssertTrue(fixture.app.languageManagerTestFacts.controller === installed)
    XCTAssertTrue(installed.languageManagerTestFacts.session.isAttached)
  }
}

@MainActor final class LanguageManagerEditSaveRegressionTests: XCTestCase {
  private func accepted(
    _ value: NativeLanguageManagerEditAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    guard case .accepted = value else {
      XCTFail("Actual local admission required before regression horizon", file: file, line: line)
      return false
    }
    return true
  }
  private func opened(_ value: NativeLanguageManagerFormAdmission)
    -> NativeLanguageManagerFormHandle?
  {
    guard case .opened(let handle) = value else {
      XCTFail("Actual session-issued form required before dependent controls")
      return nil
    }
    return handle
  }
  private func current(_ session: NativeLanguageManagerSession)
    -> NativeLanguageManagerRawDefinition?
  {
    guard case .definition(let raw)? = session.editState?.activeForm?.raw else {
      XCTFail("Actual definition form required")
      return nil
    }
    return raw
  }
  private func edit(_ session: NativeLanguageManagerSession, _ id: UUID)
    -> NativeLanguageManagerFormHandle?
  {
    guard let state = session.editState else {
      XCTFail("Actual workspace missing")
      return nil
    }
    return opened(
      session.beginEdit(
        target: .definition(id), expectedDraftID: state.draftID,
        expectedEpoch: state.rawEpoch))
  }
  private func ready(_ fixture: ApplicationCatalogFixture, seed64: Bool = false) async throws
    -> (NativeLanguageManagerController, NativeLanguageManagerSession, [UUID])?
  {
    guard await fixture.load() else { return nil }
    let owner = try XCTUnwrap(fixture.catalog)
    if seed64 {
      let publication = try XCTUnwrap(owner.state.current)
      let ids = [CatalogTestFixture.id] + (1..<64).map { _ in UUID() }
      XCTAssertEqual(Set(ids).count, 64)
      guard Set(ids).count == 64 else { return nil }
      let definitions = try ids.enumerated().map { index, id in
        try LiteralLanguageDefinition(
          id: id, name: "Profile \(index)", fileExtensions: [],
          keywords: [], lineComment: nil, blockComment: nil, quotes: [],
          highlightDecimalNumbers: false, indentation: .legacy)
      }
      // Core values are proposals; only this genuine request supplies receipt/generation authority.
      let draft = try NativeLanguageCatalogDraft(
        definitions: definitions,
        overrides: publication.catalog.overrides)
      guard
        let operation = fixture.requestID(
          owner.requestApply(
            draft,
            expectedPublication: .current(publication.id))), await fixture.settle(operation)
      else { return nil }
      let fresh = try await fixture.fresh()
      XCTAssertEqual(fresh.snapshot.definitions, definitions)
      XCTAssertEqual(fresh.snapshot.definitions.count, 64)
      guard fresh.snapshot.definitions == definitions else { return nil }
    }
    let panel = fixture.app.languageManagerTestMake()
    XCTAssertNotNil(panel, "Actual App manager factory precedes regression setup")
    guard let panel else { return nil }
    XCTAssertNotNil(panel.window)
    guard let window = panel.window else { return nil }
    XCTAssertFalse(window.isVisible)
    let session = panel.languageManagerTestFacts.session
    XCTAssertNotNil(session.editState)
    guard let state = session.editState else { return nil }
    XCTAssertTrue(session.languageManagerTestOwner === owner)
    let ids = state.definitions.map(\.id)
    if seed64 {
      XCTAssertEqual(ids.count, 64)
      guard ids.count == 64 else { return nil }
    }
    return (panel, session, ids)
  }
  private func sameText(
    _ a: String, _ b: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(a.utf16.elementsEqual(b.utf16), file: file, line: line)
  }
  // Independent Test projection of declared raw fields, never the Source fits/strings helpers.
  private func fields(_ raw: NativeLanguageManagerRawDefinition) -> [String] {
    [
      raw.name, raw.extensionsText, raw.keywordsText, raw.lineText, raw.blockOpening,
      raw.blockClosing, raw.widthText,
    ] + raw.quotes.flatMap { [$0.opening, $0.closing, $0.escapeText] }
  }
  private func units(_ state: NativeLanguageManagerEditState) -> Int {
    state.definitions.flatMap { fields($0) }.reduce(0) { $0 + $1.utf16.count }
      + state.overrides.flatMap { [$0.lineText, $0.blockOpening, $0.blockClosing, $0.widthText] }
      .reduce(0) { $0 + $1.utf16.count }
  }
  private func sameDefinition(
    _ a: NativeLanguageManagerRawDefinition,
    _ b: NativeLanguageManagerRawDefinition
  ) {
    XCTAssertEqual(a.id, b.id)
    XCTAssertEqual(fields(a).count, fields(b).count)
    for (x, y) in zip(fields(a), fields(b)) { sameText(x, y) }
    XCTAssertEqual(a.lineEnabled, b.lineEnabled)
    XCTAssertEqual(a.blockEnabled, b.blockEnabled)
    XCTAssertEqual(a.highlightDecimalNumbers, b.highlightDecimalNumbers)
    switch (a.indentationKind, b.indentationKind) {
    case (.legacy, .legacy), (.spaces, .spaces), (.tabs, .tabs): break
    default: XCTFail("Raw indentation changed")
    }
    XCTAssertEqual(a.quotes.map(\.rowID), b.quotes.map(\.rowID))
    for (x, y) in zip(a.quotes, b.quotes) {
      XCTAssertEqual(x.escapeEnabled, y.escapeEnabled)
      XCTAssertEqual(x.multiline, y.multiline)
    }
  }
  private func unchanged(
    _ before: NativeLanguageManagerEditState,
    _ after: NativeLanguageManagerEditState
  ) {
    XCTAssertEqual(after.draftID, before.draftID)
    XCTAssertEqual(after.rawEpoch, before.rawEpoch)
    XCTAssertEqual(after.viewID, before.viewID)
    XCTAssertEqual(after.basePublicationID, before.basePublicationID)
    XCTAssertEqual(after.selectedTarget, before.selectedTarget)
    XCTAssertEqual(after.isDirty, before.isDirty)
    XCTAssertEqual(after.isStale, before.isStale)
    XCTAssertEqual(after.saveOperationID, before.saveOperationID)
    XCTAssertEqual(after.issues.count, before.issues.count)
    XCTAssertEqual(after.activeForm?.handle.id, before.activeForm?.handle.id)
    XCTAssertTrue(after.activeForm?.handle === before.activeForm?.handle)
    XCTAssertEqual(after.definitions.map(\.id), before.definitions.map(\.id))
    guard after.definitions.map(\.id) == before.definitions.map(\.id) else { return }
    for (x, y) in zip(after.definitions, before.definitions) { sameDefinition(x, y) }
    XCTAssertEqual(after.overrides.map(\.language), before.overrides.map(\.language))
    for (x, y) in zip(after.overrides, before.overrides) {
      switch (x.lineKind, y.lineKind) {
      case (.inherit, .inherit), (.disabled, .disabled), (.literal, .literal): break
      default: XCTFail("Raw override line policy changed")
      }
      switch (x.blockKind, y.blockKind) {
      case (.inherit, .inherit), (.disabled, .disabled), (.literal, .literal): break
      default: XCTFail("Raw override block policy changed")
      }
      switch (x.indentationKind, y.indentationKind) {
      case (.legacy, .legacy), (.spaces, .spaces), (.tabs, .tabs): break
      default: XCTFail("Raw override indentation changed")
      }
      for (a, b) in zip(
        [x.lineText, x.blockOpening, x.blockClosing, x.widthText],
        [y.lineText, y.blockOpening, y.blockClosing, y.widthText])
      { sameText(a, b) }
    }
  }

  func testRevertDeletedBaseRefusesSixtyFifthDefinitionWithoutChangingDraft() async throws {
    try await withEditableLanguageManager { f in
      guard let (_, session, ids) = try await ready(f, seed64: true), let deleted = ids.first else {
        return
      }
      let original = try XCTUnwrap(session.editState)
      let beforeBytes = try f.bytes()
      let control = try XCTUnwrap(f.control)
      guard
        accepted(
          session.stageDelete(
            profileID: deleted, expectedDraftID: original.draftID,
            expectedEpoch: original.rawEpoch))
      else { return }
      XCTAssertEqual(session.editState?.definitions.count, 63)
      guard let handle = opened(session.beginNewDefinition()), var raw = current(session) else {
        return
      }
      raw.name = "Replacement staged"
      guard accepted(session.updateForm(handle: handle, raw: .definition(raw))),
        accepted(session.finishForm(handle: handle))
      else { return }
      let before = try XCTUnwrap(session.editState)
      XCTAssertEqual(before.definitions.count, 64)
      guard before.definitions.count == 64 else { return }
      let calls = control.calls.map(\.kind)
      let admission = session.revertChange(
        target: .definition(deleted), expectedDraftID: before.draftID,
        expectedEpoch: before.rawEpoch)
      if case .refused(.boundExceeded) = admission {
      } else {
        XCTFail("Restoring a base definition cannot publish a sixty-fifth raw entry")
      }
      unchanged(before, try XCTUnwrap(session.editState))
      XCTAssertEqual(control.calls.map(\.kind), calls)
      XCTAssertEqual(try f.bytes(), beforeBytes)
      // Correct refusal and defective V1 acceptance both leave a genuine local-reset cleanup route.
      let cleanup = try XCTUnwrap(session.editState)
      guard
        accepted(
          session.discardDraft(
            expectedDraftID: cleanup.draftID,
            expectedEpoch: cleanup.rawEpoch))
      else { return }
      XCTAssertEqual(session.editState?.definitions.count, 64)
      XCTAssertFalse(try XCTUnwrap(session.editState).isDirty)
    }
  }

  func testDiscardSavedFormBaselineRefusesAggregateOverflowAndKeepsCurrentForm() async throws {
    try await withEditableLanguageManager { f in
      guard let (_, session, ids) = try await ready(f, seed64: true), let a = ids.first,
        let originalHandle = edit(session, a), var submitted = current(session)
      else { return }
      let control = try XCTUnwrap(f.control)
      let buffer = String(repeating: "x", count: 65536)
      submitted.name = "Submitted A"  // A real effective change guarantees a real Store write hook.
      submitted.lineEnabled = false
      submitted.lineText = buffer
      guard accepted(session.updateForm(handle: originalHandle, raw: .definition(submitted))) else {
        return
      }
      let proposal = try XCTUnwrap(session.editState)
      // Safe exact boundary pair; bounded-prefix-before-split remains a Source-review obligation.
      var oneOver = submitted
      oneOver.lineText += "x"
      if case .refused(.boundExceeded) = session.updateForm(
        handle: originalHandle,
        raw: .definition(oneOver))
      {
      } else {
        XCTFail("65537-unit field must refuse without truncation")
      }
      unchanged(proposal, try XCTUnwrap(session.editState))
      XCTAssertEqual(control.count(.save), 1, "Only genuine64 seed publication so far")
      let gate = control.hold(.save)
      defer {
        gate.release()  // Always before outer fixture joins, including early assertion returns.
        // Current raw is valid. Finish, rather than re-discard the potentially oversized baseline.
        if let active = session.editState?.activeForm?.handle {
          _ = accepted(session.finishForm(handle: active))
        }
      }
      let admission = session.requestSave(
        expectedDraftID: proposal.draftID, expectedEpoch: proposal.rawEpoch)
      let operation: UUID?
      if case .started(let id) = admission { operation = id } else { operation = nil }
      XCTAssertNotNil(operation, "Actual Save admission must precede held-hook wait")
      guard let operation else { return }
      await fulfillment(of: [gate.entered], timeout: 4)
      guard await f.wait("real aggregate-test Save hook", { control.count(.save) == 2 }) else {
        return
      }
      var currentA = submitted
      currentA.name = "Current A"
      currentA.lineText = ""
      guard accepted(session.updateForm(handle: originalHandle, raw: .definition(currentA))),
        accepted(session.finishForm(handle: originalHandle))
      else { return }
      for id in ids.dropFirst().prefix(31) {
        guard let handle = edit(session, id), var raw = current(session) else { return }
        raw.lineEnabled = false
        raw.lineText = buffer
        guard accepted(session.updateForm(handle: handle, raw: .definition(raw))),
          accepted(session.finishForm(handle: handle))
        else { return }
      }
      guard let reopened = edit(session, a) else { return }
      let admitted = try XCTUnwrap(session.editState)
      let retainedUnits = units(admitted)
      XCTAssertEqual(admitted.definitions.count, 64)
      XCTAssertGreaterThan(retainedUnits, 31 * 65536)
      XCTAssertLessThan(retainedUnits, 2_097_152)
      XCTAssertGreaterThan(retainedUnits + 65536, 2_097_152)
      // Settlement must advance this NEW form's baseline to genuine immutable submitted A.
      gate.release()
      guard await f.settle(operation) else { return }
      let fresh = try await f.fresh()
      XCTAssertEqual(fresh.snapshot.definitions.count, 64)
      XCTAssertEqual(fresh.snapshot.definitions.first?.name, "Submitted A")
      XCTAssertNil(fresh.snapshot.definitions.first?.lineComment, "Disabled raw never enters wire")
      let before = try XCTUnwrap(session.editState)
      XCTAssertEqual(before.activeForm?.handle.id, reopened.id)
      XCTAssertNil(before.saveOperationID)
      XCTAssertEqual(before.basePublicationID, f.catalog?.state.current?.id)
      let calls = control.calls.map(\.kind)
      let discard = session.discardFormChanges(handle: reopened)
      if case .refused(.boundExceeded) = discard {
      } else {
        XCTFail("Restoring saved 64KiB form baseline must not exceed aggregate raw capacity")
      }
      unchanged(before, try XCTUnwrap(session.editState))
      XCTAssertEqual(control.calls.map(\.kind), calls)
      XCTAssertEqual(control.count(.save), 2)
      XCTAssertEqual(control.maximum, 1)
      // Do not ask ordinary fixture cleanup to discard the same overflowing form again.
      if let active = session.editState?.activeForm?.handle {
        guard accepted(session.finishForm(handle: active)) else { return }
      }
      let withoutForm = try XCTUnwrap(session.editState)
      if units(withoutForm) < 2_097_152 {
        // Correct form refusal leaves the same under-cap current A. Revert must also preflight
        // its saved large baseline; fixing only the64-count path is insufficient.
        let revert = session.revertChange(
          target: .definition(a), expectedDraftID: withoutForm.draftID,
          expectedEpoch: withoutForm.rawEpoch)
        if case .refused(.boundExceeded) = revert {
        } else {
          XCTFail(
            "Aggregate Revert must preserve newer raw instead of restoring oversized baseline")
        }
        unchanged(withoutForm, try XCTUnwrap(session.editState))
        XCTAssertEqual(control.calls.map(\.kind), calls)
      }
      // If defectiveV1 already published overflow, this additional Revert horizon is unentered.
      let cleanable = try XCTUnwrap(session.editState)
      guard
        accepted(
          session.discardDraft(
            expectedDraftID: cleanable.draftID,
            expectedEpoch: cleanable.rawEpoch))
      else { return }
      XCTAssertFalse(try XCTUnwrap(session.editState).isDirty)
      XCTAssertLessThan(units(try XCTUnwrap(session.editState)), 65536)
    }
  }

  func testNativeFieldSubmissionReentryKeepsSameHandleSuccessorInControlsAndDone() async throws {
    try await withEditableLanguageManager { f in
      guard let (panel, session, _) = try await ready(f) else { return }
      panel.languageManagerTestFacts.table.selectRowIndexes(
        IndexSet(integer: 0), byExtendingSelection: false)
      panel.languageManagerEditingTestFacts.edit.performClick(nil)
      XCTAssertNotNil(session.editState?.activeForm)
      XCTAssertNotNil(panel.languageManagerEditingTestFacts.editor)
      guard let form = session.editState?.activeForm,
        let editor = panel.languageManagerEditingTestFacts.editor
      else { return }
      let handle = form.handle
      let controls = editor.languageDefinitionEditingTestFacts
      let renderer = session.onChange
      var successorAdmissions = 0
      var armed = true
      let control = try XCTUnwrap(f.control)
      let calls = control.calls.map(\.kind)
      defer { session.onChange = renderer }
      session.onChange = { snapshot in
        if armed, case .definition(var raw)? = session.editState?.activeForm?.raw,
          raw.name.utf16.elementsEqual("Outer".utf16)
        {
          // Burn before synchronous successor publication, never suppress the renderer.
          armed = false
          raw.name = "Successor"
          if self.accepted(session.updateForm(handle: handle, raw: .definition(raw))) {
            successorAdmissions += 1
          }
        }
        renderer?(snapshot)
      }
      controls.name.stringValue = "Outer"
      editor.controlTextDidChange(
        Notification(
          name: NSControl.textDidChangeNotification,
          object: controls.name))
      XCTAssertEqual(successorAdmissions, 1)
      XCTAssertEqual(session.editState?.activeForm?.handle.id, handle.id)
      sameText(try XCTUnwrap(current(session)).name, "Successor")
      sameText(controls.name.stringValue, "Successor")
      // Ordinary Done performs real native flush. Old stale control text cannot overwrite B.
      controls.done.performClick(nil)
      XCTAssertNil(session.editState?.activeForm)
      sameText(try XCTUnwrap(session.editState?.definitions.first).name, "Successor")
      XCTAssertEqual(control.calls.map(\.kind), calls)
      XCTAssertEqual(control.count(.save), 0)
    }
  }

  func testUninstalledCandidateCloseRetiresOnlyItsOwnSessionAndWindow() async throws {
    try await withEditableLanguageManager { f in
      XCTAssertNil(
        ManagerRegressionFailureCustody.unclosedCandidate,
        "A prior exact candidate remains in explicit failure custody")
      guard ManagerRegressionFailureCustody.unclosedCandidate == nil,
        let (installed, _, _) = try await ready(f)
      else { return }
      let owner = try XCTUnwrap(f.catalog)
      let control = try XCTUnwrap(f.control)
      let calls = control.calls.map(\.kind)
      let freshSession = NativeLanguageManagerSession(owner: owner)
      XCTAssertNil(freshSession.snapshot)
      let observation = ManagerCandidateCloseObservation(f, installed: installed)
      let candidate = NativeLanguageManagerController(session: freshSession) {
        [weak observation] value in
        observation?.retired(value)
      }
      observation.candidate = candidate
      XCTAssertNotNil(candidate.window)
      guard let window = candidate.window else {
        ManagerRegressionFailureCustody.unclosedCandidate = candidate
        return
      }
      XCTAssertFalse(window.isVisible)
      let token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window, queue: nil
      ) { [weak observation] _ in
        MainActor.assumeIsolated { observation?.nativeClosed() }
      }
      defer { NotificationCenter.default.removeObserver(token) }
      candidate.close()
      candidate.close()
      window.close()
      XCTAssertEqual(observation.retirementCalls, 1)
      XCTAssertEqual(observation.nativeCloseCalls, 1)
      XCTAssertFalse(freshSession.isAttached)
      XCTAssertTrue(f.app.languageManagerTestFacts.controller === installed)
      XCTAssertTrue(installed.languageManagerTestFacts.session.isAttached)
      XCTAssertEqual(control.calls.map(\.kind), calls)
      XCTAssertFalse(window.isVisible)
      if observation.nativeCloseCalls != 1 || freshSession.isAttached {
        // V1 has no legitimate close route. Retain the known hidden object, not a fake bypass.
        ManagerRegressionFailureCustody.unclosedCandidate = candidate
      }
    }
  }
}
