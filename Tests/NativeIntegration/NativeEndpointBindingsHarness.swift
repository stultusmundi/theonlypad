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
    let movingStore = try NativeDocumentEndpointBindings()
    let movingDocument = try model()
    let movingModel = movingDocument.0
    let movingBridge = movingModel.fileState!
    do {
      let receipt = try movingStore.reserveTransfer(movingModel, transactionID: UUID())!
      check(
        movingStore.retainedCount == 1,
        "file-backed model reserves exact ownership transfer receipt")
      refuses("ordinary endpoint detach cannot consume transfer") {
        try movingStore.detach(movingModel)
      }
      let firstOwnership = movingModel.ownershipGeneration
      try movingStore.suspendTransfer(receipt, validateLease: {})
      movingModel.advanceOwnershipGeneration()
      let targetOwnership = movingModel.ownershipGeneration
      var deliveries = 0
      try movingStore.attachTransfer(
        receipt, expectedPreviousOwnership: firstOwnership, newOwnership: targetOwnership,
        liveContext: { context(movingModel) }, onChange: { deliveries += 1 }, validateLease: {})
      check(deliveries == 0, "transfer buffers endpoint rendering until exact finish")
      try movingStore.suspendTransfer(receipt, validateLease: {})
      movingModel.advanceOwnershipGeneration()
      try movingStore.attachTransfer(
        receipt, expectedPreviousOwnership: targetOwnership,
        newOwnership: movingModel.ownershipGeneration, liveContext: { context(movingModel) },
        onChange: { deliveries += 1 }, validateLease: {})
      try movingStore.finishTransfer(receipt, validateLease: {})
      check(
        movingStore.retainedCount == 0 && movingModel.fileState === movingBridge,
        "rollback second rotation preserves same bridge and consumes exact receipt")
      check(deliveries == 1, "only settled endpoint renders")
      refuses("finished transfer receipt cannot replay") {
        try movingStore.finishTransfer(receipt, validateLease: {})
      }
      try movingStore.detach(movingModel)
      try movingStore.reattach(movingModel, liveContext: { context(movingModel) }, onChange: {})
      check(true, "ordinary endpoint lifecycle resumes after transfer")
      movingModel.acknowledgeFileBaseline()
      movingBridge.adoptBaseline(bytes: movingModel.originalBytes!)
      let updated = try movingBridge.detachEndpoint()
      check(
        updated.binding.baselineRevision == movingModel.baselineRevision,
        "future baseline adoption uses new live endpoint after transfer")
      try movingBridge.reattachEndpoint(
        updated, expectedBinding: FileStateBindingIdentity(context(movingModel)),
        liveContext: { context(movingModel) }, onChange: {})

    } catch { check(false, "native ownership transfer succeeds: \(error)") }
    let reentrantStore = try NativeDocumentEndpointBindings()
    let reentrantModel = try model().0
    let reentrantReceipt = try reentrantStore.reserveTransfer(
      reentrantModel, transactionID: UUID())!
    try reentrantStore.suspendTransfer(reentrantReceipt, validateLease: {})
    let originalOwnership = reentrantModel.ownershipGeneration
    reentrantModel.advanceOwnershipGeneration()
    var nestedRefused = false
    var nextReceipt: NativeEndpointOwnershipTransferReceipt?
    try reentrantStore.attachTransfer(
      reentrantReceipt, expectedPreviousOwnership: originalOwnership,
      newOwnership: reentrantModel.ownershipGeneration,
      liveContext: {
        do { try reentrantStore.suspendTransfer(reentrantReceipt, validateLease: {}) } catch {
          nestedRefused = true
        }
        return context(reentrantModel)
      },
      onChange: {
        nextReceipt = try? reentrantStore.reserveTransfer(reentrantModel, transactionID: UUID())
      }, validateLease: {})
    check(nestedRefused, "live context callback cannot reenter transfer phase")
    try reentrantStore.finishTransfer(reentrantReceipt, validateLease: {})
    check(
      nextReceipt != nil && reentrantStore.retainedCount == 1,
      "settled render can reserve new transaction without old cleanup erasing it")
    try reentrantStore.invalidateTransfer(nextReceipt!, validateDisposal: {})
    check(
      reentrantStore.retainedCount == 0,
      "explicit terminal disposal consumes only exact new receipt")
    let releasedStore = try NativeDocumentEndpointBindings()
    var releasedTransfer: (EditorDocument, ContextBox)? = try model()
    weak var releasedModel = releasedTransfer!.0
    let heldBridge = releasedTransfer!.0.fileState!
    _ = try releasedStore.reserveTransfer(releasedTransfer!.0, transactionID: UUID())
    releasedTransfer = nil
    check(releasedModel == nil, "transfer store never becomes model owner")
    releasedStore.purgeReleasedModels()
    check(
      releasedStore.retainedCount == 0 && heldBridge.captureAction(.reload) == nil,
      "released model purge explicitly disposes process registration")
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
