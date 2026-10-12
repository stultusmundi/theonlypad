import Foundation
import XCTest

@testable import PadCore

final class LanguageCatalogCodecTests: XCTestCase {
  private func decode(_ bytes: Data) -> LanguageCatalogSnapshot? {
    do { return try LanguageCatalogCodec.decode(bytes) } catch {
      XCTFail("Valid independent catalog refused: \(error)")
      return nil
    }
  }

  func testFixedCatalogCarriesExactDefinitionRevisionOverrideAndRawKeywords() {
    guard let snapshot = decode(CatalogTestFixture.originalBytes) else { return }
    XCTAssertEqual(snapshot.generation, 7)
    XCTAssertEqual(snapshot.definitions.count, 1)
    let profile = CatalogTestFixture.profile(snapshot)
    XCTAssertEqual(profile.requestedID, .custom(CatalogTestFixture.id))
    XCTAssertEqual(profile.definitionRevision, 3)
    XCTAssertEqual(
      profile.definition?.keywords.map { Array($0.utf16) },
      [
        [99, 97, 102, 233], [99, 97, 102, 101, 769],
      ])
    let builtin = snapshot.resolve(
      selection: .manual(.builtIn(.swift)), filename: "demo.demo", builtinDetected: .plainText)
    XCTAssertNil(builtin.editing.lineComment)
    XCTAssertEqual(builtin.editing.blockComment, .init(opening: "/*", closing: "*/"))
    XCTAssertEqual(builtin.editing.indentation, .tabs(width: 3))
  }

