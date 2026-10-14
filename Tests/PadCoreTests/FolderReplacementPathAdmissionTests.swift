// Path admission regression tests using isolated synthetic files.
// Preview integration tests provide separate byte, encoding and error coverage.
import Darwin
import Foundation
import XCTest

@testable import PadCore

final class FolderReplacementPathAdmissionTests: XCTestCase {
  // Break: recursive percent decoding or escaped-path canonicalization selects a different inode/name.
  func testActualLiteralPercentAndEscapedNamesBindExactSelectedFiles() throws {
    try withFixture { fixture in
      let names = ["literal%.txt", "literal%00.txt", "literal%2F.txt", "e\u{301} 😀 #?.txt"]
      for name in names {
        let selected = fixture.root.appendingPathComponent(name)
        try fixture.write(Data([0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65]), to: selected)
        let before = try fixture.observe()
        defer { fixture.assertEqual(before) }
        let result = try FolderReplacementPreviewBuilder().preview(
          root: fixture.root, selectedURLs: [selected],
          query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.count, 1)
        guard let entry = result.entries.first else { return XCTFail("Missing selected entry") }
        XCTAssertEqual(entry.url, selected)
        XCTAssertEqual(entry.relativePath, name)
        XCTAssertEqual(entry.originalData, Data([0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65]))
        XCTAssertEqual(entry.proposedData, Data([0x58]))
        XCTAssertEqual(entry.ranges, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(entry.snapshot.identity, try fixture.fileIdentity(selected))
        XCTAssertEqual(result.sourceBytes, 6)
        XCTAssertEqual(result.outputBytes, 1)
        XCTAssertEqual(result.matchCount, 1)
      }
    }
  }

  // Break: checking legacy URL.path lets encoded NUL cross admission into a snapshot collaborator.
  func testActualEncodedNULRefusesBeforeAnyFilesystemCollaborator() throws {
    try withFixture { fixture in
      let rootString =
        fixture.root.absoluteString.hasSuffix("/")
        ? fixture.root.absoluteString : fixture.root.absoluteString + "/"
      let constructed = URL(
        fileURLWithPath: fixture.root.path(percentEncoded: false) + "/nul\0name")
      let explicit = try XCTUnwrap(URL(string: rootString + "nul%00name"))
      for selected in [constructed, explicit] {
        XCTAssertTrue(
          selected.path(percentEncoded: false).contains("\0"),
          "Fixture must carry actual decoded NUL")
        let reader = PathAdmissionThrowingReader()
        let before = try fixture.observe()
        defer { fixture.assertEqual(before) }
        XCTAssertThrowsError(
          try FolderReplacementPreviewBuilder(reader: reader).preview(
            root: fixture.root, selectedURLs: [selected],
            query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
        ) {
          XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
        }
        XCTAssertEqual(reader.rootCalls, 0)
        XCTAssertEqual(reader.fileCalls, 0)
        XCTAssertEqual(reader.revalidationCalls, 0)
      }
      // Encoded NUL in root must also refuse without reading the legitimate selected file.
      let reader = PathAdmissionThrowingReader()
      let beforeRoot = try fixture.observe()
      defer { fixture.assertEqual(beforeRoot) }
      XCTAssertThrowsError(
        try FolderReplacementPreviewBuilder(reader: reader).preview(
          root: explicit, selectedURLs: [], query: SearchQuery(pattern: "needle", mode: .literal),
          replacement: "X")
      ) {
        XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
      }
      XCTAssertEqual(reader.rootCalls, 0)
    }
  }

  // Root-reviewed policy: discrepant decoded/filesystem URI views refuse, never read a decoy.
  // Break: choosing legacy percent-named file or modern nested file despite conflicting URL semantics.
  func testEncodedSeparatorAmbiguityRefusesWithDistinctRealDecoyAndNestedFiles() throws {
    try withFixture { fixture in
      let nested = fixture.root.appendingPathComponent("nested", isDirectory: true)
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
      let target = nested.appendingPathComponent("target.txt")
      let decoy = fixture.root.appendingPathComponent("nested%2Ftarget.txt")
      try fixture.write(Data("needle NESTED".utf8), to: target)
      try fixture.write(Data("needle DECOY".utf8), to: decoy)
      XCTAssertNotEqual(try fixture.fileIdentity(target), try fixture.fileIdentity(decoy))
      let rootString =
        fixture.root.absoluteString.hasSuffix("/")
        ? fixture.root.absoluteString : fixture.root.absoluteString + "/"
      for spelling in ["nested%2Ftarget.txt", "nested%2ftarget.txt"] {
        let selected = try XCTUnwrap(URL(string: rootString + spelling))
        let filesystem = selected.withUnsafeFileSystemRepresentation {
          $0.map { String(cString: $0) }
        }
        let decoded = selected.path(percentEncoded: false)
        XCTAssertNotEqual(
          Optional(decoded), filesystem,
          "Required ambiguity precondition; Root diagnostic must establish this")
        let before = try fixture.observe()
        defer { fixture.assertEqual(before) }
        let reader = PathAdmissionThrowingReader()
        XCTAssertThrowsError(
          try FolderReplacementPreviewBuilder(reader: reader).preview(
            root: fixture.root, selectedURLs: [selected],
            query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
        ) {
          XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
        }
        XCTAssertEqual(reader.rootCalls, 0)
        XCTAssertEqual(reader.fileCalls, 0)
        var returned: FolderReplacementPreview?
        XCTAssertThrowsError(
          try {
            returned = try FolderReplacementPreviewBuilder().preview(
              root: fixture.root, selectedURLs: [selected],
              query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
          }()
        ) {
          XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
        }
        XCTAssertNil(returned)
      }
    }
  }

  // Break: canonicalizing or resolving a forbidden symlink ancestor silently admits its target.
  func testActualAliasAndSymlinkDotRootRefuseWhileCanonicalRootSucceeds() throws {
    try withFixture { fixture in
      let ordinaryDirectoryRoot = URL(
        fileURLWithPath: fixture.root.path(percentEncoded: false), isDirectory: true)
      XCTAssertTrue(ordinaryDirectoryRoot.hasDirectoryPath)
      let beforeSafe = try fixture.observe()
      do {
        defer { fixture.assertEqual(beforeSafe) }
        let safe = try FolderReplacementPreviewBuilder().preview(
          root: ordinaryDirectoryRoot, selectedURLs: [],
          query: SearchQuery(pattern: "needle", mode: .literal),
          replacement: "X")
        XCTAssertTrue(safe.isComplete)
        XCTAssertTrue(safe.entries.isEmpty)
      }
      let alias = fixture.container.appendingPathComponent("synthetic-alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
      let dotAlias = URL(
        fileURLWithPath:
          fixture.container.path(percentEncoded: false) + "/synthetic-alias/../selected-root")
      let terminalAlias = URL(fileURLWithPath: alias.path(percentEncoded: false), isDirectory: true)
      // Actual synthetic raw POSIX alias spelling; no assumption about a host's temporary directory.
      let rawSyntheticAlias = URL(
        fileURLWithPath:
          fixture.container.path(percentEncoded: false) + "/synthetic-alias", isDirectory: false)
      XCTAssertEqual(
        rawSyntheticAlias.path(percentEncoded: false), alias.path(percentEncoded: false))
      XCTAssertEqual(
        try FileManager.default.destinationOfSymbolicLink(
          atPath: rawSyntheticAlias.path(percentEncoded: false)),
        fixture.root.path(percentEncoded: false))
      for root in [rawSyntheticAlias, alias, terminalAlias, dotAlias] {
        let before = try fixture.observe()
        defer { fixture.assertEqual(before) }
        XCTAssertThrowsError(
          try FolderReplacementPreviewBuilder().preview(
            root: root, selectedURLs: [], query: SearchQuery(pattern: "needle", mode: .literal),
            replacement: "X")
        ) {
          XCTAssertEqual($0 as? FolderReplacementPreviewError, .unsupportedInput)
        }
      }
    }
  }

  // Break: stripping a directory-only terminal slash relabels a regular-file request.
  func testActualTrailingDirectorySemanticsRefuseRegularFileTarget() throws {
    try withFixture { fixture in
      let selected = fixture.root.appendingPathComponent("target.txt")
      try fixture.write(Data("needle".utf8), to: selected)
      let directorySpelling = try XCTUnwrap(URL(string: selected.absoluteString + "/"))
      let decoded = directorySpelling.path(percentEncoded: false)
      let filesystem = directorySpelling.withUnsafeFileSystemRepresentation {
        $0.map { String(cString: $0) }
      }
      XCTAssertTrue(decoded.hasSuffix("/"))
      XCTAssertNotEqual(
        Optional(decoded), filesystem,
        "Actual Foundation drops terminal slash; regular-file role must refuse")
      let before = try fixture.observe()
      defer { fixture.assertEqual(before) }
      let reader = PathAdmissionThrowingReader()
      XCTAssertThrowsError(
        try FolderReplacementPreviewBuilder(reader: reader).preview(
          root: fixture.root, selectedURLs: [directorySpelling],
          query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
      ) {
        XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
      }
      XCTAssertEqual(reader.rootCalls, 0)
      XCTAssertEqual(reader.fileCalls, 0)
      XCTAssertThrowsError(
        try FolderReplacementPreviewBuilder().preview(
          root: fixture.root, selectedURLs: [directorySpelling],
          query: SearchQuery(pattern: "needle", mode: .literal), replacement: "X")
      ) {
        XCTAssertEqual($0 as? FolderReplacementPreviewError, .invalidRequest)
      }
    }
  }

  private func withFixture(_ body: (PathAdmissionFixture) throws -> Void) throws {
    let fixture = try PathAdmissionFixture()
    defer {
      do { try FileManager.default.removeItem(at: fixture.container) } catch {
        XCTFail("Owned synthetic path fixture cleanup failed: \(error)")
      }
    }
    try body(fixture)
  }
}

private final class PathAdmissionThrowingReader: FolderReplacementSnapshotReading {
  var rootCalls = 0
  var fileCalls = 0
  var revalidationCalls = 0
  func captureRoot(_ url: URL, isCancelled: @escaping () -> Bool) throws
    -> FolderReplacementRootSnapshot
  {
    rootCalls += 1
    throw NSError(domain: "SyntheticPathAdmissionUnexpectedRoot", code: 1)
  }
  func captureFile(
    _ url: URL, within root: FolderReplacementRootSnapshot, maximumBytes: Int,
    isCancelled: @escaping () -> Bool
  ) throws -> FolderReplacementFileSnapshot {
    fileCalls += 1
    throw NSError(domain: "SyntheticPathAdmissionUnexpectedFile", code: 2)
  }
  func revalidate(
    _ snapshot: FolderReplacementFileSnapshot, within root: FolderReplacementRootSnapshot,
    maximumBytes: Int, isCancelled: @escaping () -> Bool
  ) throws {
    revalidationCalls += 1
    throw NSError(domain: "SyntheticPathAdmissionUnexpectedRevalidation", code: 3)
  }
}

private final class PathAdmissionFixture {
  let container: URL
  let root: URL
  init() throws {
    // Test-only kernel canonical EXISTING base; Source never resolves symlinks for admission.
    let temporary = FileManager.default.temporaryDirectory.path(percentEncoded: false)
    guard let pointer = realpath(temporary, nil) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let actual = String(cString: pointer)
    free(pointer)
    let base = URL(fileURLWithPath: actual, isDirectory: true)
    container = base.appendingPathComponent(UUID().uuidString)
    root = container.appendingPathComponent("selected-root")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sentinel = container.appendingPathComponent("sentinel-backups", isDirectory: true)
    try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
    try Data([0x00, 0xff, 0x42]).write(to: sentinel.appendingPathComponent("sentinel.bin"))
  }
  func write(_ data: Data, to url: URL) throws { try data.write(to: url) }
  func fileIdentity(_ url: URL) throws -> FolderReplacementFilesystemIdentity {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return FolderReplacementFilesystemIdentity(
      device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
  }
  func observe() throws -> [String: PathAdmissionEntry] {
    guard
      let children = FileManager.default.enumerator(at: container, includingPropertiesForKeys: nil)
    else {
      throw NSError(domain: "SyntheticPathAdmissionInventory", code: 1)
    }
    var observed: [String: PathAdmissionEntry] = [:]
    var base = container.path(percentEncoded: false)
    while base.count > 1, base.hasSuffix("/") { base.removeLast() }
    for case let url as URL in children {
      let path = url.path(percentEncoded: false)
      var info = stat()
      guard lstat(path, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      let kind = info.st_mode & S_IFMT
      let bytes = kind == S_IFREG ? try Data(contentsOf: url) : nil
      let link =
        kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
      if kind == S_IFLNK { children.skipDescendants() }
      guard path.hasPrefix(base + "/") else {
        throw NSError(domain: "SyntheticPathAdmissionInventory", code: 2)
      }
      let relative = String(path.dropFirst(base.count + 1))
      observed[relative] = PathAdmissionEntry(
        device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
        mode: UInt32(info.st_mode), owner: UInt32(info.st_uid), links: UInt64(info.st_nlink),
        msec: Int64(info.st_mtimespec.tv_sec), mnsec: Int64(info.st_mtimespec.tv_nsec),
        csec: Int64(info.st_ctimespec.tv_sec), cnsec: Int64(info.st_ctimespec.tv_nsec),
        bytes: bytes, link: link)
    }
    return observed
  }
  func assertEqual(
    _ expected: [String: PathAdmissionEntry], file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      let actual = try observe()
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
      XCTFail("Cannot observe owned synthetic path inventory: \(error)", file: file, line: line)
    }
  }
}

private struct PathAdmissionEntry: Equatable {
  let device: UInt64
  let inode: UInt64
  let mode: UInt32
  let owner: UInt32
  let links: UInt64
  let msec: Int64
  let mnsec: Int64
  let csec: Int64
  let cnsec: Int64
  let bytes: Data?
  let link: String?
}
