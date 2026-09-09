import AppKit
import Darwin
import Foundation
import PadCore

/// Standalone synthetic benchmark, intentionally excluded from the general native test suite.
/// The script runs each document size in a fresh process; no window is shown or activated.
@main struct CheckpointPerformanceHarness {
  struct Sample: Codable {
    let run: Int
    let utf16Units: Int
    let captureSeconds: Double
    let actorCommitSeconds: Double
    let processPeakRSSBytes: Int64
    let generation: UInt64
  }
  struct Report: Codable {
    let generatedAt: String
    let operatingSystem: String
    let architecture: String
    let hardwareModel: String
    let processor: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let swiftToolchain: String
    let optimization: String
    let syntheticUTF8Bytes: Int
    let repeats: Int
    let captureScope: String
    let commitScope: String
    let cacheConditions: String
    let memoryScope: String
    let limitations: [String]
    let persistedTextVerified: Bool
    let samples: [Sample]
  }
  enum Failure: Error {
    case invalidArguments, fixtureDirectory, missingEditor, wrongCapture, wrongReceipt,
      wrongPersistence, usage
  }

  @MainActor static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  static func systemString(_ name: String) -> String {
    var count = 0
    guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return "unavailable" }
    var bytes = [CChar](repeating: 0, count: count)
    guard sysctlbyname(name, &bytes, &count, nil, 0) == 0 else { return "unavailable" }
    return String(cString: bytes)
  }
  @MainActor static func main() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, let size = Int(arguments[1]),
      [1_000_000, 10_000_000, 100_000_000].contains(size)
    else { throw Failure.invalidArguments }
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    // The caller supplies a new directory. Never recursively remove an existing path.
    guard mkdir(directory.path, 0o700) == 0 else { throw Failure.fixtureDirectory }
    defer { try? FileManager.default.removeItem(at: directory) }
    setenv("THEONLYPAD_STATE_DIRECTORY", directory.appendingPathComponent("app-state").path, 1)
    let swiftToolchain = try String(contentsOfFile: arguments[3], encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    _ = NSApplication.shared

    // ASCII with short lines gives identical decimal UTF-8 byte and UTF-16 unit counts.
    // Fixture setup and native edit costs are deliberately outside capture/commit measurements.
    let line = "0123456789abcdef\n"
    let baseline =
      String(repeating: line, count: size / line.utf8.count)
      + String(line.prefix(size % line.utf8.count))
    let originalBytes = Data(baseline.utf8)
    guard originalBytes.count == size else { throw Failure.wrongCapture }
    let originalURL = directory.appendingPathComponent("synthetic-original.txt")
    try originalBytes.write(to: originalURL)
    let controller = EditorWindowController(restoreStartup: false, onSessionChange: {})
    let tab = SessionTab(originalPath: originalURL.path)
    try controller.restoreSessionTab(
      tab, decoded: DecodedDocument(text: baseline, encoding: .utf8, hasBOM: false),
      originalBytes: originalBytes, url: originalURL,
      viewState: try RestoredViewState.resolve(
        selection: NSRange(location: 0, length: 0), bookmarks: [], in: baseline))
    guard
      let textView = descendants(controller.window!.contentView!).compactMap({ $0 as? NSTextView })
        .first
    else { throw Failure.missingEditor }
    let recoveryDirectory = directory.appendingPathComponent("recovery")
    let sessionStore = SessionStore(directory: directory.appendingPathComponent("session"))
    let recovery = RecoveryCoordinator(
      directory: recoveryDirectory,
      saveCheckpointSession: { try sessionStore.save($0) },
      readCheckpointSession: { try sessionStore.load() })
    var samples: [Sample] = []
    for run in 1...3 {
      // A single native replacement makes each capture dirty and changes the persisted bytes.
      // Normal UI refresh computes dirty state before the timed capture, as in regular editing.
      textView.insertText(
        String(UnicodeScalar(64 + run)!),
        replacementRange: NSRange(location: size - 1, length: 1))
      guard controller.currentDocumentIsDirty, textView.textStorage?.length == size else {
        throw Failure.wrongCapture
      }
      let captureStart = ProcessInfo.processInfo.systemUptime
      let window = try controller.captureSessionCheckpoint()
      let checkpoint = SessionCheckpointCapture(
        generation: UInt64(run), liveTabIDs: window.liveTabIDs, recovery: window.recovery,
        session: EditorSession(windows: [window.window]))
      let captureEnd = ProcessInfo.processInfo.systemUptime
      guard window.recovery.count == 1, window.recovery[0].snapshot != nil,
        window.recovery[0].snapshot!.text.utf16.count == size
      else { throw Failure.wrongCapture }
      let commitStart = ProcessInfo.processInfo.systemUptime
      let receipt = try await recovery.commitSessionCheckpoint(checkpoint)
      let commitEnd = ProcessInfo.processInfo.systemUptime
      guard receipt.generation == UInt64(run),
        receipt.recoveryRevisions[tab.id] == window.recovery[0].revision
      else { throw Failure.wrongReceipt }
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.usage }
      samples.append(
        Sample(
          run: run, utf16Units: size,
          captureSeconds: captureEnd - captureStart, actorCommitSeconds: commitEnd - commitStart,
          processPeakRSSBytes: Int64(usage.ru_maxrss), generation: receipt.generation))
    }
    // Validate exact persisted content outside the measured intervals.
    let restored = try RecoveryStore(directory: recoveryDirectory).loadAll()
    guard restored.count == 1,
      restored[0].text.utf16.elementsEqual(textView.string.utf16),
      try sessionStore.load()?.windows.first?.tabs.first?.id == tab.id,
      try Data(contentsOf: originalURL) == originalBytes
    else { throw Failure.wrongPersistence }
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "other"
    #endif
    let report = Report(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture, hardwareModel: systemString("hw.model"),
      processor: systemString("machdep.cpu.brand_string"),
      processorCount: ProcessInfo.processInfo.processorCount,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      swiftToolchain: swiftToolchain,
      optimization: "release PadCore; swiftc -O -swift-version 5 native harness",
      syntheticUTF8Bytes: size, repeats: samples.count,
      captureScope:
        "MainActor synchronous native window capture plus immutable session-payload assembly; native edits and setup excluded",
      commitScope:
        "Awaited recovery actor admission, recovery validation/encoding/checksum/publication and synchronous session publication; includes actor scheduling and filesystem waits",
      cacheConditions:
        "Fresh process per size, three sequential dirty captures; first creates recovery/session files and later runs replace them. Filesystem caches are not flushed; normal edit refresh has warmed dirty-state cache.",
      memoryScope:
        "Darwin ru_maxrss bytes: cumulative process high-water including fixture setup and preceding runs for this size; not per-operation allocation or peak measured only during capture",
      limitations: [
        "Three individual samples; no percentile, throughput target, or statistical confidence claim.",
        "Hidden in-process native capture and filesystem cost only; not keystroke latency, end-to-end responsiveness, rendering, or desktop acceptance.",
        "Short-line ASCII workload only; emoji, long lines, pathological JSON escaping, and multiple documents are not performance-tested here.",
        "One active document and serial commits; does not measure scheduler coalescing under sustained user input.",
        "No window shown or activated. No system prompts or physical input are used.",
        "Concurrent machine activity, thermal conditions and filesystem cache affect results; no power-loss or atomic multi-file crash guarantee.",
      ], persistedTextVerified: true, samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(report))
    try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    // Do not invoke window-close recovery callbacks; this isolated process is ending and its
    // explicitly-owned synthetic directory is removed above. No app scheduler/timer was installed.
  }
}
