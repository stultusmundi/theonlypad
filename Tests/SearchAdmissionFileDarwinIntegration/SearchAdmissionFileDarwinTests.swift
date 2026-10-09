import Darwin
import XCTest

@testable import SearchExecution

final class SearchAdmissionFileDarwinTests: XCTestCase {
  private func assertCleanup(
    _ report: DarwinFixtureCleanup, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(report.errors, [], file: file, line: line)
    XCTAssertEqual(report.violations, [], file: file, line: line)
    XCTAssertTrue(
      report.uncertainCloses.isEmpty, "\(report.uncertainCloses)", file: file, line: line)
    XCTAssertEqual(report.remainingOwned, 0, file: file, line: line)
  }

  private func opened(
    _ result: SearchAdmissionFileOpenResult, file: StaticString = #filePath, line: UInt = #line
  ) throws -> SearchAdmissionFileDescriptor {
    guard case .opened(let fd) = result else {
      XCTFail("Expected a genuine synthetic-file open", file: file, line: line)
      throw DarwinFixtureFailure.unexpectedResult
    }
    return fd
  }

  private func sampled(
    _ result: SearchAdmissionFileSampleResult, file: StaticString = #filePath, line: UInt = #line
  ) throws -> SearchAdmissionFileSample {
    guard case .sampled(let sample) = result else {
      XCTFail("Expected concrete sampled metadata", file: file, line: line)
      throw DarwinFixtureFailure.unexpectedResult
    }
    return sample
  }

  private func assertSample(
    _ sample: SearchAdmissionFileSample, equals raw: stat,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // Independent field comparisons; do not call the candidate normalization helper.
    XCTAssertEqual(
      sample.identity.device, UInt64(UInt32(bitPattern: raw.st_dev)), file: file, line: line)
    XCTAssertEqual(sample.identity.inode, UInt64(raw.st_ino), file: file, line: line)
    XCTAssertEqual(sample.identity.size, Int64(raw.st_size), file: file, line: line)
    XCTAssertEqual(
      sample.identity.modifiedSeconds, Int64(raw.st_mtimespec.tv_sec), file: file, line: line)
    XCTAssertEqual(
      sample.identity.modifiedNanoseconds, Int64(raw.st_mtimespec.tv_nsec), file: file, line: line)
    XCTAssertEqual(
      sample.identity.changedSeconds, Int64(raw.st_ctimespec.tv_sec), file: file, line: line)
    XCTAssertEqual(
      sample.identity.changedNanoseconds, Int64(raw.st_ctimespec.tv_nsec), file: file, line: line)
    XCTAssertEqual(sample.isRegular, raw.st_mode & S_IFMT == S_IFREG, file: file, line: line)
  }

  private func assertClosed(
    _ result: SearchAdmissionFileCloseResult, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .closed = result else {
      XCTFail("Concrete once-close did not return closed", file: file, line: line)
      return
    }
  }

  private func assertBodyClosed(
    _ fixture: DarwinFileFixture, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(fixture.opened.count, 1, file: file, line: line)
    XCTAssertEqual(fixture.openAttempts, 1, file: file, line: line)
    XCTAssertEqual(fixture.closeAttempts, 1, file: file, line: line)
    XCTAssertEqual(fixture.closeResults.count, 1, file: file, line: line)
    XCTAssertEqual(fixture.liveReaderCount, 0, file: file, line: line)
    XCTAssertTrue(fixture.uncertainCloses.isEmpty, file: file, line: line)
    XCTAssertEqual(fixture.violations, [], file: file, line: line)
  }

  private func assertBytes(
    _ result: SearchAdmissionFileReadResult, _ count: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .bytes(let actual) = result else {
      XCTFail("Expected a genuine bounded pread byte count", file: file, line: line)
      return
    }
    XCTAssertEqual(actual, count, file: file, line: line)
  }

