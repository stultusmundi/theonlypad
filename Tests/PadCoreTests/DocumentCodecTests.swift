import XCTest

@testable import PadCore

final class DocumentCodecTests: XCTestCase {
  func testByteFixturesPreserveBOMAndMixedEndings() throws {
    let fixtures: [(Data, DocumentEncoding, String)] = [
      (Data([0xEF, 0xBB, 0xBF, 65, 13, 10, 66, 13]), .utf8, "A\r\nB\r"),
      (Data([0xFF, 0xFE, 65, 0, 13, 0, 10, 0]), .utf16LE, "A\r\n"),
      (Data([0xFE, 0xFF, 0, 65]), .utf16BE, "A"),
      (Data([0x80, 0x93, 0xE9]), .windows1252, "€“é"),
      (Data([0x80, 0xE9]), .latin1, "\u{80}é"),
    ]
    for (bytes, encoding, text) in fixtures {
      let document = try DocumentCodec.decode(bytes, encoding: encoding)
      XCTAssertEqual(document.text, text)
      XCTAssertEqual(try DocumentCodec.encode(document), bytes)
    }
  }

  func testInvalidUnicodeAndLossyConversionFail() throws {
    for bytes in [[UInt8(0xFF)], [0xC0, 0x80], [0xED, 0xA0, 0x80]] {
      XCTAssertThrowsError(try DocumentCodec.decode(Data(bytes)))
    }
    XCTAssertThrowsError(try DocumentCodec.decode(Data([0xFF, 0xFE, 0, 0xD8])))
    XCTAssertThrowsError(try DocumentCodec.decode(Data([0xFF, 0xFE, 65])))
    XCTAssertThrowsError(
      try DocumentCodec.encode(.init(text: "😀", encoding: .windows1252, hasBOM: false)))
  }

  func testSeededUnicodeRoundTrips() throws {
    var state: UInt64 = 0xBADCAFE
    for encoding in [DocumentEncoding.utf8, .utf16LE, .utf16BE] {
      for _ in 0..<100 {
        var text = "a\r\n👩🏽‍💻e\u{301}العربية\r"
        for _ in 0..<30 {
          state = state &* 6_364_136_223_846_793_005 &+ 1
          if let scalar = UnicodeScalar(UInt32(state % 0x110000)) {
            text.unicodeScalars.append(scalar)
          }
        }
        let original = DecodedDocument(text: text, encoding: encoding, hasBOM: true)
        let bytes = try DocumentCodec.encode(original)
        XCTAssertEqual(try DocumentCodec.decode(bytes), original)
      }
    }
  }

  func testAllLegacyBytesAndBOMlessUnicodeRoundTrip() throws {
    let bytes = Data((0...255).map(UInt8.init))
    for encoding in [DocumentEncoding.latin1, .windows1252] {
      XCTAssertEqual(
        try DocumentCodec.encode(DocumentCodec.decode(bytes, encoding: encoding)), bytes)
    }
    for encoding in [DocumentEncoding.utf8, .utf16LE, .utf16BE] {
      let original = DecodedDocument(text: "\u{FEFF}content\n", encoding: encoding, hasBOM: true)
      XCTAssertEqual(try DocumentCodec.decode(DocumentCodec.encode(original)), original)
      let noBOM = DecodedDocument(text: "hello😀\r", encoding: encoding, hasBOM: false)
      XCTAssertEqual(
        try DocumentCodec.decode(DocumentCodec.encode(noBOM), encoding: encoding), noBOM)
    }
    XCTAssertThrowsError(
      try DocumentCodec.encode(.init(text: "hello", encoding: .latin1, hasBOM: true)))
  }
}
