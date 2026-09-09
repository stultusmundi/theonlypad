import AppKit
import PadCore

@MainActor final class Gate {
  var continuation: CheckedContinuation<Void, Never>?
  var entered: Bool { continuation != nil }
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
@main struct Harness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let mode = CommandLine.arguments[1]
    let success = CommandLine.arguments[2].hasSuffix("-success")
    let variant = CommandLine.arguments[2].replacingOccurrences(of: "-success", with: "")
    let preserves = ["control", "presentation", "reorder", "status", "unrelated", "opened"]
      .contains(variant)
    var failures = 0
    func check(_ condition: Bool, _ label: String) {
      print("\(condition ? "PASS" : "FAIL") \(label)")
      if !condition { failures += 1 }
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
      }
      check(condition(), "bounded callback wait")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ShortcutVariant-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.txt")
    try Data("retained synthetic file".utf8).write(to: file)
    let gate = Gate()
    var completed = false
    if mode == "recent" {
      var admitted = false
      var openCalls = 0
      let panel = RecentFilesController(
        paths: [file.path],
        onOpen: { url, isCurrent in
          openCalls += 1
          check(url == file, "open callback receives captured file")
          await gate.wait()
          admitted = isCurrent()
          completed = true
          guard admitted else { throw CancellationError() }
          if success { return }
          throw NSError(
            domain: "SyntheticVariant", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "VISIBLE OPEN FAILURE"])
        }, onRemove: { _ in }, onClear: {})
      panel.fixtureOpen()
      await wait { gate.entered }
      check(panel.isBusy, "recent operation admitted before refresh")
      switch variant {
      case "presentation": panel.refreshPresentation(paths: [file.path])
      case "reorder":
        panel.refreshPresentation(paths: [
          directory.appendingPathComponent("another.txt").path, file.path,
        ])
      case "opened":
        panel.refreshPresentation(
          paths: [directory.appendingPathComponent("another.txt").path, file.path],
          openedPath: directory.appendingPathComponent("another.txt").path)
      case "selection":
        panel.refreshPresentation(paths: [
          directory.appendingPathComponent("another.txt").path, file.path,
        ])
        panel.fixtureSelectPath(directory.appendingPathComponent("another.txt").path)
      case "remove": panel.refreshPresentation(paths: [])
      case "update": panel.update(paths: [file.path])
      case "suspend": panel.setSuspended(true)
      case "close": panel.close()
      default: break
      }
      gate.release()
      await wait { completed }
      try? await Task.sleep(for: .milliseconds(40))
      check(admitted == preserves, "request admission follows semantic target/lifecycle")
      check(
        panel.statusMessage.contains(success ? "Opened." : "VISIBLE OPEN FAILURE") == preserves,
        "only live same-target operation error is displayed")
      check(
        panel.paths.contains(file.path) == (variant != "remove"),
        "recent membership follows supplied list")
      check(openCalls == 1, "open callback invoked exactly once")
      panel.close()
    } else {
      let entry = UnresolvedSessionEntry(
        windowID: UUID(), metadata: SessionTab(originalPath: file.path),
        errorMessage: "Initial unresolved reason")
      var resolvedCalls = 0
      var removalCalls = 0
      var otherID: UUID?
      let panel = SessionRestorationController(
        entries: [entry],
        onRetry: { _ in
          await gate.wait()
          completed = true
          if success {
            return SessionResolvedFile(
              url: file, originalBytes: Data("restored exact text".utf8),
              decoded: try DocumentCodec.decode(Data("restored exact text".utf8)))
          }
          throw NSError(
            domain: "SyntheticVariant", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "VISIBLE RETRY FAILURE"])
        }, onLocate: { _, _ in throw CancellationError() },
        onResolved: { target, result in
          resolvedCalls += 1
          check(success, "only successful operation may resolve")
          check(
            target == entry && result.url == file && result.decoded.text == "restored exact text"
              && result.originalBytes == Data("restored exact text".utf8),
            "resolved callback receives exact captured entry and result")
        },
        onRemove: { target in
          removalCalls += 1
          check(target == entry, "removal callback receives exact captured entry")
          await gate.wait()
          completed = true
          if success { return }
          throw NSError(
            domain: "SyntheticVariant", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "VISIBLE REMOVE FAILURE"])
        })
      panel.fixtureSelect()
      if mode == "remove" { panel.fixtureRemove() } else { panel.fixtureRetry() }
      await wait { gate.entered }
      check(panel.isBusy, "session operation admitted before refresh")
      switch variant {
      case "presentation": panel.refreshPresentation(entries: [entry])
      case "status":
        var updated = entry
        updated.errorMessage = "Owner status updated"
        panel.refreshPresentation(entries: [updated])
      case "unrelated":
        let other = UnresolvedSessionEntry(
          windowID: UUID(), metadata: SessionTab(), errorMessage: "Other entry")
        otherID = other.metadata.id
        panel.refreshPresentation(entries: [other, entry])
      case "change":
        let changed = UnresolvedSessionEntry(
          windowID: UUID(), metadata: entry.metadata, errorMessage: "Changed target")
        panel.refreshPresentation(entries: [changed])
      case "metadata":
        let changed = UnresolvedSessionEntry(
          windowID: entry.windowID,
          metadata: SessionTab(
            id: entry.metadata.id,
            originalPath: directory.appendingPathComponent("changed.txt").path),
          errorMessage: "Changed metadata")
        panel.refreshPresentation(entries: [changed])
      case "recovery":
        let changed = UnresolvedSessionEntry(
          windowID: entry.windowID, metadata: entry.metadata,
          errorMessage: "Changed recovery source", hasRecovery: true)
        panel.refreshPresentation(entries: [changed])
      case "remove": panel.refreshPresentation(entries: [])
      case "update": panel.update(entries: [entry])
      case "close": panel.close()
      default: break
      }
      gate.release()
      await wait { completed }
      try? await Task.sleep(for: .milliseconds(40))
      if success {
        check(
          !panel.entries.contains { $0.metadata.id == entry.metadata.id },
          "successful action removes only resolved entry")
        if let otherID {
          check(
            panel.entries.map { $0.metadata.id } == [otherID],
            "unrelated entry survives successful action")
        }
        check(resolvedCalls == (mode == "retry" ? 1 : 0), "successful retry resolves exactly once")
        check(removalCalls == (mode == "remove" ? 1 : 0), "successful removal runs exactly once")
        check(
          !panel.fixtureStatus.contains("FAILURE") && !panel.isBusy,
          "success clears busy without error")
      } else {
        check(
          panel.entries.contains { $0.metadata.id == entry.metadata.id } == (variant != "remove"),
          "failure preserves current unresolved membership")
        check(
          panel.fixtureStatus.contains(
            mode == "remove" ? "VISIBLE REMOVE FAILURE" : "VISIBLE RETRY FAILURE") == preserves,
          "only live same-target session failure is displayed")
      }
      panel.close()
    }
    check(
      try Data(contentsOf: file) == Data("retained synthetic file".utf8),
      "original file bytes unchanged")
    exit(failures == 0 ? 0 : 1)
  }
}
