// SPDX-License-Identifier: MIT
// Private test-only fixtures. No production receipt constructors or owner access extensions.
import Foundation
import XCTest

@testable import NativeLanguageCatalogComponent
@testable import PadCore

enum CatalogFixtureFailure: Error, Equatable {
  case selectedFailure, unexpectedRead, readOnMainThread, gateTimedOut
}

struct CatalogCapsule: Sendable {
  let root: URL
  let store: CustomLanguageStore
  var file: URL { store.directory.appendingPathComponent("Profiles.json") }

  static func create(populated: Bool = false, corrupt: Bool = false) throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NativeLanguageCatalogSynthetic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let capsule = Self(
      root: root, store: CustomLanguageStore(directory: root.appendingPathComponent("Catalog")))
    do {
      if populated {
        let definition = try LiteralLanguageDefinition(
          id: UUID(uuidString: "00000000-0000-4000-8000-000000000015")!,
          name: "Synthetic café", fileExtensions: ["synthetic"],
          keywords: ["let", "café", "cafe\u{301}"], lineComment: "#", blockComment: nil,
          quotes: [], highlightDecimalNumbers: true, indentation: .spaces(width: 2))
        let override = try BuiltInLanguageOverride(
          language: .swift, lineComment: .inherit, blockComment: .disabled,
          indentation: .tabs(width: 3))
        let absent = try capsule.store.load()
        let draft = try LanguageCatalogSnapshot(
          definitions: [definition], overrides: [override], generation: 0)
        _ = try capsule.store.save(draft, expected: absent)
      }
      if corrupt {
        try FileManager.default.createDirectory(
          at: capsule.store.directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        try Data("{\"version\":1,\"generation\":".utf8).write(to: capsule.file)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: capsule.file.path)
      }
      return capsule
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }
}

/// One selected synchronous dependency invocation; waiting is permitted only off main.
final class CatalogReadStep: @unchecked Sendable {
  enum Outcome { case actualStore, failure }
  let entered: XCTestExpectation
  let finished: XCTestExpectation
  private let held: Bool
  private let outcome: Outcome
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var released = false
  private var didEnter = false
  private var didFinish = false
  private var wasOnMain: Bool?

  init(_ label: String, held: Bool = false, outcome: Outcome = .actualStore) {
    entered = XCTestExpectation(description: "\(label) actual read entered")
    finished = XCTestExpectation(description: "\(label) actual read finished")
    self.held = held
    self.outcome = outcome
  }
  var facts: (entered: Bool, finished: Bool, onMain: Bool?) {
    lock.lock()
    defer { lock.unlock() }
    return (didEnter, didFinish, wasOnMain)
  }
  func release() {
    lock.lock()
    let shouldSignal = !released
    released = true
    lock.unlock()
    if shouldSignal { gate.signal() }
  }
  func perform(_ store: CustomLanguageStore) throws -> LoadedLanguageCatalog {
    let onMain = Thread.isMainThread
    lock.lock()
    didEnter = true
    wasOnMain = onMain
    lock.unlock()
    entered.fulfill()
    defer {
      lock.lock()
      didFinish = true
      lock.unlock()
      finished.fulfill()
    }
    // A regression that invokes the dependency on main fails without hanging that actor.
    guard !onMain else { throw CatalogFixtureFailure.readOnMainThread }
    if held {
      guard gate.wait(timeout: .now() + 20) == .success else {
        throw CatalogFixtureFailure.gateTimedOut
      }
    }
    switch outcome {
    case .actualStore: return try store.load()
    case .failure: throw CatalogFixtureFailure.selectedFailure
    }
  }
}

/// Script only controls the owner's read dependency; actual worker/lifecycle stays in owner.
final class CatalogReadScript: @unchecked Sendable {
  let store: CustomLanguageStore
  let steps: [CatalogReadStep]
  private let lock = NSLock()
  private var count = 0
  private var active = 0
  private var maximum = 0
  init(store: CustomLanguageStore, steps: [CatalogReadStep]) {
    self.store = store
    self.steps = steps
  }
  var facts: (count: Int, active: Int, maximum: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (count, active, maximum)
  }
  func releaseAll() { for step in steps { step.release() } }
  func read() throws -> LoadedLanguageCatalog {
    lock.lock()
    let index = count
    count += 1
    active += 1
    maximum = max(maximum, active)
    lock.unlock()
    defer {
      lock.lock()
      active -= 1
      lock.unlock()
    }
    guard steps.indices.contains(index) else { throw CatalogFixtureFailure.unexpectedRead }
    return try steps[index].perform(store)
  }
}

@MainActor final class CatalogStateProbe {
  let terminals: [XCTestExpectation]
  var states: [NativeLanguageCatalogState] = []
  var deliveryOnMain: [Bool] = []
  var terminalCount = 0
  var terminalAction: ((NativeLanguageCatalogState) -> Void)?
  init(terminals count: Int = 1) {
    terminals = (0..<count).map { XCTestExpectation(description: "catalog terminal \($0 + 1)") }
  }
  func receive(_ state: NativeLanguageCatalogState) {
    states.append(state)
    deliveryOnMain.append(Thread.isMainThread)
    if state.activeRequestID == nil, state.lastSettledRequestID != nil {
      let index = terminalCount
      terminalCount += 1
      if terminals.indices.contains(index) { terminals[index].fulfill() }
      terminalAction?(state)
    }
  }
}

