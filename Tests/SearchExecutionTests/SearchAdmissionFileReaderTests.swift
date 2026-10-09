import XCTest

@testable import SearchExecution

final class SearchAdmissionFileReaderTests: XCTestCase {
  private func input(size: Int64, window: Int) throws -> SearchAdmissionFileInput {
    try SearchAdmissionFileInput(
      path: readerFixturePath, identity: readerIdentity(size: size), windowBytes: window)
  }

  private func run(
    _ input: SearchAdmissionFileInput, _ io: FileReaderScript
  ) throws -> SearchAdmissionFileReturn {
    let bounds = try SearchAdmissionFileReadBounds(input: input)
    return SearchAdmissionFileReader.read(
      input: input, bounds: bounds, io: io, cancelled: { io.cancelled })
  }

  private func assertFinished(
    _ io: FileReaderScript, closes: Int = 1, quarantine: Set<Int32> = [],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(io.calls, io.expectedCalls, file: file, line: line)
    XCTAssertEqual(io.remainingSteps, 0, file: file, line: line)
    XCTAssertTrue(io.violations.isEmpty, "\(io.violations)", file: file, line: line)
    XCTAssertEqual(io.closeInvocationCount, closes, file: file, line: line)
    XCTAssertTrue(io.liveFakeTokens.isEmpty, file: file, line: line)
    XCTAssertEqual(io.quarantinedFakeTokens, quarantine, file: file, line: line)
  }

