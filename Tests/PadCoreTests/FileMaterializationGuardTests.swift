import Darwin
import Foundation
import XCTest

@testable import PadCore

final class FileMaterializationGuardTests: XCTestCase {
  private func ownedThread(_ body: @escaping () throws -> Void) {
    let done = expectation(description: "owned thread completed")
    Thread {
      defer { done.fulfill() }
      let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
      XCTAssertGreaterThanOrEqual(previous, 0)
      guard previous >= 0 else { return }
      defer {
        XCTAssertEqual(
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous), 0
        )
      }
      XCTAssertEqual(
        setiopolicy_np(
          IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
          IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT), 0)
      do { try body() } catch { XCTFail("Unexpected policy error: \(error)") }
    }.start()
    wait(for: [done], timeout: 10)
  }
  private static func policy() -> Int32 {
    getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
  }
  func testActualOwnedThreadDisablesBeforeBodyAndRestores() {
    ownedThread {
      let value = try FileMaterializationGuard.perform {
        XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        return 42
      }
      XCTAssertEqual(value, 42)
      XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
    }
  }
  func testThrownBodyRestoresActualThreadPolicy() {
    enum Failure: Error { case expected }
    ownedThread {
      XCTAssertThrowsError(
        try FileMaterializationGuard.perform {
          XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
          throw Failure.expected
        }
      ) { error in
        guard case Failure.expected = error else { return XCTFail("Original error changed") }
      }
      XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
    }
  }
  func testNestedGuardRetainsOuterDisabledPolicy() {
    ownedThread {
      try FileMaterializationGuard.perform {
        try FileMaterializationGuard.perform {
          XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        }
        XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
      }
      XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
    }
  }
  func testQueryFailurePreventsWork() {
    var worked = false
    var hooks = MaterializationPolicyHooks()
    hooks.get = {
      errno = EIO
      return -1
    }
    hooks.set = { _ in
      XCTFail("No set after failed query")
      return 0
    }
    XCTAssertThrowsError(try FileMaterializationGuard.perform(hooks: hooks) { worked = true }) {
      error in
      guard case FileMaterializationError.query(EIO) = error else { return XCTFail("Wrong error") }
    }
    XCTAssertFalse(worked)
  }
  func testDisableFailurePreventsWork() {
    var worked = false
    var hooks = MaterializationPolicyHooks()
    hooks.get = { IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT }
    hooks.set = { _ in
      errno = EACCES
      return -1
    }
    XCTAssertThrowsError(try FileMaterializationGuard.perform(hooks: hooks) { worked = true }) {
      error in
      guard case FileMaterializationError.disable(EACCES) = error else {
        return XCTFail("Wrong error")
      }
    }
    XCTAssertFalse(worked)
  }
  func testRestoreFailureDiscardsResourceBeforeThrowing() {
    var discarded: [Int] = []
    var hooks = MaterializationPolicyHooks()
    hooks.get = { IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT }
    hooks.set = { value in
      if value == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { return 0 }
      errno = EIO
      return -1
    }
    XCTAssertThrowsError(
      try FileMaterializationGuard.perform(
        hooks: hooks,
        discardOnRestoreFailure: { discarded.append($0) }
      ) { 73 }
    ) { error in
      guard case FileMaterializationError.restore(EIO) = error else {
        return XCTFail("Wrong error")
      }
    }
    XCTAssertEqual(discarded, [73])
  }
  func testRestoreFailureAfterThrownBodyIsReported() {
    enum Failure: Error { case expected }
    var hooks = MaterializationPolicyHooks()
    hooks.get = { IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT }
    hooks.set = { value in
      if value == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { return 0 }
      errno = EIO
      return -1
    }
    XCTAssertThrowsError(
      try FileMaterializationGuard.perform(hooks: hooks) { throw Failure.expected }
    ) { error in
      guard case FileMaterializationError.restore(EIO) = error else {
        return XCTFail("Wrong error")
      }
    }
  }
  func testExactSyntheticFileReadWithMaterializationDisabled() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bytes = Data("synthetic € 😀\r\n".utf8)
    try bytes.write(to: file, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: file) }
    ownedThread {
      let read = try FileMaterializationGuard.perform {
        XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        return try Data(contentsOf: file)
      }
      XCTAssertEqual(read, bytes)
    }
  }
  func testProcessPolicyIsNeverChanged() {
    let processPolicy = getiopolicy_np(
      IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
    XCTAssertGreaterThanOrEqual(processPolicy, 0)
    ownedThread {
      try FileMaterializationGuard.perform {
        XCTAssertEqual(Self.policy(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(
          getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS),
          processPolicy)
      }
    }
    XCTAssertEqual(
      getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS), processPolicy)
  }

}
