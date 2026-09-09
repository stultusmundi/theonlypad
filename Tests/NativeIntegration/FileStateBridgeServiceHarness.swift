import Foundation

@testable import PadCore

final class CallbackGate: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  private let semaphore = DispatchSemaphore(value: 0)
  var isEntered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entered
  }
  func wait() {
    lock.lock()
    entered = true
    lock.unlock()
    _ = semaphore.wait(timeout: .now() + 8)
  }
  func release() { semaphore.signal() }
}
@MainActor final class RealFixture {
  var live: FileStateLiveContext
  let client: NativeFileMonitorClient
  var renders = 0
  lazy var bridge = DocumentFileStateController(
    documentID: live.documentID, client: client,
    liveContext: { [weak self] in self?.live }, onChange: { [weak self] in self?.renders += 1 })
  init(url: URL, service: FileMonitorService) {
    live = FileStateLiveContext(
      documentID: UUID(), bindingID: UUID(), baselineRevision: 1, url: url)
    client = NativeFileMonitorClient(service: service)
  }
}
@main struct RealServiceHarness {
  @MainActor static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let parent = directory.appendingPathComponent("parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let file = parent.appendingPathComponent("synthetic.txt")
    let original = Data("original synthetic text\n".utf8)
    try original.write(to: file)
    let service = FileMonitorService()
    defer { service.stop() }
    let f = RealFixture(url: file, service: service)
    defer { f.bridge.invalidate() }
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      guard value else {
        print("FAIL: \(message)")
        exit(1)
      }
      checks += 1
    }
    func wait(_ message: String, _ condition: @escaping @MainActor () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(8)
      while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      check(condition(), message)
    }
    f.bridge.adoptBaseline(bytes: original)
    try await wait("real registered initial comparison") {
      f.bridge.state.observation?.content == .matchesBaseline
    }
    check(f.bridge.state.observation?.metadata != nil, "real observation carries identity")
    let changed = Data("changed synthetic text\n".utf8)
    try changed.write(to: file, options: .atomic)
    f.bridge.checkAgain()
    try await wait("real changed bytes after atomic replacement") {
      f.bridge.state.observation?.content == .differsFromBaseline
    }
    check(f.live.editRevision == 0 && !f.live.dirty, "monitor cannot dirty logical buffer")
    let detachParent = directory.appendingPathComponent("detach-parent")
    try FileManager.default.createDirectory(at: detachParent, withIntermediateDirectories: true)
    let detachFile = detachParent.appendingPathComponent("same.txt")
    try original.write(to: detachFile)
    let reattached = RealFixture(url: detachFile, service: service)
    reattached.live.ownershipGeneration = UUID()
    reattached.bridge.adoptBaseline(bytes: original)
    try await wait("reattach fixture first parent bound") {
      reattached.bridge.state.observation?.content == .matchesBaseline
    }
    let detachment = try reattached.bridge.detachEndpoint()
    let oldRenders = reattached.renders
    reattached.live.closed = true
    reattached.bridge.reconcileEligibility()
    try FileManager.default.moveItem(
      at: detachParent, to: directory.appendingPathComponent("detach-old"))
    try FileManager.default.createDirectory(at: detachParent, withIntermediateDirectories: true)
    try original.write(to: detachFile)
    reattached.live.closed = false
    var newRenders = 0
    try reattached.bridge.reattachEndpoint(
      detachment, expectedBinding: FileStateBindingIdentity(reattached.live),
      liveContext: { reattached.live }, onChange: { newRenders += 1 })
    try await wait("reattachment refuses equal bytes under retargeted parent") {
      reattached.bridge.state.observation?.locationProblem == .parentChanged
    }
    check(
      reattached.bridge.captureAction(.reload) == nil,
      "reattached parent refusal has no reload authority")
    check(
      reattached.renders == oldRenders && newRenders > 0,
      "only replacement endpoint renders new observation")
    check(
      reattached.live.editRevision == 0 && !reattached.live.dirty,
      "reattachment does not alter logical editing state")
    reattached.bridge.invalidate()
    f.bridge.useManualFallback()
    check(f.bridge.manualNotice != nil, "manual fallback remains explicit")
    // Same file bytes under a different parent must remain a parent-retarget refusal.
    let moved = directory.appendingPathComponent("old-parent")
    try FileManager.default.moveItem(at: parent, to: moved)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try original.write(to: file)
    f.bridge.checkAgain()
    try await wait("manual fallback preserves parent continuity") {
      f.bridge.state.observation?.locationProblem == .parentChanged
    }
    check(f.bridge.captureAction(.reload) == nil, "retargeted parent cannot admit reload")
    f.bridge.retryRegistration()
    try await wait("retry monitoring preserves parent continuity") {
      f.bridge.state.observation?.locationProblem == .parentChanged
    }
    check(
      f.bridge.state.observation?.content == .unavailable,
      "equal bytes under new parent not silently matched")
    f.live.bindingID = UUID()
    f.live.baselineRevision += 1
    f.bridge.adoptBaseline(bytes: original)
    try await wait("explicit acknowledged new baseline permits new binding") {
      f.bridge.state.observation?.content == .matchesBaseline
    }
    check(
      f.bridge.state.token?.baselineRevision == f.live.baselineRevision,
      "new baseline token matches owner revision")
    f.bridge.useManualFallback()
    f.bridge.checkAgain()
    f.live.quitting = true
    f.live.deliveryGeneration = UUID()
    f.bridge.reconcileEligibility()
    let before = f.renders
    try await Task.sleep(for: .milliseconds(100))
    check(
      f.bridge.state.token == nil && f.renders == before,
      "real manual completion cannot update quitting document")
    f.live.quitting = false
    f.live.deliveryGeneration = UUID()
    f.bridge.reconcileEligibility()
    try await wait("manual reconciliation resumes after veto") {
      f.bridge.state.observation?.content == .matchesBaseline
    }
    f.bridge.checkAgain()
    f.bridge.invalidate()
    let closedRenders = f.renders
    try await Task.sleep(for: .milliseconds(100))
    check(
      f.bridge.state.token == nil && f.renders == closedRenders, "real close rejects late delivery")
    let callbackParent = directory.appendingPathComponent("callback-parent")
    try FileManager.default.createDirectory(at: callbackParent, withIntermediateDirectories: true)
    let callbackFile = callbackParent.appendingPathComponent("synthetic.txt")
    try original.write(to: callbackFile)
    let gate = CallbackGate()
    var hooks = MonitorHooks()
    hooks.beforeDelivery = { gate.wait() }
    let blockedService = FileMonitorService(hooks: hooks)
    defer {
      gate.release()
      blockedService.stop()
    }
    let blocked = RealFixture(url: callbackFile, service: blockedService)
    defer { blocked.bridge.invalidate() }
    blocked.bridge.adoptBaseline(bytes: original)
    try await wait("real first callback held after binding") { gate.isEntered }
    check(blocked.bridge.state.token == nil, "no first observation reached bridge before handoff")
    blocked.bridge.useManualFallback()
    try FileManager.default.moveItem(
      at: callbackParent, to: directory.appendingPathComponent("old-callback-parent"))
    try FileManager.default.createDirectory(at: callbackParent, withIntermediateDirectories: true)
    try original.write(to: callbackFile)
    blocked.bridge.checkAgain()
    try await wait("atomic real handoff preserves undelivered first parent binding") {
      blocked.bridge.state.observation?.locationProblem == .parentChanged
    }
    gate.release()
    try await Task.sleep(for: .milliseconds(100))
    check(
      blocked.bridge.state.observation?.locationProblem == .parentChanged,
      "released stale registered result cannot overwrite manual refusal")
    let candidateParent = directory.appendingPathComponent("candidate-parent")
    try FileManager.default.createDirectory(at: candidateParent, withIntermediateDirectories: true)
    let candidateFile = candidateParent.appendingPathComponent("synthetic.txt")
    try original.write(to: candidateFile)
    let candidateFixture = RealFixture(url: candidateFile, service: service)
    defer { candidateFixture.bridge.invalidate() }
    candidateFixture.bridge.adoptBaseline(bytes: original)
    try await wait("candidate identity initially established") {
      candidateFixture.bridge.state.observation?.metadata != nil
    }
    let validated = candidateFixture.bridge.state.observation!.metadata!.identity
    try FileManager.default.moveItem(
      at: candidateParent, to: directory.appendingPathComponent("validated-parent"))
    try FileManager.default.createDirectory(at: candidateParent, withIntermediateDirectories: true)
    try original.write(to: candidateFile)
    candidateFixture.live.bindingID = UUID()
    candidateFixture.live.baselineRevision += 1
    candidateFixture.bridge.adoptBaseline(bytes: original, validatedIdentity: validated)
    try await wait("fresh validated registration rejects parent changed after Locate validation") {
      candidateFixture.bridge.state.observation?.locationProblem == .parentChanged
    }
    print(
      "PASS \(checks) production service/bridge assertions; no AppKit/GUI or editor-owner integration"
    )
  }
}