  private func assertInvalid(
    _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual(error as? SearchAdmissionFileFailure, .invalidBounds, file: file, line: line)
    }
  }

  func testMetadataAndReadBoundsRejectBeforeIO() throws {
    let identity = try readerIdentity(size: 1)
    for path in [
      "", "relative.txt", "/bad\0path", "/" + String(repeating: "a", count: 4096),
      "/" + String(repeating: "é", count: 2048),
    ] {
      assertInvalid { _ = try SearchAdmissionFileInput(path: path, identity: identity) }
    }
    for window in [0, 65_537] {
      assertInvalid {
        _ = try SearchAdmissionFileInput(
          path: readerFixturePath, identity: identity, windowBytes: window)
      }
    }
    assertInvalid { _ = try readerIdentity(size: -1) }
    let tooLarge = try readerIdentity(size: 10_000_001)
    assertInvalid { _ = try SearchAdmissionFileInput(path: readerFixturePath, identity: tooLarge) }
    for nanoseconds in [Int64(-1), 1_000_000_000] {
      assertInvalid { _ = try readerIdentity(size: 1, modifiedNanoseconds: nanoseconds) }
      assertInvalid { _ = try readerIdentity(size: 1, changedNanoseconds: nanoseconds) }
    }
    assertInvalid { _ = try SearchAdmissionFileDescriptor(rawValue: -1) }
    XCTAssertEqual(try SearchAdmissionFileDescriptor(rawValue: 0).rawValue, 0)
    let unusual = try readerIdentity(
      size: 0, device: 0, inode: 0, modifiedSeconds: -2, modifiedNanoseconds: 0,
      changedSeconds: -3, changedNanoseconds: 999_999_999)
    XCTAssertEqual(unusual.device, 0)
    XCTAssertEqual(unusual.inode, 0)
    XCTAssertEqual(unusual.modifiedSeconds, -2)
    XCTAssertEqual(unusual.changedSeconds, -3)
    XCTAssertEqual(unusual.modifiedNanoseconds, 0)
    XCTAssertEqual(unusual.changedNanoseconds, 999_999_999)
    let longestPath = "/" + String(repeating: "a", count: 4095)
    XCTAssertEqual(
      try SearchAdmissionFileInput(path: longestPath, identity: unusual).path, longestPath)
    let empty = try SearchAdmissionFileReadBounds(input: input(size: 0, window: 1))
    XCTAssertEqual(empty.inputBytes, 0)
    XCTAssertEqual(empty.inputUTF16, 0)
    XCTAssertEqual(empty.windowBytes, 1)
    XCTAssertEqual(empty.outputUTF8, 0)
    let largest = try SearchAdmissionFileReadBounds(input: input(size: 10_000_000, window: 65_536))
    XCTAssertEqual(largest.inputBytes, 10_000_000)
    XCTAssertEqual(largest.inputUTF16, 10_000_000)
    XCTAssertEqual(largest.windowBytes, 65_536)
    XCTAssertEqual(largest.outputUTF8, 30_000_000)
    let actual = try input(size: 3, window: 3)
    for other in [try input(size: 2, window: 3), try input(size: 3, window: 2)] {
      let bounds = try SearchAdmissionFileReadBounds(input: other)
      let io = FileReaderScript([])
      defer { io.disposeSyntheticState() }
      XCTAssertEqual(
        SearchAdmissionFileReader.read(input: actual, bounds: bounds, io: io, cancelled: { false }),
        .failed(.invalidBounds))
      assertFinished(io, closes: 0)
    }
  }

  func testShortReadsPreserveBOMAndSupplementaryText() throws {
    let source = try input(size: 9, window: 4)
    let io = FileReaderScript(
      try readerSuccessSteps(
        identity: source.identity,
        reads: [
          .read(offset: 0, count: 4, reply: .bytes([0xEF, 0xBB])),
          .read(offset: 2, count: 4, reply: .bytes([0xBF, 0x41, 0xF0, 0x9F])),
          .read(offset: 6, count: 3, reply: .bytes([0x98, 0x80, 0x42])),
        ]))
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .prepared(.init(text: "A😀B", inputUTF16: 4)))
    XCTAssertEqual(
      io.readCalls,
      [
        .read(fd: 40, offset: 0, count: 4), .read(fd: 40, offset: 2, count: 4),
        .read(fd: 40, offset: 6, count: 3),
      ])
    XCTAssertEqual(io.calls.count, 11)
    assertFinished(io)
  }

  func testEmptyInputStillChecksIdentityAndCloses() throws {
    let source = try input(size: 0, window: 1)
    let io = FileReaderScript(try readerSuccessSteps(identity: source.identity, reads: []))
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .prepared(.init(text: "", inputUTF16: 0)))
    XCTAssertEqual(
      io.calls,
      [
        .open(readerFixturePathBytes), .descriptor(40), .path(readerFixturePathBytes),
        .descriptor(40), .path(readerFixturePathBytes), .descriptor(40),
        .path(readerFixturePathBytes), .close(40),
      ])
    XCTAssertTrue(io.readCalls.isEmpty)
    assertFinished(io)
  }

  func testDeclaredEndDoesNotProbeExtraByte() throws {
    let source = try input(size: 3, window: 8)
    let io = FileReaderScript(
      try readerSuccessSteps(
        identity: source.identity,
        reads: [
          .read(offset: 0, count: 3, reply: .bytes([0x61, 0x62, 0x63]))
        ]))
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .prepared(.init(text: "abc", inputUTF16: 3)))
    XCTAssertEqual(io.readCalls, [.read(fd: 40, offset: 0, count: 3)])
    assertFinished(io)
  }

  func testEarlyEOFReturnsSourceChangedAndCloses() throws {
    let source = try input(size: 5, window: 4)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let io = FileReaderScript(
      [.open(.opened(fd))] + readerSamplePair(source.identity) + [
        .read(offset: 0, count: 4, reply: .bytes([0x61, 0x62])),
        .read(offset: 2, count: 3, reply: .bytes([])), .close(.closed),
      ])
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .failed(.sourceChanged))
    XCTAssertEqual(
      io.readCalls,
      [
        .read(fd: 40, offset: 0, count: 4), .read(fd: 40, offset: 2, count: 3),
      ])
    assertFinished(io)
  }

  func testInitialDescriptorPathMismatchPreventsRead() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let mismatches = [
      try readerIdentity(size: 3, inode: 12), try readerIdentity(size: 4),
      try readerIdentity(size: 10_000_001), try readerIdentity(size: 3, device: 8),
      try readerIdentity(size: 3, modifiedSeconds: 14),
      try readerIdentity(size: 3, modifiedNanoseconds: 18),
      try readerIdentity(size: 3, changedSeconds: 20),
      try readerIdentity(size: 3, changedNanoseconds: 24),
    ]
    for changed in mismatches {
      for descriptorFirst in [false, true] {
        let wrong = SearchAdmissionFileSampleResult.sampled(
          .init(identity: changed, isRegular: true))
        let good = SearchAdmissionFileSampleResult.sampled(
          .init(identity: source.identity, isRegular: true))
        let samples: [ReaderFixtureStep] =
          descriptorFirst
          ? [.descriptor(wrong)] : [.descriptor(good), .path(wrong)]
        let io = FileReaderScript([.open(.opened(fd))] + samples + [.close(.closed)])
        defer { io.disposeSyntheticState() }
        XCTAssertEqual(try run(source, io), .failed(.sourceChanged))
        XCTAssertTrue(io.readCalls.isEmpty)
        assertFinished(io)
      }
    }
  }

  func testNonregularDescriptorRefusesBeforeContent() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let io = FileReaderScript([
      .open(.opened(fd)), .descriptor(.sampled(.init(identity: source.identity, isRegular: false))),
      .close(.closed),
    ])
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .failed(.unreadable))
    XCTAssertEqual(io.calls, [.open(readerFixturePathBytes), .descriptor(40), .close(40)])
    assertFinished(io)
  }

  func testNegativeReadIncludingEINTRIsNotRetried() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    // Literal 4 is the selected Darwin EINTR value; no Darwin call or import.
    for errno in [Int32(4), 5] {
      let io = FileReaderScript(
        [.open(.opened(fd))] + readerSamplePair(source.identity) + [
          .read(offset: 0, count: 3, reply: .failure(errno)), .close(.closed),
        ])
      defer { io.disposeSyntheticState() }
      XCTAssertEqual(try run(source, io), .failed(.unreadable))
      XCTAssertEqual(io.readCalls, [.read(fd: 40, offset: 0, count: 3)])
      assertFinished(io)
    }
  }

  func testRealDecoderErrorsRemainTyped() throws {
    let cases: [(bytes: [UInt8], failure: SearchAdmissionFileFailure, reachesFinish: Bool)] = [
      ([0xC0, 0xAF], .invalidUTF8, false), ([0x00], .binaryInput, false),
      ([0xF0, 0x9F, 0x98], .invalidUTF8, true),
    ]
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    for item in cases {
      let source = try input(size: Int64(item.bytes.count), window: item.bytes.count)
      let postRead = item.reachesFinish ? readerSamplePair(source.identity) : []
      let io = FileReaderScript(
        [.open(.opened(fd))] + readerSamplePair(source.identity) + [
          .read(offset: 0, count: item.bytes.count, reply: .bytes(item.bytes))
        ] + postRead + [.close(.closed)])
      defer { io.disposeSyntheticState() }
      XCTAssertEqual(try run(source, io), .failed(item.failure))
      XCTAssertEqual(io.readCalls.count, 1)
      assertFinished(io)
    }
  }

  func testCancelledBeforeEntryDoesNoIO() throws {
    let source = try input(size: 1, window: 1)
    let io = FileReaderScript([])
    defer { io.disposeSyntheticState() }
    io.cancelled = true
    XCTAssertEqual(try run(source, io), .failed(.cancelled))
    XCTAssertTrue(io.calls.isEmpty)
    assertFinished(io, closes: 0)
  }

  func testCancellationAfterReadPrecedesConsume() throws {
    let source = try input(size: 1, window: 1)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let io = FileReaderScript(
      [.open(.opened(fd))] + readerSamplePair(source.identity) + [
        .read(offset: 0, count: 1, reply: .bytes([0x00]), cancelAfter: true), .close(.closed),
      ])
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .failed(.cancelled))
    XCTAssertEqual(io.readCalls, [.read(fd: 40, offset: 0, count: 1)])
    assertFinished(io)
  }

  func testOpenFailureCreatesNoCloseObligation() throws {
    let source = try input(size: 1, window: 1)
    let io = FileReaderScript([.open(.failed(errno: 13))])
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .failed(.unreadable))
    XCTAssertEqual(io.calls, [.open(readerFixturePathBytes)])
    assertFinished(io, closes: 0)
  }

  func testSampleFailureStillClosesOpenedDescriptor() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let good = SearchAdmissionFileSampleResult.sampled(
      .init(identity: source.identity, isRegular: true))
    // Six explicit sampling positions: initial FD/path, post-read FD/path, final FD/path.
    let prefixes: [[ReaderFixtureStep]] = [
      [], [.descriptor(good)],
      [.descriptor(good), .path(good), .read(offset: 0, count: 3, reply: .bytes([97, 98, 99]))],
      [
        .descriptor(good), .path(good), .read(offset: 0, count: 3, reply: .bytes([97, 98, 99])),
        .descriptor(good),
      ],
      [
        .descriptor(good), .path(good), .read(offset: 0, count: 3, reply: .bytes([97, 98, 99])),
        .descriptor(good), .path(good),
      ],
      [
        .descriptor(good), .path(good), .read(offset: 0, count: 3, reply: .bytes([97, 98, 99])),
        .descriptor(good), .path(good), .descriptor(good),
      ],
    ]
    for (position, prefix) in prefixes.enumerated() {
      for invalidMetadata in [false, true] {
        let sample: SearchAdmissionFileSampleResult =
          invalidMetadata ? .invalidMetadata : .failed(errno: 5)
        let refusal: ReaderFixtureStep =
          position.isMultiple(of: 2) ? .descriptor(sample) : .path(sample)
        let io = FileReaderScript([.open(.opened(fd))] + prefix + [refusal, .close(.closed)])
        defer { io.disposeSyntheticState() }
        XCTAssertEqual(
          try run(source, io), .failed(invalidMetadata ? .internalFailure : .unreadable))
        XCTAssertEqual(io.calls.last, .close(40))
        assertFinished(io)
      }
    }
  }

  func testFinalIdentityChangeAfterMaterializationRefuses() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let changed = try readerIdentity(size: 3, changedNanoseconds: 24)
    let wrong = SearchAdmissionFileSampleResult.sampled(.init(identity: changed, isRegular: true))
    let good = SearchAdmissionFileSampleResult.sampled(
      .init(identity: source.identity, isRegular: true))
    for descriptorFirst in [true, false] {
      let final: [ReaderFixtureStep] =
        descriptorFirst
        ? [.descriptor(wrong)] : [.descriptor(good), .path(wrong)]
      let io = FileReaderScript(
        [.open(.opened(fd))] + readerSamplePair(source.identity) + [
          .read(offset: 0, count: 3, reply: .bytes([97, 98, 99]))
        ] + readerSamplePair(source.identity) + final + [.close(.closed)])
      defer { io.disposeSyntheticState() }
      XCTAssertEqual(try run(source, io), .failed(.sourceChanged))
      XCTAssertEqual(io.calls.last, .close(40))
      XCTAssertEqual(
        io.calls.dropLast().last, descriptorFirst ? .descriptor(40) : .path(readerFixturePathBytes))
      assertFinished(io)
    }
  }

  func testUncertainCloseRetainsExactOwnershipWithoutText() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    for earlyEOF in [false, true] {
      let steps: [ReaderFixtureStep]
      if earlyEOF {
        steps =
          [.open(.opened(fd))] + readerSamplePair(source.identity) + [
            .read(offset: 0, count: 3, reply: .bytes([])), .close(.uncertain(errno: 4)),
          ]
      } else {
        steps = try readerSuccessSteps(
          identity: source.identity,
          reads: [
            .read(offset: 0, count: 3, reply: .bytes([97, 98, 99]))
          ], close: .uncertain(errno: 4))
      }
      let io = FileReaderScript(steps)
      defer { io.disposeSyntheticState() }
      let result = try run(source, io)
      // Assert ownership/call facts even when the candidate publishes the wrong result.
      assertFinished(io, quarantine: [40])
      guard case .ownershipUncertain(let issue) = result else {
        XCTFail("Uncertain close must return ownership without prepared text")
        continue
      }
      XCTAssertEqual(issue.descriptor, fd)
      XCTAssertEqual(issue.expectedIdentity, source.identity)
      XCTAssertEqual(issue.closeErrno, 4)
      XCTAssertEqual(issue.primaryFailure, earlyEOF ? .sourceChanged : nil)
    }
  }

  func testOverreportedReadCountRefusesBeforeBorrow() throws {
    let source = try input(size: 3, window: 3)
    let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
    let io = FileReaderScript(
      [.open(.opened(fd))] + readerSamplePair(source.identity) + [
        .read(offset: 0, count: 3, reply: .countOnly(4)), .close(.closed),
      ])
    defer { io.disposeSyntheticState() }
    XCTAssertEqual(try run(source, io), .failed(.internalFailure))
    XCTAssertEqual(io.readCalls, [.read(fd: 40, offset: 0, count: 3)])
    assertFinished(io)
  }
}
