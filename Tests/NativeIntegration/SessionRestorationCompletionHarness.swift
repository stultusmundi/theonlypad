import AppKit
import PadCore

@MainActor private final class ResolutionGate {
  var entered = false
  var completion: CheckedContinuation<Void, Error>?
  func wait() async throws {
    entered = true
    try await withCheckedThrowingContinuation { completion = $0 }
  }
  func finish(_ error: Error? = nil) {
    let value = completion
    completion = nil
    if let error { value?.resume(throwing: error) } else { value?.resume() }
  }
}
@main struct SessionRestorationCompletionHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var failures = 0
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value { failures += 1 }
      print("\(value ? "PASS" : "FAIL") \(message)")
    }
    func settle(_ condition: () -> Bool) async {
      for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
      }
      check(condition(), "bounded async completion")
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let entry = UnresolvedSessionEntry(
      windowID: UUID(), metadata: .init(originalPath: "/synthetic/input.txt"),
      errorMessage: "Missing")
    let file = SessionResolvedFile(
      url: URL(fileURLWithPath: "/synthetic/input.txt"), originalBytes: Data("text".utf8),
      decoded: .init(text: "text"))
    func panel(
      _ resolve:
        @escaping @MainActor (UnresolvedSessionEntry, SessionResolvedFile) async throws -> Void
    ) -> SessionRestorationController {
      SessionRestorationController(
        entries: [entry], onRetry: { _ in file }, onLocate: { _, _ in file }, onResolved: resolve,
        onRemove: { _ in })
    }
    func retry(_ panel: SessionRestorationController) {
      let controls = descendants(panel.window!.contentView!)
      let table = controls.compactMap { $0 as? NSTableView }.first!
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      (controls.first { $0.identifier?.rawValue == "session.retry" } as! NSButton).performClick(nil)
    }
    let gate = ResolutionGate()
    let first = panel { _, _ in try await gate.wait() }
    retry(first)
    await settle { gate.entered }
    check(
      first.entries.count == 1 && first.isBusy, "held acceptance preserves record and busy state")
    first.refreshPresentation(entries: [entry])
    check(
      first.isBusy && first.entries.count == 1, "same semantic refresh preserves pending acceptance"
    )
    gate.finish()
    await settle { !first.isBusy }
    check(first.entries.isEmpty, "successful acceptance removes record only after completion")
    first.close()
    let failureGate = ResolutionGate()
    let failed = panel { _, _ in try await failureGate.wait() }
    retry(failed)
    await settle { failureGate.entered }
    failureGate.finish(
      NSError(
        domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Acceptance failed"]))
    await settle { !failed.isBusy }
    check(
      failed.entries.count == 1 && failed.entries.first?.errorMessage == "Acceptance failed",
      "acceptance failure preserves record with error")
    failed.close()
    let ownedGate = ResolutionGate()
    var accepted = false
    var finished = false
    let owned = Task { @MainActor in
      try await ownedGate.wait()
      finished = true
    }
    let closing = panel { _, _ in
      accepted = true
      try await owned.value
    }
    retry(closing)
    await settle { accepted && ownedGate.entered }
    closing.close()
    ownedGate.finish()
    try await owned.value
    for _ in 0..<20 { await Task.yield() }
    check(finished, "panel closure does not cancel separately owned accepted operation")
    check(closing.entries.count == 1, "closed panel suppresses late successful removal")
    let updateGate = ResolutionGate()
    let updating = panel { _, _ in try await updateGate.wait() }
    retry(updating)
    await settle { updateGate.entered }
    var refreshed = entry
    refreshed.errorMessage = "New owner state"
    updating.update(entries: [refreshed])
    check(!updating.isBusy, "explicit update releases UI busy state")
    updateGate.finish()
    for _ in 0..<20 { await Task.yield() }
    check(
      updating.entries.first?.errorMessage == "New owner state",
      "explicit generation update suppresses old acceptance outcome")
    updating.close()
    let readGate = ResolutionGate()
    var unwantedAcceptance = false
    let reading = SessionRestorationController(
      entries: [entry],
      onRetry: { _ in
        try await readGate.wait()
        return file
      }, onLocate: { _, _ in file }, onResolved: { _, _ in unwantedAcceptance = true },
      onRemove: { _ in })
    retry(reading)
    await settle { readGate.entered }
    reading.close()
    readGate.finish()
    for _ in 0..<20 { await Task.yield() }
    check(!unwantedAcceptance, "panel closed before handoff cannot begin acceptance")
    check(
      !first.window!.isVisible && !failed.window!.isVisible && !closing.window!.isVisible,
      "panels never shown")
    print("Session completion checks: \(checks), failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
