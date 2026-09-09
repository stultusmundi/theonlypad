import Darwin
import Foundation
import XCTest

@testable import PadCore

final class ExternalFileProbeTests: XCTestCase {
  private var directory: URL!
  private let probe = ExternalFileProbe()

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-ExternalProbe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws {
    if let directory { try FileManager.default.removeItem(at: directory) }
  }
  private func file(_ name: String = "document.txt", bytes: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }
  private func observe(_ url: URL, expected: Data, identity: FileTargetIdentity? = nil) throws
    -> DiskObservation
  {
    try probe.observe(
      url, expected: expected, boundIdentity: identity,
      forceContents: true, previous: nil, isCancelled: { false })
  }
  private func identity(_ url: URL) throws -> FileTargetIdentity {
    var parent = stat()
    var target = stat()
    guard stat(url.deletingLastPathComponent().path, &parent) == 0,
      lstat(url.path, &target) == 0
    else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return FileTargetIdentity(
      parentDevice: UInt64(parent.st_dev), parentInode: UInt64(parent.st_ino),
      fileDevice: UInt64(target.st_dev), fileInode: UInt64(target.st_ino))
  }

  // First intended behavioral red: missing detection may never accept external bytes as baseline.
  func testSameSizeAtomicReplacementIsChangedAndDoesNotWrite() throws {
    let saved = Data("alpha\r\n".utf8)
    let external = Data("omega\r\n".utf8)
    XCTAssertEqual(saved.count, external.count)
    let url = try file(bytes: saved)
    let originalIdentity = try identity(url)
    let held = open(url.path, O_RDONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(held, 0)
    guard held >= 0 else { return }
    defer { close(held) }
    try external.write(to: url, options: .atomic)
    XCTAssertNotEqual(try identity(url).fileInode, originalIdentity.fileInode)
    let result = try observe(url, expected: saved, identity: originalIdentity)
    XCTAssertEqual(
      result.content, .differsFromBaseline,
      "Same-size replacement must not become the editor's saved baseline")
    XCTAssertNil(result.locationProblem)
    XCTAssertEqual(try Data(contentsOf: url), external, "Observation must not overwrite the file")
    XCTAssertEqual(saved, Data("alpha\r\n".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path), ["document.txt"])
  }

  func testUnchangedArbitraryBytesRemainExact() throws {
    let bytes = Data([0xFF, 0xFE, 0, 0, 0x3D, 0xD8, 0, 0xDE, 13, 0, 10, 0, 0x81, 0])
    let url = try file(bytes: bytes)
    let result = try observe(url, expected: bytes)
    XCTAssertEqual(result.content, .matchesBaseline)
    XCTAssertNil(result.locationProblem)
    XCTAssertEqual(result.metadata?.byteCount, Int64(bytes.count))
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testSameByteAtomicReplacementIsNotAContentConflict() throws {
    let bytes = Data("same bytes\n".utf8)
    let url = try file(bytes: bytes)
    let old = try identity(url)
    let held = open(url.path, O_RDONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(held, 0)
    guard held >= 0 else { return }
    defer { close(held) }
    try bytes.write(to: url, options: .atomic)
    let replacement = try identity(url)
    XCTAssertNotEqual(old.fileInode, replacement.fileInode)
    let result = try observe(url, expected: bytes, identity: old)
    XCTAssertEqual(result.content, .matchesBaseline)
    XCTAssertEqual(result.metadata?.identity, replacement)
    XCTAssertNil(result.locationProblem)
  }

  func testInPlaceSameLengthByteChangeIsDetected() throws {
    let original = Data("abcdef\n".utf8)
    let url = try file(bytes: original)
    let before = try identity(url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 3)
    try handle.write(contentsOf: Data("X".utf8))
    try handle.close()
    XCTAssertEqual(try identity(url), before)
    XCTAssertEqual(
      try observe(url, expected: original, identity: before).content, .differsFromBaseline)
    XCTAssertEqual(try Data(contentsOf: url), Data("abcXef\n".utf8))
  }

  func testMissingIsNotEmptyOrUnchanged() throws {
    let url = directory.appendingPathComponent("missing.txt")
    let result = try observe(url, expected: Data())
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .missing)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testFinalSymlinkIsRefusedWithoutFollowingOrChangingTarget() throws {
    let bytes = Data("target stays untouched\n".utf8)
    let target = try file("target.txt", bytes: bytes)
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let result = try observe(link, expected: bytes)
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .symbolicLink)
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
  }

  func testFIFOIsRefusedWithoutWaitingForWriter() throws {
    let fifo = directory.appendingPathComponent("pipe")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let result = try observe(fifo, expected: Data())
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .nonregular)
  }

  func testReadOnlyModeDoesNotHideContentChangeOrModifyPermissions() throws {
    let external = Data("external\n".utf8)
    let url = try file(bytes: external)
    XCTAssertEqual(chmod(url.path, 0o444), 0)
    defer { _ = chmod(url.path, 0o600) }
    let result = try observe(url, expected: Data("original\n".utf8))
    XCTAssertEqual(result.content, .differsFromBaseline)
    XCTAssertTrue(result.readOnlyHint)
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o444)
    XCTAssertEqual(try Data(contentsOf: url), external)
  }

