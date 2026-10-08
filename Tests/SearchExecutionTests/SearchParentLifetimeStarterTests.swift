import Darwin
import XCTest

@testable import SearchExecution

final class SearchParentLifetimeStarterTests: XCTestCase {
  func testNegativeDescriptorRejectsBeforeAnyAttributeOrContextWork() {
    for fd in [Int32(-1), Int32.min] {
      let script = LifetimeThreadScript(controlFD: fd)
      assertError(.invalidDescriptor, code: EINVAL) { try script.start() }
      XCTAssertEqual(script.calls, [])
      XCTAssertNil(script.context)
      XCTAssertEqual(script.runFDs, [])
    }
  }

  func testInitializationFailureDoesNotDestroyUninitializedAttributes() {
    let script = LifetimeThreadScript()
    script.initializeCode = EAGAIN
    assertError(.attributeInitialization, code: EAGAIN) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize"])
    XCTAssertNil(script.context)
    XCTAssertEqual(script.runFDs, [])
  }

  func testInitializationErrorCannotBeReplacedByUnattemptedCleanup() {
    let script = LifetimeThreadScript()
    script.initializeCode = EIO
    script.destroyCode = EINVAL
    assertError(.attributeInitialization, code: EIO) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize"])
    XCTAssertEqual(script.contextAliveAtDestroy, [])
    XCTAssertNil(script.context)
  }

  func testDetachedStateFailureDestroysOnceWithoutCreatingContext() {
    let script = LifetimeThreadScript()
    script.detachCode = EINVAL
    assertError(.detachedState, code: EINVAL) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize", "detach", "destroy"])
    XCTAssertEqual(script.contextAliveAtDestroy, [false])
    XCTAssertNil(script.context)
    XCTAssertEqual(script.runFDs, [])
  }

  func testDetachedStateFailurePreservesPrimaryAndSecondaryCleanupCodes() {
    let script = LifetimeThreadScript()
    script.detachCode = EIO
    script.destroyCode = EBUSY
    assertError(.detachedState, code: EIO, cleanup: EBUSY) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize", "detach", "destroy"])
    XCTAssertNil(script.context)
    XCTAssertEqual(script.runFDs, [])
  }

  func testCreationFailureReclaimsActualContextWithoutCallbackOrRetry() {
    let script = LifetimeThreadScript()
    script.createCode = EAGAIN
    assertError(.creation, code: EAGAIN) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize", "detach", "create", "create-return", "destroy"])
    XCTAssertEqual(script.contextObservedDuringCreate, [true])
    XCTAssertEqual(script.contextAliveAtDestroy, [false])
    XCTAssertNil(script.context)
    XCTAssertEqual(script.runFDs, [])
    XCTAssertFalse(script.hasDeferredCallback)
  }

  func testCreationFailureKeepsPrimaryWhenAttributeCleanupAlsoFails() {
    let script = LifetimeThreadScript()
    script.createCode = EIO
    script.destroyCode = EINVAL
    assertError(.creation, code: EIO, cleanup: EINVAL) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize", "detach", "create", "create-return", "destroy"])
    XCTAssertEqual(script.contextObservedDuringCreate, [true])
    XCTAssertEqual(script.contextAliveAtDestroy, [false])
    XCTAssertNil(script.context)
    XCTAssertEqual(script.runFDs, [])
    XCTAssertFalse(script.hasDeferredCallback)
  }

  func testCallbackBeforeCreateReturnsConsumesContextBeforeBodyExactlyOnce() throws {
    let script = LifetimeThreadScript()
    script.callbackBeforeReturn = true
    try script.start()
    XCTAssertEqual(
      script.calls,
      [
        "initialize", "detach", "create", "callback", "run", "callback-return", "create-return",
        "destroy",
      ])
    XCTAssertEqual(script.contextObservedDuringCreate, [true])
    XCTAssertEqual(script.contextAliveAtDestroy, [false])
    XCTAssertEqual(script.runFDs, [73])
    XCTAssertNil(script.context)
    XCTAssertFalse(script.hasDeferredCallback)
  }

  func testCallbackAfterStarterReturnsRetainsContextUntilActualTrampolineConsumesIt() throws {
    let script = LifetimeThreadScript()
    try script.start()
    XCTAssertEqual(script.calls, ["initialize", "detach", "create", "create-return", "destroy"])
    XCTAssertEqual(script.contextObservedDuringCreate, [true])
    XCTAssertEqual(script.contextAliveAtDestroy, [true])
    XCTAssertNotNil(script.context)
    XCTAssertEqual(script.runFDs, [])
    script.invokeDeferredCallback()
    XCTAssertEqual(
      script.calls,
      [
        "initialize", "detach", "create", "create-return", "destroy", "callback", "run",
        "callback-return",
      ])
    XCTAssertEqual(script.runFDs, [73])
    XCTAssertNil(script.context)
    XCTAssertFalse(script.hasDeferredCallback)
  }

  func testDestroyFailureAfterSynchronousCallbackReportsCreatedWithoutReclaimingAgain() {
    let script = LifetimeThreadScript()
    script.callbackBeforeReturn = true
    script.destroyCode = EIO
    assertError(.attributeDestruction, code: EIO, threadCreated: true) { try script.start() }
    XCTAssertEqual(
      script.calls,
      [
        "initialize", "detach", "create", "callback", "run", "callback-return", "create-return",
        "destroy",
      ])
    XCTAssertEqual(script.runFDs, [73])
    XCTAssertEqual(script.contextAliveAtDestroy, [false])
    XCTAssertNil(script.context)
    XCTAssertFalse(script.hasDeferredCallback)
  }

