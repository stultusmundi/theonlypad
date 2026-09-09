import XCTest

@testable import PadCore

final class TextUtilitiesTests: XCTestCase {
  func testKnownBase64URLJSONAndChecksumValues() throws {
    XCTAssertEqual(try TextUtilities.process("hello", operation: .base64Encode), "aGVsbG8=")
    XCTAssertEqual(try TextUtilities.process("aGVsbG8=", operation: .base64Decode), "hello")
    XCTAssertEqual(
      try TextUtilities.process("a+b c/?é", operation: .urlEncode), "a%2Bb%20c%2F%3F%C3%A9")
    XCTAssertEqual(try TextUtilities.process("a+b%20c", operation: .urlDecode), "a+b c")
    XCTAssertEqual(try TextUtilities.process("a\n\"b\\c", operation: .jsonEscape), #""a\n\"b\\c""#)
    XCTAssertEqual(
      try TextUtilities.process(#""a\n\"b\\c""#, operation: .jsonUnescape), "a\n\"b\\c")
    XCTAssertEqual(
      try TextUtilities.process("abc", operation: .sha256),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testRoundTripsPreserveExactUnicodeBytesIncludingBOMAndControlCharacters() throws {
    let texts = [
      "", "\u{FEFF}content", "é e\u{301} 👩🏽‍💻 العربية", "a\r\nb\rc\n", "\0\u{1}\u{8}\u{C}\t/\\\"",
    ]
    let pairs: [(TextUtilityOperation, TextUtilityOperation)] = [
      (.base64Encode, .base64Decode), (.urlEncode, .urlDecode), (.jsonEscape, .jsonUnescape),
    ]
    for text in texts {
      for (encode, decode) in pairs {
        let encoded = try TextUtilities.process(text, operation: encode)
        let decoded = try TextUtilities.process(encoded, operation: decode)
        XCTAssertEqual(Data(decoded.utf8), Data(text.utf8))
      }
    }
  }

  func testStrictBase64RejectsWhitespaceBadPaddingAndInvalidUTF8() {
    for input in ["aGVs bG8=", "aGVsbG8", "Zh==", "/w==", "7aCA", "====", "aGVsbG8=ignored"] {
      XCTAssertThrowsError(try TextUtilities.process(input, operation: .base64Decode), input)
    }
  }

  func testMalformedPercentAndJSONStringInputsFail() {
    for input in ["%", "%0", "%GG", "%FF", "%F0%9F", "%C0%80"] {
      XCTAssertThrowsError(try TextUtilities.process(input, operation: .urlDecode), input)
    }
    for input in ["unquoted", "[]", "null", #""\uD800""#, #""hello" trailing"#] {
      XCTAssertThrowsError(try TextUtilities.process(input, operation: .jsonUnescape), input)
    }
  }

  func testInputAndExpandedOutputLimitsAreEnforced() {
    XCTAssertThrowsError(
      try TextUtilities.process(String(repeating: "a", count: 2_000_001), operation: .sha256))
    XCTAssertThrowsError(
      try TextUtilities.process(String(repeating: "a", count: 1_500_001), operation: .base64Encode))
    XCTAssertThrowsError(
      try TextUtilities.process(String(repeating: " ", count: 666_667), operation: .urlEncode))
    XCTAssertThrowsError(
      try TextUtilities.process(String(repeating: "\0", count: 333_334), operation: .jsonEscape))
  }
}
