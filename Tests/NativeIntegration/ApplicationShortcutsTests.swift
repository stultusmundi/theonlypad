import Foundation
import XCTest

@testable import PadCore
@testable import ShortcutOwner

final class Gate: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func awaitStart() { _ = started.wait(timeout: .now() + 2) }
  func wait() {
    started.signal()
    _ = release.wait(timeout: .now() + 8)
  }
}
final class Counters: @unchecked Sendable {
  let lock = NSLock()
  private var counts: [String: Int] = [:]
  func bump(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    counts[key, default: 0] += 1
    return counts[key]!
  }
  func get(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[key, default: 0]
  }
}
@MainActor final class ApplicationShortcutsTests: XCTestCase {
  func fixture() throws -> (ShortcutStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ShortcutOwner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return (ShortcutStore(directory: directory), directory)
  }
  func draft() throws -> ShortcutProfile {
    try .init(records: [
      .init(
        commandID: "file.open",
        assignment: .assigned(KeyboardShortcut(key: "r", modifiers: [.command, .control])))
    ])
  }
  func catalog() throws -> [CommandDescriptor] { try AppCommands.registry().commands }
  func wait(_ condition: @escaping @MainActor () -> Bool) async {
    let end = Date().addingTimeInterval(5)
    while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition())
  }
  func testLoadAndConfirmedApply() async throws {
    let (store, _) = try fixture()
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    try await owner.load()
    XCTAssertEqual(owner.state.composition?.registry.commands, try catalog())
    let profile = try draft()
    try await owner.apply(profile)
    XCTAssertEqual(owner.state.profile, profile)
    XCTAssertEqual(try store.read().decoded.get(), profile)
    XCTAssertEqual(
      owner.state.composition?.registry.commands.first { $0.id == "file.open" }?.shortcut,
      "cmd+ctrl+r")
    XCTAssertTrue(owner.state.canQuit)
  }
  func testInvalidStoredRequiresExplicitRepair() async throws {
    let (store, directory) = try fixture()
    let bytes = Data("{\"version\":999}".utf8)
    let path = directory.appendingPathComponent("Shortcuts.json")
    try bytes.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    try await owner.load()
    XCTAssertTrue(owner.state.issues.contains(.invalidStoredProfile))
    XCTAssertEqual(owner.state.profile, .defaults)
    do {
      try await owner.apply(draft())
      XCTFail("unapproved repair")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: path), bytes)
    try await owner.apply(draft(), allowReplacingInvalidStorage: true)
    XCTAssertEqual(try store.read().decoded.get(), try draft())
  }
  func testConflictingDraftDoesNotWrite() async throws {
    let (store, _) = try fixture()
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    try await owner.load()
    let profile = try ShortcutProfile(records: [
      .init(
        commandID: "file.open", assignment: .assigned(KeyboardShortcut(canonicalString: "cmd+s")))
    ])
    do {
      try await owner.apply(profile)
      XCTFail("conflicting apply")
    } catch {}
    XCTAssertNil(try store.read().receipt.rawBytes)
    XCTAssertEqual(owner.state.profile, .defaults)
  }
  func testExternalChangeRetainsRuntimeAndRequiresExplicitReload() async throws {
    let (store, _) = try fixture()
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    try await owner.load()
    _ = try store.write(draft(), matching: store.read().receipt)
    do {
      try await owner.apply(.defaults)
      XCTFail("stale receipt write")
    } catch {}
    XCTAssertEqual(owner.state.profile, .defaults)
    XCTAssertTrue(owner.state.issues.contains(.writeFailure))
    try await owner.reload()
    XCTAssertEqual(owner.state.profile, try draft())
  }
  func testRapidCatalogDuringWritePublishesOnlyLatestWithSavedProfile() async throws {
    let (store, _) = try fixture()
    let gate = Gate()
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.write = { profile, receipt in
      gate.wait()
      return try store.write(profile, matching: receipt)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    let profile = try draft()
    let task = Task { try await owner.apply(profile) }
    await Task.detached { gate.awaitStart() }.value
    XCTAssertFalse(owner.state.canQuit)
    for index in 0..<100 {
      owner.updateCatalog(
        try catalog() + [.init(id: "extension.synthetic.\(index)", title: "Synthetic")])
    }
    XCTAssertNil(owner.state.composition)
    owner.onChange = { if owner.state.composition != nil { _ = counts.bump("published") } }
    gate.release.signal()
    try await task.value
    XCTAssertEqual(owner.state.profile, profile)
    XCTAssertEqual(owner.state.composition?.registry.commands.last?.id, "extension.synthetic.99")
    XCTAssertFalse(
      owner.state.composition?.registry.commands.contains { $0.id == "extension.synthetic.0" }
        ?? true)
    XCTAssertEqual(counts.get("published"), 1)
  }
  func testCatalogConflictFallbackRetainsProfileAndExplains() async throws {
    let (store, _) = try fixture()
    _ = try store.write(draft(), matching: store.read().receipt)
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    try await owner.load()
    owner.updateCatalog(
      try catalog() + [.init(id: "tool.new", title: "New", shortcut: "cmd+ctrl+r")])
    await wait { !owner.state.isBusy && owner.state.composition != nil }
    XCTAssertEqual(owner.state.profile, try draft())
    XCTAssertTrue(owner.state.composition?.usesDefaults ?? false)
    XCTAssertTrue(
      owner.state.issues.contains {
        if case .conflicts = $0 { return true }
        return false
      })
  }
  func testUncertainRequiresValidationReadAndFreshWrite() async throws {
    let (store, directory) = try fixture()
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.write = { profile, receipt in
      if counts.bump("write") == 1 { return try faulty.write(profile, matching: receipt) }
      return try store.write(profile, matching: receipt)
    }
    services.validate = { uncertain in
      _ = counts.bump("validate")
      try AtomicFileStore().validatePublication(
        uncertain.evidence, expected: uncertain.attemptedBytes)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    do {
      try await owner.apply(draft())
      XCTFail("uncertainty must throw")
    } catch {}
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertFalse(owner.state.canQuit)
    XCTAssertEqual(owner.state.profile, .defaults)
    do {
      try await owner.apply(.defaults)
      XCTFail("pending blocks new save")
    } catch {}
    XCTAssertEqual(counts.get("write"), 1)
    try await owner.verifyAndRetry()
    XCTAssertEqual(counts.get("validate"), 2)
    XCTAssertEqual(counts.get("write"), 2)
    XCTAssertEqual(owner.state.profile, try draft())
    XCTAssertTrue(owner.state.canQuit)
  }
  func testFailedVerifyAndReadbackDoNotAcknowledgeOrClearPending() async throws {
    let (store, directory) = try fixture()
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    var services = ShortcutServices(store: store)
    services.write = { try faulty.write($0, matching: $1) }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    do { try await owner.apply(draft()) } catch {}
    _ = try store.write(.defaults, matching: store.read().receipt)
    do {
      try await owner.verifyAndRetry()
      XCTFail("changed publication")
    } catch {}
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertEqual(owner.state.profile, .defaults)
    do {
      try await owner.reload()
      XCTFail("discard authorization")
    } catch {}
    XCTAssertTrue(owner.state.hasPendingPublication)
    try await owner.reload(discardPending: true)
    XCTAssertFalse(owner.state.hasPendingPublication)
  }
  func testReadFailurePreservesRuntimeAndReentryCannotOverlap() async throws {
    let (store, _) = try fixture()
    let count = Counters()
    var services = ShortcutServices(store: store)
    services.read = {
      if count.bump("reads") > 1 { throw ShortcutStoreError.unreadable }
      return try store.read()
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    try await owner.apply(draft())
    let prior = owner.state.composition?.registry.commands
    do {
      try await owner.reload()
      XCTFail("read failure")
    } catch {}
    XCTAssertEqual(owner.state.profile, try draft())
    XCTAssertEqual(owner.state.composition?.registry.commands, prior)
    XCTAssertTrue(owner.state.issues.contains(.readFailure))
  }
  func testReadbackCannotAcknowledgeBeforeBlockedFreshWriteAndUIClosure() async throws {
    let (store, directory) = try fixture()
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    let counts = Counters()
    let gate = Gate()
    var services = ShortcutServices(store: store)
    services.write = { profile, receipt in
      if counts.bump("write") == 1 { return try faulty.write(profile, matching: receipt) }
      gate.wait()
      return try store.write(profile, matching: receipt)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    do { try await owner.apply(draft()) } catch {}
    let priorRevision = owner.state.profileRevision
    let retry = Task { try await owner.verifyAndRetry() }
    await Task.detached { gate.awaitStart() }.value
    XCTAssertEqual(counts.get("write"), 2)
    XCTAssertEqual(owner.state.profileRevision, priorRevision)
    XCTAssertEqual(owner.state.profile, .defaults)
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertFalse(owner.state.canQuit)
    owner.onChange = nil  // A settings window closing only drops its presentation callback.
    gate.release.signal()
    try await retry.value
    XCTAssertEqual(owner.state.profile, try draft())
    XCTAssertTrue(owner.state.canQuit)
  }
  func testReloadFailureCannotDiscardUncertainEvidenceEvenWhenAuthorized() async throws {
    let (store, directory) = try fixture()
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.write = { try faulty.write($0, matching: $1) }
    services.read = {
      if counts.bump("read") > 1 { throw ShortcutStoreError.unreadable }
      return try store.read()
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    do { try await owner.apply(draft()) } catch {}
    do {
      try await owner.reload(discardPending: true)
      XCTFail("read must fail")
    } catch {}
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertFalse(owner.state.canQuit)
    XCTAssertEqual(owner.state.profile, .defaults)
  }
  func testReentrantPublicationStartsCatalogWorkWithoutOldFinishClearingIt() async throws {
    let (store, _) = try fixture()
    let gate = Gate()
    var services = ShortcutServices(store: store)
    services.compose = { commands, profile, revision in
      if commands.last?.id == "extension.latest.run" { gate.wait() }
      return try ShortcutComposer.build(
        catalog: commands, profile: profile, catalogRevision: revision)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    let latest = try catalog() + [CommandDescriptor(id: "extension.latest.run", title: "Latest")]
    var changed = false
    owner.onChange = {
      if !owner.state.isBusy && !changed {
        changed = true
        owner.updateCatalog(latest)
      }
    }
    try await owner.apply(draft())
    XCTAssertTrue(changed)
    XCTAssertTrue(owner.state.isBusy)
    XCTAssertNil(owner.state.composition)
    await Task.detached { gate.awaitStart() }.value
    XCTAssertFalse(owner.state.canQuit)
    gate.release.signal()
    await wait { owner.state.composition?.registry.commands.last?.id == "extension.latest.run" }
    XCTAssertTrue(owner.state.canQuit)
  }
  func testStaleDraftValidationRechecksLatestCatalogBeforeWrite() async throws {
    let (store, _) = try fixture()
    let gate = Gate()
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.compose = { commands, profile, revision in
      if !profile.records.isEmpty && counts.bump("draftCompose") == 1 { gate.wait() }
      return try ShortcutComposer.build(
        catalog: commands, profile: profile, catalogRevision: revision)
    }
    services.write = { profile, receipt in
      _ = counts.bump("write")
      return try store.write(profile, matching: receipt)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    let task = Task { try await owner.apply(draft()) }
    await Task.detached { gate.awaitStart() }.value
    owner.updateCatalog(
      try catalog() + [.init(id: "tool.conflicting", title: "Conflict", shortcut: "cmd+ctrl+r")])
    gate.release.signal()
    do {
      try await task.value
      XCTFail("latest catalog conflicts before write")
    } catch {}
    XCTAssertEqual(counts.get("write"), 0)
    XCTAssertNil(try store.read().receipt.rawBytes)
    XCTAssertEqual(owner.state.composition?.registry.commands.last?.id, "tool.conflicting")
  }
  func testSecondUncertainAttemptRetainsNewestEvidenceUntilThirdConfirmedWrite() async throws {
    let (store, directory) = try fixture()
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.write = { profile, receipt in
      if counts.bump("write") < 3 { return try faulty.write(profile, matching: receipt) }
      return try store.write(profile, matching: receipt)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    do { try await owner.apply(draft()) } catch {}
    do {
      try await owner.verifyAndRetry()
      XCTFail("second sync must fail")
    } catch {}
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertEqual(owner.state.profile, .defaults)
    try await owner.verifyAndRetry()
    XCTAssertEqual(counts.get("write"), 3)
    XCTAssertEqual(owner.state.profile, try draft())
    XCTAssertTrue(owner.state.canQuit)
  }
  func testOverlappingApplyRefusedAndEveryServiceRunsOffMainActor() async throws {
    let (store, _) = try fixture()
    let gate = Gate()
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.read = {
      if Thread.isMainThread { _ = counts.bump("main") }
      return try store.read()
    }
    services.write = { profile, receipt in
      if Thread.isMainThread { _ = counts.bump("main") }
      _ = counts.bump("write")
      gate.wait()
      return try store.write(profile, matching: receipt)
    }
    services.compose = { commands, profile, revision in
      if Thread.isMainThread { _ = counts.bump("main") }
      return try ShortcutComposer.build(
        catalog: commands, profile: profile, catalogRevision: revision)
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    let task = Task { try await owner.apply(draft()) }
    await Task.detached { gate.awaitStart() }.value
    do {
      try await owner.apply(.defaults)
      XCTFail("overlap")
    } catch {}
    XCTAssertEqual(counts.get("write"), 1)
    gate.release.signal()
    try await task.value
    XCTAssertEqual(counts.get("main"), 0)
    XCTAssertEqual(owner.state.profile, try draft())
  }

  func testPublicRevisionsFenceDraftsWithoutChangingForCatalogOnly() async throws {
    let (store, _) = try fixture()
    let owner = ApplicationShortcuts(services: .init(store: store), catalog: try catalog())
    let initial = owner.state.profileRevision
    try await owner.load()
    let loaded = owner.state.profileRevision
    XCTAssertNotEqual(initial, loaded)
    let catalogRevision = owner.state.catalogRevision
    let updated = try catalog() + [CommandDescriptor(id: "extension.new.run", title: "New")]
    owner.updateCatalog(updated)
    XCTAssertEqual(owner.state.catalog, updated)
    XCTAssertNotEqual(owner.state.catalogRevision, catalogRevision)
    XCTAssertEqual(owner.state.profileRevision, loaded)
    await wait { !owner.state.isBusy }
    XCTAssertEqual(owner.state.profileRevision, loaded)
    try await owner.apply(draft())
    XCTAssertNotEqual(owner.state.profileRevision, loaded)
    let applied = owner.state.profileRevision
    try await owner.reload()
    XCTAssertNotEqual(
      owner.state.profileRevision, applied,
      "Fresh loaded receipt invalidates old drafts even for equal profile")
  }

  func testOwnerErrorsExposeActionableDescriptions() {
    let errors: [ApplicationShortcutError] = [
      .busy, .notLoaded, .repairAuthorizationRequired, .pendingPublication, .conflictingProfile,
      .changedPublication,
    ]
    for error in errors { XCTAssertNotNil(error.errorDescription) }
  }

  func testRetryCannotMintReceiptUnderReplacedParentAfterEvidenceValidation() async throws {
    let (store, directory) = try fixture()
    let retired = directory.deletingLastPathComponent().appendingPathComponent(
      "RetiredShortcutOwner-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: retired) }
    var hooks = ShortcutStoreHooks()
    hooks.fault = .directorySync
    let faulty = ShortcutStore(directory: directory, hooks: hooks)
    let counts = Counters()
    var services = ShortcutServices(store: store)
    services.write = { profile, receipt in
      if counts.bump("write") == 1 { return try faulty.write(profile, matching: receipt) }
      return try store.write(profile, matching: receipt)
    }
    services.validate = { uncertainty in
      try AtomicFileStore().validatePublication(
        uncertainty.evidence, expected: uncertainty.attemptedBytes)
      if counts.bump("validate") == 1 {
        try FileManager.default.moveItem(at: directory, to: retired)
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let replacement = directory.appendingPathComponent("Shortcuts.json")
        try uncertainty.attemptedBytes.write(to: replacement)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: replacement.path)
      }
    }
    let owner = ApplicationShortcuts(services: services, catalog: try catalog())
    try await owner.load()
    let revision = owner.state.profileRevision
    do {
      try await owner.apply(draft())
      XCTFail("expected directory sync uncertainty")
    } catch {}
    do {
      try await owner.verifyAndRetry()
      XCTFail("replacement parent cannot authorize retry")
    } catch {}
    XCTAssertEqual(
      counts.get("write"), 1, "No write may use a receipt minted under the replacement parent")
    XCTAssertTrue(owner.state.hasPendingPublication)
    XCTAssertEqual(owner.state.profile, .defaults)
    XCTAssertEqual(owner.state.profileRevision, revision)
    XCTAssertFalse(owner.state.canQuit)
    XCTAssertEqual(
      try store.read().decoded.get(), try draft(),
      "Equal replacement bytes do not establish original publication authority")
  }

}
