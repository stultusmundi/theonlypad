import Darwin
import Foundation
import XCTest

@testable import PadCore

/// Injected Process.run always throws before any OS spawn. No actual child.
final class ExternalCommandAdmissionTests: XCTestCase {
  func testCancellationDuringConfirmedContentionPreventsProcessRun() {
    let contended = DispatchSemaphore(value: 0)
    let gate = ProcessSpawnGate(onContention: { contended.signal() })
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let holderDone = expectation(description: "held gate released")
    let commandDone = expectation(description: "cancelled admission returned")
    let process = AdmissionProcess()
    let runner = ExternalCommandRunner(spawnGate: gate, makeProcess: { process })
    defer { release.signal() }
    DispatchQueue.global().async {
      defer { holderDone.fulfill() }
      do {
        try gate.withCriticalRegion { _ in
          held.signal()
          XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }
      } catch { XCTFail("Holder failed: \(error)") }
    }
    XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async {
      defer { commandDone.fulfill() }
      do {
        let result = try self.run(runner)
        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
      } catch { XCTFail("Cancelled admission invoked launch: \(error)") }
    }
    XCTAssertEqual(contended.wait(timeout: .now() + 2), .success)
    runner.cancel()
    release.signal()
    wait(for: [holderDone, commandDone], timeout: 3)
    XCTAssertEqual(process.attempts, 0)
  }

  func testSharedPoisonRefusesFreshRunnersBeforeLaunchAndMapsActionableError() throws {
    let gate = ProcessSpawnGate()
    try gate.withCriticalRegion { $0.quarantine(EBADF) }
    for _ in 0..<2 {
      let process = AdmissionProcess()
      let runner = ExternalCommandRunner(spawnGate: gate, makeProcess: { process })
      XCTAssertThrowsError(try run(runner)) {
        guard case ExternalCommandError.spawnSafetyUnavailable = $0 else {
          return XCTFail("Shared refusal lost origin: \($0)")
        }
        XCTAssertTrue($0.localizedDescription.contains("Restart"))
      }
      XCTAssertEqual(process.attempts, 0)
    }
  }

  func testAdmittedRunnerUsesExactProcessAdapterAndPreservesLaunchFailure() throws {
    let gate = ProcessSpawnGate()
    let process = AdmissionProcess()
    let runner = ExternalCommandRunner(spawnGate: gate, makeProcess: { process })
    XCTAssertThrowsError(try run(runner)) {
      XCTAssertEqual($0 as? AdmissionFailure, .expected)
    }
    XCTAssertEqual(process.attempts, 1)
    XCTAssertEqual(process.arguments, ["literal"])
    XCTAssertEqual(process.executableURL?.path, "/synthetic/command-fixture")
    XCTAssertEqual(try gate.withCriticalRegion { _ in 17 }, 17)
  }

  func testRunnerStateLockIsReleasedDuringSharedAdmission() {
    let process = AdmissionProcess()
    let runner = ExternalCommandRunner(spawnGate: ProcessSpawnGate(), makeProcess: { process })
    let cancelReturned = DispatchSemaphore(value: 0)
    let done = expectation(description: "injected launch settled")
    process.onRun = {
      DispatchQueue.global().async {
        runner.cancel()
        cancelReturned.signal()
      }
      XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)
    }
    defer { process.onRun = nil }
    DispatchQueue.global().async {
      defer { done.fulfill() }
      do {
        _ = try self.run(runner)
        XCTFail("Injected launch should refuse")
      } catch { XCTAssertEqual(error as? AdmissionFailure, .expected) }
    }
    wait(for: [done], timeout: 3)
  }

  func testPrelaunchCancellationNeverInvokesProcessFactory() throws {
    let runner = ExternalCommandRunner(
      spawnGate: ProcessSpawnGate(),
      makeProcess: {
        XCTFail("Cancelled command created a process")
        return AdmissionProcess()
      })
    runner.cancel()
    XCTAssertEqual(try run(runner).termination, .cancelled)
  }

  private func run(_ runner: ExternalCommandRunner) throws -> ExternalCommandResult {
    try runner.run(
      executable: "/synthetic/command-fixture", arguments: ["literal"],
      context: CommandContext(path: nil, selection: ""))
  }
}

private enum AdmissionFailure: Error, Equatable { case expected }

private final class AdmissionProcess: Process, @unchecked Sendable {
  var attempts = 0
  var onRun: (() -> Void)?
  // Process is a Foundation class cluster. Override all configured abstract
  // properties as well as run, so this double never enters its OS adapter.
  private var executable: URL?
  private var argv: [String]?
  private var input: Any?
  private var output: Any?
  private var errors: Any?
  override var executableURL: URL? {
    get { executable }
    set { executable = newValue }
  }
  override var arguments: [String]? {
    get { argv }
    set { argv = newValue }
  }
  override var standardInput: Any? {
    get { input }
    set { input = newValue }
  }
  override var standardOutput: Any? {
    get { output }
    set { output = newValue }
  }
  override var standardError: Any? {
    get { errors }
    set { errors = newValue }
  }
  override func run() throws {
    attempts += 1
    onRun?()
    throw AdmissionFailure.expected
  }
}
