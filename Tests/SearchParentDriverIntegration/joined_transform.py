"""Counted frozen-only boundaries; candidate production bytes contain none."""

def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError('joined fixture anchor not unique: ' + repr(old))
    return text.replace(old, new)

def driver(text):
    text = replace(text,
        '      owner.task = Task.detached { [self] in await runJoined(ownerID) }',
        '''      owner.task = Task.detached { [self] in
        await SearchParentJoinedTestHooks.ownerStart?()
        await runJoined(ownerID)
      }''')
    text = replace(text, '    let originalChild = await lifecycle.shutdown()',
        '''    let originalChild = await lifecycle.shutdown()
    await SearchParentJoinedTestHooks.originalChild?(originalChild)''')
    text = replace(text, '          joinedWake = continuation',
        '''          joinedWake = continuation
          SearchParentJoinedTestHooks.mechanicalWaitInstalled?()''')
    text = replace(text, '    lane.requestStop()\n    let laneStop: SearchParentJoinedLaneStop',
        '''    lane.requestStop()
    SearchParentJoinedTestHooks.laneJoinBoundary?()
    let laneStop: SearchParentJoinedLaneStop''')
    text = replace(text, '  func shutdown() async -> SearchParentWireShutdown {\n',
        '''  func shutdown() async -> SearchParentWireShutdown {
    SearchParentJoinedTestHooks.legacyEntry?()
''')
    text = replace(text, '    abandoned = true\n    if case .joinedStarted(let owner) = terminalMode {',
        '''    abandoned = true
    SearchParentJoinedTestHooks.abandoned?()
    if case .joinedStarted(let owner) = terminalMode {''')
    text = replace(text,
        '      let work = try beginLane(token: token, reserved: true) { try codec.discard(token: token) }',
        '''      SearchParentJoinedTestHooks.discardWorkAdmitted?(token.operationID)
      let work = try beginLane(token: token, reserved: true) { try codec.discard(token: token) }''')
    return text + '''
// Frozen-only holds/observations/rescue. No member is present in candidate production.
enum SearchParentJoinedTestHooks {
  static var ownerStart: (@Sendable () async -> Void)?
  static var originalChild: (@Sendable (SearchChildShutdown) async -> Void)?
  static var mechanicalWaitInstalled: (@Sendable () -> Void)?
  static var laneJoinBoundary: (@Sendable () -> Void)?
  static var legacyEntry: (@Sendable () -> Void)?
  static var abandoned: (@Sendable () -> Void)?
  static var childShutdown: (@Sendable (ObjectIdentifier) -> Void)?
  static var closeAcknowledged: (@Sendable (UUID) -> Void)?
  static var shutdownGraceInstalled: (@Sendable (UInt64) -> Void)?
  static var laneWait: (@Sendable () -> Void)?
  static var laneObserverInstalled: (@Sendable () -> Void)?
  static var loopStop: (@Sendable () -> Void)?
  static var completionReturning: (@Sendable (UUID) -> Void)?
  static var discardWorkAdmitted: (@Sendable (UUID) -> Void)?
}
struct SearchParentJoinedTestSnapshot: Sendable {
  let mechanicalReady: Bool
  let wakeRegistered: Bool
  let observerPresent: Bool
  let receiptPresent: Bool
  let committed: Bool
  let abandoned: Bool
  let latest: SearchParentWireHandle?
}
extension SearchParentWireDriver {
  func testJoinedSnapshot() async -> SearchParentJoinedTestSnapshot { await state.testJoinedSnapshot() }
  func testJoinedAbandon() async { await state.abandon() }
  func testRescueJoinedWake() async { await state.testRescueJoinedWake() }
  func testRescueOrphanedObserver() async { await state.testRescueOrphanedObserver() }
  func testInstallLaneObserver() async throws { try await state.testInstallLaneObserver() }
}
extension SearchParentDriverState {
  func testJoinedSnapshot() -> SearchParentJoinedTestSnapshot {
    let committed: Bool
    if case .joinedStarted(let owner) = terminalMode { committed = owner.completion != nil }
    else { committed = false }
    return SearchParentJoinedTestSnapshot(
      mechanicalReady: joinedMechanicalReady, wakeRegistered: joinedWake != nil,
      observerPresent: waiter != nil, receiptPresent: receipt != nil,
      committed: committed, abandoned: abandoned, latest: lastAdmittedHandle)
  }
  func testRescueJoinedWake() {
    // Fixture rescue only, after an explicit wake-loss assertion. No predicate bypass.
    guard joinedMechanicalReady else { return }
    let old = joinedWake
    joinedWake = nil
    old?.resume()
  }
  func testRescueOrphanedObserver() {
    // Fixture rescue only, after publication assertions; does not fabricate payload.
    guard operation == nil, receipt == nil, let old = waiter else { return }
    waiter = nil
    old.continuation.resume(throwing: CancellationError())
  }
  func testInstallLaneObserver() async throws { try await lane.waitForStop() }
}
'''

def lifecycle(text):
    text = replace(text, '      owner.enqueue { owner.shutdown(continuation) }',
        '''      SearchParentJoinedTestHooks.childShutdown?(ObjectIdentifier(self))
      owner.enqueue { owner.shutdown(continuation) }''')
    text = replace(text, '    child.closed = true\n    slot = .owned(child)',
        '''    child.closed = true
    slot = .owned(child)
    SearchParentJoinedTestHooks.closeAcknowledged?(generation)''')
    return replace(text,
        '      self.enqueue { self.shutdownGraceFired(deadline) }\n    }\n  }',
        '''      self.enqueue { self.shutdownGraceFired(deadline) }
    }
    SearchParentJoinedTestHooks.shutdownGraceInstalled?(deadline)
  }''')

def lane(text):
    text = replace(text, '  func waitForStop() async throws {\n',
        '''  func waitForStop() async throws {
    SearchParentJoinedTestHooks.laneWait?()
''')
    text = replace(text, '      state.stopWaiter = continuation',
        '''      state.stopWaiter = continuation
      SearchParentJoinedTestHooks.laneObserverInstalled?()''')
    # The loop hold must release the lane condition, so driver control can register
    # its real existing stop waiter. Stopping is monotonic and disallows submissions.
    text = replace(text, '        if job == nil && stopping {\n          exited = true',
        '''        if job == nil && stopping {
          condition.unlock()
          SearchParentJoinedTestHooks.loopStop?()
          condition.lock()
          exited = true''')
    text = replace(text, '        completion?()\n        completion = nil',
        '''        completion?()
        SearchParentJoinedTestHooks.completionReturning?(completedOwner)
        completion = nil''')
    text = replace(text, '        var completion: (() -> Void)? = autoreleasepool {',
        '''        let completedOwner = work!.token.operationID
        var completion: (() -> Void)? = autoreleasepool {''')
    return text
