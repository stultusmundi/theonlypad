// Synthetic test collaborators only. Every authority is issued by actual Store methods.
import Darwin
import Foundation
import XCTest

@testable import NativeLanguageCatalogComponent
@testable import PadCore

enum MutationFixtureError: Error, Equatable {
  case wrongThread, selectedReadFailure, readback, gateTimeout, callBound
}
enum MutationCallKind: Sendable, Equatable { case read, inspect, save, repair, verify, retry }
enum MutationFaultMode: Sendable, Equatable { case clean, prepublication, uncertain, unconfirmed }
struct MutationCall: Sendable {
  let kind: MutationCallKind
  let mode: MutationFaultMode
  let failRead: Bool
  let onMain: Bool
}

final class MutationGate: @unchecked Sendable {
  let entered = XCTestExpectation(description: "actual Store hook entered")
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var didEnter = false
  private var released = false
  func wait() throws {
    guard !Thread.isMainThread else { throw MutationFixtureError.wrongThread }
    lock.lock()
    let first = !didEnter
    didEnter = true
    lock.unlock()
    guard first else { return }
    entered.fulfill()
    guard semaphore.wait(timeout: .now() + 15) == .success else {
      throw MutationFixtureError.gateTimeout
    }
  }
  func release() {
    lock.lock()
    let first = !released
    released = true
    lock.unlock()
    if first { semaphore.signal() }
  }
}
private final class MutationReadbackFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var wrote = false
  func mark() {
    lock.lock()
    wrote = true
    lock.unlock()
  }
  var marked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return wrote
  }
}
final class MutationControl: @unchecked Sendable {
  let directory: URL  // Fixed canonical logical Store destination; never caller-retargeted.
  private let lock = NSLock()
  private var selectedMode = MutationFaultMode.clean
  private var readFailure = false
  private var held: (MutationCallKind, MutationGate)?
  private var records: [MutationCall] = []
  private var active = 0
  private var peak = 0
  private var actualError: (any Error)?
  private var candidates: [LanguageCatalogSnapshot] = []
  init(directory: URL) { self.directory = directory }
  func mode(_ value: MutationFaultMode) {
    lock.lock()
    selectedMode = value
    lock.unlock()
  }
  func failReads(_ value: Bool) {
    lock.lock()
    readFailure = value
    lock.unlock()
  }
  func hold(_ kind: MutationCallKind) -> MutationGate {
    let gate = MutationGate()
    lock.lock()
    precondition(held == nil)
    held = (kind, gate)
    lock.unlock()
    return gate
  }
  func release() {
    lock.lock()
    let gate = held?.1
    lock.unlock()
    gate?.release()
  }
  var calls: [MutationCall] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }
  var maximum: Int {
    lock.lock()
    defer { lock.unlock() }
    return peak
  }
  var error: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return actualError
  }
  var savedCandidates: [LanguageCatalogSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return candidates
  }
  func count(_ kind: MutationCallKind) -> Int { calls.filter { $0.kind == kind }.count }

  private func perform<T>(_ kind: MutationCallKind, _ body: (CustomLanguageStore) throws -> T)
    throws -> T
  {
    guard !Thread.isMainThread else { throw MutationFixtureError.wrongThread }
    lock.lock()
    guard records.count < 128 else {
      lock.unlock()
      throw MutationFixtureError.callBound
    }
    let mode = selectedMode
    let failRead = readFailure
    let gate = held.flatMap { $0.0 == kind ? $0.1 : nil }
    records.append(
      MutationCall(kind: kind, mode: mode, failRead: failRead, onMain: Thread.isMainThread))
    active += 1
    peak = max(peak, active)
    lock.unlock()
    defer {
      lock.lock()
      active -= 1
      lock.unlock()
    }
    let file = directory.appendingPathComponent("Profiles.json")
    var originalLeaf = stat()
    let hadOriginalLeaf = lstat(file.path, &originalLeaf) == 0
    let originalDevice = originalLeaf.st_dev
    let originalInode = originalLeaf.st_ino
    let flag = MutationReadbackFlag()
    var hooks = CustomLanguageStoreHooks()
    if kind == .save || kind == .repair || kind == .retry {
      switch mode {
      case .clean, .unconfirmed: break
      case .prepublication: hooks.fault = .beforeWrite
      case .uncertain: hooks.fault = .directorySync
      }
    }
    hooks.beforeWrite = {
      flag.mark()
      if kind == .save || kind == .repair || kind == .retry { try gate?.wait() }
    }
    hooks.afterRead = {
      if kind == .read || kind == .inspect || kind == .verify { try gate?.wait() }
      if failRead { throw MutationFixtureError.selectedReadFailure }
      if case .unconfirmed = mode, flag.marked, hadOriginalLeaf {
        var currentLeaf = stat()
        if lstat(file.path, &currentLeaf) == 0,
          currentLeaf.st_dev != originalDevice || currentLeaf.st_ino != originalInode
        {
          throw MutationFixtureError.readback
        }
      }
    }
    // Existing immutable Store fault hook choices require separate actual values at this ONE
    // directory. No typed result/receipt/token/evidence constructor appears in this fixture.
    let store = CustomLanguageStore(directory: directory, hooks: hooks)
    do { return try body(store) } catch {
      lock.lock()
      actualError = error
      lock.unlock()
      throw error
    }
  }
  var services: NativeLanguageCatalogServices {
    NativeLanguageCatalogServices(
      read: { try self.perform(.read) { try $0.load() } },
      inspect: { try self.perform(.inspect) { try $0.inspect() } },
      save: { candidate, receipt in
        self.lock.lock()
        self.candidates.append(candidate)
        self.lock.unlock()
        return try self.perform(.save) { try $0.save(candidate, expected: receipt) }
      },
      repair: { definitions, overrides, token in
        try self.perform(.repair) {
          try $0.repair(definitions: definitions, overrides: overrides, matching: token)
        }
      },
      validatePending: { pending in
        try self.perform(.verify) { try $0.validatePendingPublication(pending) }
      },
      retryPending: { pending in
        try self.perform(.retry) { try $0.retryPendingPublication(pending) }
      })
  }
}

