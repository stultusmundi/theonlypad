import Foundation
import XCTest

@testable import PadCore

/// Direct mechanics controls distinguish parser limits from schema/type rejection.
final class BoundedProfileJSONTests: XCTestCase {
  private let limits = BoundedProfileJSON.Limits(
    maximumBytes: 65536, maximumDepth: 16, maximumValues: 8192)

  private func parse(
    _ text: String, using limits: BoundedProfileJSON.Limits? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> BoundedProfileJSON.Value? {
    do { return try BoundedProfileJSON.parse(Data(text.utf8), limits: limits ?? self.limits) } catch
    {
      XCTFail("Valid JSON mechanics were refused: \(error)", file: file, line: line)
      return nil
    }
  }

  private func refuses(_ text: String, using limits: BoundedProfileJSON.Limits, label: String) {
    XCTAssertThrowsError(try BoundedProfileJSON.parse(Data(text.utf8), limits: limits)) {
      XCTAssertNotEqual($0 as? BoundedProfileJSON.Failure, .unimplemented, label)
    }
  }

  func testNumbersKeepSpellingAndBoolNullRemainDistinct() {
    guard let parsed = parse("[1,1.0,1e0,true,false,null]") else { return }
    guard case .array(let values) = parsed else { return XCTFail("Array kind was lost") }
    XCTAssertEqual(values.count, 6)
    guard values.count == 6 else { return }
    guard case .number(let first) = values[0],
      case .number(let second) = values[1], case .number(let third) = values[2],
      case .bool(let yes) = values[3], case .bool(let no) = values[4],
      case .null = values[5]
    else { return XCTFail("Scalar kinds or numeric lexemes were collapsed") }
    XCTAssertEqual(first, "1")
    XCTAssertEqual(second, "1.0")
    XCTAssertEqual(third, "1e0")
    XCTAssertTrue(yes)
    XCTAssertFalse(no)
  }

  func testDepthSixteenAcceptedAndSeventeenRefused() {
    let atLimit = String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16)
    guard var value = parse(atLimit) else { return }
    var depth = 0
    while case .array(let children) = value {
      XCTAssertEqual(children.count, 1)
      guard let child = children.first else { return XCTFail("Nested scalar was lost") }
      value = child
      depth += 1
    }
    XCTAssertEqual(depth, 16)
    guard case .number(let spelling) = value else { return XCTFail("Leaf kind changed") }
    XCTAssertEqual(spelling, "0")
    refuses(
      "[" + atLimit + "]", using: limits, label: "Depth 17 exceeds root-at-zero depth 16")
  }

  func testValueBudgetCountsContainersBeforeAppending() {
    let three = BoundedProfileJSON.Limits(maximumBytes: 64, maximumDepth: 16, maximumValues: 3)
    guard let parsed = parse("[null,null]", using: three) else { return }
    guard case .array(let values) = parsed else { return XCTFail("Array kind was lost") }
    XCTAssertEqual(values.count, 2)
    refuses(
      "[null,null]", using: .init(maximumBytes: 64, maximumDepth: 16, maximumValues: 2),
      label: "Container plus two values is three")
  }

  func testCatalogValueLimitIsIndependentOfImportBudget() {
    let catalogLimits = BoundedProfileJSON.Limits(
      maximumBytes: 1_048_576, maximumDepth: 16, maximumValues: 100000)
    let atLimit = "[" + Array(repeating: "0", count: 99999).joined(separator: ",") + "]"
    guard let parsed = parse(atLimit, using: catalogLimits) else { return }
    guard case .array(let values) = parsed else { return XCTFail("Catalog array kind was lost") }
    XCTAssertEqual(values.count, 99999)
    let excessive = "[" + Array(repeating: "0", count: 100000).joined(separator: ",") + "]"
    refuses(excessive, using: catalogLimits, label: "Root plus 100,000 values exceeds catalog cap")
  }

  func testByteBoundaryAndDuplicateEscapedKeys() {
    guard
      let parsed = parse(
        "0  ", using: .init(maximumBytes: 3, maximumDepth: 16, maximumValues: 2))
    else { return }
    guard case .number(let number) = parsed else { return XCTFail("Number kind was lost") }
    XCTAssertEqual(number, "0")
    refuses(
      "0   ", using: .init(maximumBytes: 3, maximumDepth: 16, maximumValues: 2),
      label: "Byte maximum plus one")
    refuses(#"{"name":1,"na\u006de":2}"#, using: limits, label: "Escaped duplicate key")
  }
}
