import XCTest

@testable import PadCore

final class WorkspaceIndexTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func write(_ name: String, root: URL, bytes: Data = Data("synthetic".utf8)) throws {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
  }
  func testDiscoveryUsesRelativePathsAndSkipsGeneratedHiddenDirectories() throws {
    let root = try folder()
    for name in [
      "src/Script.SWIFT", "notes.txt", ".hidden.txt", ".git/config", ".build/log",
      "node_modules/package/index.js", "src/.secret/value",
    ] { try write(name, root: root) }
    try write("blob.bin", root: root, bytes: Data([0, 255]))
    let found = try WorkspaceIndex.scan(root: root)
    XCTAssertEqual(found.map(\.relativePath), ["blob.bin", "notes.txt", "src/Script.SWIFT"])
    XCTAssertEqual(
      WorkspaceIndex.filtered(found, query: "script.swift").map(\.relativePath),
      ["src/Script.SWIFT"])
    XCTAssertEqual(WorkspaceIndex.filtered(found, query: "").count, 3)
    XCTAssertEqual(WorkspaceIndex.filtered(found, query: "not present"), [])
  }
  func testSymlinkFilesDirectoriesAndPostIndexEscapeAreRejected() throws {
    let root = try folder()
    let outside = try folder()
    try write("external.txt", root: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("file-link"),
      withDestinationURL: outside.appendingPathComponent("external.txt"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("dir-link"), withDestinationURL: outside)
    try write("inside.txt", root: root)
    XCTAssertEqual(try WorkspaceIndex.scan(root: root).map(\.relativePath), ["inside.txt"])
    let entry = try WorkspaceIndex.scan(root: root)[0]
    try FileManager.default.removeItem(at: entry.url)
    try FileManager.default.createSymbolicLink(
      at: entry.url, withDestinationURL: outside.appendingPathComponent("external.txt"))
    XCTAssertThrowsError(try WorkspaceIndex.validatedFile(entry.url, within: root))
    XCTAssertThrowsError(
      try WorkspaceIndex.validatedFile(outside.appendingPathComponent("external.txt"), within: root)
    )
  }
  func testBoundCountsVisitedDirectoriesAndCancellationIsExplicit() throws {
    let root = try folder()
    try write("a/b/c/file.txt", root: root)
    XCTAssertThrowsError(try WorkspaceIndex.scan(root: root, limit: 2)) {
      XCTAssertEqual($0 as? WorkspaceIndexError, .pathLimit)
    }
    XCTAssertThrowsError(try WorkspaceIndex.scan(root: root, isCancelled: { true })) {
      XCTAssertEqual($0 as? WorkspaceIndexError, .cancelled)
    }
    var visits: [Int] = []
    let found = try WorkspaceIndex.scan(root: root, onProgress: { visits.append($0) })
    XCTAssertEqual(found.count, 1)
    XCTAssertEqual(visits.last, 4)
    XCTAssertTrue(zip(visits, visits.dropFirst()).allSatisfy { $0 <= $1 })
    XCTAssertThrowsError(try WorkspaceIndex.scan(root: root, limit: 50_001)) {
      XCTAssertEqual($0 as? WorkspaceIndexError, .invalidLimit)
    }
  }
  func testRootAndOpenValidationRequireLocalDirectoryAndRegularFile() throws {
    let root = try folder()
    try write("file.txt", root: root)
    XCTAssertThrowsError(try WorkspaceIndex.scan(root: root.appendingPathComponent("file.txt")))
    XCTAssertThrowsError(
      try WorkspaceIndex.scan(root: URL(string: "https://example.invalid/workspace")!))
    XCTAssertThrowsError(try WorkspaceIndex.validatedFile(root, within: root))
    XCTAssertEqual(
      try WorkspaceIndex.validatedFile(root.appendingPathComponent("file.txt"), within: root),
      root.resolvingSymlinksInPath().appendingPathComponent("file.txt"))
  }
}
