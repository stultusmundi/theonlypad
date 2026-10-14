// Read-only preview integration tests using isolated synthetic documents.
// Fault controls preserve independent byte, identity and no-mutation assertions.
import Darwin
import Foundation
import XCTest

@testable import PadCore

final class FolderReplacementPreviewTests: XCTestCase {
  // Catches decoded-text reconstruction losing BOM, Unicode offset or mixed-ending bytes.
  func testActualTwoFilePreviewPreservesIndependentBytesAndUTF16Ranges() throws {
    try withFixture { fixture in
      let a = Data([0xef, 0xbb, 0xbf]) + Data("needle\r\n😀needle\r".utf8)
      let b = Data("e\u{301}\nneedle\r\nend\r".utf8)
      try fixture.write(a, to: fixture.a)
      try fixture.write(b, to: fixture.b)
      let result = try preview(fixture, replacement: "X")

      XCTAssertTrue(result.isComplete)
      XCTAssertEqual(result.entries.map(\.url), [fixture.a, fixture.b])
      XCTAssertEqual(result.entries.map(\.relativePath), ["a.txt", "b.txt"])
      XCTAssertEqual(result.entries[0].originalData, a)
      XCTAssertEqual(result.entries[1].originalData, b)
      XCTAssertEqual(
        result.entries[0].proposedData,
        Data([0xef, 0xbb, 0xbf]) + Data("X\r\n😀X\r".utf8))
      XCTAssertEqual(result.entries[1].proposedData, Data("e\u{301}\nX\r\nend\r".utf8))
      XCTAssertEqual(
        result.entries[0].ranges,
        [NSRange(location: 0, length: 6), NSRange(location: 10, length: 6)])
      XCTAssertEqual(result.entries[1].ranges, [NSRange(location: 3, length: 6)])
      XCTAssertEqual(result.entries.map(\.hasBOM), [true, false])
      XCTAssertEqual(result.entries.map(\.wouldChange), [true, true])
      XCTAssertEqual(result.sourceBytes, 38)
      XCTAssertEqual(result.outputBytes, 23)
      XCTAssertEqual(result.matchCount, 3)
    }
  }