  func testOversizedSparseFileIsExplicitlyRefused() throws {
    let url = try file(bytes: Data())
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 100_000_001)
    try handle.close()
    let result = try observe(url, expected: Data())
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .tooLarge)
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    XCTAssertEqual(info.st_size, 100_000_001)
  }

  func testCancelledObservationDoesNotReportAnUnchangedFile() throws {
    let bytes = Data("cancelled\n".utf8)
    let url = try file(bytes: bytes)
    XCTAssertThrowsError(
      try probe.observe(
        url, expected: bytes, boundIdentity: nil,
        forceContents: true, previous: nil, isCancelled: { true })
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testReadRejectsReplacementAfterOfferedObservation() throws {
    let bytes = Data("before\n".utf8)
    let url = try file(bytes: bytes)
    let offered = try observe(url, expected: bytes)
    XCTAssertEqual(offered.content, .matchesBaseline)
    try Data("after!\n".utf8).write(to: url, options: .atomic)
    XCTAssertThrowsError(try probe.read(url, matching: offered, isCancelled: { false })) { error in
      XCTAssertEqual(error as? ExternalFileProbeError, .observationChanged)
    }
    XCTAssertEqual(try Data(contentsOf: url), Data("after!\n".utf8))
  }
  func testAdmittedReadReturnsExactOpaqueBytes() throws {
    let bytes = Data([0xEF, 0xBB, 0xBF, 0, 0xC3, 0xA9, 13, 10, 0x81])
    let url = try file(bytes: bytes)
    let offered = try observe(url, expected: bytes)
    let admitted = try? probe.read(url, matching: offered, isCancelled: { false })
    XCTAssertEqual(
      admitted?.bytes, bytes, "A stable offered observation must admit an exact bounded read")
    XCTAssertEqual(admitted?.observation.metadata, offered.metadata)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testPartialReadsAndEINTRStillCompareEveryByte() throws {
    let bytes = Data("0123456789abcdef\r\n".utf8)
    let url = try file(bytes: bytes)
    let calls = LockedCounter()
    var hooks = ProbeHooks()
    hooks.read = { descriptor, buffer, count in
      if calls.next() == 1 {
        errno = EINTR
        return -1
      }
      return Darwin.read(descriptor, buffer, min(3, count))
    }
    let observed = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(observed.content, .matchesBaseline)
    XCTAssertGreaterThan(calls.value, 3)
  }

  func testPrematureEOFIsNotAByteMatch() throws {
    let bytes = Data("not empty".utf8)
    let url = try file(bytes: bytes)
    var hooks = ProbeHooks()
    hooks.read = { _, _, _ in 0 }
    let observed = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(observed.content, .unavailable)
    XCTAssertEqual(observed.locationProblem, .changedDuringRead)
  }

  func testCancellationBetweenChunksDoesNotPublishResult() throws {
    let bytes = Data(repeating: 0x41, count: 65_537)
    let url = try file(bytes: bytes)
    let calls = LockedCounter()
    var hooks = ProbeHooks()
    hooks.read = { descriptor, buffer, count in
      let result = Darwin.read(descriptor, buffer, count)
      _ = calls.next()
      return result
    }
    XCTAssertThrowsError(
      try ExternalFileProbe(hooks: hooks).observe(
        url, expected: bytes,
        boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { calls.value > 0 })
    ) {
      XCTAssertTrue($0 is CancellationError)
    }
  }

  func testPathReplacementAtFinalValidationIsUnavailable() throws {
    let bytes = Data("original".utf8)
    let url = try file(bytes: bytes)
    var hooks = ProbeHooks()
    hooks.boundary = { boundary in
      if case .beforeRevalidate = boundary {
        try Data("replaced".utf8).write(to: url, options: .atomic)
      }
    }
    let observed = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(observed.content, .unavailable)
    XCTAssertEqual(observed.locationProblem, .changedDuringRead)
    XCTAssertEqual(try Data(contentsOf: url), Data("replaced".utf8))
  }

  func testParentSymlinkRetargetIsNotAdopted() throws {
    let left = directory.appendingPathComponent("left")
    let right = directory.appendingPathComponent("right")
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
    let bytes = Data("same".utf8)
    try bytes.write(to: left.appendingPathComponent("document.txt"))
    try bytes.write(to: right.appendingPathComponent("document.txt"))
    let link = directory.appendingPathComponent("parent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: left)
    let url = link.appendingPathComponent("document.txt")
    let accepted = try observe(url, expected: bytes)
    XCTAssertEqual(accepted.content, .matchesBaseline)
    let bound = try XCTUnwrap(accepted.metadata?.identity)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: right)
    let retargeted = try observe(url, expected: bytes, identity: bound)
    XCTAssertEqual(retargeted.content, .unavailable)
    XCTAssertEqual(retargeted.locationProblem, .parentChanged)
  }

  func testMetadataFastPathDoesNotReuseObservationForAnotherBaseline() throws {
    let bytes = Data("saved".utf8)
    let url = try file(bytes: bytes)
    let original = try observe(url, expected: bytes)
    let changed = try probe.observe(
      url, expected: Data("other".utf8),
      boundIdentity: original.metadata?.identity, forceContents: false, previous: original,
      isCancelled: { false })
    XCTAssertEqual(changed.content, .differsFromBaseline)
  }

  func testUnsupportedVolumePolicyReturnsExplicitUnavailable() throws {
    let bytes = Data("volume policy".utf8)
    let url = try file(bytes: bytes)
    var hooks = ProbeHooks()
    hooks.isLocalVolume = { _ in false }
    let result = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .unsupportedVolume)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testExactMaximumSizeIsAcceptedByObserveAndRead() throws {
    let url = try file(bytes: Data())
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 100_000_000)
    try handle.close()
    let bytes = Data(repeating: 0, count: 100_000_000)
    let observation = try observe(url, expected: bytes)
    XCTAssertEqual(observation.content, .matchesBaseline)
    let read = try probe.read(url, matching: observation, isCancelled: { false })
    XCTAssertEqual(read.bytes.count, 100_000_000)
    XCTAssertEqual(read.bytes, bytes)
  }

  func testParentRetargetDuringReadRejectsResult() throws {
    let left = directory.appendingPathComponent("original")
    let right = directory.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
    let bytes = Data("same".utf8)
    try bytes.write(to: left.appendingPathComponent("document.txt"))
    try bytes.write(to: right.appendingPathComponent("document.txt"))
    let link = directory.appendingPathComponent("parent-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: left)
    let url = link.appendingPathComponent("document.txt")
    var hooks = ProbeHooks()
    hooks.boundary = { boundary in
      if case .afterOpen = boundary {
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: right)
      }
    }
    let observation = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(observation.content, .unavailable)
    XCTAssertEqual(observation.locationProblem, .parentChanged)
  }

  func testAdmittedReadRejectsLateAtomicReplacement() throws {
    let bytes = Data("before!".utf8)
    let url = try file(bytes: bytes)
    let offered = try observe(url, expected: bytes)
    var hooks = ProbeHooks()
    hooks.boundary = { boundary in
      if case .beforeRevalidate = boundary {
        try Data("after!!".utf8).write(to: url, options: .atomic)
      }
    }
    XCTAssertThrowsError(
      try ExternalFileProbe(hooks: hooks).read(
        url, matching: offered,
        isCancelled: { false })
    ) {
      XCTAssertEqual($0 as? ExternalFileProbeError, .observationChanged)
    }
    XCTAssertEqual(try Data(contentsOf: url), Data("after!!".utf8))
  }

  func testParentAccessRevocationDuringRevalidationIsInaccessible() throws {
    if geteuid() == 0 { throw XCTSkip("Root bypasses mode denial; real fixture requires nonroot") }
    for stage in [ProbeBoundary.beforeRevalidate, .beforeParentReopen] {
      let parent = directory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      defer { _ = chmod(parent.path, 0o700) }
      let url = parent.appendingPathComponent("document.txt")
      let bytes = Data("original bytes".utf8)
      try bytes.write(to: url)
      var hooks = ProbeHooks()
      hooks.boundary = { boundary in
        if boundary == stage, chmod(parent.path, 0) != 0 {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
      }
      let result = try ExternalFileProbe(hooks: hooks).observe(
        url, expected: bytes,
        boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
      XCTAssertEqual(result.content, .unavailable)
      XCTAssertEqual(
        result.locationProblem, .inaccessible,
        "Permission revocation must not be diagnosed as a moved/changed parent")
      XCTAssertEqual(chmod(parent.path, 0o700), 0)
      XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
  }

  func testSignedDeviceIdentityPreservesHighBitWithoutTrapping() {
    var info = stat()
    info.st_dev = Int32.min
    XCTAssertEqual(probeDeviceIdentifier(info.st_dev), 2_147_483_648)
    info.st_dev = -1
    XCTAssertEqual(probeDeviceIdentifier(info.st_dev), 4_294_967_295)
    info.st_dev = Int32.max
    XCTAssertEqual(probeDeviceIdentifier(info.st_dev), 2_147_483_647)
  }

  func testUnreadableModeIsNotMissingAndDoesNotChangeMode() throws {
    if geteuid() == 0 {
      throw XCTSkip("Root bypasses mode denial; this real permission case requires nonroot")
    }
    let bytes = Data("private fixture".utf8)
    let url = try file(bytes: bytes)
    XCTAssertEqual(chmod(url.path, 0), 0)
    defer { _ = chmod(url.path, 0o600) }
    let result = try observe(url, expected: bytes)
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .inaccessible)
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0)
  }

  func testReadErrorClosesOpenedDescriptorsAndPreservesBytes() throws {
    let descriptors: @Sendable () -> Set<Int32> = {
      Set((0..<512).map(Int32.init).filter { fcntl($0, F_GETFD) >= 0 })
    }
    let bytes = Data("error leaves bytes intact".utf8)
    let url = try file(bytes: bytes)
    let before = descriptors()
    let opened = LockedDescriptors()
    var hooks = ProbeHooks()
    hooks.boundary = { boundary in
      if case .afterOpen = boundary { opened.set(descriptors().subtracting(before)) }
    }
    hooks.read = { _, _, _ in
      errno = EIO
      return -1
    }
    XCTAssertThrowsError(
      try ExternalFileProbe(hooks: hooks).observe(
        url, expected: bytes,
        boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    ) {
      XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
      XCTAssertEqual(($0 as NSError).code, Int(EIO))
    }
    XCTAssertEqual(opened.value.count, 2)
    for descriptor in opened.value { XCTAssertEqual(fcntl(descriptor, F_GETFD), -1) }
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testReadErrorNeverReturnsPartialData() throws {
    let bytes = Data(repeating: 0x61, count: 65_537)
    let url = try file(bytes: bytes)
    let offered = try observe(url, expected: bytes)
    let calls = LockedCounter()
    var hooks = ProbeHooks()
    hooks.read = { descriptor, buffer, count in
      if calls.next() > 1 {
        errno = EIO
        return -1
      }
      return Darwin.read(descriptor, buffer, count)
    }
    XCTAssertThrowsError(
      try ExternalFileProbe(hooks: hooks).read(
        url, matching: offered,
        isCancelled: { false })
    ) { XCTAssertEqual(($0 as NSError).code, Int(EIO)) }
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testExpiredCooperativeDeadlineIsExplicitlyDelayed() throws {
    let bytes = Data("deadline".utf8)
    let url = try file(bytes: bytes)
    let ticks = LockedCounter()
    var hooks = ProbeHooks()
    hooks.clock = { TimeInterval(ticks.next()) }
    let result = try ExternalFileProbe(hooks: hooks).observe(
      url, expected: bytes,
      boundIdentity: nil, forceContents: true, previous: nil, isCancelled: { false })
    XCTAssertEqual(result.content, .unavailable)
    XCTAssertEqual(result.locationProblem, .checkDelayed)
  }

  func testParentRenameAndRecreationDoesNotRebindEqualBytes() throws {
    let parent = directory.appendingPathComponent("parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let url = parent.appendingPathComponent("document.txt")
    let bytes = Data("same".utf8)
    try bytes.write(to: url)
    let accepted = try observe(url, expected: bytes)
    let old = try XCTUnwrap(accepted.metadata?.identity)
    try FileManager.default.moveItem(at: parent, to: directory.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try bytes.write(to: url)
    let result = try observe(url, expected: bytes, identity: old)
    XCTAssertEqual(result.locationProblem, .parentChanged)
    XCTAssertEqual(result.content, .unavailable)
  }

  func testRestoredModificationTimeDoesNotHideForcedByteComparison() throws {
    let bytes = Data("before".utf8)
    let url = try file(bytes: bytes)
    let accepted = try observe(url, expected: bytes)
    var before = stat()
    XCTAssertEqual(stat(url.path, &before), 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data("after!".utf8))
    try handle.close()
    let times = [before.st_atimespec, before.st_mtimespec]
    XCTAssertEqual(
      times.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress!, 0) }, 0)
    var after = stat()
    XCTAssertEqual(stat(url.path, &after), 0)
    XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
    XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
    let result = try probe.observe(
      url, expected: bytes, boundIdentity: accepted.metadata?.identity,
      forceContents: true, previous: accepted, isCancelled: { false })
    XCTAssertEqual(result.content, .differsFromBaseline)
  }
}

private final class LockedDescriptors: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptors: Set<Int32> = []
  var value: Set<Int32> {
    lock.lock()
    defer { lock.unlock() }
    return descriptors
  }
  func set(_ value: Set<Int32>) {
    lock.lock()
    defer { lock.unlock() }
    descriptors = value
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}