final class CatalogObserverSentinel {}

@MainActor extension NativeLanguageCatalogOwnerTests {
  func withCapsule(
    populated: Bool = false, corrupt: Bool = false,
    _ body: @MainActor (CatalogCapsule) async throws -> Void
  ) async throws {
    let capsule = try await Task.detached(priority: .utility) {
      try CatalogCapsule.create(populated: populated, corrupt: corrupt)
    }.value
    do {
      try await body(capsule)
    } catch {
      try? await Task.detached(priority: .utility) {
        try FileManager.default.removeItem(at: capsule.root)
      }.value
      throw error
    }
    try await Task.detached(priority: .utility) {
      try FileManager.default.removeItem(at: capsule.root)
    }.value
  }

  /// Every early return/throw releases all held reads, drops test observer cycles, and joins.
  func withOwner(
    _ owner: NativeLanguageCatalogOwner, script: CatalogReadScript? = nil,
    _ body: @MainActor (NativeLanguageCatalogOwner) async throws -> Void
  ) async throws {
    do {
      try await body(owner)
    } catch {
      script?.releaseAll()
      owner.onChange = nil
      await owner.invalidateAndWait()
      throw error
    }
    script?.releaseAll()
    owner.onChange = nil
    await owner.invalidateAndWait()
  }

  func startedID(
    _ result: NativeLanguageCatalogAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) -> UUID? {
    let id: UUID?
    if case .started(let value) = result { id = value } else { id = nil }
    // Ordinary reached assertion, before any dependent event wait or optional unwrap.
    XCTAssertNotNil(id, "An active idle owner must actually start a read", file: file, line: line)
    return id
  }
  func assertBusy(
    _ result: NativeLanguageCatalogAdmission, matching id: UUID,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if case .busy(let active) = result {
      XCTAssertEqual(active, id, file: file, line: line)
    } else {
      XCTFail("Overlapping request must return the current busy identity", file: file, line: line)
    }
  }
  func assertRefused(
    _ result: NativeLanguageCatalogAdmission,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if case .invalidated = result {
    } else {
      XCTFail("Invalidated owner must refuse admission", file: file, line: line)
    }
  }
  func assertInvalidated(
    _ state: NativeLanguageCatalogState,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    if case .invalidated = state.lifetime {
    } else {
      XCTFail("Owner must expose terminal invalidation", file: file, line: line)
    }
    XCTAssertNil(state.activeRequestID, file: file, line: line)
    XCTAssertNil(state.lastSettledRequestID, file: file, line: line)
    XCTAssertNil(state.current, file: file, line: line)
    XCTAssertNil(state.failure, file: file, line: line)
  }
  func assertSameCurrent(
    _ actual: NativeLanguageCatalogPublication?, _ expected: NativeLanguageCatalogPublication,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertEqual(actual?.id, expected.id, file: file, line: line)
    XCTAssertEqual(actual?.requestID, expected.requestID, file: file, line: line)
    XCTAssertNotNil(actual, file: file, line: line)
    guard let actual else { return }
    XCTAssertEqual(
      try LanguageCatalogCodec.encode(actual.catalog),
      try LanguageCatalogCodec.encode(expected.catalog),
      file: file, line: line)
  }
  func assertPopulated(
    _ catalog: LanguageCatalogSnapshot,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(catalog.generation, 1, file: file, line: line)
    XCTAssertEqual(catalog.definitions.count, 1, file: file, line: line)
    XCTAssertEqual(catalog.overrides.count, 1, file: file, line: line)
    XCTAssertEqual(
      catalog.definitions.first?.id.uuidString, "00000000-0000-4000-8000-000000000015", file: file,
      line: line)
    XCTAssertEqual(
      catalog.definitions.first?.name.utf16.map { $0 }, Array("Synthetic café".utf16), file: file,
      line: line)
    XCTAssertEqual(
      catalog.definitions.first?.keywords.map { Array($0.utf16) },
      [[108, 101, 116], [99, 97, 102, 233], [99, 97, 102, 101, 769]], file: file, line: line)
    XCTAssertEqual(
      catalog.definitions.first?.indentation, .spaces(width: 2), file: file, line: line)
    XCTAssertEqual(catalog.overrides.first?.language, .swift, file: file, line: line)
    XCTAssertEqual(catalog.overrides.first?.indentation, .tabs(width: 3), file: file, line: line)
    XCTAssertEqual(catalog.overrides.first?.blockComment, .disabled, file: file, line: line)
    if let id = catalog.definitions.first?.id {
      let resolved = catalog.resolve(
        selection: .manual(.custom(id)), filename: "", builtinDetected: .plainText)
      XCTAssertEqual(resolved.definitionRevision, 1, file: file, line: line)
    }
  }
}