  func testDestroyFailureBeforeDeferredCallbackDoesNotReclaimTransferredContext() {
    let script = LifetimeThreadScript()
    script.destroyCode = EINVAL
    assertError(.attributeDestruction, code: EINVAL, threadCreated: true) { try script.start() }
    XCTAssertEqual(script.calls, ["initialize", "detach", "create", "create-return", "destroy"])
    XCTAssertEqual(script.contextAliveAtDestroy, [true])
    XCTAssertNotNil(script.context)
    XCTAssertEqual(script.runFDs, [])
    script.invokeDeferredCallback()
    XCTAssertEqual(script.runFDs, [73])
    XCTAssertNil(script.context)
    XCTAssertFalse(script.hasDeferredCallback)
    XCTAssertEqual(
      script.calls,
      [
        "initialize", "detach", "create", "create-return", "destroy", "callback", "run",
        "callback-return",
      ])
  }

  func testDescriptorZeroIsBorrowedUnchangedRatherThanRejectedAsNegative() throws {
    let script = LifetimeThreadScript(controlFD: 0)
    script.callbackBeforeReturn = true
    try script.start()
    XCTAssertEqual(script.runFDs, [0])
    XCTAssertEqual(script.contextObservedDuringCreate, [true])
    XCTAssertNil(script.context)
    XCTAssertEqual(
      script.calls,
      [
        "initialize", "detach", "create", "callback", "run", "callback-return", "create-return",
        "destroy",
      ])
  }

  private func assertError(
    _ stage: SearchParentLifetimeStartError.Stage, code: Int32, cleanup: Int32? = nil,
    threadCreated: Bool = false, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      guard let actual = error as? SearchParentLifetimeStartError else {
        XCTFail("Unexpected startup error: \(error)", file: file, line: line)
        return
      }
      XCTAssertEqual(actual.stage, stage, file: file, line: line)
      XCTAssertEqual(actual.code, code, file: file, line: line)
      XCTAssertEqual(actual.attributeCleanupCode, cleanup, file: file, line: line)
      XCTAssertEqual(actual.threadCreated, threadCreated, file: file, line: line)
    }
  }
}

/// Syscall results are injected; the actual retained production context and C entry are used.
private final class LifetimeThreadScript {
  let controlFD: Int32
  var initializeCode: Int32 = 0
  var detachCode: Int32 = 0
  var createCode: Int32 = 0
  var destroyCode: Int32 = 0
  var callbackBeforeReturn = false
  var calls: [String] = []
  var runFDs: [Int32] = []
  var contextObservedDuringCreate: [Bool] = []
  var contextAliveAtDestroy: [Bool] = []
  weak var context: SearchParentLifetimeThreadContext?
  private var deferredEntry: SearchParentLifetimeThreadEntry?
  private var deferredArgument: UnsafeMutableRawPointer?

  init(controlFD: Int32 = 73) {
    self.controlFD = controlFD
  }

  var hasDeferredCallback: Bool {
    deferredEntry != nil && deferredArgument != nil
  }

  func start() throws {
    try SearchParentLifetime.start(controlFD: controlFD, operations: operations) { fd in
      self.calls.append("run")
      XCTAssertNil(self.context, "actual context ownership ends before the watcher body")
      self.runFDs.append(fd)
    }
  }

  var operations: SearchParentLifetimeThreadOperations {
    SearchParentLifetimeThreadOperations(
      initializeAttributes: { _ in
        self.calls.append("initialize")
        return self.initializeCode
      },
      setDetached: { _ in
        self.calls.append("detach")
        return self.detachCode
      },
      create: { _, _, entry, argument in
        self.calls.append("create")
        self.observeContext(argument)
        // A failed create never invokes or stores a callback: that is the pthread contract.
        if self.createCode == 0 {
          if self.callbackBeforeReturn {
            self.invoke(entry, argument)
          } else {
            self.deferredEntry = entry
            self.deferredArgument = argument
          }
        }
        self.calls.append("create-return")
        return self.createCode
      },
      destroyAttributes: { _ in
        self.calls.append("destroy")
        self.contextAliveAtDestroy.append(self.context != nil)
        return self.destroyCode
      })
  }

  private func observeContext(_ argument: UnsafeMutableRawPointer) {
    context = Unmanaged<SearchParentLifetimeThreadContext>.fromOpaque(argument)
      .takeUnretainedValue()
    contextObservedDuringCreate.append(context != nil)
    XCTAssertNotNil(context, "create receives the actual live retained context")
    XCTAssertEqual(context?.controlFD, controlFD, "context contains the exact borrowed descriptor")
    // End this helper's temporary weak-load ownership before invoking the real trampoline.
  }

  func invokeDeferredCallback() {
    guard let entry = deferredEntry, let argument = deferredArgument else {
      XCTFail("Missing transferred callback")
      return
    }
    deferredEntry = nil
    deferredArgument = nil
    invoke(entry, argument)
  }

  private func invoke(
    _ entry: SearchParentLifetimeThreadEntry, _ argument: UnsafeMutableRawPointer
  ) {
    calls.append("callback")
    XCTAssertNil(entry(argument), "returning test watcher leaves no thread result")
    calls.append("callback-return")
  }
}
