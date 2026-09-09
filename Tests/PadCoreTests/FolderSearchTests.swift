import Foundation
import XCTest

@testable import PadCore

final class FolderSearchTests: XCTestCase {
  func fixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
  }
  func testUTF8BOMMatchesEditorSnapshotAndRange() throws {
    try fixture { root in
      try Data([0xEF, 0xBB, 0xBF] + Array("needle".utf8)).write(
        to: root.appendingPathComponent("bom.txt"))
      let report = try FolderSearch.search(
        root: root, query: .init(pattern: "needle", mode: .literal))
      XCTAssertEqual(report.hits.first?.originalText, "needle")
      XCTAssertEqual(report.hits.first?.range, NSRange(location: 0, length: 6))
    }
  }
  func testMatchesSnapshotRangesGlobsAndSkips() throws {
    try fixture { root in
      try Data("é hello HELLO".utf8).write(to: root.appendingPathComponent("a.txt"))
      try Data("hello".utf8).write(to: root.appendingPathComponent("b.log"))
      try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.txt"))
      try Data([255]).write(to: root.appendingPathComponent("invalid.txt"))
      let report = try FolderSearch.search(
        root: root, query: SearchQuery(pattern: "hello", mode: .literal, caseSensitive: false),
        includes: ["*.txt"])
      XCTAssertEqual(report.hits.count, 2)
      XCTAssertEqual(report.hits.first?.range, NSRange(location: 2, length: 5))
      XCTAssertEqual(report.hits.first?.originalText, "é hello HELLO")
      XCTAssertEqual(report.skippedBinary, 2)
      XCTAssertEqual(report.skippedGlob, 1)
    }
  }
  func testLimitsCancellationAndMalformedRegexAreExplicit() throws {
    try fixture { root in
      try Data("aaa".utf8).write(to: root.appendingPathComponent("a.txt"))
      XCTAssertThrowsError(
        try FolderSearch.search(
          root: root, query: .init(pattern: "a", mode: .literal), limits: .init(maxMatches: 2)))
      XCTAssertThrowsError(
        try FolderSearch.search(
          root: root, query: .init(pattern: "a", mode: .literal), isCancelled: { true }))
      XCTAssertThrowsError(
        try FolderSearch.search(root: root, query: .init(pattern: "[", mode: .regex)))
      XCTAssertThrowsError(
        try FolderSearch.search(
          root: root, query: .init(pattern: "a", mode: .literal), limits: .init(maxSnapshotBytes: 2)
        ))
      let small = try FolderSearch.search(
        root: root, query: .init(pattern: "a", mode: .literal), limits: .init(maxFileBytes: 2))
      XCTAssertEqual(small.skippedSize, 1)
    }
  }
  func testRecursiveExclusionProgressAndHiddenFiles() throws {
    try fixture { root in
      let sub = root.appendingPathComponent("sub")
      try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
      try Data("needle".utf8).write(to: sub.appendingPathComponent("a.txt"))
      try Data("needle".utf8).write(to: root.appendingPathComponent(".hidden"))
      var counts: [Int] = []
      let report = try FolderSearch.search(
        root: root, query: .init(pattern: "needle", mode: .literal), excludes: ["sub/*"],
        onProgress: { counts.append($0.filesProcessed) })
      XCTAssertTrue(report.hits.isEmpty)
      XCTAssertEqual(report.skippedGlob, 1)
      XCTAssertEqual(counts.last, 1)
    }
  }
}
