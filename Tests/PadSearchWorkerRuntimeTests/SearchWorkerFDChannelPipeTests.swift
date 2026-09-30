import Darwin
import Foundation
import XCTest

@testable import PadSearchWorkerRuntime

/// Small prefilled pipes only. Run under the owned-process watchdog.
final class SearchWorkerFDChannelPipeTests: XCTestCase {
  func testExactInputFragmentationAndRealEOF() throws {
    let input = try OwnedWorkerPipe()
    let output = try OwnedWorkerPipe()
    let channel = try SearchWorkerFDChannel(
      inputFD: input.readFD, outputFD: output.writeFD, system: .darwin)
    let payload = Data((0..<256).map(UInt8.init))
    try input.seed(payload)
    try input.closeWriter()
    var received = Data()
    for _ in 0..<256 {
      let piece = try channel.read(maxBytes: 7)
      if piece.isEmpty { break }
      XCTAssertLessThanOrEqual(piece.count, 7)
      received.append(piece)
    }
    XCTAssertEqual(received, payload)
    XCTAssertTrue(try channel.read(maxBytes: 1).isEmpty)
    XCTAssertEqual(fcntl(input.readFD, F_GETFL) & O_NONBLOCK, 0)
    try input.closeRemaining()
    try output.closeRemaining()
  }

  func testExactOutputAndBorrowedDescriptorsOutliveChannel() throws {
    let input = try OwnedWorkerPipe()
    let output = try OwnedWorkerPipe()
    var channel: SearchWorkerFDChannel? = try SearchWorkerFDChannel(
      inputFD: input.readFD, outputFD: output.writeFD, system: .darwin)
    weak var released: SearchWorkerFDChannel?
    released = channel
    let payload = Data([0, 255, 13, 10, 0xF0, 0x9F, 0x98, 0x80])
    try channel!.write(payload)
    channel = nil
    XCTAssertNil(released)
    XCTAssertNotEqual(fcntl(input.readFD, F_GETFD), -1)
    XCTAssertNotEqual(fcntl(output.writeFD, F_GETFD), -1)
    XCTAssertEqual(fcntl(output.writeFD, F_GETFL) & O_NONBLOCK, 0)
    try output.closeWriter()
    XCTAssertEqual(try output.drain(maximum: 256), payload)
    try input.closeRemaining()
    try output.closeRemaining()
  }

  func testEPIPEUsesPerDescriptorSuppressionAndLeavesSIGPIPEUnchanged() throws {
    let before = try WorkerSignalDisposition.read()
    // An ignored process-wide signal would not prove the production FD policy.
    XCTAssertEqual(before.handler, 0)
    guard before.handler == 0 else { throw WorkerPipeFailure.unsupportedSignalDisposition }
    let input = try OwnedWorkerPipe()
    let output = try OwnedWorkerPipe()
    let channel = try SearchWorkerFDChannel(
      inputFD: input.readFD, outputFD: output.writeFD, system: .darwin)
    XCTAssertEqual(fcntl(output.writeFD, F_GETNOSIGPIPE), 1)
    XCTAssertEqual(try WorkerSignalDisposition.read(), before)
    try output.closeReader()
    XCTAssertThrowsError(try channel.write(Data([1]))) { error in
      XCTAssertEqual(error as? SearchWorkerIOFailure, SearchWorkerIOFailure(code: EPIPE))
    }
    XCTAssertEqual(try WorkerSignalDisposition.read(), before)
    XCTAssertNotEqual(fcntl(output.writeFD, F_GETFD), -1)
    try input.closeRemaining()
    try output.closeRemaining()
  }

  func testOutOfRangeOutputRefusesConstructionWithoutClosingBorrowedInput() throws {
    let input = try OwnedWorkerPipe()
    // No close/reuse race: this descriptor is absent and above the current allocation limit.
    var limit = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
    guard UInt64(Int32.max) > limit.rlim_cur else {
      throw WorkerPipeFailure.unexpectedCount
    }
    let absent = fcntl(Int32.max, F_GETFD)
    let absenceError = errno
    XCTAssertEqual(absent, -1)
    XCTAssertEqual(absenceError, EBADF)
    guard absent == -1, absenceError == EBADF else { throw WorkerPipeFailure.unexpectedCount }
    XCTAssertThrowsError(
      try SearchWorkerFDChannel(inputFD: input.readFD, outputFD: Int32.max, system: .darwin)
    ) { error in
      XCTAssertEqual(error as? SearchWorkerIOFailure, SearchWorkerIOFailure(code: EBADF))
    }
    XCTAssertNotEqual(fcntl(input.readFD, F_GETFD), -1)
    try input.closeRemaining()
  }
}

private enum WorkerPipeFailure: Error {
  case syscall(Int32)
  case unexpectedCount
  case unsupportedSignalDisposition
}

private struct WorkerSignalDisposition: Equatable {
  let handler: UInt
  let flags: Int32
  let mask: sigset_t

  static func read() throws -> Self {
    var value = sigaction()
    let (status, error) = withUnsafeMutablePointer(to: &value) {
      let status = sigaction(SIGPIPE, nil, $0)
      return (status, status < 0 ? errno : 0)
    }
    guard status == 0 else { throw WorkerPipeFailure.syscall(error) }
    return Self(
      handler: unsafeBitCast(value.__sigaction_u.__sa_handler, to: UInt.self),
      flags: value.sa_flags, mask: value.sa_mask)
  }
}

private final class OwnedWorkerPipe {
  private(set) var readFD: Int32
  private(set) var writeFD: Int32

  init() throws {
    var pair: [Int32] = [-1, -1]
    guard Darwin.pipe(&pair) == 0 else { throw WorkerPipeFailure.syscall(errno) }
    readFD = pair[0]
    writeFD = pair[1]
  }

  deinit {
    if readFD >= 0 { _ = Darwin.close(readFD) }
    if writeFD >= 0 { _ = Darwin.close(writeFD) }
  }

  func closeRemaining() throws {
    if readFD >= 0 { try closeReader() }
    if writeFD >= 0 { try closeWriter() }
  }

  func closeReader() throws { try Self.closeOwned(&readFD) }
  func closeWriter() throws { try Self.closeOwned(&writeFD) }

  private static func closeOwned(_ owned: inout Int32) throws {
    let descriptor = owned
    guard descriptor >= 0 else { throw WorkerPipeFailure.unexpectedCount }
    owned = -1
    guard Darwin.close(descriptor) == 0 else { throw WorkerPipeFailure.syscall(errno) }
  }

  func seed(_ bytes: Data) throws {
    guard (1...256).contains(bytes.count) else { throw WorkerPipeFailure.unexpectedCount }
    let (count, error) = bytes.withUnsafeBytes {
      let count = Darwin.write(writeFD, $0.baseAddress, $0.count)
      return (count, count < 0 ? errno : 0)
    }
    guard count == bytes.count else {
      throw count < 0 ? WorkerPipeFailure.syscall(error) : WorkerPipeFailure.unexpectedCount
    }
  }

  func drain(maximum: Int) throws -> Data {
    guard writeFD == -1, maximum == 256 else { throw WorkerPipeFailure.unexpectedCount }
    var result = Data()
    for _ in 0...maximum {
      var byte: UInt8 = 0
      let count = Darwin.read(readFD, &byte, 1)
      if count == 0 { return result }
      if count < 0 { throw WorkerPipeFailure.syscall(errno) }
      guard result.count < maximum else { throw WorkerPipeFailure.unexpectedCount }
      result.append(byte)
    }
    throw WorkerPipeFailure.unexpectedCount
  }
}