  // Catches an exactly-two-files restriction, unvalidated empty root or trimming literal input.
  func testOneEmptyAndNoChangeSelectedSetsHaveFactualCompleteness() throws {
    try withFixture { fixture in
      let one = try preview(fixture, urls: [fixture.a], limits: .init(maxFiles: 1))
      XCTAssertTrue(one.isComplete)
      XCTAssertEqual(one.entries.count, 1)
      XCTAssertEqual(one.entries[0].proposedData, Data("X".utf8))

      let empty = try preview(fixture, urls: [], limits: .init(maxFiles: 0))
      XCTAssertTrue(empty.isComplete)
      XCTAssertTrue(empty.entries.isEmpty)
      XCTAssertEqual(empty.sourceBytes, 0)
      XCTAssertEqual(empty.outputBytes, 0)
      XCTAssertEqual(empty.matchCount, 0)
      assertError(.unsupportedInput) {
        try FolderReplacementPreviewBuilder().preview(
          root: fixture.a, selectedURLs: [], query: literal(), replacement: "X")
      }

      let unmatched = try preview(fixture, urls: [fixture.a], query: literal("absent"))
      XCTAssertTrue(unmatched.isComplete)
      XCTAssertEqual(unmatched.entries[0].originalData, Data("needle".utf8))
      XCTAssertEqual(unmatched.entries[0].proposedData, Data("needle".utf8))
      XCTAssertTrue(unmatched.entries[0].ranges.isEmpty)
      XCTAssertFalse(unmatched.entries[0].wouldChange)

      let same = try preview(fixture, urls: [fixture.a], replacement: "needle")
      XCTAssertEqual(same.entries[0].ranges, [NSRange(location: 0, length: 6)])
      XCTAssertFalse(same.entries[0].wouldChange)
      try fixture.write(Data(" \t ".utf8), to: fixture.a)
      let whitespace = try preview(
        fixture, urls: [fixture.a], query: literal(" "), replacement: "")
      XCTAssertEqual(whitespace.entries[0].proposedData, Data([0x09]))
      XCTAssertEqual(
        whitespace.entries[0].ranges,
        [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }
  }

  // Catches capture expansion/escape interpretation in literal replacement and empty-query admission.
  func testLiteralReplacementIsVerbatimAndEmptyReplacementDeletes() throws {
    try withFixture { fixture in
      try fixture.write(Data("needle\r\nneedle".utf8), to: fixture.a)
      let result = try preview(fixture, urls: [fixture.a], replacement: #"$1$&\n"#)
      let sixLiteralBytes: [UInt8] = [0x24, 0x31, 0x24, 0x26, 0x5c, 0x6e]
      XCTAssertEqual(
        result.entries[0].proposedData,
        Data(sixLiteralBytes + [0x0d, 0x0a] + sixLiteralBytes))
      let deletion = try preview(fixture, urls: [fixture.a], replacement: "")
      XCTAssertEqual(deletion.entries[0].proposedData, Data([0x0d, 0x0a]))
      XCTAssertEqual(deletion.matchCount, 2)

      let reader = ControlledReader()
      assertError(.invalidRequest) {
        try preview(fixture, builder: .init(reader: reader), query: literal(""))
      }
      XCTAssertEqual(reader.rootCalls, 0, "Empty pattern must refuse before filesystem I/O")
      XCTAssertEqual(reader.fileCalls, 0)
    }
  }

  // Catches missing preflight admission, discarded lower limits and truncated match results.
  func testAdmissionAndBudgetsRejectBeforeExpensiveWork() throws {
    try withFixture { fixture in
      let invalidLimits: [FolderReplacementPreviewLimits] = [
        .init(maxFiles: -1), .init(maxFiles: 3),
        .init(maxSourceFileBytes: -1), .init(maxSourceFileBytes: 1_048_577),
        .init(maxOutputFileBytes: -1), .init(maxOutputFileBytes: 1_048_577),
        .init(maxRetainedBytes: -1), .init(maxRetainedBytes: 4_194_305),
        .init(maxMatches: -1), .init(maxMatches: 1_001),
        .init(maxPatternUTF8Bytes: -1), .init(maxPatternUTF8Bytes: 4_097),
        .init(maxReplacementUTF8Bytes: -1), .init(maxReplacementUTF8Bytes: 4_097),
      ]
      for limits in invalidLimits {
        let reader = ControlledReader()
        assertError(.invalidLimits) {
          try preview(fixture, builder: .init(reader: reader), limits: limits)
        }
        XCTAssertEqual(reader.rootCalls, 0)
        XCTAssertEqual(reader.fileCalls, 0)
      }

      let longPath = URL(
        fileURLWithPath: fixture.root.path + "/" + String(repeating: "p", count: 4097))
      let nulPath = URL(fileURLWithPath: fixture.root.path + "/nul\u{0}name")
      let requestCases: [([URL], SearchQuery, String, FolderReplacementPreviewLimits)] = [
        (
          [fixture.a, fixture.b, fixture.root.appendingPathComponent("third.txt")], literal(), "X",
          .init()
        ),
        ([fixture.a, fixture.a], literal(), "X", .init()),
        ([fixture.a, fixture.b], literal(), "X", .init(maxFiles: 1)),
        ([fixture.a], .init(pattern: "needle", mode: .escaped), "X", .init()),
        ([fixture.a], .init(pattern: "needle", mode: .regex), "X", .init()),
        ([fixture.a], literal(String(repeating: "é", count: 2049)), "X", .init()),
        ([fixture.a], literal(), String(repeating: "é", count: 2049), .init()),
        ([fixture.a], literal(), "X", .init(maxPatternUTF8Bytes: 5)),
        ([fixture.a], literal(), "XX", .init(maxReplacementUTF8Bytes: 1)),
        ([longPath], literal(), "X", .init()),
        ([nulPath], literal(), "X", .init()),
        ([URL(string: "https://invalid.example/synthetic.txt")!], literal(), "X", .init()),
      ]
      for (urls, query, replacement, limits) in requestCases {
        let reader = ControlledReader()
        assertError(.invalidRequest) {
          try preview(
            fixture, urls: urls, builder: .init(reader: reader), query: query,
            replacement: replacement, limits: limits)
        }
        XCTAssertEqual(reader.rootCalls, 0)
        XCTAssertEqual(reader.fileCalls, 0)
      }

      let exact = try preview(
        fixture, urls: [fixture.a],
        limits: .init(
          maxSourceFileBytes: 6, maxOutputFileBytes: 1, maxRetainedBytes: 7, maxMatches: 1,
          maxPatternUTF8Bytes: 6, maxReplacementUTF8Bytes: 1))
      XCTAssertEqual(exact.sourceBytes, 6)
      XCTAssertEqual(exact.outputBytes, 1)
      XCTAssertEqual(exact.matchCount, 1)
      assertError(.sourceLimit) {
        try preview(fixture, urls: [fixture.a], limits: .init(maxSourceFileBytes: 5))
      }
      assertError(.retainedLimit) {
        try preview(fixture, urls: [fixture.a], limits: .init(maxRetainedBytes: 5))
      }
      assertError(.matchLimit) {
        try preview(fixture, urls: [fixture.a], limits: .init(maxMatches: 0))
      }
      let zeroMatches = try preview(
        fixture, urls: [fixture.a], query: literal("absent"), limits: .init(maxMatches: 0))
      XCTAssertEqual(zeroMatches.matchCount, 0)

      let exactPattern = try preview(
        fixture, urls: [fixture.a], query: literal(String(repeating: "é", count: 2048)))
      XCTAssertEqual(exactPattern.matchCount, 0)
      XCTAssertEqual(exactPattern.entries[0].proposedData, Data("needle".utf8))
      let exactReplacement = try preview(
        fixture, urls: [fixture.a], replacement: String(repeating: "é", count: 2048))
      let independentUTF8Bytes = Array(repeating: [UInt8](arrayLiteral: 0xc3, 0xa9), count: 2048)
        .flatMap { $0 }
      XCTAssertEqual(exactReplacement.entries[0].proposedData, Data(independentUTF8Bytes))
      XCTAssertEqual(exactReplacement.outputBytes, 4096)

      let handle = try FileHandle(forWritingTo: fixture.a)
      try handle.truncate(atOffset: 1_048_577)
      try handle.close()
      try fixture.acknowledgeTestMutation()
      assertError(.sourceLimit) { try preview(fixture, urls: [fixture.a]) }
    }
  }

  // Catches returning the first result after later file I/O or selected-content rejection.
  func testSecondReadFailureReturnsNoPartialPreviewAndLeavesSourcesBackups() throws {
    try withFixture { fixture in
      let reader = ControlledReader()
      let marker = NSError(domain: "SyntheticFolderPreviewReadFailure", code: 42)
      reader.beforeCapture = { index, _ in if index == 2 { throw marker } }
      var returned: FolderReplacementPreview?
      XCTAssertThrowsError(
        try {
          returned = try preview(fixture, builder: .init(reader: reader))
        }()
      ) {
        XCTAssertEqual(($0 as NSError).domain, marker.domain)
        XCTAssertEqual(($0 as NSError).code, marker.code)
      }
      XCTAssertNil(returned)
      XCTAssertEqual(reader.fileCalls, 2)
      XCTAssertEqual(reader.revalidationCalls, 0)
      for badBytes in [Data([0xff]), Data([0x00, 0x61])] {
        try fixture.write(badBytes, to: fixture.b)
        assertError(.unsupportedInput) { try preview(fixture) }
      }
    }
  }

  // Catches partial returns or new file admission after deterministic cancellation boundaries.
  func testCancellationBeforeDuringAndBetweenReadsReturnsNoPreview() throws {
    try withFixture { fixture in
      let before = ControlledReader()
      assertError(.cancelled) {
        try preview(fixture, builder: .init(reader: before), isCancelled: { true })
      }
      XCTAssertEqual(before.rootCalls, 0)
      XCTAssertEqual(before.fileCalls, 0)

      let during = ControlledReader()
      during.cancelOnSecondCapturePoll = true
      try fixture.write(Data(repeating: 0x61, count: 262_144), to: fixture.a)
      assertError(.cancelled) { try preview(fixture, builder: .init(reader: during)) }
      XCTAssertGreaterThanOrEqual(during.captureCancellationPolls, 2)
      XCTAssertEqual(during.fileCalls, 1)
      XCTAssertEqual(during.revalidationCalls, 0)
      // This proves cancellation during actual default-reader polling, not interrupted POSIX I/O.
      try fixture.write(Data("needle".utf8), to: fixture.a)

      let between = ControlledReader()
      let betweenFlag = CancellationFlag()
      between.afterCapture = { index, _ in if index == 1 { betweenFlag.value = true } }
      assertError(.cancelled) {
        try preview(
          fixture, builder: .init(reader: between), isCancelled: { betweenFlag.value })
      }
      XCTAssertEqual(between.fileCalls, 1)
      XCTAssertEqual(between.revalidationCalls, 0)

      let final = ControlledReader()
      let finalFlag = CancellationFlag()
      final.beforeRevalidate = { index, _ in if index == 1 { finalFlag.value = true } }
      assertError(.cancelled) {
        try preview(fixture, builder: .init(reader: final), isCancelled: { finalFlag.value })
      }
      XCTAssertEqual(final.fileCalls, 2)
      XCTAssertEqual(final.revalidationCalls, 1)
    }
  }

  // Catches text/byte equality replacing identity/containment checks in the actual default reader.
  func testActualRevalidationRefusesEqualByteInodeAndSymlinkSubstitution() throws {
    try withFixture { fixture in
      let reader = ControlledReader()
      reader.beforeRevalidate = { index, _ in
        guard index == 1 else { return }
        fixture.assertPreserved()
        let retained = fixture.root.appendingPathComponent("retained-original.txt")
        try FileManager.default.moveItem(at: fixture.a, to: retained)
        try Data("needle".utf8).write(to: fixture.a)
        let originalID = try self.inode(retained)
        let replacementID = try self.inode(fixture.a)
        XCTAssertNotEqual(originalID, replacementID, "Fixture must really substitute the inode")
        XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: fixture.a))
        try fixture.acknowledgeTestMutation()
      }
      assertError(.staleInput) { try preview(fixture, builder: .init(reader: reader)) }
      XCTAssertEqual(reader.revalidationCalls, 1)
    }
    try withFixture { fixture in
      let peer = fixture.container.appendingPathComponent("external-synthetic.txt")
      try fixture.write(Data("DO NOT CHANGE".utf8), to: peer)
      let reader = ControlledReader()
      reader.beforeRevalidate = { index, _ in
        guard index == 1 else { return }
        fixture.assertPreserved()
        try FileManager.default.moveItem(
          at: fixture.a, to: fixture.root.appendingPathComponent("retained-original.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.a, withDestinationURL: peer)
        try fixture.acknowledgeTestMutation()
      }
      assertError(.staleInput) { try preview(fixture, builder: .init(reader: reader)) }
      XCTAssertEqual(try Data(contentsOf: peer), Data("DO NOT CHANGE".utf8))
    }
    try withFixture { fixture in
      let reader = ControlledReader()
      reader.beforeRevalidate = { index, _ in
        guard index == 1 else { return }
        fixture.assertPreserved()
        try FileManager.default.moveItem(
          at: fixture.root, to: fixture.container.appendingPathComponent("retained-root"))
        try FileManager.default.createDirectory(
          at: fixture.root, withIntermediateDirectories: false)
        try Data("needle".utf8).write(to: fixture.a)
        try Data("needle".utf8).write(to: fixture.b)
        try fixture.acknowledgeTestMutation()
      }
      assertError(.staleInput) { try preview(fixture, builder: .init(reader: reader)) }
    }
    try withFixture { fixture in
      let alias = fixture.root.appendingPathComponent("alias.txt")
      XCTAssertEqual(link(fixture.a.path, alias.path), 0)
      try fixture.acknowledgeTestMutation()
      assertError(.unsupportedInput) { try preview(fixture, urls: [fixture.a]) }
      assertError(.unsupportedInput) { try preview(fixture, urls: [fixture.a, alias]) }
    }
    try withFixture { fixture in
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: fixture.a.path)
      try fixture.acknowledgeTestMutation()
      assertError(.unsupportedInput) { try preview(fixture, urls: [fixture.a]) }
    }
  }

  // Catches UTF-16-only output caps, unchecked aggregate budgets and match truncation.
  func testEncodedOutputOverflowRefusesCompletePreview() throws {
    try withFixture { fixture in
      assertError(.outputLimit) {
        try preview(
          fixture, urls: [fixture.a], replacement: "😀", limits: .init(maxOutputFileBytes: 3))
      }
      let fourBytes = try preview(
        fixture, urls: [fixture.a], replacement: "😀", limits: .init(maxOutputFileBytes: 4))
      XCTAssertEqual(fourBytes.entries[0].proposedData, Data([0xf0, 0x9f, 0x98, 0x80]))
      XCTAssertEqual(fourBytes.outputBytes, 4)

      assertError(.retainedLimit) {
        try preview(fixture, limits: .init(maxRetainedBytes: 13))
      }
      let exact = try preview(fixture, limits: .init(maxRetainedBytes: 14))
      XCTAssertEqual(exact.sourceBytes, 12)
      XCTAssertEqual(exact.outputBytes, 2)
      XCTAssertEqual(exact.matchCount, 2)

      try fixture.write(Data(String(repeating: "needle", count: 1001).utf8), to: fixture.a)
      assertError(.matchLimit) { try preview(fixture, urls: [fixture.a]) }
      try fixture.write(Data(String(repeating: "needle", count: 1000).utf8), to: fixture.a)
      let matchBoundary = try preview(fixture, urls: [fixture.a])
      XCTAssertEqual(matchBoundary.matchCount, 1000)
      XCTAssertEqual(matchBoundary.entries[0].ranges.count, 1000)
      XCTAssertEqual(matchBoundary.entries[0].proposedData, Data(repeating: 0x58, count: 1000))
    }
  }

  private func literal(_ pattern: String = "needle") -> SearchQuery {
    SearchQuery(pattern: pattern, mode: .literal)
  }

  private func preview(
    _ fixture: Fixture,
    urls: [URL]? = nil,
    builder: FolderReplacementPreviewBuilder = .init(),
    query: SearchQuery? = nil,
    replacement: String = "X",
    limits: FolderReplacementPreviewLimits = .init(),
    isCancelled: @escaping () -> Bool = { false }
  ) throws -> FolderReplacementPreview {
    defer { fixture.assertPreserved() }
    return try builder.preview(
      root: fixture.root, selectedURLs: urls ?? [fixture.a, fixture.b],
      query: query ?? literal(), replacement: replacement, limits: limits,
      isCancelled: isCancelled)
  }

  private func assertError<T>(
    _ expected: FolderReplacementPreviewError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> T
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      XCTAssertEqual($0 as? FolderReplacementPreviewError, expected, file: file, line: line)
    }
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fixture = try Fixture()
    defer {
      // Safety assertions run on thrown failures too; cleanup is test-owned only.
      fixture.assertPreserved()
      do { try FileManager.default.removeItem(at: fixture.container) } catch {
        XCTFail("Synthetic fixture cleanup failed: \(error)")
      }
    }
    try body(fixture)
  }

  private func inode(_ url: URL) throws -> UInt64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return UInt64(info.st_ino)
  }
}

