import XCTest

@testable import PadCore

final class TabOrderTests: XCTestCase {
  private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

  func testReorderUsesFinalIndexInBothDirections() throws {
    XCTAssertEqual(try TabOrder.reordered(items: [a, b, c], moving: a, to: 2), [b, c, a])
    XCTAssertEqual(try TabOrder.reordered(items: [a, b, c], moving: c, to: 0), [c, a, b])
    XCTAssertEqual(try TabOrder.reordered(items: [a, b, c], moving: b, to: 1), [a, b, c])
  }
  func testInvalidOrderInputsAreRejected() {
    XCTAssertThrowsError(try TabOrder.reordered(items: [a, a], moving: a, to: 0)) {
      XCTAssertEqual($0 as? TabOrderError, .duplicateID)
    }
    XCTAssertThrowsError(try TabOrder.reordered(items: [a, b], moving: c, to: 0)) {
      XCTAssertEqual($0 as? TabOrderError, .missingItem)
    }
    for index in [-1, 2, Int.max] {
      XCTAssertThrowsError(try TabOrder.reordered(items: [a, b], moving: a, to: index)) {
        XCTAssertEqual($0 as? TabOrderError, .invalidIndex)
      }
    }
  }
  func testCloseProjectionsPreserveOrderAndKeepAnchor() throws {
    XCTAssertEqual(try TabOrder.closingOthers(items: [a, b, c], keeping: b), [b])
    XCTAssertEqual(try TabOrder.closingRight(items: [a, b, c], after: b), [a, b])
    XCTAssertEqual(try TabOrder.closingRight(items: [a, b, c], after: c), [a, b, c])
    XCTAssertThrowsError(try TabOrder.closingOthers(items: [a], keeping: b))
    XCTAssertThrowsError(try TabOrder.closingRight(items: [a, a], after: a))
  }
  func testPinnedFirstIsStableAndDoesNotChangeMetadata() throws {
    let items = [
      TabItem(id: a, title: "A", dirty: true, pinned: false),
      TabItem(id: b, title: "B", dirty: false, pinned: true),
      TabItem(id: c, title: "C", dirty: true, pinned: true),
    ]
    XCTAssertEqual(try TabOrder.pinnedFirst(items: items), [items[1], items[2], items[0]])
    XCTAssertThrowsError(try TabOrder.pinnedFirst(items: [items[0], items[0]])) {
      XCTAssertEqual($0 as? TabOrderError, .duplicateID)
    }
  }
}
