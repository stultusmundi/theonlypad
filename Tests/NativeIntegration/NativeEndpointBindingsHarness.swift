import AppKit
import PadCore

@MainActor private final class ContextBox {
  var value: FileStateLiveContext?
  init(_ value: FileStateLiveContext?) { self.value = value }
}
@main struct NativeEndpointBindingsHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = FileMonitorService()
    defer { service.stop() }
    let client = NativeFileMonitorClient(service: service)
    var checks = 0
    func check(_ condition: Bool, _ label: String) {
      checks += 1
      print("\(condition ? "PASS" : "FAIL") \(label)")
      if !condition { exit(1) }
    }
    func refuses(_ label: String, _ body: () throws -> Void) {
      do {
        try body()
        check(false, label)
      } catch { check(true, label) }
    }
    func context(_ model: EditorDocument) -> FileStateLiveContext {
      .init(
        documentID: model.id, ownershipGeneration: model.ownershipGeneration,
        bindingID: model.fileBindingID, baselineRevision: model.baselineRevision, url: model.url)
    }
    func model() throws -> (EditorDocument, ContextBox) {
      let doc = EditorDocument()
      let url = directory.appendingPathComponent(doc.id.uuidString)
      let bytes = Data("synthetic baseline".utf8)
      try bytes.write(to: url)
      doc.url = url
      doc.originalBytes = bytes
      doc.acknowledgeFileBaseline()
      let box = ContextBox(context(doc))
      let bridge = DocumentFileStateController(
        documentID: doc.id, client: client,
        liveContext: { box.value }, onChange: {})
      doc.fileState = bridge
      bridge.adoptBaseline(bytes: bytes)
      return (doc, box)
    }
    let store = try NativeDocumentEndpointBindings()
    var first: (EditorDocument, ContextBox)? = try model()
    let doc = first!.0
    let bridge = doc.fileState!
    weak var oldContext = first!.1
    do { try store.detach(doc) } catch {
      check(false, "valid bridge detachment must succeed: \(error)")
    }
    check(store.retainedCount == 1, "detach retains exact bridge record")
    try store.detach(doc)
    check(store.retainedCount == 1, "same model detach is idempotent")
    first = nil
    check(oldContext == nil, "old endpoint callbacks released")
    var changes = 0
    try store.reattach(doc, liveContext: { context(doc) }, onChange: { changes += 1 })
    check(
      store.retainedCount == 0 && doc.fileState === bridge, "reattach commits exact original bridge"
    )
    check(changes > 0, "new endpoint receives coalesced registration render")
    try store.detach(doc)
    refuses("failed context retains receipt") {
      try store.reattach(doc, liveContext: { nil }, onChange: {})
    }
    check(store.retainedCount == 1, "failure remains process owned")
    try store.reattach(doc, liveContext: { context(doc) }, onChange: {})
    check(store.retainedCount == 0, "pre-consumption failure retries exact receipt")
    try store.detach(doc)
    doc.fileState = nil
    refuses("nil bridge cannot discard retained failure") { try store.detach(doc) }
    check(store.retainedCount == 1, "changed bridge keeps old record")
    doc.fileState = bridge
    try store.reattach(doc, liveContext: { context(doc) }, onChange: {})
    try store.detach(doc)
    doc.acknowledgeFileBaseline()
    refuses("changed baseline refuses reattachment") {
      try store.reattach(doc, liveContext: { context(doc) }, onChange: {})
    }
    check(store.retainedCount == 1, "baseline failure retained")
    let limited = try NativeDocumentEndpointBindings(maximumRecords: 1)
    var released: (EditorDocument, ContextBox)? = try model()
    weak var weakModel = released!.0
    try limited.detach(released!.0)
    let second = try model()
    refuses("capacity refuses before consuming second bridge") { try limited.detach(second.0) }
    let untouched = try second.0.fileState!.detachEndpoint()
    try second.0.fileState!.reattachEndpoint(
      untouched, expectedBinding: untouched.binding,
      liveContext: { second.1.value }, onChange: {})
    released = nil
    limited.purgeReleasedModels()
    check(
      weakModel == nil && limited.retainedCount == 0,
      "weak model cleanup does not retain evicted history")
    let recursive = try NativeDocumentEndpointBindings()
    let third = try model()
    try recursive.detach(third.0)
    var forwarded = false
    try recursive.reattach(
      third.0, liveContext: { third.1.value },
      onChange: {
        guard !forwarded else { return }
        forwarded = true
        do { try recursive.detach(third.0) } catch {
          check(false, "callback can create newer detachment")
        }
      })
    check(forwarded && recursive.retainedCount == 1, "render reentry preserves newer record")
    let baselineStore = try NativeDocumentEndpointBindings()
    let saved = try model()
    try baselineStore.detach(saved.0)
    try baselineStore.reattach(saved.0, liveContext: { context(saved.0) }, onChange: {})
    saved.0.acknowledgeFileBaseline()
    saved.0.fileState!.adoptBaseline(bytes: saved.0.originalBytes!)
    do { try baselineStore.detach(saved.0) } catch {
      check(false, "later baseline adoption remains detachable: \(error)")
    }
    check(
      baselineStore.retainedCount == 1, "new acknowledged baseline retained after another detach")
    let retryStore = try NativeDocumentEndpointBindings()
    let retry = try model()
    let original = retry.1.value
    retry.1.value = nil
    refuses("detach failure is retained") { try retryStore.detach(retry.0) }
    check(retryStore.retainedCount == 1, "failed detach reserves capacity")
    retry.1.value = original
    try retryStore.detach(retry.0)
    var reentryRefused = false
    try retryStore.reattach(
      retry.0,
      liveContext: {
        do { try retryStore.detach(retry.0) } catch NativeEndpointBindingError.busy {
          reentryRefused = true
        } catch { check(false, "unexpected reentry error") }
        return retry.1.value
      }, onChange: {})
    check(
      reentryRefused && retryStore.retainedCount == 0, "context reentry cannot consume transition")
    let blockedStore = try NativeDocumentEndpointBindings()
    let blocked = try model()
    try blockedStore.detach(blocked.0)
    var calls = 0
    refuses("post-consumption invalidation refuses") {
      try blockedStore.reattach(
        blocked.0,
        liveContext: {
          calls += 1
          if calls == 2 { blocked.0.fileState!.invalidate() }
          return blocked.1.value
        }, onChange: {})
    }
    let priorCalls = calls
    refuses("consumed failure requires reconciliation") {
      try blockedStore.reattach(
        blocked.0,
        liveContext: {
          calls += 1
          return blocked.1.value
        }, onChange: {})
    }
    check(
      calls == priorCalls && blockedStore.retainedCount == 1,
      "blocked retry retains evidence without guessing receipt")
    let lifetimeStore = try NativeDocumentEndpointBindings()
    var lifetime: (EditorDocument, ContextBox)? = try model()
    weak var lifetimeModel = lifetime!.0
    weak var lifetimeBridge = lifetime!.0.fileState
    try lifetimeStore.detach(lifetime!.0)
    let detachedContext = lifetime!.1
    try lifetimeStore.reattach(lifetime!.0, liveContext: { detachedContext.value }, onChange: {})
    lifetime = nil
    for _ in 0..<100 where lifetimeModel != nil || lifetimeBridge != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    check(
      lifetimeModel == nil && lifetimeBridge == nil,
      "committed wrappers retain neither model nor bridge cycle")
    print("Native endpoint binding checks: \(checks), failures: 0")
  }
}