private final class CancellationFlag { var value = false }

// Wraps real proposed default I/O; never constructs a snapshot from fake text or old hits.
private final class ControlledReader: FolderReplacementSnapshotReading {
  private let actual = FolderReplacementDefaultSnapshotReader()
  var rootCalls = 0
  var fileCalls = 0
  var revalidationCalls = 0
  var captureCancellationPolls = 0
  var cancelOnSecondCapturePoll = false
  var beforeCapture: ((Int, URL) throws -> Void)?
  var afterCapture: ((Int, URL) throws -> Void)?
  var beforeRevalidate: ((Int, URL) throws -> Void)?

  func captureRoot(_ url: URL, isCancelled: @escaping () -> Bool) throws
    -> FolderReplacementRootSnapshot
  {
    rootCalls += 1
    return try actual.captureRoot(url, isCancelled: isCancelled)
  }

  func captureFile(
    _ url: URL, within root: FolderReplacementRootSnapshot,
    maximumBytes: Int, isCancelled: @escaping () -> Bool
  ) throws -> FolderReplacementFileSnapshot {
    fileCalls += 1
    try beforeCapture?(fileCalls, url)
    let result = try actual.captureFile(
      url, within: root, maximumBytes: maximumBytes,
      isCancelled: { [self] in
        if isCancelled() { return true }
        if cancelOnSecondCapturePoll {
          captureCancellationPolls += 1
          return captureCancellationPolls >= 2
        }
        return false
      })
    try afterCapture?(fileCalls, url)
    return result
  }