struct MutationCapsule: Sendable {
  let root: URL
  let directory: URL
  var file: URL { directory.appendingPathComponent("Profiles.json") }
  static func create() throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CatalogMutation-" + UUID().uuidString
    )
    .resolvingSymlinksInPath()
    let directory = root.appendingPathComponent("Catalog")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    do {
      try CatalogTestFixture.originalBytes.write(
        to: directory.appendingPathComponent("Profiles.json"))
      guard chmod(directory.appendingPathComponent("Profiles.json").path, 0o600) == 0 else {
        throw MutationFixtureError.selectedReadFailure
      }
      _ = try CustomLanguageStore(directory: directory).load()
      return Self(root: root, directory: directory)
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
}

@MainActor final class MutationHarness {
  let capsule: MutationCapsule
  let control: MutationControl
  let owner: NativeLanguageCatalogOwner
  var action: ((NativeLanguageCatalogState) -> Void)?
  var notifications = 0
  var terminalIDs: [UUID] = []
  var waiters: [UUID: XCTestExpectation] = [:]
  init(_ capsule: MutationCapsule, readOnly: Bool = false, defaultStore: Bool = false) {
    self.capsule = capsule
    let control = MutationControl(directory: capsule.directory)
    self.control = control
    if readOnly {
      owner = NativeLanguageCatalogOwner(read: control.services.read)
    } else if defaultStore {
      owner = NativeLanguageCatalogOwner(store: CustomLanguageStore(directory: capsule.directory))
    } else {
      owner = NativeLanguageCatalogOwner(services: control.services)
    }
    owner.onChange = { [weak self] state in
      guard let self else { return }
      self.notifications += 1
      if state.activeRequestID == nil, let id = state.lastSettledRequestID {
        self.terminalIDs.append(id)
        self.waiters.removeValue(forKey: id)?.fulfill()
      }
      self.action?(state)
    }
  }
  func draft(_ name: String = "Owner attempted café") throws -> NativeLanguageCatalogDraft {
    try NativeLanguageCatalogDraft(
      definitions: [CatalogTestFixture.definition(name: name)],
      overrides: [
        BuiltInLanguageOverride(
          language: .swift, lineComment: .disabled,
          blockComment: .inherit, indentation: .tabs(width: 3))
      ])
  }
  func fresh() async throws -> LoadedLanguageCatalog {
    let directory = capsule.directory
    return try await Task.detached { try CustomLanguageStore(directory: directory).load() }.value
  }
  func bytes() throws -> Data { try Data(contentsOf: capsule.file) }
  func install(_ data: Data) throws {
    try data.write(to: capsule.file)
    guard chmod(capsule.file.path, 0o600) == 0 else {
      throw MutationFixtureError.selectedReadFailure
    }
  }
  var expectation: CatalogPublicationExpectation {
    owner.state.current.map { .current($0.id) } ?? .none
  }
}

