import Foundation
import XCTest

@testable import PadCore

final class FolderReplacementNULPreflightTests: XCTestCase {
  func testPercentEncodedNULIsRejectedBeforeDecodedPath() throws {
    let url = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/nul%00name"))
    var calls = 0

    XCTAssertFalse(
      FolderReplacementPathPolicy.valid(
        url,
        decodedPath: { _ in
          calls += 1
          return "/synthetic/nul\0name"
        }))
    XCTAssertEqual(calls, 0, "NUL URI input must be refused before Foundation path decoding")
  }

  func testConstructedNULURLIsRejectedBeforeDecodedPath() {
    let url = URL(fileURLWithPath: "/tmp/folder-preview/nul\0name")
    var calls = 0

    XCTAssertFalse(
      FolderReplacementPathPolicy.valid(
        url,
        decodedPath: { _ in
          calls += 1
          return "/synthetic/nul\0name"
        }))
    XCTAssertEqual(calls, 0, "constructed NUL URL must not reach decoded path access")
  }

  func testEncodedNULRootIsRejectedBeforeDecodedPath() throws {
    let url = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/root%00part/"))
    var calls = 0

    XCTAssertFalse(
      FolderReplacementPathPolicy.valid(
        url, requiresDirectory: true,
        decodedPath: { _ in
          calls += 1
          return "/synthetic/nul\0name"
        }))
    XCTAssertEqual(calls, 0, "root NUL must be refused before Foundation path decoding")
  }

  func testDoubleEscapedPercent00IsAnOrdinaryLiteralFilename() throws {
    let encoded = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/literal%2500name"))
    let constructed = URL(fileURLWithPath: "/tmp/folder-preview/literal%00name")
    var observedPath: String?
    var calls = 0

    XCTAssertTrue(FolderReplacementPathPolicy.valid(encoded))
    XCTAssertEqual(FolderReplacementPathPolicy.path(encoded), "/tmp/folder-preview/literal%00name")
    XCTAssertTrue(
      FolderReplacementPathPolicy.valid(
        constructed,
        decodedPath: { candidate in
          calls += 1
          observedPath = FolderReplacementPathPolicy.path(candidate)
          return observedPath ?? ""
        }))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(observedPath, "/tmp/folder-preview/literal%00name")
    XCTAssertTrue(FolderReplacementPathPolicy.valid(constructed))
    XCTAssertEqual(
      FolderReplacementPathPolicy.path(constructed), "/tmp/folder-preview/literal%00name")
  }

  func testPercent00InQueryOrFragmentDoesNotChangePathAdmission() throws {
    let query = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/file.txt?note=%00"))
    let fragment = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/file.txt#%00"))

    XCTAssertTrue(FolderReplacementPathPolicy.valid(query))
    XCTAssertTrue(FolderReplacementPathPolicy.valid(fragment))
    XCTAssertEqual(FolderReplacementPathPolicy.path(query), "/tmp/folder-preview/file.txt")
    XCTAssertEqual(FolderReplacementPathPolicy.path(fragment), "/tmp/folder-preview/file.txt")
  }

  func testUnicodePathRemainsAdmissible() throws {
    let url = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/%E9%9B%AA-%F0%9F%98%80.txt"))

    XCTAssertTrue(FolderReplacementPathPolicy.valid(url))
    XCTAssertEqual(FolderReplacementPathPolicy.path(url), "/tmp/folder-preview/雪-😀.txt")
  }

  func testNonzeroPercentEscapeRemainsAdmissible() throws {
    let url = try XCTUnwrap(URL(string: "file:///tmp/folder-preview/name%20with%20spaces.txt"))

    XCTAssertTrue(FolderReplacementPathPolicy.valid(url))
    XCTAssertEqual(
      FolderReplacementPathPolicy.path(url), "/tmp/folder-preview/name with spaces.txt")
  }

  func testNonFileURLRemainsRejectedWithoutDecodedPathAccess() throws {
    let url = try XCTUnwrap(URL(string: "https://example.invalid/folder-preview/file.txt"))
    var calls = 0

    XCTAssertFalse(
      FolderReplacementPathPolicy.valid(
        url,
        decodedPath: { candidate in
          calls += 1
          return FolderReplacementPathPolicy.path(candidate)
        }))
    XCTAssertEqual(calls, 0)
  }
}