  func revalidate(
    _ snapshot: FolderReplacementFileSnapshot,
    within root: FolderReplacementRootSnapshot,
    maximumBytes: Int, isCancelled: @escaping () -> Bool
  ) throws {
    revalidationCalls += 1
    try beforeRevalidate?(revalidationCalls, snapshot.url)
    try actual.revalidate(
      snapshot, within: root, maximumBytes: maximumBytes, isCancelled: isCancelled)
  }
}

// Complete synthetic inventory makes incidental target/backup writes or temporary entries visible.
private final class Fixture {
  let container: URL
  let root: URL
  let backups: URL
  var a: URL { root.appendingPathComponent("a.txt") }
  var b: URL { root.appendingPathComponent("b.txt") }
  private var expected: [String: ObservedEntry] = [:]

  init() throws {
    // Test-only canonical EXISTING base; production reader never resolves symlinks for admission.
    let temporary = FileManager.default.temporaryDirectory.path(percentEncoded: false)
    guard let pointer = realpath(temporary, nil) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let canonicalBase = String(cString: pointer)
    free(pointer)
    container = URL(fileURLWithPath: canonicalBase, isDirectory: true)
      .appendingPathComponent(UUID().uuidString)
    root = container.appendingPathComponent("selected-root")
    backups = container.appendingPathComponent("sentinel-backups")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
    try Data("needle".utf8).write(to: a)
    try Data("needle".utf8).write(to: b)
    try Data([0x00, 0xff, 0x42]).write(to: backups.appendingPathComponent("sentinel.bin"))
    try acknowledgeTestMutation()
  }

