import Darwin
import Foundation
import XCTest

@testable import PadSearchWorkerRuntime

final class SearchWorkerBlockingChannelTests: XCTestCase {
  func testInitializationProtectsOnlyOutputBeforeIO() throws {
    let io = ScriptedWorkerIO()
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    XCTAssertEqual(io.protectedFDs, [202])
    XCTAssertTrue(io.readFDs.isEmpty)
    XCTAssertTrue(io.writeFDs.isEmpty)
    withExtendedLifetime(channel) {}
  }

  func testInvalidDescriptorsRefuseBeforeProtectionOrIO() {
    for (input, output) in [(-1, 202), (101, -1), (101, 101)] as [(Int32, Int32)] {
      let io = ScriptedWorkerIO()
      assertFailure(EINVAL) {
        _ = try SearchWorkerFDChannel(inputFD: input, outputFD: output, system: io.system)
      }
      XCTAssertTrue(io.protectedFDs.isEmpty)
      XCTAssertTrue(io.readFDs.isEmpty)
      XCTAssertTrue(io.writeFDs.isEmpty)
    }
  }

  func testProtectionFailureRefusesConstruction() {
    let io = ScriptedWorkerIO()
    io.protection = .failure(SearchWorkerIOFailure(code: ENOTSUP))
    assertFailure(ENOTSUP) {
      _ = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    }
    XCTAssertEqual(io.protectedFDs, [202])
    XCTAssertTrue(io.readFDs.isEmpty)
    XCTAssertTrue(io.writeFDs.isEmpty)
  }

  func testReadReturnsOnlyBytesActuallyRead() throws {
    let io = ScriptedWorkerIO()
    io.readSteps = [.bytes([0, 65, 255]), .bytes([66]), .count(0)]
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    XCTAssertEqual(try channel.read(maxBytes: 8), Data([0, 65, 255]))
    XCTAssertEqual(try channel.read(maxBytes: 1), Data([66]))
    XCTAssertEqual(try channel.read(maxBytes: 65_568), Data())
    XCTAssertEqual(io.readFDs, [101, 101, 101])
    XCTAssertEqual(io.readCapacities, [8, 1, 65_568])
  }

  func testReadRetriesEINTRWithoutReportingFalseEOF() throws {
    let io = ScriptedWorkerIO()
    io.readSteps = [.failure(EINTR), .failure(EINTR), .bytes([7])]
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    XCTAssertEqual(try channel.read(maxBytes: 3), Data([7]))
    XCTAssertEqual(io.readCapacities, [3, 3, 3])
  }

  func testReadErrorsPreserveCodeWithoutRetry() throws {
    for code in [EIO, EBADF, EAGAIN] {
      let io = ScriptedWorkerIO()
      io.readSteps = [.failure(code), .bytes([7])]
      let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
      assertFailure(code) { _ = try channel.read(maxBytes: 8) }
      XCTAssertEqual(io.readFDs, [101])
    }
  }

  func testInvalidReadBoundsNeverInvokeIO() throws {
    let io = ScriptedWorkerIO()
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    for size in [Int.min, -1, 0, 65_569, Int.max] {
      assertFailure(EINVAL) { _ = try channel.read(maxBytes: size) }
    }
    XCTAssertTrue(io.readFDs.isEmpty)
  }

  func testImpossibleReadCountsFailClosed() throws {
    for count in [-1, 5] {
      let io = ScriptedWorkerIO()
      io.readSteps = [.count(count)]
      let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
      assertFailure(EIO) { _ = try channel.read(maxBytes: 4) }
      XCTAssertEqual(io.readCapacities, [4])
    }
  }

  func testWriteAdvancesExactlyAcrossShortWritesAndEINTR() throws {
    let io = ScriptedWorkerIO()
    io.writeSteps = [
      .failure(SearchWorkerIOFailure(code: EINTR)), .success(2),
      .failure(SearchWorkerIOFailure(code: EINTR)), .success(1), .success(2),
    ]
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    try channel.write(Data([0, 1, 2, 3, 255]))
    XCTAssertEqual(io.writeFDs, [202, 202, 202, 202, 202])
    XCTAssertEqual(
      io.writeBuffers,
      [
        Data([0, 1, 2, 3, 255]), Data([0, 1, 2, 3, 255]),
        Data([2, 3, 255]), Data([2, 3, 255]), Data([3, 255]),
      ])
  }

