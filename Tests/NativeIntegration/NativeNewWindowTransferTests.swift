import AppKit
import PadCore
import XCTest

@testable import NativeRouting

@MainActor final class NativeNewWindowTransferTests: XCTestCase {
  @MainActor private final class Observations {
    var configurations = 0
    var announcements = 0
    var configure: ((EditorWindowController) -> Void)?
  }
  @MainActor private final class Fixture {
    let directory: URL
    let session: SessionCoordinator
    let owner: NativeApplicationDocuments
    let documentID: UUID
    let observations = Observations()
    init(windows: Int, documents: Int = 1, overlap: Bool = false) throws {
      _ = NSApplication.shared
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("synthetic.txt")
      try Data("synthetic buffer".utf8).write(to: file)
      let source = SessionTab(originalPath: file.path)
      documentID = source.id
      var tabs = [source]
      for _ in 1..<max(1, documents) { tabs.append(SessionTab()) }
      if overlap { tabs.append(SessionTab()) }
      var saved = [SessionWindow(tabs: tabs, selectedTabID: source.id)]
      for _ in 1..<max(1, windows) {
        let missing = SessionTab()
        saved.append(SessionWindow(tabs: [missing], selectedTabID: missing.id))
      }
      let snapshot = EditorSession(windows: saved)
      let store = SessionStore(directory: directory.appendingPathComponent("session"))
      let recovery = RecoveryCoordinator(
        directory: directory.appendingPathComponent("recovery"),
        saveCheckpointSession: { try store.save($0) }, readCheckpointSession: { try store.load() })
      session = SessionCoordinator(
        loadSession: { snapshot }, claimRecovery: { try await recovery.claimStartup() })
      let observations = observations
      owner = try NativeApplicationDocuments(
        session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
        onWindowCreated: { _ in observations.announcements += 1 },
        configureWindow: { controller in
          observations.configurations += 1
          observations.configure?(controller)
        }, onError: { _ in })
    }
    func start() async throws {
      try await owner.start()
      newWindowFactoryCalls = 0
      newWindowAdoptionCalls = 0
    }
    func cleanup() async {
      newWindowDrainHook = nil
      newWindowStatusHook = nil
      _ = try? await owner.prepareQuit()
      for window in owner.windows { window.window?.close() }
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func testThirtyOneAggregateWindowsAdmitOneEmptyUnannouncedEndpoint() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let original = try XCTUnwrap(f.owner.registry.handle(id: f.documentID) as? EditorDocument)
    let windowsBefore = f.owner.windows.count
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared(let destination) = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("31 aggregate windows must admit the 32nd")
    }
    XCTAssertEqual(f.owner.windows.count, windowsBefore + 1)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertEqual(f.owner.registry.window(id: destination.windowID)?.groups.first?.documentIDs, [])
    XCTAssertTrue(f.owner.registry.handle(id: f.documentID) === original)
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    XCTAssertFalse(
      try XCTUnwrap(f.owner.windows.first { $0.sessionMetadata.id == destination.windowID }).window!
        .isVisible)
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Prepared ownership must veto quit")
    } catch {}
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertNil(f.owner.registry.window(id: destination.windowID))
    XCTAssertEqual(f.owner.windows.count, windowsBefore)
    await f.cleanup()
  }

  func testThirtyTwoAggregateWindowsRefuseWithoutConstruction() async throws {
    let f = try Fixture(windows: 32)
    try await f.start()
    let before = f.owner.windows.count
    XCTAssertNotNil(f.owner.newWindowMoveRefusalReason())
    do {
      _ = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.owner.windows.count, before)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    await f.cleanup()
  }

  func testLiveUnresolvedOverlapCountsOnce() async throws {
    let f = try Fixture(windows: 31, overlap: true)
    try await f.start()
    XCTAssertNil(f.owner.newWindowMoveRefusalReason())
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Live/unresolved overlap must count once")
    }
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testExisting128DocumentIDsPermitZeroDocumentGrowth() async throws {
    let f = try Fixture(windows: 1, documents: 128)
    try await f.start()
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("New destination adds no document IDs")
    }
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    XCTAssertEqual(f.session.unresolved.count, 127)
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testOrdinaryTextEditDoesNotExpireChoiceAndSecondPreparationRefuses() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let source = try XCTUnwrap(f.owner.windows.first)
    source.focusedPane?.editor.insertText(
      "edit ", replacementRange: NSRange(location: 0, length: 0))
    let id = try f.owner.startNewWindowPreparation(choices)
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("Expected admission refusal")
    } catch {}
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Ordinary buffer editing preserves the choice")
    }
    XCTAssertEqual(
      (f.owner.registry.handle(id: f.documentID) as? EditorDocument)?.storage.string,
      "edit synthetic buffer")
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }
  func testExistingOverLimitAggregateRefusesGrowth() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let first = UUID()
    let second = UUID()
    try f.owner.registry.registerWindow(id: first, initialGroupID: UUID())
    try f.owner.registry.registerWindow(id: second, initialGroupID: UUID())
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let constructions = f.observations.configurations
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.observations.configurations, constructions)
    XCTAssertFalse(f.owner.testPreparationPending)
    try f.owner.registry.unregisterEmptyWindow(
      first, expectedRevision: f.owner.registry.workspaceRevision)
    try f.owner.registry.unregisterEmptyWindow(
      second, expectedRevision: f.owner.registry.workspaceRevision)
    await f.cleanup()
  }

  func testSelectionABAExpiresChoiceWhileForeignChoiceCreatesNothing() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let source = try XCTUnwrap(f.owner.windows.first)
    source.newDocument()
    for _ in 0..<10000 {
      if source.sessionMetadata.tabs.count == 2 { break }
      await Task.yield()
    }
    let second = try XCTUnwrap(source.selectedDocumentID)
    var settled: NativeDocumentMoveChoices?
    for _ in 0..<10000 {
      settled = try? f.owner.prepareMove(documentID: second)
      if settled != nil { break }
      await Task.yield()
    }
    let choice = try XCTUnwrap(settled)
    let assignment = try XCTUnwrap(f.owner.registry.assignment(of: second))
    try f.owner.registry.selectDocument(
      f.documentID, in: assignment, expectedRevision: f.owner.registry.workspaceRevision)
    try f.owner.registry.selectDocument(
      second, in: assignment, expectedRevision: f.owner.registry.workspaceRevision)
    let constructions = f.observations.configurations
    do {
      _ = try f.owner.startNewWindowPreparation(choice)
      XCTFail("Expected admission refusal")
    } catch {}
    let foreign = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: choice.ownershipGeneration,
      sourceWindowID: UUID(), sourceEndpointID: choice.sourceEndpointID, destinations: [],
      sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(foreign)
      XCTFail("Expected admission refusal")
    } catch {}
    XCTAssertEqual(f.observations.configurations, constructions)
    await f.cleanup()
  }

  func testCapacityRevisionChangeAcrossHeldDrainRetainsWithoutConstruction() async throws {
    let f = try Fixture(windows: 2)
    try await f.start()
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let before = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(release)
    f.session.resolved(try XCTUnwrap(f.session.unresolved.first))
    held.resume()
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Changed capacity receipt must refuse construction")
    }
    XCTAssertEqual(f.observations.configurations, before)
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertTrue(f.owner.canRetryRecovery)
    newWindowDrainHook = nil
    try await f.owner.retryRecovery()
    XCTAssertFalse(f.owner.testPreparationPending)
    await f.cleanup()
  }

  func testConfigurationReentryCannotCreateIntakeCloseOrPublish() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choice = try f.owner.prepareMove(documentID: f.documentID)
    var reentered = false
    var provisional: EditorWindowController?
    f.observations.configure = { controller in
      reentered = true
      provisional = controller
      XCTAssertTrue(f.owner.testPreparationPending)
      do {
        _ = try f.owner.createWindow()
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        _ = try f.owner.startNewWindowPreparation(choice)
        XCTFail("Expected admission refusal")
      } catch {}
      controller.newDocument()
      do {
        try f.owner.testStartClose(f.documentID)
        XCTFail("Close must refuse during configuration")
      } catch {}
    }
    let announcements = f.observations.announcements
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(choice)
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Refused reentry must preserve preparation")
    }
    XCTAssertTrue(reentered)
    XCTAssertEqual(newWindowFactoryCalls, 0)
    XCTAssertEqual(newWindowAdoptionCalls, 0)
    XCTAssertEqual(f.observations.configurations, constructions + 1)
    XCTAssertEqual(f.observations.announcements, announcements)
    XCTAssertTrue(try XCTUnwrap(provisional).sessionMetadata.tabs.isEmpty)
    do {
      try await f.owner.testPreparePublisher()
      XCTFail("Publisher preparation must refuse immediately")
    } catch {}
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Preparation must veto quit")
    } catch {}
    do {
      try await f.owner.start()
      XCTFail("Reentrant startup must refuse")
    } catch {}
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testCancelledWaiterDoesNotReleaseOwnerPauseOrDiscardPreparation() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let unrelated = try f.owner.testAcquirePause()
    try await f.owner.testDrainPause(unrelated)
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    let waiter = Task { try await f.owner.waitForNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    waiter.cancel()
    XCTAssertTrue(f.owner.testPreparationPending)
    try XCTUnwrap(release).resume()
    guard case .prepared = try await waiter.value else {
      return XCTFail("Waiter does not own cancellation")
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertFalse(f.owner.testPreparationPending)
    // Exact independently-held token must remain valid and unreleased.
    try f.owner.testReleasePause(unrelated)
    do {
      _ = try f.owner.testReleasePause(unrelated)
      XCTFail("Expected admission refusal")
    } catch {}
    await f.cleanup()
  }

  func testRegistrationNotifiesAfterOwnerReceiptAndUnderFence() async throws {
    let registry = ApplicationDocuments()
    let id = UUID()
    let group = UUID()
    var receipt: UUID?
    var notified = false
    registry.onChange = { revision in
      notified = true
      XCTAssertEqual(receipt, revision)
    }
    try registry.registerWindow(
      id: id, initialGroupID: group,
      willNotify: { revision in
        receipt = revision
        do {
          _ = try registry.registerWindow(id: UUID(), initialGroupID: UUID())
          XCTFail("Expected admission refusal")
        } catch {}
      })
    XCTAssertTrue(notified)
    registry.onChange = { _ in XCTAssertNil(registry.window(id: id)) }
    var removed = false
    try registry.unregisterEmptyWindow(
      id, expectedRevision: registry.workspaceRevision,
      willNotify: { _ in
        removed = true
        do {
          _ = try registry.registerWindow(id: id, initialGroupID: group)
          XCTFail("Expected admission refusal")
        } catch {}
      })
    XCTAssertTrue(removed)
  }

  func testUnregisterCallbackRecreationSurvivesOldCleanup() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .prepared(let destination) = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Expected provisional endpoint")
    }
    let replacementGroup = UUID()
    var replaced = false
    f.owner.registry.onChange = { _ in
      guard !replaced, f.owner.registry.window(id: destination.windowID) == nil else { return }
      replaced = true
      XCTAssertTrue(f.owner.testCleanupRunning)
      do {
        _ = try f.owner.startNewWindowPreparation(choices)
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        _ = try f.owner.createWindow()
        XCTFail("Expected admission refusal")
      } catch {}
      do {
        try f.owner.registry.registerWindow(
          id: destination.windowID, initialGroupID: replacementGroup)
      } catch { XCTFail("Replacement fixture failed: \(error)") }
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertTrue(replaced)
    XCTAssertEqual(
      f.owner.registry.window(id: destination.windowID)?.groups.first?.id, replacementGroup)
    f.owner.registry.onChange = nil
    try f.owner.registry.unregisterEmptyWindow(
      destination.windowID, expectedRevision: f.owner.registry.workspaceRevision)
    await f.cleanup()
  }

  func testReentrantExternalOpenRetainsIntentWithoutSecondEndpoint() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let extra = f.directory.appendingPathComponent("extra-synthetic.txt")
    try Data("extra".utf8).write(to: extra)
    var result: OpenRequestAdmission?
    f.observations.configure = { _ in result = f.owner.enqueueExternal([.init(url: extra)]) }
    let before = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Pending open invalidates the preparation admission")
    }
    for _ in 0..<10000 {
      if f.owner.externalOpenFailure != nil { break }
      await Task.yield()
    }
    XCTAssertEqual(result?.acceptedCount, 1)
    XCTAssertNotNil(f.owner.externalOpenFailure)
    XCTAssertEqual(f.observations.configurations, before + 1)
    XCTAssertEqual(
      try f.owner.registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) },
      [f.documentID])
    try await f.owner.cancelNewWindowPreparation(id)
    await f.cleanup()
  }

  func testExplicitCancelDuringDrainReturnsCancelledToWaiter() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    var release: CheckedContinuation<Void, Never>?
    newWindowDrainHook = { await withCheckedContinuation { release = $0 } }
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    let waiter = Task { try await f.owner.waitForNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if release != nil { break }
      await Task.yield()
    }
    let cancel = Task { try await f.owner.cancelNewWindowPreparation(id) }
    for _ in 0..<10000 {
      if f.owner.testCleanupRunning { break }
      await Task.yield()
    }
    try XCTUnwrap(release).resume()
    newWindowDrainHook = nil
    let result = try await waiter.value
    if case .cancelled = result {
    } else {
      XCTFail("Explicit owner cancellation must report cancelled, not a retained/prepared receipt")
    }
    try await cancel.value
    XCTAssertFalse(f.owner.testPreparationPending)
    await f.cleanup()
  }

  func testPauseReleaseRenderingCannotReenterPreparationOrConsumeTwice() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .prepared = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Expected prepared destination")
    }
    var releaseRendered = false
    newWindowStatusHook = {
      guard f.owner.testCleanupRunning else { return }
      releaseRendered = true
      XCTAssertTrue(f.owner.testPreparationPending)
      do {
        _ = try f.owner.startNewWindowPreparation(choices)
        XCTFail("Reentrant prepare must refuse")
      } catch {}
      do {
        _ = try f.owner.createWindow()
        XCTFail("Reentrant window must refuse")
      } catch {}
    }
    try await f.owner.cancelNewWindowPreparation(id)
    XCTAssertTrue(releaseRendered)
    XCTAssertFalse(f.owner.testPreparationPending)
    do {
      try await f.owner.cancelNewWindowPreparation(id)
      XCTFail("Exact cleanup cannot repeat")
    } catch {}
    await f.cleanup()
  }
  func testActualPendingRecoveryRemovalRefusesBeforeConstruction() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = SessionTab()
    let saved = EditorSession(windows: [.init(tabs: [tab], selectedTabID: tab.id)])
    let store = SessionStore(directory: directory.appendingPathComponent("session"))
    let recoveryDirectory = directory.appendingPathComponent("recovery")
    try RecoveryStore(directory: recoveryDirectory).save(
      .init(id: tab.id, text: "unresolved synthetic", encoding: .utf8, hasBOM: false))
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory, saveCheckpointSession: { try store.save($0) },
      readCheckpointSession: { try store.load() })
    var removal: CheckedContinuation<Void, Error>?
    let session = SessionCoordinator(
      loadSession: { saved }, claimRecovery: { try await recovery.claimStartup() },
      removeRecovery: { _ in
        try await withCheckedThrowingContinuation { removal = $0 }
      })
    await session.restore { _ in [tab.id: "Synthetic retained import"] }
    var constructions = 0
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, configureWindow: { _ in constructions += 1 }, onError: { _ in })
    try await owner.start()
    let source = try XCTUnwrap(owner.windows.first?.selectedDocumentID)
    let choices = try owner.prepareMove(documentID: source)
    let entry = try XCTUnwrap(session.unresolved.first)
    let task = Task { try await session.remove(entry) }
    for _ in 0..<10000 {
      if removal != nil { break }
      await Task.yield()
    }
    let held = try XCTUnwrap(removal)
    let before = constructions
    do {
      _ = try owner.startNewWindowPreparation(choices)
      XCTFail("Pending removal must refuse")
    } catch {}
    XCTAssertEqual(constructions, before)
    XCTAssertFalse(owner.testPreparationPending)
    XCTAssertNotNil(owner.newWindowMoveRefusalReason())
    XCTAssertEqual(try RecoveryStore(directory: recoveryDirectory).loadAll().map(\.id), [tab.id])
    held.resume(throwing: NativeNewWindowPreparationError.changed)
    do {
      try await task.value
      XCTFail("Injected removal fails")
    } catch {}
    let prepared = try owner.startNewWindowPreparation(owner.prepareMove(documentID: source))
    guard case .prepared = try await owner.waitForNewWindowPreparation(prepared) else {
      return XCTFail("Settled failed removal permits fresh admission")
    }
    try await owner.cancelNewWindowPreparation(prepared)
    _ = try await owner.prepareQuit()
    for window in owner.windows { window.window?.close() }
  }

  func testCorruptSessionPreservesBytesAndRefusesWithoutAdditionalConstructionOrIO() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Session.json")
    let corrupt = Data("{synthetic corrupt session".utf8)
    try corrupt.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let store = SessionStore(directory: directory)
    let recovery = RecoveryCoordinator(directory: directory.appendingPathComponent("recovery"))
    var reads = 0
    var constructions = 0
    let session = SessionCoordinator(
      loadSession: {
        reads += 1
        return try store.load()
      }, claimRecovery: { try await recovery.claimStartup() })
    let owner = try NativeApplicationDocuments(
      session: session, recovery: recovery, monitoring: ApplicationFileMonitoring(),
      onWindowCreated: { _ in }, configureWindow: { _ in constructions += 1 }, onError: { _ in })
    do { try await owner.start() } catch {}
    let before = constructions
    let choice = NativeDocumentMoveChoices(
      documentID: UUID(), ownershipGeneration: UUID(), sourceWindowID: UUID(),
      sourceEndpointID: UUID(), destinations: [],
      sourceWorkspaceRevision: owner.registry.workspaceRevision)
    do {
      _ = try owner.startNewWindowPreparation(choice)
      XCTFail("Corrupt session refuses admission")
    } catch {}
    XCTAssertEqual(constructions, before)
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    XCTAssertFalse(owner.testPreparationPending)
  }
  func testRegistrationCallbackWorkspaceABAIsDetectedBeforeConstructionAndRetainsExactWindow()
    async throws
  {
    let f = try Fixture(windows: 1)
    try await f.start()
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    var provisional: UUID?
    f.owner.registry.onChange = { _ in
      guard provisional == nil,
        let added = f.owner.registry.windowIDs.first(where: { $0 != choices.sourceWindowID })
      else { return }
      provisional = added
      do {
        let unrelated = UUID()
        try f.owner.registry.registerWindow(id: unrelated, initialGroupID: UUID())
        try f.owner.registry.unregisterEmptyWindow(
          unrelated, expectedRevision: f.owner.registry.workspaceRevision)
      } catch { XCTFail("Fixture mutation failed: \(String(reflecting: error))") }
      do {
        _ = try f.owner.createWindow()
        XCTFail("Registration callback must remain gated")
      } catch {}
    }
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(choices)
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Registration callback revision ABA must invalidate the receipt")
    }
    XCTAssertEqual(f.observations.configurations, constructions)
    let windowID = try XCTUnwrap(provisional)
    XCTAssertNotNil(f.owner.registry.window(id: windowID))
    do {
      try await f.owner.cancelNewWindowPreparation(id)
      XCTFail("Unproven changed registration must be retained")
    } catch {}
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertNotNil(f.owner.registry.window(id: windowID))
    do {
      _ = try await f.owner.prepareQuit()
      XCTFail("Retained cleanup must veto quit")
    } catch {}
    f.owner.registry.onChange = nil
    // This intentionally retained synthetic owner remains paused until the isolated process exits.
    try? FileManager.default.removeItem(at: f.directory)
  }

  func testOwnershipABAAndForeignEndpointRefuseBeforeConstruction() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let target = try f.owner.createWindow(createDocument: false)
    let choice = try f.owner.prepareMove(documentID: f.documentID)
    let forward = try f.owner.moveDocument(f.documentID, toWindowID: target.sessionMetadata.id)
    guard case .moved = try await f.owner.waitForTransfer(forward) else {
      return XCTFail("Fixture forward transfer failed")
    }
    let reverse = try f.owner.moveDocument(f.documentID, toWindowID: choice.sourceWindowID)
    guard case .moved = try await f.owner.waitForTransfer(reverse) else {
      return XCTFail("Fixture reverse transfer failed")
    }
    let before = f.observations.configurations
    let aba = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: choice.ownershipGeneration,
      sourceWindowID: choice.sourceWindowID, sourceEndpointID: choice.sourceEndpointID,
      destinations: [], sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(aba)
      XCTFail("Old ownership must not revive")
    } catch {}
    let fresh = try f.owner.prepareMove(documentID: f.documentID)
    let foreign = NativeDocumentMoveChoices(
      documentID: f.documentID, ownershipGeneration: fresh.ownershipGeneration,
      sourceWindowID: fresh.sourceWindowID, sourceEndpointID: UUID(), destinations: [],
      sourceWorkspaceRevision: f.owner.registry.workspaceRevision)
    do {
      _ = try f.owner.startNewWindowPreparation(foreign)
      XCTFail("Foreign endpoint must refuse")
    } catch {}
    XCTAssertEqual(f.observations.configurations, before)
    await f.cleanup()
  }

  func testExhaustedNewWindowCapacityPreservesExistingDestinationTransfer() async throws {
    let f = try Fixture(windows: 31)
    try await f.start()
    let target = try f.owner.createWindow(createDocument: false)
    let choices = try f.owner.prepareMove(documentID: f.documentID)
    let destination = try XCTUnwrap(
      choices.destinations.first { $0.windowID == target.sessionMetadata.id })
    XCTAssertNotNil(f.owner.newWindowMoveRefusalReason())
    do {
      _ = try f.owner.startNewWindowPreparation(choices)
      XCTFail("32 windows must refuse growth")
    } catch {}
    let transfer = try f.owner.moveDocument(choices, to: destination)
    guard case .moved = try await f.owner.waitForTransfer(transfer) else {
      return XCTFail("Existing destination remains usable without window growth")
    }
    XCTAssertEqual(
      f.owner.registry.assignment(of: f.documentID)?.windowID, target.sessionMetadata.id)
    await f.cleanup()
  }

  func testDrainFailureRetainsItsPauseUntilExactRecoveryCleanup() async throws {
    let f = try Fixture(windows: 1)
    try await f.start()
    let otherPause = try f.owner.testAcquirePause()
    try await f.owner.testDrainPause(otherPause)
    newWindowDrainHook = { throw NativeNewWindowPreparationError.changed }
    let constructions = f.observations.configurations
    let id = try f.owner.startNewWindowPreparation(f.owner.prepareMove(documentID: f.documentID))
    guard case .retained = try await f.owner.waitForNewWindowPreparation(id) else {
      return XCTFail("Drain failure must retain the exact operation")
    }
    XCTAssertTrue(f.owner.testPreparationPending)
    XCTAssertTrue(f.owner.canRetryRecovery)
    XCTAssertEqual(f.observations.configurations, constructions)
    newWindowDrainHook = nil
    try await f.owner.retryRecovery()
    XCTAssertFalse(f.owner.testPreparationPending)
    try f.owner.testReleasePause(otherPause)
    await f.cleanup()
  }
}
