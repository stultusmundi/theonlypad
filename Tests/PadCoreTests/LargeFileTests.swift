import Foundation
import XCTest

@testable import PadCore

final class LargeFileTests: XCTestCase {
  private func fixture(_ bytes: Data) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("synthetic.bin")
    try bytes.write(to: url)
    return url
  }
  func testBinaryWindowsAndEOF() throws {
    let reader = try LargeFileReader(url: fixture(Data([0, 255, 65, 128, 10])), chunkSize: 2)
    XCTAssertEqual(try reader.readWindow(offset: 1, length: 3), Data([255, 65, 128]))
    XCTAssertEqual(try reader.readWindow(offset: 4, length: 5), Data([10]))
    XCTAssertEqual(try reader.readWindow(offset: 5, length: 1), Data())
    XCTAssertEqual(reader.identity.size, 5)
    for (offset, length) in [(Int64(-1), 1), (6, 1), (0, -1), (0, 1_048_577)] {
      XCTAssertThrowsError(try reader.readWindow(offset: offset, length: length)) {
        XCTAssertEqual($0 as? LargeFileError, .invalidWindow)
      }
    }
  }
  func testEmptyFileAndEmptyPattern() throws {
    let reader = try LargeFileReader(url: fixture(Data()))
    XCTAssertEqual(try reader.readWindow(offset: 0, length: 10), Data())
    XCTAssertEqual(try reader.searchLiteral(Data([1])), [])
    XCTAssertThrowsError(try reader.searchLiteral(Data())) {
      XCTAssertEqual($0 as? LargeFileError, .invalidPattern)
    }
  }
  func testBoundarySpanningLongerThanChunkAndOverlappingMatches() throws {
    let reader = try LargeFileReader(url: fixture(Data("xxabcdefxxabcdefaaa".utf8)), chunkSize: 4)
    XCTAssertEqual(try reader.searchLiteral(Data("abcdef".utf8)), [2, 10])
    XCTAssertEqual(try reader.searchLiteral(Data("aa".utf8)), [16, 17])
    XCTAssertEqual(try reader.searchLiteral(Data("missing".utf8)), [])
  }
  func testSearchResultLimitThrowsAndCancellationStops() throws {
    let reader = try LargeFileReader(url: fixture(Data("aaaa".utf8)), chunkSize: 2)
    XCTAssertThrowsError(try reader.searchLiteral(Data("a".utf8), limit: 2)) {
      XCTAssertEqual($0 as? LargeFileError, .resultLimit)
    }
    XCTAssertThrowsError(try reader.searchLiteral(Data("a".utf8), cancellation: { true })) {
      XCTAssertEqual($0 as? LargeFileError, .cancelled)
    }
    var checks = 0
    XCTAssertThrowsError(
      try reader.searchLiteral(
        Data("z".utf8),
        cancellation: {
          checks += 1
          return checks >= 3
        })
    ) { XCTAssertEqual($0 as? LargeFileError, .cancelled) }
    XCTAssertThrowsError(try reader.searchLiteral(Data("a".utf8), limit: -1)) {
      XCTAssertEqual($0 as? LargeFileError, .invalidLimit)
    }
  }
  func testModificationTruncationAndReplacementAreDetected() throws {
    for replacement in [Data("edited".utf8), Data(), Data("original".utf8)] {
      let url = try fixture(Data("original".utf8))
      let reader = try LargeFileReader(url: url)
      try replacement.write(to: url, options: .atomic)
      XCTAssertThrowsError(try reader.readWindow(offset: 0, length: 1)) {
        XCTAssertEqual($0 as? LargeFileError, .changed)
      }
    }
    let url = try fixture(Data("original".utf8))
    let reader = try LargeFileReader(url: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data("changed!".utf8))
    try handle.close()
    XCTAssertThrowsError(try reader.searchLiteral(Data("o".utf8))) {
      XCTAssertEqual($0 as? LargeFileError, .changed)
    }
  }
  func testRejectsDirectorySymlinkAndOversizedFile() throws {
    let url = try fixture(Data())
    XCTAssertThrowsError(try LargeFileReader(url: url.deletingLastPathComponent())) {
      XCTAssertEqual($0 as? LargeFileError, .unsafeFile)
    }
    let link = url.deletingLastPathComponent().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    XCTAssertThrowsError(try LargeFileReader(url: link)) {
      XCTAssertEqual($0 as? LargeFileError, .unsafeFile)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 1_000_000_001)
    try handle.close()
    XCTAssertThrowsError(try LargeFileReader(url: url)) {
      XCTAssertEqual($0 as? LargeFileError, .fileTooLarge)
    }
  }
  func testChangesDuringSearchRejectPartialResults() throws {
    let url = try fixture(Data("abcdefghabcdefgh".utf8))
    let reader = try LargeFileReader(url: url, chunkSize: 4)
    var calls = 0
    var modificationError: Error?
    XCTAssertThrowsError(
      try reader.searchLiteral(
        Data("a".utf8),
        cancellation: {
          calls += 1
          if calls == 4 {
            do {
              let handle = try FileHandle(forWritingTo: url)
              defer { try? handle.close() }
              try handle.truncate(atOffset: 1)
            } catch { modificationError = error }
          }
          return false
        })
    ) { XCTAssertEqual($0 as? LargeFileError, .changed) }
    XCTAssertNil(modificationError)
  }

  func testSeededByteSearchMatchesIndependentSlidingWindows() throws {
    var state: UInt64 = 0xC0FFEE
    for iteration in 0..<40 {
      var bytes: [UInt8] = []
      for _ in 0..<127 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        bytes.append(UInt8((state >> 32) % 4))
      }
      let needle = Array(bytes[(iteration % 30)..<(iteration % 30 + 3)])
      let expected = (0...(bytes.count - needle.count)).filter {
        Array(bytes[$0..<($0 + needle.count)]) == needle
      }.map(Int64.init)
      let reader = try LargeFileReader(url: fixture(Data(bytes)), chunkSize: iteration % 11 + 1)
      XCTAssertEqual(try reader.searchLiteral(Data(needle)), expected)
    }
  }

}
