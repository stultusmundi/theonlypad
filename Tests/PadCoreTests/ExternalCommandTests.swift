import XCTest

@testable import PadCore

final class ExternalCommandTests: XCTestCase {
  private func script(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "external-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fixture.sh")
    try Data(body.utf8).write(to: path)
    return path
  }

  func testArgumentsRemainLiteralAndExpansionIsNotRecursive() throws {
    let fixture = try script("printf '%s\\n' \"$1\" \"$2\"")
    let marker = fixture.deletingLastPathComponent().appendingPathComponent("must-not-exist")
    let hostile = "$(touch \(marker.path)); & ' \" ${path}"
    let result = try ExternalCommandRunner().run(
      executable: "/bin/sh", arguments: [fixture.path, "${selection}", "${path}"],
      context: CommandContext(path: "literal ${selection}", selection: hostile))
    XCTAssertEqual(
      String(decoding: result.stdout, as: UTF8.self), hostile + "\nliteral ${selection}\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(result.exitCode, 0)
  }

  func testDrainsBothStreamsBeyondPipeCapacityAndReportsNonzeroExit() throws {
    let fixture = try script(
      "i=0; while [ $i -lt 4096 ]; do printf 'abcdefghijklmnopabcdefghijklmnop'; printf 'ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP' >&2; i=$((i+1)); done; exit 7"
    )
    let result = try ExternalCommandRunner().run(
      executable: "/bin/sh", arguments: [fixture.path],
      context: CommandContext(path: nil, selection: ""))
    XCTAssertEqual(result.stdout.count, 131072)
    XCTAssertEqual(result.stderr.count, 131072)
    XCTAssertEqual(result.exitCode, 7)
    XCTAssertEqual(result.termination, .exited)
    XCTAssertFalse(result.outputTruncated)
  }

  func testOutputLimitStopsChildAndBoundsCombinedCapture() throws {
    let fixture = try script("while :; do printf '012345678901234567890123456789'; done")
    let result = try ExternalCommandRunner().run(
      executable: "/bin/sh", arguments: [fixture.path],
      context: CommandContext(path: nil, selection: ""), maximumOutputBytes: 4096)
    XCTAssertEqual(result.termination, .outputLimit)
    XCTAssertTrue(result.outputTruncated)
    XCTAssertLessThanOrEqual(result.stdout.count + result.stderr.count, 4096)
  }

  func testCancellationEscalatesWhenChildIgnoresTERM() async throws {
    let fixture = try script("trap '' TERM; printf ready > \"$1\"; while :; do :; done")
    let ready = fixture.deletingLastPathComponent().appendingPathComponent("ready")
    let runner = ExternalCommandRunner()
    let task = Task.detached {
      try runner.run(
        executable: "/bin/sh", arguments: [fixture.path, ready.path],
        context: CommandContext(path: nil, selection: ""))
    }
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
    let start = Date()
    runner.cancel()
    let result = try await task.value
    XCTAssertEqual(result.termination, .cancelled)
    XCTAssertEqual(result.signal, 9)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testArgumentBudgetsNULAndPrelaunchCancellation() throws {
    let context = CommandContext(path: nil, selection: "")
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "/bin/echo", arguments: Array(repeating: "x", count: 129), context: context))
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "/bin/echo", arguments: [String(repeating: "x", count: 1_048_577)],
        context: context))
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "/bin/echo", arguments: ["nul\u{0}argument"], context: context))
    let runner = ExternalCommandRunner()
    runner.cancel()
    let result = try runner.run(
      executable: "/bin/echo", arguments: ["not launched"], context: context)
    XCTAssertEqual(result.termination, .cancelled)
    XCTAssertNil(result.exitCode)
    XCTAssertTrue(result.stdout.isEmpty)
    XCTAssertThrowsError(try runner.run(executable: "/bin/echo", arguments: [], context: context))
  }

  func testTimeoutAndInvalidInputs() throws {
    let fixture = try script("while :; do :; done")
    let result = try ExternalCommandRunner().run(
      executable: "/bin/sh", arguments: [fixture.path],
      context: CommandContext(path: nil, selection: ""), timeout: 0.1)
    XCTAssertEqual(result.termination, .timedOut)
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "sh", arguments: [], context: CommandContext(path: nil, selection: "")))
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "/bin/echo", arguments: ["${path}"],
        context: CommandContext(path: nil, selection: "")))
    XCTAssertThrowsError(
      try ExternalCommandRunner().run(
        executable: "/bin/echo", arguments: ["${unknown}"],
        context: CommandContext(path: nil, selection: "")))
  }
}
