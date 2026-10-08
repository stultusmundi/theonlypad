import Foundation
import XCTest

@testable import PadCore

final class FileMonitorActionTests: XCTestCase {
  func fixture(_ bytes: Data) throws -> (URL, DiskObservation) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sample")
    try bytes.write(to: url)
    let observation = try ExternalFileProbe().observe(
      url, expected: bytes, boundIdentity: nil,
      forceContents: true, previous: nil, isCancelled: { false })
    return (url, observation)
  }
  func testReadOnceReturnsExactBytesAndBOMDecodedSnapshot() throws {
    let bytes = Data([0xFF, 0xFE, 0x41, 0, 0x0D, 0, 0x0A, 0])
    let (url, observation) = try fixture(bytes)
    let service = FileMonitorService()
    defer { service.stop() }
    let done = expectation(description: "read")
    let request = UUID()
    _ = service.readOnce(
      requestID: request, url: url, matching: observation, fallbackEncoding: .windows1252
    ) { id, result in
      XCTAssertEqual(id, request)
      switch result {
      case .success(let snapshot):
        XCTAssertEqual(snapshot.bytes, bytes)
        XCTAssertEqual(snapshot.document.text, "A\r\n")
        XCTAssertEqual(snapshot.document.encoding, .utf16LE)
        XCTAssertTrue(snapshot.document.hasBOM)
      case .failure(let error): XCTFail("Exact snapshot read must succeed: \(error)")
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }
  // The real read must refuse an editable snapshot, not publish binary bytes or hide it as I/O.
  func testNULBearingDiskReadRefusesSnapshotAndPreservesExactFileBytes() throws {
    let bytes = Data("before\u{0}after".utf8)
    let (url, observation) = try fixture(bytes)
    let service = FileMonitorService()
    defer { service.stop() }
    let done = expectation(description: "binary refusal")
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      switch result {
      case .success: XCTFail("NUL-bearing disk bytes must not produce an editable snapshot")
      case .failure(let error):
        XCTAssertEqual(error, .notText, "Binary admission must retain its precise typed refusal")
        XCTAssertNotEqual(
          error, .readFailed, "Admission refusal must not be reported as an I/O error")
        XCTAssertNotEqual(error, .observationChanged, "Unchanged fixture must reach text admission")
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testRevalidationRejectsChangedFileWithoutChangingSnapshot() throws {
    let bytes = Data("before".utf8)
    let (url, observation) = try fixture(bytes)
    let snapshot = try ExternalFileActionReader().read(
      url, matching: observation,
      fallbackEncoding: .utf8, isCancelled: { false })
    try Data("after!".utf8).write(to: url, options: .atomic)
    let service = FileMonitorService()
    defer { service.stop() }
    let done = expectation(description: "revalidate")
    _ = service.revalidateOnce(requestID: UUID(), snapshot: snapshot) { _, result in
      switch result {
      case .success: XCTFail("Changed inode/content must not be admitted for reload")
      case .failure(let error): XCTAssertEqual(error, .observationChanged)
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(snapshot.bytes, bytes)
    XCTAssertEqual(snapshot.document.text, "before")
    XCTAssertEqual(try Data(contentsOf: url), Data("after!".utf8))
  }
  func testTypedDecodePolicyAndObservationErrors() throws {
    let (invalidURL, invalidObservation) = try fixture(Data([0xFF]))
    let (url, observation) = try fixture(Data("before".utf8))
    try Data("after!".utf8).write(to: url, options: .atomic)
    let service = FileMonitorService()
    defer { service.stop() }
    let decode = expectation(description: "decode")
    let changed = expectation(description: "changed")
    _ = service.readOnce(
      requestID: UUID(), url: invalidURL, matching: invalidObservation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(.decoding) = result {} else { XCTFail("Expected typed decoding failure") }
      decode.fulfill()
    }
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(.observationChanged) = result {
      } else {
        XCTFail("Expected stale observation rejection")
      }
      changed.fulfill()
    }
    wait(for: [decode, changed], timeout: 5)
    for expected in [FileActionError.policy, .notDownloaded, .readFailed] {
      var hooks = MonitorHooks()
      hooks.readAction = { _, _, _, _ in
        switch expected {
        case .policy: throw FileMaterializationError.disable(1)
        case .notDownloaded: throw ExternalFileProbeError.notDownloaded
        default: throw NSError(domain: NSPOSIXErrorDomain, code: 5)
        }
      }
      let fault = FileMonitorService(hooks: hooks)
      defer { fault.stop() }
      let done = expectation(description: "fault")
      _ = fault.readOnce(
        requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
      ) { _, result in
        if case .failure(let error) = result {
          XCTAssertEqual(error, expected)
        } else {
          XCTFail("No successful empty snapshot")
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 5)
    }
  }

  func testCancellationAndStopFenceLateReadWithoutReleasingBusyWorkers() throws {
    let (url, observation) = try fixture(Data("exact".utf8))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.readAction = { url, observation, encoding, _ in
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
      // Simulates a noninterruptible operation returning success after cancellation.
      return try ExternalFileActionReader().read(
        url, matching: observation, fallbackEncoding: encoding, isCancelled: { false })
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      release.signal()
      service.stop()
    }
    let results = ActionBox<[FileActionError]>([])
    let token = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(let error) = result {
        results.update { $0.append(error) }
      } else {
        XCTFail("Late success must be fenced")
      }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    token.cancel()
    XCTAssertEqual(results.value, [.cancelled], "Explicit cancellation completes synchronously")
    XCTAssertEqual(service.diagnostics.workers, 1, "Cancelled syscall retains worker admission")
    service.stop()
    release.signal()
    XCTAssertTrue(eventually { service.diagnostics.workers == 0 })
    XCTAssertEqual(results.value, [.cancelled])
    let stopped = ActionBox<FileActionError?>(nil)
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(let error) = result { stopped.update { $0 = error } }
    }
    XCTAssertEqual(stopped.value, .stopped)
  }

  func testReadRevalidationAndChecksShareSixteenAdmissionsAndTwoWorkers() throws {
    let bytes = Data("exact".utf8)
    let (url, observation) = try fixture(bytes)
    let snapshot = try ExternalFileActionReader().read(
      url, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    let gate = DispatchSemaphore(value: 0)
    let entries = ActionBox(0)
    var hooks = MonitorHooks()
    hooks.readAction = { url, observation, encoding, cancelled in
      entries.update { $0 += 1 }
      _ = gate.wait(timeout: .now() + 5)
      return try ExternalFileActionReader().read(
        url, matching: observation, fallbackEncoding: encoding, isCancelled: cancelled)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      for _ in 0..<2 { gate.signal() }
      service.stop()
    }
    let callbacks = ActionBox(0)
    for _ in 0..<2 {
      _ = service.readOnce(
        requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
      ) { _, _ in callbacks.update { $0 += 1 } }
    }
    XCTAssertTrue(eventually { entries.value == 2 })
    for index in 0..<14 {
      if index.isMultiple(of: 2) {
        _ = service.checkOnce(
          requestID: UUID(), documentID: UUID(), url: url, baseline: bytes, baselineRevision: 1
        ) { _, _ in callbacks.update { $0 += 1 } }
      } else {
        _ = service.revalidateOnce(requestID: UUID(), snapshot: snapshot) { _, _ in
          callbacks.update { $0 += 1 }
        }
      }
    }
    let refused = ActionBox<FileActionError?>(nil)
    _ = service.revalidateOnce(requestID: UUID(), snapshot: snapshot) { _, result in
      if case .failure(let error) = result { refused.update { $0 = error } }
    }
    XCTAssertEqual(refused.value, .capacity)
    XCTAssertEqual(service.diagnostics.workers, 2)
    gate.signal()
    gate.signal()
    XCTAssertTrue(eventually { callbacks.value == 16 }, "Every queued action kind makes progress")
  }

  func testBlockedCallbackRetainsCancelledActionAdmissionsUntilDrain() throws {
    let (url, observation) = try fixture(Data(repeating: 65, count: 1024))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let service = FileMonitorService()
    defer {
      release.signal()
      service.stop()
    }
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .success = result {} else { XCTFail("First read succeeds") }
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    for _ in 0..<15 {
      let token = service.readOnce(
        requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
      ) { _, _ in }
      XCTAssertTrue(eventually { service.diagnostics.workers == 0 })
      token.cancel()
    }
    XCTAssertEqual(service.diagnostics.pendingManualCallbacks, 16)
    let refused = ActionBox<FileActionError?>(nil)
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(let error) = result { refused.update { $0 = error } }
    }
    XCTAssertEqual(
      refused.value, .capacity, "Cancellation cannot free a queued retained snapshot admission")
    release.signal()
    XCTAssertTrue(eventually { service.diagnostics.pendingManualCallbacks == 0 })
    let finished = expectation(description: "readmitted")
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .success = result {} else { XCTFail("Draining permits new work") }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
  }

  func testStopFencesSuccessfulActionWaitingForCallbackAdmission() throws {
    let (url, observation) = try fixture(Data("exact".utf8))
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.beforeManualDelivery = {
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      release.signal()
      service.stop()
    }
    let done = expectation(description: "cancelled")
    _ = service.readOnce(
      requestID: UUID(), url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .failure(.cancelled) = result {
      } else {
        XCTFail("Stopped service cannot publish queued snapshot success")
      }
      done.fulfill()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    service.stop()
    release.signal()
    wait(for: [done], timeout: 5)
  }

  func testDuplicateRequestAcrossKindsCannotRemoveOriginalRead() throws {
    let bytes = Data("exact".utf8)
    let (url, observation) = try fixture(bytes)
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.readAction = { url, observation, encoding, cancelled in
      entered.signal()
      _ = gate.wait(timeout: .now() + 5)
      return try ExternalFileActionReader().read(
        url, matching: observation, fallbackEncoding: encoding, isCancelled: cancelled)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let request = UUID()
    let done = expectation(description: "original")
    _ = service.readOnce(
      requestID: request, url: url, matching: observation, fallbackEncoding: .utf8
    ) { _, result in
      if case .success(let snapshot) = result {
        XCTAssertEqual(snapshot.bytes, bytes)
      } else {
        XCTFail("Duplicate refusal cannot remove accepted original")
      }
      done.fulfill()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    let refused = ActionBox<FileCheckError?>(nil)
    _ = service.checkOnce(
      requestID: request, documentID: UUID(), url: url, baseline: bytes, baselineRevision: 1
    ) { _, result in
      if case .failure(let error) = result { refused.update { $0 = error } }
    }
    XCTAssertEqual(refused.value, .invalidRequest)
    gate.signal()
    wait(for: [done], timeout: 5)
  }

  func eventually(_ predicate: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(4)
    while Date() < end {
      if predicate() { return true }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return predicate()
  }

}

private final class ActionBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T
  init(_ value: T) { stored = value }
  var value: T {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func update(_ body: (inout T) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&stored)
  }
}
