import Foundation
import XCTest

@testable import PadCore

final class ExternalDocumentDecoderTests: XCTestCase {
  func testExternalBOMOverridesSavedEncodingAndRoundTrips() throws {
    let fixtures: [(Data, DocumentEncoding, DocumentEncoding, String)] = [
      (Data([0xFE, 0xFF, 0, 65, 0, 13, 0, 10]), .utf16LE, .utf16BE, "A\r\n"),
      (Data([0xFF, 0xFE, 65, 0]), .utf16BE, .utf16LE, "A"),
      (Data([0xEF, 0xBB, 0xBF, 0xE2, 0x82, 0xAC]), .windows1252, .utf8, "€"),
    ]
    for (bytes, fallback, encoding, text) in fixtures {
      let decoded = try ExternalDocumentDecoder.decode(bytes, fallbackEncoding: fallback)
      XCTAssertEqual(decoded.encoding, encoding)
      XCTAssertTrue(decoded.hasBOM)
      XCTAssertEqual(Array(decoded.text.utf16), Array(text.utf16))
      XCTAssertEqual(try DocumentCodec.encode(decoded), bytes)
    }
  }

  func testUTF32MarkersAreRefusedBeforeUTF16OrLegacyInterpretation() {
    let markers: [[UInt8]] = [
      [0xFF, 0xFE, 0, 0], [0, 0, 0xFE, 0xFF],
      [0, 0, 0xFF, 0xFE], [0xFE, 0xFF, 0, 0],
    ]
    for marker in markers {
      for fallback in DocumentEncoding.allCases {
        XCTAssertThrowsError(
          try ExternalDocumentDecoder.decode(
            Data(marker + [65, 0, 0, 0]),
            fallbackEncoding: fallback)
        ) { error in
          guard case ExternalDocumentDecodingError.unsupportedUTF32 = error else {
            return XCTFail(
              "Expected unsupported UTF-32 prefix refusal, received \(type(of: error))")
          }
        }
      }
    }
  }

  func testBOMlessBytesUseSavedEncodingWithoutGuessing() throws {
    let fixtures: [(Data, DocumentEncoding, String)] = [
      (Data([0x80, 0xE9, 13]), .windows1252, "€é\r"),
      (Data([0x80, 0xE9]), .latin1, "\u{80}é"),
      (Data([65, 0, 10, 0]), .utf16LE, "A\n"),
      (Data([0, 65, 0, 10]), .utf16BE, "A\n"),
      (Data("😀e\u{301}".utf8), .utf8, "😀e\u{301}"),
    ]
    for (bytes, fallback, text) in fixtures {
      let decoded = try ExternalDocumentDecoder.decode(bytes, fallbackEncoding: fallback)
      XCTAssertEqual(decoded.encoding, fallback)
      XCTAssertFalse(decoded.hasBOM)
      XCTAssertEqual(Array(decoded.text.utf16), Array(text.utf16))
      XCTAssertEqual(try DocumentCodec.encode(decoded), bytes)
    }
  }

  func testBOMSelectedMalformedUnicodeRefusesLegacyFallback() {
    for bytes: [UInt8] in [[0xEF, 0xBB, 0xBF, 0xFF], [0xFF, 0xFE, 0, 0xD8], [0xFE, 0xFF, 0]] {
      XCTAssertThrowsError(
        try ExternalDocumentDecoder.decode(Data(bytes), fallbackEncoding: .windows1252))
    }
  }

  func testExplicitReopenCodecRetainsItsSeparateInterpretation() throws {
    let bytes = Data([0xEF, 0xBB, 0xBF, 65])
    let explicit = try DocumentCodec.decode(bytes, encoding: .windows1252)
    XCTAssertEqual(explicit.encoding, .windows1252)
    XCTAssertFalse(explicit.hasBOM)
    XCTAssertEqual(try DocumentCodec.encode(explicit), bytes)
  }
}
