import Darwin
import Dispatch
import Foundation
import XCTest

@testable import PadCore

final class FileMonitorServiceTests: XCTestCase {
  func testCancelReceiptRetainsFirstBindingBeforeCallbackAndRetryParentContinuity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let url = parent.appendingPathComponent("document.txt")
    let bytes = Data("same".utf8)
    try bytes.write(to: url)
    let expected = try XCTUnwrap(
      ExternalFileProbe().observe(
        url, expected: bytes, boundIdentity: nil, forceContents: true, previous: nil,
        isCancelled: { false }
      ).metadata?.identity)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.beforeDelivery = {
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      release.signal()
      service.stop()
    }
    let registration = try service.register(
      documentID: UUID(), url: url, baseline: bytes, baselineRevision: 7
    ) { _, _ in }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    let receipt = registration.cancelAndSnapshot()
    XCTAssertEqual(
      receipt.boundIdentity, expected,
      "Identity must survive cancellation before the first callback")
    XCTAssertEqual(receipt.baselineRevision, 7)
    XCTAssertTrue(receipt.cancelled)
    let moved = directory.appendingPathComponent("old")
    try FileManager.default.moveItem(at: parent, to: moved)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try bytes.write(to: url)
    let observations = LockedBox<[DiskObservation]>([])
    let retry = FileMonitorService()
    defer { retry.stop() }
    _ = try retry.register(
      documentID: UUID(), url: url, baseline: bytes, baselineRevision: 7,
      boundIdentity: expected
    ) { _, value in observations.update { $0.append(value) } }
    XCTAssertTrue(
      waitUntil { observations.value.contains { $0.locationProblem == .parentChanged } },
      "Retry registration must preserve the acknowledged parent binding")
  }

  func testCancelAndSnapshotLinearizesBeforeOrAfterWorkerBinding() throws {
    for cancelBeforeBinding in [true, false] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("sample")
      let bytes = Data("bytes".utf8)
      try bytes.write(to: url)
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      var hooks = MonitorHooks()
      let barrier: @Sendable () -> Void = {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      if cancelBeforeBinding {
        hooks.beforeFirstBinding = barrier
      } else {
        hooks.afterFirstBinding = barrier
      }
      let service = FileMonitorService(hooks: hooks)
      defer {
        release.signal()
        service.stop()
      }
      let callbacks = LockedBox(0)
      let registration = try service.register(
        documentID: UUID(), url: url, baseline: bytes,
        baselineRevision: 23
      ) { _, _ in callbacks.update { $0 += 1 } }
      XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
      let receipt = registration.cancelAndSnapshot()
      XCTAssertEqual(receipt.boundIdentity == nil, cancelBeforeBinding)
      XCTAssertEqual(receipt.baselineRevision, 23)
      release.signal()
      XCTAssertTrue(
        waitUntil { service.diagnostics.workers == 0 && service.diagnostics.watchReservations == 0 }
      )
      XCTAssertEqual(
        registration.snapshot.boundIdentity, receipt.boundIdentity,
        "Late first binding cannot change a frozen receipt")
      XCTAssertEqual(callbacks.value, 0)
    }
  }

  func testFailedRebindKeepsReceiptContextAndSuccessfulRebindResetsBeforeTokenIssue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sample")
    let bytes = Data("bytes".utf8)
    try bytes.write(to: url)
    let service = FileMonitorService()
    defer { service.stop() }
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: url, baseline: bytes,
      baselineRevision: 4
    ) { _, _ in }
    XCTAssertTrue(waitUntil { registration.snapshot.boundIdentity != nil })
    let original = registration.snapshot
    XCTAssertThrowsError(
      try service.rebind(
        documentID: id, url: URL(string: "https://example.invalid")!,
        baseline: bytes, baselineRevision: 5))
    XCTAssertEqual(registration.snapshot.baselineRevision, 4)
    XCTAssertEqual(registration.snapshot.boundIdentity, original.boundIdentity)
    XCTAssertEqual(registration.snapshot.epoch, original.epoch)
    try service.rebind(
      documentID: id, url: directory.appendingPathComponent("missing"), baseline: bytes,
      baselineRevision: 6)
    let new = registration.cancelAndSnapshot()
    XCTAssertEqual(new.documentID, id)
    XCTAssertEqual(new.baselineRevision, 6)
    XCTAssertGreaterThan(new.epoch, original.epoch)
    XCTAssertNil(new.boundIdentity)
  }

  func testAtomicReplacementAndRearmDetectSecondReplacement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("document.txt")
    let original = Data("alpha".utf8)
    try original.write(to: url)
    // Genuine vnode event witness distinguishes unavailable host events from service failure.
    let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    let events = LockedBox(0)
    let witness = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete], queue: DispatchQueue(label: "test.vnode.witness"))
    witness.setEventHandler { events.update { $0 += 1 } }
    witness.setCancelHandler { close(descriptor) }
    witness.resume()
    defer { witness.cancel() }
    let service = FileMonitorService()
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: UUID(), url: url, baseline: original,
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer {
      registration.cancel()
      service.stop()
    }
    try Data("omega".utf8).write(to: url, options: .atomic)
    XCTAssertTrue(
      waitUntil { events.value > 0 }, "Native directory event must be observed by the witness")
    XCTAssertTrue(
      waitUntil { results.value.contains { $0.content == .differsFromBaseline } },
      "An atomic external replacement must produce a changed observation; observed: \(results.value.map { String(describing: $0.locationProblem) + String(describing: $0.content) }) token=\(String(describing: registration.snapshot.currentToken))"
    )
    let firstCount = results.value.count
    try Data("gamma".utf8).write(to: url, options: .atomic)
    var replacement = stat()
    XCTAssertEqual(lstat(url.path, &replacement), 0)
    let replacementInode = UInt64(replacement.st_ino)
    XCTAssertTrue(
      waitUntil {
        results.value.dropFirst(firstCount).contains {
          $0.content == .differsFromBaseline
            && $0.metadata?.identity.fileInode == replacementInode
        }
      }, "Rearmed monitoring must continue detecting replacement")
    XCTAssertEqual(try Data(contentsOf: url), Data("gamma".utf8))
  }

  func testInitialRaceReconcilesWithoutWaitingForAnotherFileEvent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("race.txt")
    let data = Data("stable".utf8)
    try data.write(to: url)
    let calls = LockedBox(0)
    var hooks = MonitorHooks()
    let original = hooks.probe
    hooks.probe = { url, expected, identity, cancelled in
      var first = false
      calls.update {
        $0 += 1
        first = $0 == 1
      }
      if first {
        return DiskObservation(
          metadata: nil, content: .unavailable,
          locationProblem: .changedDuringRead, readOnlyHint: false, movedCandidate: nil)
      }
      return try original(url, expected, identity, cancelled)
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: UUID(), url: url,
      baseline: data, baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { results.value.contains { $0.content == .matchesBaseline } },
      "Transient initial validation race must not strand a registration without watchers")
    XCTAssertEqual(try Data(contentsOf: url), data)
  }

  func testReplacementBetweenProbeAndWatchPreparationReconciles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("race.txt")
    let data = Data("before".utf8)
    try data.write(to: url)
    let calls = LockedBox(0)
    var hooks = MonitorHooks()
    let original = hooks.probe
    hooks.probe = { url, expected, identity, cancelled in
      let result = try original(url, expected, identity, cancelled)
      var first = false
      calls.update {
        $0 += 1
        first = $0 == 1
      }
      if first { try Data("after!".utf8).write(to: url, options: .atomic) }
      return result
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: UUID(), url: url,
      baseline: data, baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { results.value.contains { $0.content == .differsFromBaseline } },
      "Watch identity mismatch must reconcile instead of leaving the last baseline match stranded")
    XCTAssertEqual(try Data(contentsOf: url), Data("after!".utf8))
  }

  func testQueuedRequestsCoalesceAndIssueLiveTokenOnlyWhenStarted() throws {
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      var count = 0
      calls.update {
        $0 += 1
        count = $0
      }
      if count == 1 { _ = gate.wait(timeout: .now() + 5) }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let results = LockedBox<[FileObservationToken]>([])
    let registration = try service.register(
      documentID: id, url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 9
    ) { token, _ in results.update { $0.append(token) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { calls.value == 1 })
    let initial = try XCTUnwrap(registration.snapshot.currentToken)
    for _ in 0..<100 { service.requestCheck(documentID: id) }
    XCTAssertEqual(
      registration.snapshot.currentToken, initial,
      "Queued work alone must not pretend a newer probe has started")
    gate.signal()
    XCTAssertTrue(
      waitUntil { calls.value == 2 && results.value.contains { $0.sequence == 2 } },
      "Queued requests need one subsequent reconciliation")
    XCTAssertEqual(registration.snapshot.currentToken?.sequence, 2)
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(calls.value, 2, "One running plus one queued bit; no event-count work queue")
  }

  func testRebindRejectsOldBlockedCompletionAndPublishesNewContext() throws {
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, baseline, _, _ in
      calls.update { $0 += 1 }
      if baseline == Data([1]) { _ = gate.wait(timeout: .now() + 5) }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let url = URL(fileURLWithPath: "/tmp/synthetic-monitor")
    let results = LockedBox<[FileObservationToken]>([])
    let registration = try service.register(
      documentID: id, url: url,
      baseline: Data([1]), baselineRevision: 1
    ) { token, _ in results.update { $0.append(token) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { calls.value == 1 })
    let initial = try XCTUnwrap(registration.snapshot.currentToken)
    try service.rebind(documentID: id, url: url, baseline: Data([2]), baselineRevision: 2)
    XCTAssertTrue(waitUntil { results.value.contains { $0.baselineRevision == 2 } })
    XCTAssertNotEqual(registration.snapshot.currentToken?.epoch, initial.epoch)
    gate.signal()
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertFalse(
      results.value.contains { $0.baselineRevision == 1 }, "Old worker cannot publish after rebind")
  }

  func testCancellationIsImmediateAndWorkerPoolStaysAtTwo() throws {
    let active = LockedBox(0)
    let maximum = LockedBox(0)
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      active.update { $0 += 1 }
      maximum.update { $0 = max($0, active.value) }
      _ = gate.wait(timeout: .now() + 5)
      active.update { $0 -= 1 }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    var registrations: [FileMonitorRegistration] = []
    defer {
      for _ in 0..<4 { gate.signal() }
      service.stop()
    }
    let results = LockedBox(0)
    for _ in 0..<3 {
      registrations.append(
        try service.register(
          documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
          baseline: Data(), baselineRevision: 1
        ) { _, _ in results.update { $0 += 1 } })
    }
    XCTAssertTrue(waitUntil { calls.value == 2 })
    for value in registrations { value.cancel() }
    XCTAssertTrue(registrations.allSatisfy { $0.snapshot.cancelled })
    gate.signal()
    gate.signal()
    XCTAssertTrue(waitUntil { active.value == 0 })
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(calls.value, 2, "Cancelled queued document must not open a replacement worker")
    XCTAssertEqual(results.value, 0)
    XCTAssertEqual(maximum.value, 2)
  }

  func testSuspendRejectsQueuedDeliveryAndResumeReconciles() throws {
    let entered = LockedBox(0)
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      return unavailableObservation()
    }
    hooks.beforeDelivery = {
      var first = false
      entered.update {
        $0 += 1
        first = $0 == 1
      }
      if first { _ = gate.wait(timeout: .now() + 5) }
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let received = LockedBox<[FileObservationToken]>([])
    let registration = try service.register(
      documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { token, _ in received.update { $0.append(token) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { entered.value == 1 })
    service.suspendDelivery()
    gate.signal()
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertTrue(
      received.value.isEmpty, "Already queued result cannot publish after quit suspension")
    service.resumeAndReconcile()
    XCTAssertTrue(
      waitUntil { received.value.contains { $0.sequence == 2 } }, "Resume forces a fresh check")
    XCTAssertFalse(received.value.contains { $0.sequence == 1 })
  }

  func testWatchSetupFailureIsExplicitAndReservationsAreReleased() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    var hooks = MonitorHooks()
    hooks.beforeWatchOpen = { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: UUID(), url: url, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { results.value.contains { $0.locationProblem == .checkDelayed } },
      "Failure to install a watch must be disclosed, not presented as healthy monitoring")
    XCTAssertTrue(waitUntil { service.diagnostics.watchReservations == 0 })
    let manual = LockedBox<[DiskObservation]>([])
    let check = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: url,
      baseline: Data([0]), baselineRevision: 1
    ) { _, result in
      if case .success(let observation) = result { manual.update { $0.append(observation) } }
    }
    defer { check.cancel() }
    XCTAssertTrue(
      waitUntil { manual.value.contains { $0.content == .differsFromBaseline } },
      "Watch-open failure must not disable manual checking")
  }

  func testCancellationKeepsDescriptorsReservedUntilWorkerCloseCompletes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let gate = DispatchSemaphore(value: 0)
    let closing = LockedBox(false)
    var hooks = MonitorHooks()
    hooks.beforeClose = {
      closing.update { $0 = true }
      _ = gate.wait(timeout: .now() + 5)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: url, baseline: Data([1]),
      baselineRevision: 1
    ) { _, _ in }
    XCTAssertTrue(waitUntil { service.diagnostics.identities[id] != nil })
    registration.cancel()
    XCTAssertTrue(registration.snapshot.cancelled)
    XCTAssertTrue(waitUntil { closing.value })
    XCTAssertEqual(
      service.diagnostics.watchReservations, 2,
      "Retired descriptor leases still count until actual worker close")
    gate.signal()
    XCTAssertTrue(
      waitUntil { service.diagnostics.watchReservations == 0 && service.diagnostics.workers == 0 })
  }

  func testFullWatchCapacityRearmsOnlyAfterRetiredLeasesClose() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = FileMonitorService()
    defer { service.stop() }
    var registrations: [FileMonitorRegistration] = []
    var ids: [UUID] = []
    defer { for value in registrations { value.cancel() } }
    for index in 0..<128 {
      let url = directory.appendingPathComponent("fixture-\(index)")
      try Data([1]).write(to: url)
      let id = UUID()
      ids.append(id)
      registrations.append(
        try service.register(
          documentID: id, url: url,
          baseline: Data([1]), baselineRevision: 1
        ) { _, _ in })
    }
    XCTAssertTrue(waitUntil { service.diagnostics.identities.count == 128 })
    XCTAssertThrowsError(
      try service.register(
        documentID: UUID(), url: directory.appendingPathComponent("129"),
        baseline: Data(), baselineRevision: 1
      ) { _, _ in })
    let manualResult = LockedBox<[DiskObservation]>([])
    let manualCheck = service.checkOnce(
      requestID: UUID(), documentID: UUID(),
      url: directory.appendingPathComponent("fixture-0"), baseline: Data([0]), baselineRevision: 1
    ) { _, result in
      if case .success(let observation) = result { manualResult.update { $0.append(observation) } }
    }
    defer { manualCheck.cancel() }
    XCTAssertTrue(
      waitUntil { manualResult.value.contains { $0.content == .differsFromBaseline } },
      "A 129th document can explicitly check without allocating another watch")
    let changed = directory.appendingPathComponent("fixture-0")
    try Data([2]).write(to: changed, options: .atomic)
    var info = stat()
    XCTAssertEqual(lstat(changed.path, &info), 0)
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[ids[0]]?.fileInode == UInt64(info.st_ino) },
      "At 256 watch leases, retire and close old pair before rearming the replacement")
    XCTAssertLessThanOrEqual(service.diagnostics.peakReservations, 268)
    for value in registrations { value.cancel() }
    XCTAssertTrue(waitUntil { service.diagnostics.watchReservations == 0 })
  }

  func testCancelDuringRebindDoesNotLeaveAnUnremovableRegistration() throws {
    let entered = LockedBox(false)
    let completed = LockedBox(false)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in unavailableObservation() }
    hooks.beforeRebindInstall = {
      entered.update { $0 = true }
      _ = gate.wait(timeout: .now() + 5)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let url = URL(fileURLWithPath: "/tmp/synthetic-monitor")
    let registration = try service.register(
      documentID: id, url: url, baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    DispatchQueue.global().async {
      try? service.rebind(documentID: id, url: url, baseline: Data([1]), baselineRevision: 2)
      completed.update { $0 = true }
    }
    XCTAssertTrue(waitUntil { entered.value })
    registration.cancel()
    XCTAssertTrue(registration.snapshot.cancelled)
    gate.signal()
    XCTAssertTrue(waitUntil { completed.value })
    // A synchronous diagnostic read drains the previously enqueued cancellation.
    _ = service.diagnostics
    XCTAssertNoThrow(
      try service.register(
        documentID: id, url: url,
        baseline: Data(), baselineRevision: 3
      ) { _, _ in },
      "The cancelled rebind must not retain an unreachable entry/capacity slot")
  }

  func testBlockedReceiverCoalescesLatestResultWithoutUnboundedCallbackQueue() throws {
    let calls = LockedBox(0)
    let delivering = LockedBox(false)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      return unavailableObservation()
    }
    hooks.beforeDelivery = {
      var first = false
      delivering.update {
        first = !$0
        $0 = true
      }
      if first { _ = gate.wait(timeout: .now() + 5) }
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let results = LockedBox<[UInt64]>([])
    let registration = try service.register(
      documentID: id, url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { token, _ in results.update { $0.append(token.sequence) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { delivering.value })
    for target in 2...31 {
      service.requestCheck(documentID: id)
      XCTAssertTrue(waitUntil { calls.value == target && service.diagnostics.workers == 0 })
    }
    XCTAssertLessThanOrEqual(
      service.diagnostics.pendingCallbacks, 1,
      "A blocked receiver retains one scheduled callback and latest payload, not one closure per probe"
    )
    gate.signal()
    XCTAssertTrue(waitUntil { results.value.contains(31) })
  }

  func testUnregisteredManualCheckReadsExactSyntheticFileWithoutWatchDescriptors() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("changed".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let service = FileMonitorService()
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let id = UUID()
    let receivedIDs = LockedBox<[UUID]>([])
    let token = service.checkOnce(
      requestID: id, documentID: UUID(), url: url,
      baseline: Data("initial".utf8), baselineRevision: 1
    ) { request, result in
      receivedIDs.update { $0.append(request) }
      if case .success(let observation) = result { results.update { $0.append(observation) } }
    }
    defer { token.cancel() }
    XCTAssertTrue(waitUntil { results.value.contains { $0.content == .differsFromBaseline } })
    XCTAssertEqual(receivedIDs.value, [id])
    XCTAssertEqual(service.diagnostics.watchReservations, 0)
    XCTAssertEqual(try Data(contentsOf: url), Data("changed".utf8))
  }

  func testManualCapacityCancellationAndInFlightWorkersStayBounded() {
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      _ = gate.wait(timeout: .now() + 5)
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      for _ in 0..<20 { gate.signal() }
      service.stop()
    }
    let results = LockedBox<[UUID: [FileCheckError]]>([:])
    var ids: [UUID] = []
    var tokens: [FileCheckToken] = []
    for _ in 0..<17 {
      let id = UUID()
      ids.append(id)
      tokens.append(
        service.checkOnce(
          requestID: id, documentID: UUID(),
          url: URL(fileURLWithPath: "/tmp/synthetic-monitor"), baseline: Data(), baselineRevision: 1
        ) { request, result in
          if case .failure(let error) = result {
            results.update { $0[request, default: []].append(error) }
          }
        })
    }
    XCTAssertTrue(waitUntil { calls.value == 2 })
    XCTAssertEqual(results.value[ids[16]], [.capacity])
    tokens[0].cancel()
    tokens[15].cancel()
    XCTAssertEqual(results.value[ids[0]], [.cancelled])
    XCTAssertEqual(results.value[ids[15]], [.cancelled])
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertEqual(calls.value, 2, "Cancelling a blocked syscall does not free its worker slot")
    for value in tokens { value.cancel() }
    for _ in 0..<20 { gate.signal() }
    XCTAssertTrue(waitUntil { service.diagnostics.workers == 0 })
    XCTAssertTrue(results.value.values.allSatisfy { $0.count == 1 })
    XCTAssertEqual(results.value.count, 17)
  }

  func testDuplicateManualIDRefusalCannotCompleteOrRemoveOriginalRequest() {
    let calls = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in
      var call = 0
      calls.update {
        $0 += 1
        call = $0
      }
      if call <= 2 { _ = gate.wait(timeout: .now() + 5) }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      gate.signal()
      service.stop()
    }
    var tokens: [FileCheckToken] = []
    let url = URL(fileURLWithPath: "/tmp/synthetic-monitor")
    for _ in 0..<2 {
      tokens.append(
        service.checkOnce(
          requestID: UUID(), documentID: UUID(), url: url,
          baseline: Data(), baselineRevision: 1
        ) { _, _ in })
    }
    XCTAssertTrue(waitUntil { calls.value == 2 })
    let id = UUID()
    let original = LockedBox(0)
    let rejected = LockedBox<[FileCheckError]>([])
    tokens.append(
      service.checkOnce(
        requestID: id, documentID: UUID(), url: url,
        baseline: Data(), baselineRevision: 1
      ) { _, _ in original.update { $0 += 1 } })
    tokens.append(
      service.checkOnce(
        requestID: id, documentID: UUID(), url: url,
        baseline: Data(), baselineRevision: 1
      ) { _, result in
        if case .failure(let error) = result { rejected.update { $0.append(error) } }
      })
    XCTAssertEqual(rejected.value, [.invalidRequest])
    gate.signal()
    gate.signal()
    XCTAssertTrue(
      waitUntil { original.value == 1 },
      "Rejected duplicate's completion cannot own the original request's bookkeeping")
    XCTAssertEqual(calls.value, 3)
    for value in tokens { value.cancel() }
  }

  func testReconciliationUsesThirtySecondCadenceWithoutTimerSpin() throws {
    let time = LockedBox(100.0)
    let calls = LockedBox(0)
    var hooks = MonitorHooks()
    hooks.clock = { time.value }
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let registration = try service.register(
      documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { calls.value == 1 && service.diagnostics.workers == 0 })
    time.update { $0 = 129.99 }
    service.tickForTesting()
    XCTAssertEqual(calls.value, 1)
    time.update { $0 = 130 }
    service.tickForTesting()
    XCTAssertTrue(
      waitUntil { calls.value == 2 && service.diagnostics.workers == 0 },
      "Missing events still need bounded exact reconciliation")
    for _ in 0..<100 { service.tickForTesting() }
    XCTAssertEqual(calls.value, 2, "A due timestamp advances instead of spawning repeated work")
  }

  func testEventDebounceHasTwoSecondMaximumDeferral() throws {
    let time = LockedBox(100.0)
    let calls = LockedBox(0)
    var hooks = MonitorHooks()
    hooks.clock = { time.value }
    hooks.probe = { _, _, _, _ in
      calls.update { $0 += 1 }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { calls.value == 1 && service.diagnostics.workers == 0 })
    for index in 0..<20 {
      time.update { $0 = 100 + Double(index) * 0.1 }
      service.noteEventForTesting(documentID: id)
    }
    XCTAssertEqual(calls.value, 1, "Trailing debounce coalesces the continuing event burst")
    time.update { $0 = 102 }
    service.tickForTesting()
    XCTAssertTrue(
      waitUntil { calls.value == 2 && service.diagnostics.workers == 0 },
      "Continuous events cannot defer reconciliation beyond two seconds")
    time.update { $0 = 103 }
    service.noteEventForTesting(documentID: id)
    time.update { $0 = 103.249 }
    service.tickForTesting()
    XCTAssertEqual(calls.value, 2)
    time.update { $0 = 103.25 }
    service.tickForTesting()
    XCTAssertTrue(waitUntil { calls.value == 3 }, "A lone event uses the 250 ms debounce")
  }

  func testCancelledManualWorkCannotBuildUnboundedTailBehindBlockedReceiver() {
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in unavailableObservation() }
    let service = FileMonitorService(hooks: hooks)
    let gate = DispatchSemaphore(value: 0)
    let entered = LockedBox(false)
    defer {
      gate.signal()
      service.stop()
    }
    let url = URL(fileURLWithPath: "/tmp/synthetic-monitor")
    let first = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: url,
      baseline: Data(), baselineRevision: 1
    ) { _, _ in
      entered.update { $0 = true }
      _ = gate.wait(timeout: .now() + 5)
    }
    defer { first.cancel() }
    XCTAssertTrue(waitUntil { entered.value })
    for _ in 0..<24 {
      let token = service.checkOnce(
        requestID: UUID(), documentID: UUID(), url: url,
        baseline: Data([1]), baselineRevision: 1
      ) { _, _ in }
      token.cancel()
      XCTAssertTrue(waitUntil { service.diagnostics.workers == 0 })
    }
    XCTAssertLessThanOrEqual(
      service.diagnostics.pendingManualCallbacks, 16,
      "Cancelled admission retains its queued completion reservation until dequeued")
    gate.signal()
    XCTAssertTrue(waitUntil { service.diagnostics.pendingManualCallbacks == 0 })
  }

  func testRealRenameOffersValidatedCandidateWithoutRebindingOriginalURL() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("original.txt")
    let moved = directory.appendingPathComponent("renamed.txt")
    let bytes = Data("exact original bytes".utf8)
    try bytes.write(to: url)
    let service = FileMonitorService()
    defer { service.stop() }
    let id = UUID()
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: id, url: url, baseline: bytes,
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try FileManager.default.moveItem(at: url, to: moved)
    XCTAssertTrue(
      waitUntil { results.value.contains { $0.movedCandidate != nil } },
      "A retained vnode descriptor can offer its validated same-inode renamed path")
    let candidate = try XCTUnwrap(results.value.last { $0.movedCandidate != nil })
    let candidateURL = try XCTUnwrap(candidate.movedCandidate)
    var expectedInfo = stat()
    var actualInfo = stat()
    XCTAssertEqual(lstat(moved.path, &expectedInfo), 0)
    XCTAssertEqual(lstat(candidateURL.path, &actualInfo), 0)
    XCTAssertEqual(actualInfo.st_dev, expectedInfo.st_dev)
    XCTAssertEqual(actualInfo.st_ino, expectedInfo.st_ino)
    XCTAssertEqual(actualInfo.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(try Data(contentsOf: candidateURL), bytes)
    XCTAssertEqual(candidate.locationProblem, .missing)
    XCTAssertEqual(candidate.content, .unavailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try Data(contentsOf: moved), bytes)
    service.requestCheck(documentID: id)
    XCTAssertTrue(
      waitUntil { results.value.last?.locationProblem == .missing },
      "Offering a candidate does not change the monitored original URL")
  }

  func testRenameCandidateReplacedAfterReadIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.txt")
    let moved = directory.appendingPathComponent("renamed.txt")
    let bytes = Data("original".utf8)
    try bytes.write(to: original)
    var hooks = MonitorHooks()
    let probe = hooks.probe
    let substituted = LockedBox(false)
    hooks.probe = { url, expected, identity, cancelled in
      let result = try probe(url, expected, identity, cancelled)
      if url.lastPathComponent == "renamed.txt" {
        try bytes.write(to: url, options: .atomic)
        substituted.update { $0 = true }
      }
      return result
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let id = UUID()
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: id, url: original, baseline: bytes,
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try FileManager.default.moveItem(at: original, to: moved)
    XCTAssertTrue(
      waitUntil { substituted.value && results.value.contains { $0.locationProblem == .missing } })
    XCTAssertTrue(
      results.value.allSatisfy { $0.movedCandidate == nil },
      "Even identical bytes cannot authorize a replacement inode as the watched rename")
    XCTAssertEqual(try Data(contentsOf: moved), bytes)
  }

  func testAmbiguousHardLinkedRenameDoesNotOfferCandidate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.txt")
    let moved = directory.appendingPathComponent("renamed.txt")
    let linked = directory.appendingPathComponent("other-link.txt")
    try Data([1]).write(to: original)
    let service = FileMonitorService()
    defer { service.stop() }
    let id = UUID()
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: id, url: original, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    XCTAssertEqual(link(original.path, linked.path), 0)
    try FileManager.default.moveItem(at: original, to: moved)
    XCTAssertTrue(waitUntil { results.value.contains { $0.locationProblem == .missing } })
    XCTAssertTrue(results.value.allSatisfy { $0.movedCandidate == nil })
  }

  func testCancelWaitsForBorrowedRenameDescriptorWithoutBlockingControlQueue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.txt")
    let moved = directory.appendingPathComponent("renamed.txt")
    try Data([1]).write(to: original)
    let gate = DispatchSemaphore(value: 0)
    let entered = LockedBox(false)
    let closed = LockedBox(false)
    var hooks = MonitorHooks()
    hooks.beforeMovedCandidate = {
      entered.update { $0 = true }
      _ = gate.wait(timeout: .now() + 5)
    }
    hooks.beforeClose = { closed.update { $0 = true } }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: original, baseline: Data([1]),
      baselineRevision: 1
    ) { _, _ in }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try FileManager.default.moveItem(at: original, to: moved)
    XCTAssertTrue(waitUntil { entered.value })
    registration.cancel()
    XCTAssertTrue(registration.snapshot.cancelled)
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertFalse(closed.value, "Cancelled source cannot close an FD still borrowed by a worker")
    XCTAssertGreaterThanOrEqual(service.diagnostics.watchReservations, 2)
    XCTAssertEqual(service.diagnostics.workers, 1)
    gate.signal()
    XCTAssertTrue(
      waitUntil { service.diagnostics.watchReservations == 0 && service.diagnostics.workers == 0 })
    XCTAssertTrue(closed.value)
  }

  func testManualFallbackPreservesBoundParentIdentityAcrossSymlinkRetarget() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    let bytes = Data("same bytes".utf8)
    try bytes.write(to: first.appendingPathComponent("file.txt"))
    try bytes.write(to: second.appendingPathComponent("file.txt"))
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    let url = alias.appendingPathComponent("file.txt")
    let observed = try ExternalFileProbe().observe(
      url, expected: bytes, boundIdentity: nil,
      forceContents: true, previous: nil, isCancelled: { false })
    let identity = try XCTUnwrap(observed.metadata?.identity)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
    let service = FileMonitorService()
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let token = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: url,
      baseline: bytes, baselineRevision: 1, boundIdentity: identity
    ) { _, result in
      if case .success(let observation) = result { results.update { $0.append(observation) } }
    }
    defer { token.cancel() }
    XCTAssertTrue(waitUntil { !results.value.isEmpty })
    XCTAssertEqual(
      results.value.first?.locationProblem, .parentChanged,
      "Manual fallback cannot erase a registered document's established parent identity")
    XCTAssertEqual(results.value.first?.content, .unavailable)
    XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("file.txt")), bytes)
    XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("file.txt")), bytes)
  }

  func testWatchFilesystemStagesCanStallOnlyTheTwoWorkers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("file.txt")
    try Data([1]).write(to: url)
    for stage in WatchPreparationStage.allCases {
      let entered = LockedBox(0)
      let mainThread = LockedBox(false)
      let gate = DispatchSemaphore(value: 0)
      var hooks = MonitorHooks()
      hooks.watchBoundary = { point in
        guard point == stage else { return }
        mainThread.update { $0 = $0 || Thread.isMainThread }
        entered.update { $0 += 1 }
        _ = gate.wait(timeout: .now() + 5)
      }
      let service = FileMonitorService(hooks: hooks)
      var tokens: [FileMonitorRegistration] = []
      defer {
        gate.signal()
        gate.signal()
        service.stop()
      }
      for _ in 0..<3 {
        tokens.append(
          try service.register(
            documentID: UUID(), url: url, baseline: Data([1]),
            baselineRevision: 1
          ) { _, _ in })
      }
      XCTAssertTrue(waitUntil { entered.value == 2 }, "Stage \(stage)")
      for value in tokens { value.cancel() }
      XCTAssertTrue(tokens.allSatisfy { $0.snapshot.cancelled })
      XCTAssertEqual(service.diagnostics.workers, 2)
      XCTAssertNil(tokens[2].snapshot.currentToken, "Queued work must not bypass stalled workers")
      XCTAssertFalse(mainThread.value)
      gate.signal()
      gate.signal()
      XCTAssertTrue(
        waitUntil { service.diagnostics.workers == 0 && service.diagnostics.watchReservations == 0 }
      )
      XCTAssertEqual(entered.value, 2)
      service.stop()
    }
  }

  func testProbeVolumeLookupStallDoesNotBlockCancellationOrAdmitExtraWorker() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let entered = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var probeHooks = ProbeHooks()
    let volume = probeHooks.isLocalVolume
    probeHooks.isLocalVolume = { descriptor in
      entered.update { $0 += 1 }
      _ = gate.wait(timeout: .now() + 5)
      return try volume(descriptor)
    }
    let probe = ExternalFileProbe(hooks: probeHooks)
    var hooks = MonitorHooks()
    hooks.probe = { url, expected, identity, cancelled in
      try probe.observe(
        url, expected: expected, boundIdentity: identity,
        forceContents: true, previous: nil, isCancelled: cancelled)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      gate.signal()
      service.stop()
    }
    var tokens: [FileMonitorRegistration] = []
    for _ in 0..<3 {
      tokens.append(
        try service.register(
          documentID: UUID(), url: url, baseline: Data([1]),
          baselineRevision: 1
        ) { _, _ in })
    }
    XCTAssertTrue(waitUntil { entered.value == 2 })
    for value in tokens { value.cancel() }
    XCTAssertTrue(tokens.allSatisfy { $0.snapshot.cancelled })
    XCTAssertEqual(service.diagnostics.workers, 2)
    XCTAssertNil(tokens[2].snapshot.currentToken)
    gate.signal()
    gate.signal()
    XCTAssertTrue(
      waitUntil { service.diagnostics.workers == 0 && service.diagnostics.watchReservations == 0 })
    XCTAssertEqual(entered.value, 2)
  }

  func testServiceAndRegistrationReleaseAfterAsynchronousDescriptorCleanup() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let closes = LockedBox(0)
    var hooks = MonitorHooks()
    hooks.beforeClose = { closes.update { $0 += 1 } }
    var service: FileMonitorService? = FileMonitorService(hooks: hooks)
    let weakService = WeakBox(service)
    let id = UUID()
    var registration: FileMonitorRegistration? = try service?.register(
      documentID: id, url: url,
      baseline: Data([1]), baselineRevision: 1
    ) { _, _ in }
    let weakRegistration = WeakBox(registration)
    XCTAssertTrue(
      waitUntil { service?.diagnostics.identities[id] != nil && service?.diagnostics.workers == 0 })
    registration?.cancel()
    registration = nil
    service?.stop()
    service = nil
    XCTAssertTrue(
      waitUntil { weakService.value == nil && weakRegistration.value == nil && closes.value == 1 })
  }

  func testManualAndDifferentDocumentsAreNotStarvedByHotRegistration() throws {
    let order = LockedBox<[String]>([])
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.probe = { url, _, _, _ in
      var position = 0
      order.update {
        $0.append(url.lastPathComponent)
        position = $0.count
      }
      if position <= 2 { _ = gate.wait(timeout: .now() + 5) }
      return unavailableObservation()
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      gate.signal()
      service.stop()
    }
    let hot = UUID()
    let first = try service.register(
      documentID: hot, url: URL(fileURLWithPath: "/tmp/A"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    let second = try service.register(
      documentID: UUID(), url: URL(fileURLWithPath: "/tmp/B"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer {
      first.cancel()
      second.cancel()
    }
    XCTAssertTrue(waitUntil { order.value.count == 2 })
    for _ in 0..<100 { service.requestCheck(documentID: hot) }
    let third = try service.register(
      documentID: UUID(), url: URL(fileURLWithPath: "/tmp/C"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer { third.cancel() }
    let manual = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: URL(fileURLWithPath: "/tmp/M"),
      baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer { manual.cancel() }
    gate.signal()
    gate.signal()
    XCTAssertTrue(waitUntil { order.value.contains("C") && order.value.contains("M") })
    XCTAssertLessThanOrEqual(try XCTUnwrap(order.value.firstIndex(of: "C")), 4)
    XCTAssertLessThanOrEqual(try XCTUnwrap(order.value.firstIndex(of: "M")), 4)
  }

  func testRebindStormWithStalledCleanupRetainsBoundedLeasesAndLatestEpoch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    try Data([1]).write(to: first)
    try Data([2]).write(to: second)
    let closings = LockedBox(0)
    let gate = DispatchSemaphore(value: 0)
    var hooks = MonitorHooks()
    hooks.beforeClose = {
      var count = 0
      closings.update {
        $0 += 1
        count = $0
      }
      if count <= 2 { _ = gate.wait(timeout: .now() + 5) }
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let revisions = LockedBox<[UInt64]>([])
    let registration = try service.register(
      documentID: id, url: first, baseline: Data([1]),
      baselineRevision: 0
    ) { token, _ in revisions.update { $0.append(token.baselineRevision) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try service.rebind(documentID: id, url: second, baseline: Data([2]), baselineRevision: 1)
    XCTAssertTrue(waitUntil { closings.value == 1 })
    try service.rebind(documentID: id, url: first, baseline: Data([1]), baselineRevision: 2)
    XCTAssertTrue(waitUntil { closings.value == 2 })
    for index in 0..<100 {
      try service.rebind(
        documentID: id, url: index % 2 == 0 ? first : second,
        baseline: Data([index % 2 == 0 ? 1 : 2]), baselineRevision: UInt64(index + 3))
    }
    XCTAssertEqual(service.diagnostics.workers, 2)
    XCTAssertLessThanOrEqual(service.diagnostics.watchReservations, 256)
    XCTAssertNil(registration.snapshot.currentToken)
    gate.signal()
    gate.signal()
    XCTAssertTrue(waitUntil { revisions.value.contains(102) && service.diagnostics.workers == 0 })
    XCTAssertEqual(registration.snapshot.currentToken?.baselineRevision, 102)
    XCTAssertEqual(service.diagnostics.watchReservations, 2)
    XCTAssertLessThanOrEqual(service.diagnostics.peakReservations, 268)
    registration.cancel()
    XCTAssertTrue(waitUntil { service.diagnostics.watchReservations == 0 })
  }

  func testMaterializationDisabledBeforeEveryServiceFilesystemBoundary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let moved = directory.appendingPathComponent("moved.txt")
    try Data([1]).write(to: file)
    let policies = LockedBox<[Int32]>([])
    @Sendable func record() {
      policies.update {
        $0.append(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
      }
    }
    var hooks = MonitorHooks()
    let originalProbe = hooks.probe
    hooks.probe = { url, expected, identity, cancelled in
      record()
      return try originalProbe(url, expected, identity, cancelled)
    }
    hooks.watchBoundary = { _ in record() }
    hooks.beforeMovedCandidate = { record() }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let id = UUID()
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: id, url: file, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try FileManager.default.moveItem(at: file, to: moved)
    XCTAssertTrue(waitUntil { results.value.contains { $0.movedCandidate != nil } })
    let manualDone = LockedBox(false)
    let manual = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: moved,
      baseline: Data([1]), baselineRevision: 1
    ) { _, _ in manualDone.update { $0 = true } }
    defer { manual.cancel() }
    XCTAssertTrue(waitUntil { manualDone.value })
    XCTAssertGreaterThanOrEqual(policies.value.count, 8)
    XCTAssertTrue(
      policies.value.allSatisfy { $0 == IOPOL_MATERIALIZE_DATALESS_FILES_OFF },
      "All probe/watch/rename/manual boundaries need OFF before filesystem work")
  }

  func testStandaloneProbeDisablesMaterializationBeforeReadAndRestoresThread() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let done = expectation(description: "owned probe thread")
    Thread {
      defer { done.fulfill() }
      let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
      guard old >= 0 else { return XCTFail("Policy query failed") }
      defer {
        XCTAssertEqual(
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old), 0)
      }
      XCTAssertEqual(
        setiopolicy_np(
          IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
          IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT), 0)
      var hooks = ProbeHooks()
      hooks.boundary = { _ in
        XCTAssertEqual(
          getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
          IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
      }
      do {
        let probe = ExternalFileProbe(hooks: hooks)
        let observed = try probe.observe(
          file, expected: Data([1]), boundIdentity: nil,
          forceContents: true, previous: nil, isCancelled: { false })
        XCTAssertEqual(
          try probe.read(file, matching: observed, isCancelled: { false }).bytes, Data([1]))
      } catch { XCTFail("Unexpected probe failure: \(error)") }
      XCTAssertEqual(
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
        IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
    }.start()
    wait(for: [done], timeout: 5)
  }

  func testEDEADLKProbeObservationAndReadAreExplicitlyNotDownloaded() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let initial = try ExternalFileProbe().observe(
      file, expected: Data([1]), boundIdentity: nil,
      forceContents: true, previous: nil, isCancelled: { false })
    var hooks = ProbeHooks()
    hooks.read = { _, _, _ in
      errno = EDEADLK
      return -1
    }
    let probe = ExternalFileProbe(hooks: hooks)
    do {
      let result = try probe.observe(
        file, expected: Data([1]), boundIdentity: nil,
        forceContents: true, previous: nil, isCancelled: { false })
      XCTAssertEqual(result.locationProblem, .notDownloaded)
      XCTAssertEqual(result.content, .unavailable)
    } catch { XCTFail("Dataless read refusal must have explicit observation state") }
    XCTAssertThrowsError(try probe.read(file, matching: initial, isCancelled: { false })) { error in
      XCTAssertEqual(error as? ExternalFileProbeError, .notDownloaded)
    }
  }

  func testEDEADLKDuringWatchPreparationClosesPartialPairAndReportsNotDownloaded() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let parentFD = LockedBox<Int32?>(nil)
    var hooks = MonitorHooks()
    let openParent = hooks.openWatchParent
    hooks.openWatchParent = { path in
      let fd = openParent(path)
      parentFD.update { $0 = fd }
      return fd
    }
    hooks.openWatchFile = { _, _ in
      errno = EDEADLK
      return -1
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let registration = try service.register(
      documentID: UUID(), url: file, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { !results.value.isEmpty && service.diagnostics.workers == 0 })
    XCTAssertEqual(results.value.last?.locationProblem, .notDownloaded)
    XCTAssertEqual(results.value.last?.content, .unavailable)
    XCTAssertEqual(service.diagnostics.watchReservations, 0)
    if let fd = parentFD.value {
      XCTAssertEqual(fcntl(fd, F_GETFD), -1)
      XCTAssertEqual(errno, EBADF)
    } else {
      XCTFail("The partial-open fixture must actually acquire its parent FD")
    }
  }

  func testPolicyAdmissionFailurePreventsProbeAndWatchWork() throws {
    for failQuery in [true, false] {
      let calls = LockedBox(0)
      let deliveries = LockedBox<[DiskObservation]>([])
      var hooks = MonitorHooks()
      hooks.workerGuard = { operation in
        var policy = MaterializationPolicyHooks()
        policy.get = {
          if failQuery {
            errno = EIO
            return -1
          }
          return IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
        }
        policy.set = { _ in
          errno = EACCES
          return -1
        }
        return try FileMaterializationGuard.perform(
          hooks: policy,
          discardOnRestoreFailure: { $0.discardPrepared() }, operation)
      }
      hooks.probe = { _, _, _, _ in
        calls.update { $0 += 1 }
        return unavailableObservation()
      }
      hooks.beforeWatchOpen = { calls.update { $0 += 1 } }
      let service = FileMonitorService(hooks: hooks)
      defer { service.stop() }
      let registration = try service.register(
        documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
        baseline: Data(), baselineRevision: 1
      ) { _, result in deliveries.update { $0.append(result) } }
      defer { registration.cancel() }
      XCTAssertTrue(waitUntil { !deliveries.value.isEmpty && service.diagnostics.workers == 0 })
      XCTAssertEqual(calls.value, 0)
      XCTAssertEqual(deliveries.value.last?.content, .unavailable)
      XCTAssertEqual(service.diagnostics.watchReservations, 0)
    }
  }

  func testRestoreFailureDiscardsPreparedFDsBeforePublishingUnavailable() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let discarded = LockedBox<[Int32]>([])
    let restoreAttempted = LockedBox(false)
    var hooks = MonitorHooks()
    hooks.workerGuard = { operation in
      let saved = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
      defer {
        XCTAssertEqual(
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, saved), 0)
      }
      var policy = MaterializationPolicyHooks()
      let realSet = policy.set
      var sets = 0
      policy.set = { value in
        sets += 1
        if sets == 2 {
          restoreAttempted.update { $0 = true }
          errno = EIO
          return -1
        }
        return realSet(value)
      }
      return try FileMaterializationGuard.perform(
        hooks: policy,
        discardOnRestoreFailure: { outcome in
          let descriptors = outcome.preparedDescriptors
          XCTAssertEqual(descriptors.count, 2)
          for descriptor in descriptors {
            XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
          }
          outcome.discardPrepared()
          for descriptor in descriptors {
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
          }
          discarded.update { $0.append(contentsOf: descriptors) }
        }, operation)
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let results = LockedBox<[DiskObservation]>([])
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: file, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in
      XCTAssertTrue(restoreAttempted.value)
      XCTAssertEqual(discarded.value.count, 2)
      results.update { $0.append(result) }
    }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { !results.value.isEmpty && service.diagnostics.workers == 0 })
    XCTAssertNil(service.diagnostics.identities[id])
    XCTAssertEqual(service.diagnostics.watchReservations, 0)
    XCTAssertEqual(results.value.last?.content, .unavailable)
    XCTAssertEqual(try Data(contentsOf: file), Data([1]))
  }

  func testStopImmediatelyFencesQueuedManualSuccessAndRegistrationSnapshot() throws {
    let controlEntered = LockedBox(false)
    let manualEntered = LockedBox(false)
    let controlGate = DispatchSemaphore(value: 0)
    let manualGate = DispatchSemaphore(value: 0)
    let rebound = LockedBox(false)
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in unavailableObservation() }
    hooks.beforeRebindInstall = {
      controlEntered.update { $0 = true }
      _ = controlGate.wait(timeout: .now() + 5)
    }
    hooks.beforeManualDelivery = {
      manualEntered.update { $0 = true }
      _ = manualGate.wait(timeout: .now() + 5)
    }
    let service = FileMonitorService(hooks: hooks)
    defer {
      controlGate.signal()
      manualGate.signal()
      service.stop()
    }
    let id = UUID()
    let url = URL(fileURLWithPath: "/tmp/synthetic-monitor")
    let registration = try service.register(
      documentID: id, url: url, baseline: Data(), baselineRevision: 1
    ) { _, _ in }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { service.diagnostics.workers == 0 })
    let results = LockedBox<[String]>([])
    let manual = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: url,
      baseline: Data(), baselineRevision: 1
    ) { _, result in
      switch result {
      case .success: results.update { $0.append("success") }
      case .failure(.cancelled): results.update { $0.append("cancelled") }
      case .failure: results.update { $0.append("other") }
      }
    }
    defer { manual.cancel() }
    XCTAssertTrue(waitUntil { manualEntered.value })
    DispatchQueue.global().async {
      try? service.rebind(documentID: id, url: url, baseline: Data([1]), baselineRevision: 2)
      rebound.update { $0 = true }
    }
    XCTAssertTrue(waitUntil { controlEntered.value })
    service.stop()
    XCTAssertTrue(
      registration.snapshot.cancelled,
      "Stop must invalidate snapshots without waiting for the control queue")
    manualGate.signal()
    XCTAssertTrue(waitUntil { !results.value.isEmpty })
    XCTAssertEqual(
      results.value, ["cancelled"], "Queued manual success cannot be admitted after stop returns")
    controlGate.signal()
    XCTAssertTrue(waitUntil { rebound.value })
  }

  func testNestedCandidatePolicyFailureAbortsAndReleasesBorrowOnCancellation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    let moved = directory.appendingPathComponent("moved.txt")
    try Data([1]).write(to: file)
    let gate = DispatchSemaphore(value: 0)
    let entered = LockedBox(false)
    let closes = LockedBox(0)
    let candidates = LockedBox(0)
    var hooks = MonitorHooks()
    hooks.beforeMovedCandidate = {
      entered.update { $0 = true }
      _ = gate.wait(timeout: .now() + 5)
      throw FileMaterializationError.restore(EIO)
    }
    hooks.beforeClose = { closes.update { $0 += 1 } }
    let service = FileMonitorService(hooks: hooks)
    defer {
      gate.signal()
      service.stop()
    }
    let id = UUID()
    let registration = try service.register(
      documentID: id, url: file, baseline: Data([1]),
      baselineRevision: 1
    ) { _, result in if result.movedCandidate != nil { candidates.update { $0 += 1 } } }
    XCTAssertTrue(
      waitUntil { service.diagnostics.identities[id] != nil && service.diagnostics.workers == 0 })
    try FileManager.default.moveItem(at: file, to: moved)
    XCTAssertTrue(waitUntil { entered.value })
    registration.cancel()
    XCTAssertEqual(closes.value, 0)
    gate.signal()
    XCTAssertTrue(
      waitUntil { service.diagnostics.workers == 0 && service.diagnostics.watchReservations == 0 })
    XCTAssertEqual(closes.value, 1)
    XCTAssertEqual(candidates.value, 0)
    XCTAssertEqual(try Data(contentsOf: moved), Data([1]))
  }

  func testNestedProbePolicyErrorCannotContinueToWatchPreparation() throws {
    let calls = LockedBox(0)
    let results = LockedBox<[DiskObservation]>([])
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in throw FileMaterializationError.restore(EIO) }
    hooks.beforeWatchOpen = { calls.update { $0 += 1 } }
    hooks.beforeMovedCandidate = { calls.update { $0 += 1 } }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let registration = try service.register(
      documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { _, result in results.update { $0.append(result) } }
    defer { registration.cancel() }
    XCTAssertTrue(waitUntil { !results.value.isEmpty && service.diagnostics.workers == 0 })
    XCTAssertEqual(calls.value, 0)
    XCTAssertEqual(results.value.last?.content, .unavailable)
    XCTAssertEqual(service.diagnostics.watchReservations, 0)
  }

  func testManualPolicyRestorationFailureNeverPublishesSuccessfulObservation() {
    let attempted = LockedBox(false)
    let results = LockedBox<[FileCheckError]>([])
    var hooks = MonitorHooks()
    hooks.probe = { _, _, _, _ in unavailableObservation() }
    hooks.observationGuard = { operation in
      var policy = MaterializationPolicyHooks()
      policy.get = { IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT }
      policy.set = { value in
        if value == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { return 0 }
        attempted.update { $0 = true }
        errno = EIO
        return -1
      }
      return try FileMaterializationGuard.perform(hooks: policy, operation)
    }
    let service = FileMonitorService(hooks: hooks)
    defer { service.stop() }
    let token = service.checkOnce(
      requestID: UUID(), documentID: UUID(), url: URL(fileURLWithPath: "/tmp/synthetic-monitor"),
      baseline: Data(), baselineRevision: 1
    ) { _, result in
      XCTAssertTrue(attempted.value)
      if case .failure(let error) = result {
        results.update { $0.append(error) }
      } else {
        XCTFail("Policy restoration failure cannot publish a successful observation")
      }
    }
    defer { token.cancel() }
    XCTAssertTrue(waitUntil { !results.value.isEmpty })
    XCTAssertEqual(results.value, [.failed])
  }

  private func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
  }
}

final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func update(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&stored)
  }
}

private func unavailableObservation() -> DiskObservation {
  DiskObservation(
    metadata: nil, content: .unavailable, locationProblem: .missing,
    readOnlyHint: false, movedCandidate: nil)
}

private final class WeakBox<Value: AnyObject> {
  weak var value: Value?
  init(_ value: Value?) { self.value = value }
}