  func write(_ data: Data, to url: URL) throws {
    assertPreserved()
    try data.write(to: url)
    try acknowledgeTestMutation()
  }

  // Called only immediately after deliberate fixture mutation, never after the preview operation.
  func acknowledgeTestMutation() throws { expected = try observe() }

  func assertPreserved(file: StaticString = #filePath, line: UInt = #line) {
    do {
      let actual = try observe()
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch { XCTFail("Cannot verify synthetic inventory: \(error)", file: file, line: line) }
  }

  private func observe() throws -> [String: ObservedEntry] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: container, includingPropertiesForKeys: nil)
    else { throw NSError(domain: "SyntheticFixtureInventory", code: 1) }
    var result: [String: ObservedEntry] = [:]
    for case let url as URL in enumerator {
      var info = stat()
      guard lstat(url.path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      let relative = String(url.path.dropFirst(container.path.count + 1))
      let kind = info.st_mode & S_IFMT
      let bytes: Data?
      let linkTarget: String?
      if kind == S_IFREG {
        bytes = try Data(contentsOf: url)
        linkTarget = nil
      } else if kind == S_IFLNK {
        bytes = nil
        linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        enumerator.skipDescendants()
      } else {
        bytes = nil
        linkTarget = nil
      }
      result[relative] = ObservedEntry(
        device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: UInt32(info.st_mode),
        owner: UInt32(info.st_uid), links: UInt64(info.st_nlink),
        modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
        changedSeconds: Int64(info.st_ctimespec.tv_sec),
        changedNanoseconds: Int64(info.st_ctimespec.tv_nsec), bytes: bytes, linkTarget: linkTarget)
    }
    return result
  }

  private struct ObservedEntry: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let links: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let bytes: Data?
    let linkTarget: String?
  }
}
