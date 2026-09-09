import AppKit
import PadCore

private final class SaveControl: @unchecked Sendable {
  private let lock = NSLock()
  private var nextFault: SaveFault?
  private var refuseBackup = false
  private var writes = 0
  func setFault(_ value: SaveFault?) { lock.withLock { nextFault = value } }
  func setBackupFailure(_ value: Bool) { lock.withLock { refuseBackup = value } }
  var writeCount: Int { lock.withLock { writes } }
  func write(_ bytes: Data, _ url: URL, _ expected: Data?) throws {
    let fault = lock.withLock {
      writes += 1
      return nextFault
    }
    try AtomicFileStore().save(bytes, to: url, expected: expected, fault: fault)
  }
  func backup(_ bytes: Data, _ url: URL, _ encoding: DocumentEncoding) throws {
    if lock.withLock({ refuseBackup }) { throw FileStoreError.injectedFailure }
    _ = try BackupStore(directory: BackupStore.defaultDirectory).capture(
      data: bytes, originalURL: url, encoding: encoding)
  }
}

private final class WriteGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var entered = false
  var hasEntered: Bool { lock.withLock { entered } }
  func write() throws {
    lock.withLock { entered = true }
    semaphore.wait()
    throw FileStoreError.injectedFailure
  }
  func release() { semaphore.signal() }
}

