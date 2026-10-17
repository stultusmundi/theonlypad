// SPDX-License-Identifier: MIT
// Diagnostic-only append. Original Macro8 and all productive Source remain whole.
private enum EventBoundaryOracleError: Error { case incomplete }
@MainActor private enum EventBoundaryOracleCustody {
  static var retained: EventBoundaryOracleFixture?
}
@MainActor private final class EventBoundaryOracleFixture {
  let base: ManagedReplacementFixture
  var pane: EditorPane!
  var observer: NSObjectProtocol?
  var timer: Timer?
  var closureArmed = false
  var closedAfterReturn = 0
  var timerTicks = 0
  var notifications = 0
  var records = 0
  var incomplete = false
  init(_ base: ManagedReplacementFixture) { self.base = base }
  func unavailable() throws -> Never {
    incomplete = true
    XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE")
    throw EventBoundaryOracleError.incomplete
  }
  func installObserver() {
    observer = NotificationCenter.default.addObserver(
      forName: .NSUndoManagerDidCloseUndoGroup, object: base.document.undoManager, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.notifications < 64 else {
          self.incomplete = true
          return
        }
        self.notifications += 1
        if self.closureArmed { self.closedAfterReturn += 1 }
      }
    }
  }
  func assertProtocol(file: StaticString = #filePath, line: UInt = #line) {
    let state = base.controller.nestedStringTestState()
    let context = EditorWindowController.nestedStringTestContext()
    XCTAssertFalse(state.hasPreparation, file: file, line: line)
    XCTAssertFalse(state.hasExplicitFrame, file: file, line: line)
    XCTAssertEqual(context.broker, 0, file: file, line: line)
    XCTAssertEqual(context.context, 0, file: file, line: line)
    XCTAssertFalse(context.overflow, file: file, line: line)
    XCTAssertFalse(base.document.undoManager.isUndoing, file: file, line: line)
    XCTAssertFalse(base.document.undoManager.isRedoing, file: file, line: line)
  }
  // Pure custody facts only; native grouping is checked separately at its actual boundary.
  func protocolIsSettled() -> Bool {
    let state = base.controller.nestedStringTestState()
    let context = EditorWindowController.nestedStringTestContext()
    let manager = base.document.undoManager
    return !state.hasPreparation && !state.hasExplicitFrame
      && context.broker == 0 && context.context == 0 && !context.overflow
      && !manager.isUndoing && !manager.isRedoing
      && pane?.editor.delegate === base.controller
  }
  func requireProtocol() throws {
    guard protocolIsSettled() else { try unavailable() }
  }
  func record(_ stage: Int) throws {
    let context = EditorWindowController.nestedStringTestContext()
    let group = base.document.undoManager.groupingLevel
    guard !incomplete, records < 8, (0...5).contains(stage), (0...64).contains(group),
      (0...24).contains(timerTicks), (0...64).contains(closedAfterReturn),
      (0...64).contains(context.broker), (0...64).contains(context.context)
    else { try unavailable() }
    records += 1
    // Closed numeric protocol only. No text, error descriptions, identity or path output.
    FileHandle.standardError.write(
      Data(
        "NATIVE_EVENT_ORACLE|\(stage)|\(group),\(timerTicks),\(closedAfterReturn),\(context.broker),\(context.context)\n"
          .utf8))
  }
  // Synchronous MainActor helper: real default-mode turns, never an async Task.yield substitute.
  // No SUT group begin/end, groupsByEvent/mode changes or registration suppression.
  func requireAutomaticClosure() throws {
    let manager = base.document.undoManager
    let before = closedAfterReturn
    let previousTicks = timerTicks
    closureArmed = true
    defer {
      closureArmed = false
      timer?.invalidate()
      timer = nil
    }
    for _ in 0..<8 {
      let actualTimer = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          guard self.timerTicks < 24 else {
            self.incomplete = true
            return
          }
          self.timerTicks += 1
        }
      }
      timer = actualTimer
      RunLoop.main.add(actualTimer, forMode: .default)
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))
      actualTimer.invalidate()
      timer = nil
      try requireProtocol()
      if !incomplete, timerTicks > previousTicks, closedAfterReturn > before,
        base.document.undoManager === manager, manager.groupingLevel == 0,
        !manager.isUndoing, !manager.isRedoing
      {
        return
      }
    }
    try unavailable()  // Missing real closure is INCOMPLETE with custody retained.
  }
  func settleHistoryIfOpen() throws {
    try requireProtocol()
    if base.document.undoManager.groupingLevel != 0 { try requireAutomaticClosure() }
    XCTAssertEqual(base.document.undoManager.groupingLevel, 0)
    assertProtocol()
    try requireProtocol()
  }
  func finish() throws {
    // Release exact passive instrumentation before any native cleanup.
    closureArmed = false
    timer?.invalidate()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    base.admission = nil
    guard !incomplete, base.document.undoManager.groupingLevel == 0, protocolIsSettled() else {
      if !incomplete { XCTFail("NATIVE_EVENT_ORACLE_INCOMPLETE") }
      incomplete = true
      throw EventBoundaryOracleError.incomplete
    }
    // This probe never installed a delegate; preserve actual controller/successor identity.
    // A foreign or nil delegate fails the pure guard above rather than being overwritten.
    base.controller.replacementTestCleanup()
  }
}