  func testRegularUnicodeFileMatchesDescriptorAndPathMetadata() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .regular)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let fd = try opened(
      fixture.withPath(.payload) {
        io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
      })
    let descriptor = try sampled(io.sampleDescriptor(fd))
    let path = try sampled(fixture.withPath(.payload) { io.samplePath($0) })
    let rawDescriptor = try fixture.rawDescriptor(fd)
    let rawPath = try fixture.rawPath(.payload)
    assertSample(descriptor, equals: rawDescriptor)
    assertSample(path, equals: rawPath)
    XCTAssertEqual(descriptor.identity, path.identity)
    XCTAssertEqual(descriptor.identity.size, 9)
    XCTAssertTrue(descriptor.isRegular)
    XCTAssertTrue(path.isRegular)
    assertClosed(io.closeOnce(fd))
    XCTAssertEqual(fixture.calls, [.open, .descriptor, .path, .close])
    assertBodyClosed(fixture)
  }

  func testOpenFlagsAreReadOnlyNonblockingAndCloseOnExec() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .regular)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let fd = try opened(
      fixture.withPath(.payload) {
        io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
      })
    // Only a live, newly owned descriptor is queried; these are not closure probes.
    let status = Darwin.fcntl(fd.rawValue, F_GETFL)
    let descriptorFlags = Darwin.fcntl(fd.rawValue, F_GETFD)
    XCTAssertGreaterThanOrEqual(status, 0)
    XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
    XCTAssertEqual(status & O_ACCMODE, O_RDONLY)
    XCTAssertNotEqual(status & O_NONBLOCK, 0)
    XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
    assertClosed(io.closeOnce(fd))
    assertBodyClosed(fixture)
  }

  func testBoundedPreadPreservesOffsetsAndGuardBytes() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .regular)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let fd = try opened(
      fixture.withPath(.payload) {
        io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
      })
    let before = Darwin.lseek(fd.rawValue, 0, SEEK_CUR)
    XCTAssertEqual(before, 0)
    var guarded = [UInt8](repeating: 0xA5, count: 11)
    let first = guarded.withUnsafeMutableBufferPointer { storage in
      io.read(fd, into: .init(start: storage.baseAddress!.advanced(by: 4), count: 3), offset: 3)
    }
    assertBytes(first, 3)
    XCTAssertEqual(guarded, [0xA5, 0xA5, 0xA5, 0xA5, 0x41, 0xF0, 0x9F, 0xA5, 0xA5, 0xA5, 0xA5])
    XCTAssertEqual(Darwin.lseek(fd.rawValue, 0, SEEK_CUR), before)
    guarded = [UInt8](repeating: 0xA5, count: 11)
    let second = guarded.withUnsafeMutableBufferPointer { storage in
      io.read(fd, into: .init(start: storage.baseAddress!.advanced(by: 4), count: 2), offset: 7)
    }
    assertBytes(second, 2)
    XCTAssertEqual(guarded, [0xA5, 0xA5, 0xA5, 0xA5, 0x80, 0x42, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5])
    XCTAssertEqual(Darwin.lseek(fd.rawValue, 0, SEEK_CUR), before)
    guarded = [UInt8](repeating: 0xA5, count: 11)
    let end = guarded.withUnsafeMutableBufferPointer { storage in
      io.read(fd, into: .init(start: storage.baseAddress!.advanced(by: 4), count: 1), offset: 9)
    }
    assertBytes(end, 0)
    XCTAssertEqual(guarded, [0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5])
    XCTAssertEqual(Darwin.lseek(fd.rawValue, 0, SEEK_CUR), before)
    assertClosed(io.closeOnce(fd))
    XCTAssertEqual(
      fixture.calls,
      [
        .open, .read(offset: 3, count: 3), .read(offset: 7, count: 2),
        .read(offset: 9, count: 1), .close,
      ])
    assertBodyClosed(fixture)
  }

  func testMissingPathPreservesENOENTWithoutDescriptor() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .regular)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    io.seedErrno = EBUSY
    let result = try fixture.withPath(.missing) {
      io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
    }
    if case .failed(let saved) = result {
      XCTAssertEqual(saved, ENOENT)
    } else {
      XCTFail("Missing entry unexpectedly opened; genuine token remains owned for cleanup")
    }
    io.seedErrno = EBUSY
    let sample = try fixture.withPath(.missing) { io.samplePath($0) }
    if case .failed(let saved) = sample {
      XCTAssertEqual(saved, ENOENT)
    } else {
      XCTFail("Missing entry unexpectedly sampled")
    }
    XCTAssertEqual(fixture.opened.count, 0)
    XCTAssertEqual(fixture.liveReaderCount, 0)
    XCTAssertEqual(fixture.closeAttempts, 0)
    XCTAssertEqual(fixture.calls, [.open, .path])
    XCTAssertEqual(fixture.violations, [])
  }

  func testFinalSymlinkIsNotFollowed() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .symlink)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let sample = try sampled(fixture.withPath(.link) { io.samplePath($0) })
    assertSample(sample, equals: try fixture.rawPath(.link))
    XCTAssertFalse(sample.isRegular)
    let result = try fixture.withPath(.link) {
      io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
    }
    if case .failed(let saved) = result {
      XCTAssertEqual(saved, ELOOP)
    } else {
      XCTFail("Final symlink was followed; genuine unexpected open will be independently closed")
    }
    XCTAssertEqual(fixture.opened.count, 0)
    XCTAssertEqual(fixture.liveReaderCount, 0)
    XCTAssertEqual(fixture.closeAttempts, 0)
    XCTAssertEqual(fixture.calls, [.path, .open])
    XCTAssertEqual(fixture.violations, [])
  }

  func testFIFOOpensWithoutPeerAndSamplesNonregular() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .fifo)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let fd = try opened(
      fixture.withPath(.payload) {
        io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
      })
    let descriptor = try sampled(io.sampleDescriptor(fd))
    let path = try sampled(fixture.withPath(.payload) { io.samplePath($0) })
    XCTAssertFalse(descriptor.isRegular)
    XCTAssertFalse(path.isRegular)
    assertSample(descriptor, equals: try fixture.rawDescriptor(fd))
    assertSample(path, equals: try fixture.rawPath(.payload))
    let status = Darwin.fcntl(fd.rawValue, F_GETFL)
    XCTAssertGreaterThanOrEqual(status, 0)
    XCTAssertNotEqual(status & O_NONBLOCK, 0)
    assertClosed(io.closeOnce(fd))
    // No FIFO read, writer, peer, signal or timing assertion exists in this method.
    XCTAssertEqual(fixture.calls, [.open, .descriptor, .path, .close])
    assertBodyClosed(fixture)
  }

  func testObservedGrowthAboveAdmissionLimitRemainsSampleable() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .sparse)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let fd = try opened(
      fixture.withPath(.payload) {
        io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: $0)
      })
    let descriptor = try sampled(io.sampleDescriptor(fd))
    let path = try sampled(fixture.withPath(.payload) { io.samplePath($0) })
    XCTAssertEqual(descriptor.identity.size, 10_000_001)
    XCTAssertEqual(path.identity.size, 10_000_001)
    XCTAssertTrue(descriptor.isRegular)
    XCTAssertTrue(path.isRegular)
    assertSample(descriptor, equals: try fixture.rawDescriptor(fd))
    assertSample(path, equals: try fixture.rawPath(.payload))
    assertClosed(io.closeOnce(fd))
    assertBodyClosed(fixture)
  }

  func testReaderAndConcreteAdapterPreserveBOMAndSupplementaryText() throws {
    let fixture = DarwinFileFixture()
    defer { assertCleanup(fixture.cleanup()) }
    try fixture.setUp(root: DarwinFileFixture.selectedRoot(), kind: .regular)
    let raw = try fixture.rawPath(.payload)
    let identity = try SearchAdmissionFileIdentity(
      device: UInt64(UInt32(bitPattern: raw.st_dev)), inode: UInt64(raw.st_ino),
      size: Int64(raw.st_size),
      modifiedSeconds: Int64(raw.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(raw.st_mtimespec.tv_nsec),
      changedSeconds: Int64(raw.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(raw.st_ctimespec.tv_nsec))
    let input = try SearchAdmissionFileInput(
      path: fixture.path(.payload), identity: identity, windowBytes: 4)
    let bounds = try SearchAdmissionFileReadBounds(input: input)
    let io = ForwardingDarwinFileIO(fixture: fixture)
    let result = SearchAdmissionFileReader.read(
      input: input, bounds: bounds, io: io, cancelled: { false })
    XCTAssertEqual(result, .prepared(.init(text: "A😀B", inputUTF16: 4)))
    let scopeCalls = fixture.calls.filter {
      if case .read = $0 { return false }
      return true
    }
    XCTAssertEqual(
      scopeCalls, [.open, .descriptor, .path, .descriptor, .path, .descriptor, .path, .close])
    XCTAssertTrue(
      fixture.calls.contains {
        if case .read = $0 { return true }
        return false
      })
    var consumed = 0
    for observation in fixture.readResults {
      XCTAssertEqual(observation.offset, Int64(consumed))
      XCTAssertGreaterThan(observation.requested, 0)
      XCTAssertLessThanOrEqual(observation.requested, 4)
      let end = observation.offset.addingReportingOverflow(Int64(observation.requested))
      XCTAssertFalse(end.overflow)
      if !end.overflow { XCTAssertLessThanOrEqual(end.partialValue, 9) }
      if case .bytes(let actual) = observation.result {
        XCTAssertGreaterThan(actual, 0)
        XCTAssertLessThanOrEqual(actual, observation.requested)
        // Bound arithmetic even if a candidate violates the byte-count contract.
        if actual > 0, actual <= 9 - consumed { consumed += actual }
      } else {
        XCTFail("Concrete reader received an actual pread failure")
      }
    }
    XCTAssertEqual(consumed, 9)
    XCTAssertEqual(fixture.sampleResults.count, 6)
    assertBodyClosed(fixture)
    if let actualClose = fixture.closeResults.first { assertClosed(actualClose) }
  }

  func testNativeStatNormalizationPreservesBitsAndRejectsInvalidMetadata() throws {
    // Pure initialized stat values. No descriptor, file, setup or kernel observation.
    var raw = stat()
    raw.st_dev = Int32(bitPattern: 0x8000_0001)
    raw.st_ino = 0xF000_0000_0000_0001
    raw.st_size = 10_000_001
    raw.st_mtimespec.tv_sec = -7
    raw.st_mtimespec.tv_nsec = 0
    raw.st_ctimespec.tv_sec = -9
    raw.st_ctimespec.tv_nsec = 999_999_999
    raw.st_mode = mode_t(S_IFREG)
    let result = try sampled(SearchAdmissionFileDarwinIO.normalizedSample(raw))
    XCTAssertEqual(result.identity.device, 2_147_483_649)
    XCTAssertEqual(result.identity.inode, 0xF000_0000_0000_0001)
    XCTAssertEqual(result.identity.size, 10_000_001)
    XCTAssertEqual(result.identity.modifiedSeconds, -7)
    XCTAssertEqual(result.identity.modifiedNanoseconds, 0)
    XCTAssertEqual(result.identity.changedSeconds, -9)
    XCTAssertEqual(result.identity.changedNanoseconds, 999_999_999)
    XCTAssertTrue(result.isRegular)
    var invalidSize = raw
    invalidSize.st_size = -1
    var invalidModifiedLow = raw
    invalidModifiedLow.st_mtimespec.tv_nsec = -1
    var invalidModifiedHigh = raw
    invalidModifiedHigh.st_mtimespec.tv_nsec = 1_000_000_000
    var invalidChangedLow = raw
    invalidChangedLow.st_ctimespec.tv_nsec = -1
    var invalidChangedHigh = raw
    invalidChangedHigh.st_ctimespec.tv_nsec = 1_000_000_000
    for invalid in [
      invalidSize, invalidModifiedLow, invalidModifiedHigh, invalidChangedLow, invalidChangedHigh,
    ] {
      if case .invalidMetadata = SearchAdmissionFileDarwinIO.normalizedSample(invalid) {
        // Expected typed refusal; no invented native errno.
      } else {
        XCTFail("Invalid synthetic stat metadata was accepted")
      }
    }
    var fifo = raw
    fifo.st_mode = mode_t(S_IFIFO)
    let nonregular = try sampled(SearchAdmissionFileDarwinIO.normalizedSample(fifo))
    XCTAssertFalse(nonregular.isRegular)
    XCTAssertEqual(nonregular.identity, result.identity)
  }
}