@main struct SaveFailureHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let directory = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment[
        "THEONLYPAD_STATE_DIRECTORY"]!
    ).appendingPathComponent("documents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func editor(_ controller: EditorWindowController) -> NSTextView {
      descendants(controller.window!.contentView!).compactMap { $0 as? NSTextView }.first!
    }
    func wait(_ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(5)
      while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
      precondition(condition(), "asynchronous native operation did not finish")
    }
    let control = SaveControl()
    var errors: [Error] = []
    var chosenDestination: URL?
    let controller = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(
        write: { try control.write($0, $1, $2) },
        backup: { try control.backup($0, $1, $2) }),
      chooseSaveDestination: { _, _ in chosenDestination },
      onError: { errors.append($0) })
    let original = Data("synthetic original\n".utf8)
    let file = directory.appendingPathComponent("original.txt")
    try original.write(to: file)
    var opened = false
    controller.open(file, onFailure: { errors.append($0) }, onOpened: { opened = true })
    await wait { opened }
    var view = editor(controller)
    func replace(_ text: String) {
      view.insertText(text, replacementRange: NSRange(location: 0, length: view.string.utf16.count))
    }
    func save(_ command: String = "file.save") async {
      controller.execute(command)
      await wait { view.isEditable }
    }
    let changed = "synthetic changed 👩🏽‍💻\n"
    replace(changed)
    control.setFault(.beforeReplace)
    await save()
    precondition(errors.count == 1 && controller.currentDocumentIsDirty)
    precondition(!controller.currentSaveIsUncertain && view.undoManager!.canUndo)
    precondition(try! Data(contentsOf: file) == original)

    control.setFault(.directorySync)
    await save()
    precondition(errors.count == 2 && controller.currentSaveIsUncertain)
    precondition(controller.currentDocumentIsDirty && controller.window!.isDocumentEdited)
    precondition(controller.window!.representedURL == file)
    precondition(try! Data(contentsOf: file) == Data(changed.utf8))
    let prepared = await controller.prepareToQuit()
    precondition(prepared)
    let recoveryDirectory = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment[
        "THEONLYPAD_STATE_DIRECTORY"]!)
    precondition(
      try! RecoveryStore(directory: recoveryDirectory).loadAll().contains {
        $0.text == changed
      }, "uncertain save must remain recoverable")
    controller.cancelPreparedQuit()
    replace("synthetic original\n")
    precondition(
      controller.currentDocumentIsDirty,
      "returning to old saved text must not clear an uncertain publication")
    let baselinePrepared = await controller.prepareToQuit()
    precondition(baselinePrepared)
    precondition(
      try! RecoveryStore(directory: recoveryDirectory).loadAll().contains {
        $0.text == "synthetic original\n"
      })
    controller.cancelPreparedQuit()
    control.setFault(nil)
    let newer = "synthetic newer after uncertainty\n"
    replace(newer)
    await save()
    precondition(errors.count == 2 && !controller.currentSaveIsUncertain)
    precondition(!controller.currentDocumentIsDirty)
    precondition(try! Data(contentsOf: file) == Data(newer.utf8))
    precondition(view.undoManager!.canUndo)
    let backups = try BackupStore(directory: BackupStore.defaultDirectory).list()
    precondition(
      try! backups.contains {
        try BackupStore(directory: BackupStore.defaultDirectory).read(id: $0.id) == original
      }, "original backup must survive uncertain-save retry")

    replace("synthetic uncertain again\n")
    control.setFault(.directorySync)
    await save()
    let outsider = Data("synthetic external writer\n".utf8)
    try outsider.write(to: file)
    control.setFault(nil)
    let countBeforeConflict = control.writeCount
    await save()
    precondition(errors.count == 4 && control.writeCount == countBeforeConflict)
    precondition(controller.currentSaveIsUncertain && controller.currentDocumentIsDirty)
    precondition(try! Data(contentsOf: file) == outsider)

    chosenDestination = directory.appendingPathComponent("save-as.txt")
    control.setFault(.directorySync)
    await save("file.saveAs")
    precondition(errors.count == 5 && controller.currentSaveIsUncertain)
    precondition(controller.window!.representedURL == file, "uncertain Save As must not adopt URL")
    control.setFault(nil)
    await save()
    precondition(errors.count == 5 && !controller.currentDocumentIsDirty)
    precondition(controller.window!.representedURL == chosenDestination)
    precondition(try! Data(contentsOf: file) == outsider)

    let savedAsBytes = try Data(contentsOf: chosenDestination!)
    replace("synthetic backup refusal\n")
    control.setBackupFailure(true)
    let writesBeforeBackup = control.writeCount
    await save()
    precondition(errors.count == 6 && control.writeCount == writesBeforeBackup)
    precondition(controller.currentDocumentIsDirty && !controller.currentSaveIsUncertain)
    precondition(try! Data(contentsOf: chosenDestination!) == savedAsBytes)
    precondition(view.isEditable && view.undoManager!.canUndo)
    control.setBackupFailure(false)
    controller.newDocument()
    view = editor(controller)
    replace("synthetic new scratch\n")
    chosenDestination = directory.appendingPathComponent("scratch-save.txt")
    control.setFault(.directorySync)
    await save()
    precondition(errors.count == 7 && controller.currentSaveIsUncertain)
    precondition(controller.window!.representedURL == nil)
    precondition(controller.currentDocumentIsDirty)
    control.setFault(nil)
    await save()
    precondition(errors.count == 7 && !controller.currentDocumentIsDirty)
    precondition(controller.window!.representedURL == chosenDestination)
    precondition(try! Data(contentsOf: chosenDestination!) == Data("synthetic new scratch\n".utf8))
    let gate = WriteGate()
    var lateErrors: [Error] = []
    let late = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(write: { _, _, _ in try gate.write() }),
      chooseSaveDestination: { _, _ in directory.appendingPathComponent("late.txt") },
      onError: { lateErrors.append($0) })
    late.newDocument()
    late.execute("file.save")
    await wait { gate.hasEntered }
    late.close()
    gate.release()
    try await Task.sleep(nanoseconds: 200_000_000)
    precondition(lateErrors.isEmpty, "late failure must not alert for a closed editor")

    var choosing: EditorWindowController!
    let chooserTarget = directory.appendingPathComponent("closed-chooser.txt")
    choosing = EditorWindowController(
      restoreStartup: false,
      saveServices: EditorSaveServices(write: { try control.write($0, $1, $2) }),
      chooseSaveDestination: { _, _ in
        choosing.close()
        return chooserTarget
      },
      onError: { lateErrors.append($0) })
    choosing.newDocument()
    let beforeChooser = control.writeCount
    choosing.execute("file.save")
    try await Task.sleep(nanoseconds: 200_000_000)
    precondition(
      control.writeCount == beforeChooser,
      "closed destination chooser must not admit a save")
    precondition(!FileManager.default.fileExists(atPath: chooserTarget.path))
    print(
      "PASS native save failures, uncertainty, exact retry, conflict, Save As, backup and recovery")
  }
}
