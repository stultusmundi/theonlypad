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
    print(
      "PASS \(checks) production service/bridge assertions; no AppKit/GUI or editor-owner integration"
    )
  }
}
