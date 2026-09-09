import XCTest

@testable import PadCore

final class LineEndingsTests: XCTestCase {
  func testDetectionCountsCRLFAsOneEnding() {
    XCTAssertEqual(LineEndings.detect(in: "plain"), .none)
    XCTAssertEqual(LineEndings.detect(in: "a\nb\n"), .uniform(.lf))
    XCTAssertEqual(LineEndings.detect(in: "a\r\nb\r\n"), .uniform(.crlf))
    XCTAssertEqual(LineEndings.detect(in: "a\rb\r"), .uniform(.cr))
    XCTAssertEqual(LineEndings.detect(in: "a\r\nb\nc\r"), .mixed)
  }

  func testConversionPreservesUnicodeScalarsAndTrailingSeparators() {
    let text = "\u{301}👩🏽‍💻e\u{301}\r\nאבג\n終\r\r\n"
    let expected = "\u{301}👩🏽‍💻e\u{301}|אבג|終||"
    for ending in LineEnding.allCases {
      let converted = LineEndings.convert(text, to: ending)
      XCTAssertTrue(
        converted.utf16.elementsEqual(
          expected.replacingOccurrences(of: "|", with: ending.sequence).utf16))
      XCTAssertEqual(LineEndings.detect(in: converted), .uniform(ending))
      XCTAssertTrue(LineEndings.convert(converted, to: ending).utf16.elementsEqual(converted.utf16))
    }
  }

  func testOtherUnicodeSeparatorsAreNotConverted() {
    let text = "a\u{85}b\u{2028}c\u{2029}e\u{301}"
    XCTAssertEqual(LineEndings.detect(in: text), .none)
    XCTAssertTrue(LineEndings.convert(text, to: .crlf).utf16.elementsEqual(text.utf16))
    XCTAssertEqual(LineEndings.convert("", to: .lf), "")
  }
}
