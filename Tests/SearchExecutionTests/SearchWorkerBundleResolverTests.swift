import Darwin
import Foundation
import XCTest

@testable import SearchExecution

final class SearchWorkerBundleResolverTests: XCTestCase {
  func testFixedCandidateIsStructuralOnAbsentBundle() throws {
    let root = URL(fileURLWithPath: "/missing-synthetic-" + UUID().uuidString, isDirectory: true)
    let bundle = root.appendingPathComponent("Example.app", isDirectory: true)
    let result = try SearchWorkerBundleResolver.candidate(in: bundle)
    XCTAssertEqual(result.path, bundle.path + "/Contents/Helpers/PadSearchWorker")
    XCTAssertTrue(result.isFileURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testCandidateNormalizesLexicallyAndPreservesUnicode() throws {
    let bundle = try XCTUnwrap(URL(string: "file:///absent/one/../A%F0%9F%98%80%20b.app/./"))
    let result = try SearchWorkerBundleResolver.candidate(in: bundle)
    XCTAssertEqual(result.path, "/absent/A😀 b.app/Contents/Helpers/PadSearchWorker")
  }

  func testCandidateRejectsInvalidURLForms() throws {
    for text in [
      "https://example.invalid/Example.app", "file:relative.app",
      "file://remote.invalid/Example.app", "file:///tmp/Example.app?override=x",
      "file:///tmp/Example.app#fragment", "file:///tmp/Example%00.app",
    ] {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try SearchWorkerBundleResolver.candidate(in: url)) {
        XCTAssertEqual($0 as? SearchWorkerBundleResolverError, .invalidURL)
      }
    }
  }

  func testValidateRejectsInvalidURLBeforeFilesystemLookup() throws {
    for text in [
      "https://example.invalid/worker", "file:relative", "file://remote.invalid/worker",
      "file:///tmp/worker?x=y", "file:///tmp/worker#fragment", "file:///tmp/worker%00suffix",
    ] {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try SearchWorkerBundleResolver.validateForLaunch(url)) {
        XCTAssertEqual($0 as? SearchWorkerBundleResolverError, .invalidURL)
      }
    }
  }

  func testBaseRelativeReferencesAreRefusedButAbsoluteFileReferenceWithBaseIsValid() throws {
    let root = try temporaryRoot()
    let relative = try XCTUnwrap(URL(string: "worker", relativeTo: root))
    XCTAssertThrowsError(try SearchWorkerBundleResolver.candidate(in: relative)) {
      XCTAssertEqual($0 as? SearchWorkerBundleResolverError, .invalidURL)
    }
    assertFailure(relative, .invalidURL)

    let absolute = try XCTUnwrap(URL(string: root.absoluteString, relativeTo: root))
    XCTAssertEqual(
      try SearchWorkerBundleResolver.candidate(in: absolute),
      try SearchWorkerBundleResolver.candidate(in: root))
    let file = root.appendingPathComponent("worker", isDirectory: false)
    try Data("inert marker".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0)
    let explicitAbsolute = try XCTUnwrap(URL(string: file.absoluteString, relativeTo: root))
    XCTAssertEqual(
      try SearchWorkerBundleResolver.validateForLaunch(explicitAbsolute), explicitAbsolute)
  }

  func testExactSyntheticRegularExecutableIsAcceptedWithoutExecutingIt() throws {
    let root = try temporaryRoot()
    let file = root.appendingPathComponent("PadSearchWorker", isDirectory: false)
    try Data("inert synthetic marker".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0)
    XCTAssertEqual(try SearchWorkerBundleResolver.validateForLaunch(file), file)
    XCTAssertEqual(try Data(contentsOf: file), Data("inert synthetic marker".utf8))
  }

  func testMissingFilePreservesENOENT() throws {
    let file = try temporaryRoot().appendingPathComponent("missing", isDirectory: false)
    assertFailure(file, .filesystem(ENOENT))
  }

  func testDirectoryAndFIFOAreRefusedWithoutOpeningThem() throws {
    let root = try temporaryRoot()
    assertFailure(root, .filesystem(EACCES))
    let fifo = root.appendingPathComponent("fifo", isDirectory: false)
    XCTAssertEqual(mkfifo(fifo.path, 0o700), 0)
    assertFailure(fifo, .filesystem(EACCES))
  }

  func testSymlinkAndDanglingSymlinkAreRefused() throws {
    let root = try temporaryRoot()
    let target = root.appendingPathComponent("target", isDirectory: false)
    try Data("inert marker".utf8).write(to: target)
    XCTAssertEqual(chmod(target.path, 0o700), 0)
    let link = root.appendingPathComponent("linked", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    assertFailure(link, .filesystem(EACCES))
    try FileManager.default.removeItem(at: target)
    assertFailure(link, .filesystem(EACCES))
  }

  func testNoExecuteBitIsRefused() throws {
    let file = try temporaryRoot().appendingPathComponent("worker", isDirectory: false)
    try Data("inert marker".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    assertFailure(file, .filesystem(EACCES))
  }

  func testSiblingAndBuildExecutablesNeverSubstituteForMissingBundledHelper() throws {
    let root = try temporaryRoot()
    let bundle = root.appendingPathComponent("Example.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    for file in [
      root.appendingPathComponent("PadSearchWorker", isDirectory: false),
      root.appendingPathComponent("Build/PadSearchWorker", isDirectory: false),
    ] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("inert marker".utf8).write(to: file)
      XCTAssertEqual(chmod(file.path, 0o700), 0)
    }
    let candidate = try SearchWorkerBundleResolver.candidate(in: bundle)
    XCTAssertEqual(candidate.path, bundle.path + "/Contents/Helpers/PadSearchWorker")
    assertFailure(candidate, .filesystem(ENOENT))
  }

  func testExplicitUnbundledFixturePathRemainsAllowed() throws {
    let file = try temporaryRoot().appendingPathComponent("BenignFixture", isDirectory: false)
    try Data("inert fixture".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0)
    XCTAssertEqual(try SearchWorkerBundleResolver.validateForLaunch(file), file)
  }

  private func assertFailure(
    _ url: URL, _ failure: SearchWorkerBundleResolverError,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try SearchWorkerBundleResolver.validateForLaunch(url), file: file, line: line
    ) {
      XCTAssertEqual($0 as? SearchWorkerBundleResolverError, failure, file: file, line: line)
    }
  }
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "search-resolver-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
