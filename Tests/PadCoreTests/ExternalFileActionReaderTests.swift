import Foundation
import XCTest

@testable import PadCore

final class ExternalFileActionReaderTests: XCTestCase {
  private var directory: URL!
  private let reader = ExternalFileActionReader()
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-FileAction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  private func fixture(_ bytes: Data) throws -> (URL, DiskObservation) {
    let url = directory.appendingPathComponent("synthetic.txt")
    try bytes.write(to: url)
    let observation = try ExternalFileProbe().observe(
      url, expected: Data(), boundIdentity: nil, forceContents: true, previous: nil,
      isCancelled: { false })
    return (url, observation)
  }
  func testReadRetainsExactBytesAndUsesSupportedBOM() throws {
    let bytes = Data([0xFE, 0xFF, 0, 0x41, 0, 0x0D, 0, 0x0A])
    let (url, observation) = try fixture(bytes)
    let snapshot = try reader.read(
      url, matching: observation, fallbackEncoding: .windows1252, isCancelled: { false })
    XCTAssertEqual(snapshot.bytes, bytes)
    XCTAssertEqual(
      snapshot.document, DecodedDocument(text: "A\r\n", encoding: .utf16BE, hasBOM: true))
    try reader.revalidate(snapshot, isCancelled: { false })
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }
  func testBOMlessReadUsesSavedEncoding() throws {
    let (url, observation) = try fixture(Data([0x80, 0x0A]))
    let snapshot = try reader.read(
      url, matching: observation, fallbackEncoding: .windows1252, isCancelled: { false })
    XCTAssertEqual(snapshot.document.text, "€\n")
    XCTAssertEqual(snapshot.document.encoding, .windows1252)
    XCTAssertFalse(snapshot.document.hasBOM)
  }
  func testReadRejectsReplacementAfterObservation() throws {
    let (url, observation) = try fixture(Data("first".utf8))
    try Data("other".utf8).write(to: url, options: .atomic)
    XCTAssertThrowsError(
      try reader.read(
        url, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    ) {
      XCTAssertEqual($0 as? ExternalFileProbeError, .observationChanged)
    }
  }
  func testReadReportsInvalidBytesWithoutChangingFile() throws {
    let bytes = Data([0xFF, 0x41])
    let (url, observation) = try fixture(bytes)
    XCTAssertThrowsError(
      try reader.read(
        url, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    ) {
      guard case DocumentCodecError.invalidBytes = $0 else {
        return XCTFail("Expected invalid-byte error")
      }
    }
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }
  func testReadCancellationIsExplicit() throws {
    let (url, observation) = try fixture(Data("cancel".utf8))
    XCTAssertThrowsError(
      try reader.read(
        url, matching: observation, fallbackEncoding: .utf8, isCancelled: { true })
    ) {
      XCTAssertTrue($0 is CancellationError)
    }
  }
  func testConfirmationRevalidationRejectsSecondDiskChange() throws {
    let (url, observation) = try fixture(Data("first".utf8))
    let snapshot = try reader.read(
      url, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    try Data("other".utf8).write(to: url, options: .atomic)
    XCTAssertThrowsError(try reader.revalidate(snapshot, isCancelled: { false }))
    XCTAssertEqual(snapshot.document.text, "first")
    XCTAssertEqual(try Data(contentsOf: url), Data("other".utf8))
  }
  func testRevalidationCancellationIsExplicit() throws {
    let (url, observation) = try fixture(Data("first".utf8))
    let snapshot = try reader.read(
      url, matching: observation, fallbackEncoding: .utf8, isCancelled: { false })
    XCTAssertThrowsError(try reader.revalidate(snapshot, isCancelled: { true })) {
      XCTAssertTrue($0 is CancellationError)
    }
  }
}