  func testWriteAcceptsExactMaximum() throws {
    let io = ScriptedWorkerIO()
    let payload = Data(repeating: 42, count: 65_536)
    io.writeSteps = [.success(65_536)]
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    try channel.write(payload)
    XCTAssertEqual(io.writeBuffers, [payload])
  }

  func testWriteAcceptsOneByte() throws {
    let io = ScriptedWorkerIO()
    io.writeSteps = [.success(1)]
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    try channel.write(Data([9]))
    XCTAssertEqual(io.writeBuffers, [Data([9])])
  }

  func testInvalidWriteBoundsNeverInvokeIO() throws {
    let io = ScriptedWorkerIO()
    let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
    for bytes in [Data(), Data(repeating: 0, count: 65_537)] {
      assertFailure(EINVAL) { try channel.write(bytes) }
    }
    XCTAssertTrue(io.writeFDs.isEmpty)
  }

  func testZeroAndImpossibleWriteCountsFailClosed() throws {
    for count in [-1, 0, 3] {
      let io = ScriptedWorkerIO()
      io.writeSteps = [.success(count), .success(2)]
      let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
      assertFailure(EIO) { try channel.write(Data([1, 2])) }
      XCTAssertEqual(io.writeBuffers, [Data([1, 2])])
    }
  }

  func testWriteErrorsIncludingEPIPEPreserveCodeWithoutRetry() throws {
    for code in [EPIPE, EBADF, EAGAIN] {
      let io = ScriptedWorkerIO()
      io.writeSteps = [.success(1), .failure(SearchWorkerIOFailure(code: code)), .success(1)]
      let channel = try SearchWorkerFDChannel(inputFD: 101, outputFD: 202, system: io.system)
      assertFailure(code) { try channel.write(Data([1, 2])) }
      XCTAssertEqual(io.writeBuffers, [Data([1, 2]), Data([2])])
    }
  }

  private func assertFailure(
    _ code: Int32, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual(
        $0 as? SearchWorkerIOFailure, SearchWorkerIOFailure(code: code), file: file, line: line)
    }
  }
}

private final class ScriptedWorkerIO {
  enum ReadStep {
    case bytes([UInt8])
    case count(Int)
    case failure(Int32)
  }
  var protection: Result<Void, SearchWorkerIOFailure> = .success(())
  var readSteps: [ReadStep] = []
  var writeSteps: [Result<Int, SearchWorkerIOFailure>] = []
  var protectedFDs: [Int32] = []
  var readFDs: [Int32] = []
  var readCapacities: [Int] = []
  var writeFDs: [Int32] = []
  var writeBuffers: [Data] = []

  var system: SearchWorkerIOSystem {
    SearchWorkerIOSystem(
      setNoSigPipe: { fd in
        self.protectedFDs.append(fd)
        return self.protection
      },
      read: { fd, buffer in
        self.readFDs.append(fd)
        self.readCapacities.append(buffer.count)
        guard !self.readSteps.isEmpty else {
          XCTFail("Unexpected read beyond script")
          return .failure(SearchWorkerIOFailure(code: EIO))
        }
        switch self.readSteps.removeFirst() {
        case .bytes(let bytes):
          guard bytes.count <= buffer.count else {
            XCTFail("Invalid fixture exceeds read buffer")
            return .failure(SearchWorkerIOFailure(code: EIO))
          }
          buffer.copyBytes(from: bytes)
          return .success(bytes.count)
        case .count(let count): return .success(count)
        case .failure(let code): return .failure(SearchWorkerIOFailure(code: code))
        }
      },
      write: { fd, buffer in
        self.writeFDs.append(fd)
        self.writeBuffers.append(Data(buffer))
        guard !self.writeSteps.isEmpty else {
          XCTFail("Unexpected write beyond script")
          return .failure(SearchWorkerIOFailure(code: EIO))
        }
        return self.writeSteps.removeFirst()
      })
  }
}