@MainActor extension NativeLanguageCatalogMutationTests {
  func withMutation(
    readOnly: Bool = false, defaultStore: Bool = false,
    _ body: @MainActor (MutationHarness) async throws -> Void
  ) async throws {
    let capsule = try await Task.detached { try MutationCapsule.create() }.value
    let h = MutationHarness(capsule, readOnly: readOnly, defaultStore: defaultStore)
    do { try await body(h) } catch {
      h.control.release()
      h.action = nil
      h.owner.onChange = nil
      await h.owner.invalidateAndWait()
      try? FileManager.default.removeItem(at: capsule.root)
      throw error
    }
    h.control.release()
    h.action = nil
    h.owner.onChange = nil
    await h.owner.invalidateAndWait()
    try FileManager.default.removeItem(at: capsule.root)
  }
  func admitted(
    _ value: NativeLanguageCatalogMutationAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> UUID? {
    if case .started(let id) = value { return id }
    XCTFail("Expected real mutation admission before any dependent wait", file: file, line: line)
    return nil
  }
  func settled(_ h: MutationHarness, _ id: UUID) async {
    // No stub ever reaches this wait: callers first guard admitted(). MainActor settlement
    // cannot run between a synchronous request and this expectation installation.
    let terminal = XCTestExpectation(description: "selected real owner operation terminal")
    if h.terminalIDs.contains(id) { return }
    h.waiters[id] = terminal
    await fulfillment(of: [terminal], timeout: 4)
    XCTAssertTrue(h.terminalIDs.contains(id))
  }
  func loaded(_ h: MutationHarness) async -> Bool {
    let value = h.owner.requestLoad()
    guard case .started(let id) = value else {
      XCTFail("Real legacy read must start")
      return false
    }
    await settled(h, id)
    XCTAssertNotNil(h.owner.state.current)
    return h.owner.state.current != nil
  }
  func refused(
    _ value: NativeLanguageCatalogMutationAdmission,
    _ matches: (NativeLanguageCatalogMutationRefusal) -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .refused(let reason) = value else {
      return XCTFail("Expected refusal", file: file, line: line)
    }
    XCTAssertTrue(matches(reason), "Wrong truthful refusal", file: file, line: line)
  }
  func prepared(
    _ value: CatalogQuitAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> UUID? {
    if case .prepared(let id) = value { return id }
    XCTFail("Expected real clean quit reservation", file: file, line: line)
    return nil
  }
  func pending(_ h: MutationHarness, readback: Bool = false) -> (attempt: UUID, recovery: UUID)? {
    guard case .pending(let attempt, let recovery, let kind, _)? = h.owner.mutationState.unresolved
    else {
      XCTFail("Actual typed Store failure must retain pending state")
      return nil
    }
    if readback {
      if case .readbackUnconfirmed = kind {} else { XCTFail("Wrong pending kind") }
    } else {
      if case .publicationUncertain = kind {} else { XCTFail("Wrong pending kind") }
    }
    return (attempt, recovery)
  }
  func attempt(_ h: MutationHarness) -> UUID? {
    guard case .failedAttempt(let id, _, _)? = h.owner.mutationState.unresolved else {
      XCTFail("Prepublication failure must retain exact attempt")
      return nil
    }
    return id
  }
  func assertNoReceiptSuccess(_ h: MutationHarness, id: UUID) {
    guard case .succeeded(let actual, let publication)? = h.owner.mutationState.lastOutcome else {
      return XCTFail("Expected nonreceipt success outcome")
    }
    XCTAssertEqual(actual, id)
    XCTAssertNil(publication)
  }
  func assertCanonical(_ h: MutationHarness) async throws {
    let actual = try await h.fresh()
    XCTAssertNotNil(h.owner.state.current)
    guard let current = h.owner.state.current else { return }
    XCTAssertEqual(
      try LanguageCatalogCodec.encode(current.catalog),
      try LanguageCatalogCodec.encode(actual.snapshot))
  }
  func makePending(_ h: MutationHarness, readback: Bool = false) async throws -> (
    attempt: UUID, recovery: UUID
  )? {
    guard await loaded(h) else { return nil }
    h.control.mode(readback ? .unconfirmed : .uncertain)
    guard let id = admitted(h.owner.requestApply(try h.draft(), expectedPublication: h.expectation))
    else { return nil }
    await settled(h, id)
    let typed =
      readback
      ? h.control.error is CustomLanguageReadbackUnconfirmed
      : h.control.error is CustomLanguagePublicationUncertain
    XCTAssertTrue(typed, "Pending authority must come from the actual typed Store failure")
    return pending(h, readback: readback)
  }
}
