import AppKit
import Darwin
import PadCore

private final class OwnerWriteGate: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var waiting = false
  private var completed = false
  let fault: SaveFault?
  init(_ fault: SaveFault? = nil) { self.fault = fault }
  var entered: Bool { lock.withLock { waiting } }
  var finished: Bool { lock.withLock { completed } }
  func run(_ data: Data, _ url: URL, _ expected: Data?) throws {
    lock.withLock { waiting = true }
    guard gate.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
    defer { lock.withLock { completed = true } }
    try AtomicFileStore().save(data, to: url, expected: expected, fault: fault)
  }
  func release() { gate.signal() }
}
@main struct OwnerControllerHarness {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    var checks = 0
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
      checks += 1
      if !condition {
        failures += 1
        print("FAIL \(message)")
      }
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      check(false, "async fixture timed out")
    }
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!)
    func file(_ name: String) throws -> URL {
      let url = root.appendingPathComponent(name)
      try Data("base😀\r\n".utf8).write(to: url)
      return url
    }
    var errors: [Error] = []
    let c = EditorWindowController(restoreStartup: false, onError: { errors.append($0) })
    let url = try file("ordinary.txt")
    var opened = false
    c.open(url, onOpened: { opened = true })
    await wait { opened }
    let doc = c.ownerTestDocument!
    check(doc.baselineRevision == 1, "real open acknowledges baseline")
    let revision = doc.baselineRevision
    c.ownerTestSave()
    check(doc.operationID != nil && doc.saving, "save owns token before worker")
    await wait { !doc.saving }
    check(
      doc.operationID == nil && doc.baselineRevision == revision + 1,
      "equal-byte real save acknowledges before finish")
    var converted = false
    let beforeEncoding = doc.baselineRevision
    c.ownerTestConvert(.utf16LE, onFinish: { converted = true })
    check(doc.operationID != nil, "encoding validation owns token")
    await wait { converted }
    check(
      doc.operationID == nil && doc.baselineRevision == beforeEncoding,
      "current encoding conversion does not acknowledge baseline")
    // Restore current encoding through native undo, preserving a clean reload admission.
    doc.undoManager.undo()
    var reloaded = false
    c.ownerTestReload(onReload: { reloaded = true })
    check(doc.operationID != nil, "reload owns token")
    await wait { reloaded }
    check(
      doc.operationID == nil && doc.baselineRevision == beforeEncoding + 1,
      "reload acknowledges before completion")
    check(errors.isEmpty, "ordinary operations produce no errors")

    for fault: SaveFault? in [nil, .directorySync] {
      let gate = OwnerWriteGate(fault)
      var staleErrors = 0
      let controller = EditorWindowController(
        restoreStartup: false,
        saveServices: EditorSaveServices(
          write: { try gate.run($0, $1, $2) }, backup: { _, _, _ in }),
        onError: { _ in staleErrors += 1 })
      let target = try file(fault == nil ? "stale-success.txt" : "stale-uncertain.txt")
      var ready = false
      controller.open(target, onOpened: { ready = true })
      await wait { ready }
      let document = controller.ownerTestDocument!
      document.editor.insertText(
        "changed", replacementRange: NSRange(location: 0, length: document.storage.length))
      let baseline = document.originalBytes
      let oldRevision = document.baselineRevision
      controller.ownerTestSave()
      await wait { gate.entered }
      let oldOperation = document.operationID
      let newer = document.beginFileOperation()
      gate.release()
      await wait { gate.finished }
      if let oldOperation { await wait { controller.ownerTestFinished(oldOperation) } }
      check(
        oldOperation != nil && oldOperation != newer, "gated save has distinct original operation")
      check(
        document.operationID == newer && document.saving,
        "stale save cannot clear newer operation or saving")
      check(
        document.originalBytes == baseline && document.baselineRevision == oldRevision,
        "stale save cannot adopt a baseline")
      check(
        document.pendingPublication == nil, "stale uncertainty cannot replace newer pending state")
      check(staleErrors == 0, "stale save cannot present obsolete error")
      _ = document.finishFileOperation(newer)
      document.saving = false
    }
    // Remaining production worker paths: no UI panels are constructed or presented.
    let unchangedRevision = doc.baselineRevision
    c.ownerTestLineEndings()
    check(doc.operationID != nil, "line-ending conversion owns token")
    await wait { doc.operationID == nil }
    check(
      !doc.storage.string.contains("\r") && doc.baselineRevision == unchangedRevision,
      "line-ending conversion commits without baseline adoption")
    doc.undoManager.undo()
    c.execute("bookmark.clear")
    check(doc.operationID != nil, "bookmark worker owns token")
    await wait { doc.operationID == nil }
    let originalText = doc.storage.string
    c.replay(
      EditorMacro(
        name: "Synthetic replay", commands: [.replace(location: 0, length: 0, text: "Z")]),
      repeatCount: 1)
    check(doc.operationID != nil, "macro replay owns token")
    await wait { doc.operationID == nil }
    check(
      doc.storage.string == "Z" + originalText && doc.baselineRevision == unchangedRevision,
      "macro replay commits without baseline adoption")
    doc.undoManager.undo()
    check(
      doc.storage.string.utf16.elementsEqual(originalText.utf16), "macro native undo remains exact")
    let commandGate = OwnerWriteGate()
    let commandFile = root.appendingPathComponent("command-gate.txt")
    c.ownerTestCommand { text, selection in
      try commandGate.run(Data([1]), commandFile, nil)
      return LineCommandResult(text: "obsolete", selection: selection)
    }
    await wait { commandGate.entered }
    let commandID = doc.operationID
    check(commandID != nil, "general document worker owns token")
    let newerCommand = doc.beginFileOperation()
    commandGate.release()
    if let commandID { await wait { c.ownerTestFinished(commandID) } }
    check(
      doc.operationID == newerCommand && doc.saving && doc.storage.string == originalText,
      "stale general command cannot mutate text or newer operation")
    _ = doc.finishFileOperation(newerCommand)
    doc.saving = false
    let encodingGate = OwnerWriteGate()
    let encodingFile = root.appendingPathComponent("encoding-gate.txt")
    var conversionFinished = false
    c.ownerTestConvertGated(
      { _ in try encodingGate.run(Data([1]), encodingFile, nil) },
      onFinish: { conversionFinished = true })
    await wait { encodingGate.entered }
    let encodingID = doc.operationID
    let newerEncoding = doc.beginFileOperation()
    let previousEncoding = doc.encoding
    encodingGate.release()
    await wait { conversionFinished }
    check(
      encodingID != nil && doc.operationID == newerEncoding && doc.saving
        && doc.encoding == previousEncoding,
      "stale encoding validation cannot mutate newer operation or encoding")
    _ = doc.finishFileOperation(newerEncoding)
    doc.saving = false
    c.execute("macro.start")
    var recordingReloadFinished = false
    c.ownerTestReload(onReload: { recordingReloadFinished = true })
    check(
      doc.operationID == nil && !recordingReloadFinished
        && doc.baselineRevision == unchangedRevision,
      "recording rejects reload before operation admission")
    c.execute("macro.discard")

    let sessionController = EditorWindowController(
      restoreStartup: false, onError: { errors.append($0) })
    let sessionText = "session😀\r\n"
    let sessionState = try RestoredViewState.resolve(
      selection: NSRange(location: 0, length: 0), bookmarks: [], in: sessionText)
    let sessionURL = try file("session.txt")
    try sessionController.restoreSessionTab(
      SessionTab(originalPath: sessionURL.path),
      decoded: DecodedDocument(text: sessionText, encoding: .utf8, hasBOM: false),
      originalBytes: Data(sessionText.utf8), url: sessionURL, viewState: sessionState)
    let imported = sessionController.ownerTestDocument!
    check(imported.baselineRevision == 1, "session file import acknowledges baseline")
    sessionController.execute("file.close")
    sessionController.execute("file.reopenClosed")
    check(
      sessionController.ownerTestDocument!.id != imported.id
        && sessionController.ownerTestDocument!.baselineRevision == 1,
      "reopened closed file has fresh owner with acknowledged baseline")
    try sessionController.restoreSessionTab(
      SessionTab(),
      decoded: DecodedDocument(text: sessionText, encoding: .utf8, hasBOM: false),
      originalBytes: nil, url: nil, viewState: sessionState)
    check(
      sessionController.ownerTestDocument!.baselineRevision == 0,
      "recovery scratch import does not fabricate file baseline")
    // Cancellation still owns the operation until the worker acknowledges it.
    c.replay(
      EditorMacro(name: "Cancelled", commands: [.replace(location: 0, length: 0, text: "X")]),
      repeatCount: 1)
    let cancelID = doc.operationID
    c.cancelMacroReplay()
    check(
      cancelID != nil && doc.operationID == cancelID,
      "cancel request does not prematurely clear operation")
    await wait { doc.operationID == nil }
    check(doc.storage.string == originalText, "cancelled replay preserves exact original buffer")

    c.replay(
      EditorMacro(
        name: "Stale replay", commands: [.replace(location: 0, length: 0, text: "obsolete")]),
      repeatCount: 1)
    let oldReplayID = doc.operationID
    let newReplayID = doc.beginFileOperation()
    let newCancellation = MacroCancellation()
    c.ownerTestSetReplayCancellation(newCancellation)
    if let oldReplayID { await wait { c.ownerTestFinished(oldReplayID) } }
    check(
      oldReplayID != nil && doc.operationID == newReplayID && doc.saving,
      "stale replay cannot clear newer operation")
    check(
      c.ownerTestReplayCancellation === newCancellation && doc.storage.string == originalText,
      "stale replay cannot clear newer cancellation or mutate buffer")
    _ = doc.finishFileOperation(newReplayID)
    doc.saving = false
    c.ownerTestSetReplayCancellation(nil)
    let uncertainGate = OwnerWriteGate(.directorySync)
    var sawCoherentError = false
    var uncertainOwner: EditorWindowController?
    uncertainOwner = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(
        write: { try uncertainGate.run($0, $1, $2) }, backup: { _, _, _ in }),
      onError: { _ in
        let d = uncertainOwner!.ownerTestDocument!
        sawCoherentError = d.pendingPublication != nil && d.operationID == nil && !d.saving
      })
    let uncertain = uncertainOwner!
    let uncertainURL = try file("uncertain.txt")
    var ready = false
    uncertain.open(uncertainURL, onOpened: { ready = true })
    await wait { ready }
    let u = uncertain.ownerTestDocument!
    let previousRevision = u.baselineRevision
    u.editor.insertText("attempt", replacementRange: NSRange(location: 0, length: u.storage.length))
    uncertain.ownerTestSave()
    await wait { uncertainGate.entered }
    uncertainGate.release()
    await wait { sawCoherentError }
    check(
      sawCoherentError && u.baselineRevision == previousRevision && u.url == uncertainURL,
      "uncertainty installed before operation completion/error without adopting authority")
    uncertainOwner = nil
    print("CONTROLLER CHECKS \(checks) FAILURES \(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