  func testExportThenReloadPreservesIndependentGenerationRevisionAndSchema() throws {
    let d = try CatalogTestFixture.definition()
    let override = try BuiltInLanguageOverride(
      language: .swift, lineComment: .disabled, blockComment: .inherit,
      indentation: .tabs(width: 3))
    let input = try LanguageCatalogSnapshot(
      definitions: [d], overrides: [override], generation: 7, definitionRevisions: [d.id: 3])
    let bytes: Data
    do { bytes = try LanguageCatalogCodec.encode(input) } catch {
      return XCTFail("Valid catalog export refused: \(error)")
    }
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["version", "generation", "profiles", "overrides"])
    XCTAssertEqual(object["version"] as? Int, 1)
    XCTAssertEqual(object["generation"] as? Int, 7)
    let records = try XCTUnwrap(object["profiles"] as? [[String: Any]])
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(Set(records[0].keys), ["revision", "definition"])
    XCTAssertEqual(records[0]["revision"] as? Int, 3)
    guard let result = decode(bytes) else { return }
    XCTAssertEqual(CatalogTestFixture.profile(result).definitionRevision, 3)
    XCTAssertEqual(result.definitions.first, d)
    XCTAssertEqual(result.overrides, [override])
  }

  func testCatalogRejectsUnknownDuplicateVersionAndMalformedRevision() {
    let invalid = [
      CatalogTestFixture.changed(#""version":1"#, #""version":2"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":7,"extra":0"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":7,"gen\u0065ration":7"#),
      CatalogTestFixture.changed(#""revision":3"#, #""revision":0"#),
      CatalogTestFixture.changed(#""revision":3"#, #""revision":3.0"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":1e0"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":-1"#),
      CatalogTestFixture.changed(#""generation":7"#, #""generation":18446744073709551616"#),
      CatalogTestFixture.changed(#""language":"swift""#, #""language":"invented""#),
      CatalogTestFixture.changed(#""kind":"disabled""#, #""kind":"disabled","value":"%""#),
      CatalogTestFixture.changed(#""kind":"tabs","width":3"#, #""kind":"tabs","width":9"#),
      Data("{malformed".utf8),
    ]
    for bytes in invalid {
      catalogRejects(
        { _ = try LanguageCatalogCodec.decode(bytes) }, "Strict owned catalog envelope")
    }
  }

  func testCatalogRejectsDuplicateIDsExtensionOwnersAndBuiltinOverrideRecords() {
    let profile = #"{"revision":3,"definition":"# + CatalogTestFixture.definitionText + "}"
    let duplicateID = CatalogTestFixture.originalText.replacingOccurrences(
      of: profile, with: profile + "," + profile)
    let otherDefinition = CatalogTestFixture.definitionText.replacingOccurrences(
      of: CatalogTestFixture.id.uuidString.lowercased(),
      with: CatalogTestFixture.otherID.uuidString.lowercased())
    let other = #"{"revision":1,"definition":"# + otherDefinition + "}"
    let duplicateExtension = CatalogTestFixture.originalText.replacingOccurrences(
      of: profile, with: profile + "," + other)
    let override =
      #"{"language":"swift","lineComment":{"kind":"disabled"},"blockComment":{"kind":"inherit"},"indentation":{"kind":"tabs","width":3}}"#
    XCTAssertTrue(CatalogTestFixture.originalText.contains(override))
    let duplicateOverride = CatalogTestFixture.originalText.replacingOccurrences(
      of: override, with: override + "," + override)
    for text in [duplicateID, duplicateExtension, duplicateOverride] {
      catalogRejects(
        { _ = try LanguageCatalogCodec.decode(Data(text.utf8)) },
        "Catalog duplicate identity/extension/override")
    }
  }

  func testCatalog64ProfilesValidAnd65RefusedWithoutDuplicateIdentity() {
    let records = (1...65).map { index -> String in
      let id = "00000000-0000-4000-8000-" + String(format: "%012d", index)
      let definition = CatalogTestFixture.definitionText
        .replacingOccurrences(of: CatalogTestFixture.id.uuidString.lowercased(), with: id)
        .replacingOccurrences(of: #"["demo"]"#, with: "[]")
      return #"{"revision":1,"definition":"# + definition + "}"
    }
    let prefix = #"{"version":1,"generation":1,"profiles":["#
    let suffix = #"],"overrides":[]}"#
    let exact = Data((prefix + records.prefix(64).joined(separator: ",") + suffix).utf8)
    guard let snapshot = decode(exact) else { return }
    XCTAssertEqual(snapshot.definitions.count, 64)
    XCTAssertEqual(Set(snapshot.definitions.map(\.id)).count, 64)
    for definition in snapshot.definitions {
      XCTAssertEqual(
        snapshot.resolve(
          selection: .manual(.custom(definition.id)), filename: "none", builtinDetected: .plainText
        )
        .definitionRevision, 1)
    }
    let tooMany = Data((prefix + records.joined(separator: ",") + suffix).utf8)
    catalogRejects({ _ = try LanguageCatalogCodec.decode(tooMany) }, "65 distinct profiles")
  }

  func testIndependentEmptyGenerationZeroCatalogIsValidAndExportsExactEmptyState() throws {
    let empty = Data(#"{"version":1,"generation":0,"profiles":[],"overrides":[]}"#.utf8)
    guard let snapshot = decode(empty) else { return }
    XCTAssertEqual(snapshot.generation, 0)
    XCTAssertTrue(snapshot.definitions.isEmpty)
    XCTAssertTrue(snapshot.overrides.isEmpty)
    let bytes: Data
    do { bytes = try LanguageCatalogCodec.encode(snapshot) } catch {
      return XCTFail("Valid empty default catalog export refused: \(error)")
    }
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(root.keys), ["version", "generation", "profiles", "overrides"])
    XCTAssertEqual(root["version"] as? Int, 1)
    XCTAssertEqual(root["generation"] as? Int, 0)
    XCTAssertEqual((root["profiles"] as? [Any])?.count, 0)
    XCTAssertEqual((root["overrides"] as? [Any])?.count, 0)
  }

  func testNonemptyGenerationZeroCatalogRefusesProfilesAndOverridesIndependently() {
    let originalAtZero = CatalogTestFixture.changed(#""generation":7"#, #""generation":0"#)
    let profilesOnly = Data(
      (#"{"version":1,"generation":0,"profiles":[{"revision":3,"definition":"#
        + CatalogTestFixture.definitionText + #"}],"overrides":[]}"#).utf8)
    let overridesOnly = Data(
      #"{"version":1,"generation":0,"profiles":[],"overrides":[{"language":"swift","lineComment":{"kind":"disabled"},"blockComment":{"kind":"inherit"},"indentation":{"kind":"tabs","width":3}}]}"#
        .utf8)
    for bytes in [originalAtZero, profilesOnly, overridesOnly] {
      catalogRejects(
        { _ = try LanguageCatalogCodec.decode(bytes) },
        "Stored generation0 represents only the empty default, not installed content")
    }
  }

  func testCatalogOneMiBIndependentCapAndDeepInputRefuseBeforePublication() {
    let padding = CustomLanguageStore.maximumBytes - CatalogTestFixture.originalBytes.count
    let exact = CatalogTestFixture.originalBytes + Data(repeating: 32, count: padding)
    guard let result = decode(exact) else { return }
    XCTAssertEqual(result.generation, 7)
    catalogRejects(
      {
        _ = try LanguageCatalogCodec.decode(exact + Data([32]))
      }, "Catalog byte cap plus one")
    let deep = Data(
      (String(repeating: "[", count: 17) + "0"
        + String(repeating: "]", count: 17)).utf8)
    catalogRejects({ _ = try LanguageCatalogCodec.decode(deep) }, "Catalog depth cap")
  }
}

final class LanguageCatalogNestedNumericTests: XCTestCase {
  func testOriginalIndependentDefinitionVersionOneRemainsValidInsideCatalog() {
    let snapshot: LanguageCatalogSnapshot
    do { snapshot = try LanguageCatalogCodec.decode(CatalogTestFixture.originalBytes) } catch {
      return XCTFail("Valid original nested definition refused: \(error)")
    }
    XCTAssertEqual(snapshot.generation, 7)
    XCTAssertEqual(snapshot.definitions.first?.id, CatalogTestFixture.id)
    XCTAssertEqual(CatalogTestFixture.profile(snapshot).definitionRevision, 3)
  }

  func testNestedDefinitionVersionMustRetainExactIntegerSpelling() {
    for version in ["1e0", "1.0"] {
      let bytes = CatalogTestFixture.changed(
        #""definition":{"version":1"#, #""definition":{"version":"# + version)
      catalogRejects(
        { _ = try LanguageCatalogCodec.decode(bytes) },
        "Nested version must not normalize through floating point/Foundation numbers")
    }
  }

  func testIndependentNestedSpacesWidthThreeRemainsValid() {
    let bytes = CatalogTestFixture.changed(
      #""indentation":{"kind":"legacy"}"#, #""indentation":{"kind":"spaces","width":3}"#)
    let snapshot: LanguageCatalogSnapshot
    do { snapshot = try LanguageCatalogCodec.decode(bytes) } catch {
      return XCTFail("Valid literal nested spaces width refused: \(error)")
    }
    XCTAssertEqual(CatalogTestFixture.profile(snapshot).editing.indentation, .spaces(width: 3))
    XCTAssertEqual(CatalogTestFixture.profile(snapshot).definitionRevision, 3)
  }

  func testNestedDefinitionIndentWidthMustRetainExactIntegerSpelling() {
    for width in ["3.0", "3e0"] {
      let bytes = CatalogTestFixture.changed(
        #""indentation":{"kind":"legacy"}"#,
        #""indentation":{"kind":"spaces","width":"# + width + "}")
      catalogRejects(
        { _ = try LanguageCatalogCodec.decode(bytes) },
        "Nested width must not normalize before Task1 strict definition validation")
    }
  }
}
