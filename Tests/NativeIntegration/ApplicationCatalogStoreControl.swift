// Synthetic test collaborators only. Every authority is issued by actual Store methods.
import Darwin
import Foundation
import XCTest

@testable import NativeRouting
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
