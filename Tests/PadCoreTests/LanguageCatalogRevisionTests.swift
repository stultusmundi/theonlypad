import Foundation
import XCTest

@testable import PadCore

final class LanguageCatalogRevisionTests: XCTestCase {
  func testSuppliedRevisionAppearsInResolvedProofAndRawEquality() throws {
    let d = try CatalogTestFixture.definition()
    let snapshot = try LanguageCatalogSnapshot(
      definitions: [d], overrides: [], generation: 9,
      definitionRevisions: [d.id: 3])
    let proof = CatalogTestFixture.profile(snapshot)
    XCTAssertEqual(proof.catalogGeneration, 9)
    XCTAssertEqual(proof.definitionRevision, 3)
    XCTAssertEqual(proof.definition?.id, d.id)
    let next = try LanguageCatalogSnapshot(
      definitions: [d], overrides: [], generation: 9,
      definitionRevisions: [d.id: 4])
    XCTAssertNotEqual(proof, CatalogTestFixture.profile(next))
    let draft = try LanguageCatalogSnapshot(definitions: [d], overrides: [], generation: 9)
    XCTAssertNil(CatalogTestFixture.profile(draft).definitionRevision)
  }
  func testRevisionInputRefusesZeroUnknownAndIncompleteInstalledMapping() throws {
    let d = try CatalogTestFixture.definition()
    let mappings: [[UUID: UInt64]] = [
      [d.id: 0], [CatalogTestFixture.otherID: 1],
      [d.id: 1, CatalogTestFixture.otherID: 1], [:],
    ]
    for entries in mappings {
      catalogRejects(
        {
          _ = try LanguageCatalogSnapshot(
            definitions: [d], overrides: [], generation: 9, definitionRevisions: entries)
        }, "Revision mapping must cover exactly installed known IDs with positive values")
    }
    let empty = try LanguageCatalogSnapshot(
      definitions: [], overrides: [], generation: 0, definitionRevisions: [:])
    XCTAssertTrue(empty.definitions.isEmpty)
  }
}
