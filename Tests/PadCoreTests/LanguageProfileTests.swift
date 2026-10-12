import Foundation
import XCTest

@testable import PadCore

/// Private Task 1 clients. No store, native editor or permit is exercised here.
final class LanguageProfileTests: XCTestCase {
  private let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
  private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!

  // Original synthetic bytes, independently authored rather than encoded by the implementation.
  private var originalJSON: Data {
    Data(
      #"""
      {"version":1,"id":"00000000-0000-4000-8000-000000000004","name":"Demo Language","fileExtensions":["demo"],"keywords":["let","café","cafe\u0301"],"lineComment":"#","blockComment":{"opening":"(*","closing":"*)"},"quotes":[{"opening":"\"","closing":"\"","escape":"\\","multiline":false}],"highlightDecimalNumbers":true,"indentation":{"kind":"spaces","width":2}}
      """#.utf8)
  }

  private func definition(
    id: UUID? = nil, name: String = "Demo Language", extensions: [String] = ["demo"],
    keywords: [String] = ["let"], line: String? = "#",
    block: BlockCommentDelimiters? = .init(opening: "(*", closing: "*)"),
    quotes: [LiteralQuoteRule] = [], indentation: LanguageIndentation = .spaces(width: 2)
  ) throws -> LiteralLanguageDefinition {
    try LiteralLanguageDefinition(
      id: id ?? profileID, name: name, fileExtensions: extensions, keywords: keywords,
      lineComment: line, blockComment: block, quotes: quotes,
      highlightDecimalNumbers: true, indentation: indentation)
  }

  private func decoded(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line)
    -> LiteralLanguageDefinition?
  {
    do { return try LanguageProfileCodec.decodeDefinition(bytes) } catch {
      XCTFail("A valid definition was refused: \(error)", file: file, line: line)
      return nil
    }
  }

  private func rejects(
    _ operation: () throws -> Void, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try operation()
      XCTFail("Invalid input was accepted: \(label)", file: file, line: line)
    } catch {
      // An unimplemented private baseline is not evidence that validation ran.
      XCTAssertNotEqual(
        error as? LanguageProfileError, .unimplemented, label, file: file, line: line)
      XCTAssertNotEqual(
        error as? BoundedProfileJSON.Failure, .unimplemented, label, file: file, line: line)
    }
  }

  private func changedJSON(_ needle: String, _ replacement: String) -> Data {
    let original = String(decoding: originalJSON, as: UTF8.self)
    XCTAssertTrue(original.contains(needle), "Independent fixture mutation must reach its field")
    return Data(original.replacingOccurrences(of: needle, with: replacement).utf8)
  }

  func testFixedOriginalJSONPreservesRawSpellingAndTypedFields() {
    guard let value = decoded(originalJSON) else { return }
    XCTAssertEqual(value.id, profileID)
    XCTAssertEqual(Array(value.name.utf16), Array("Demo Language".utf16))
    XCTAssertEqual(value.fileExtensions, ["demo"])
    XCTAssertEqual(value.keywords.count, 3)
    XCTAssertEqual(
      value.keywords.map { Array($0.utf16) },
      [
        [108, 101, 116], [99, 97, 102, 233], [99, 97, 102, 101, 769],
      ])
    XCTAssertEqual(value.lineComment.map { Array($0.utf16) }, [35])
    XCTAssertEqual(value.blockComment?.opening.utf16.map { $0 }, [40, 42])
    XCTAssertEqual(value.blockComment?.closing.utf16.map { $0 }, [42, 41])
    XCTAssertEqual(value.quotes.count, 1)
    guard let quote = value.quotes.first else { return XCTFail("Quote rule was lost") }
    XCTAssertEqual(Array(quote.opening.utf16), [34])
    XCTAssertEqual(Array(quote.closing.utf16), [34])
    XCTAssertEqual(quote.escape.map { Array($0.utf16) }, [92])
    XCTAssertFalse(quote.multiline)
    XCTAssertTrue(value.highlightDecimalNumbers)
    XCTAssertEqual(value.indentation, .spaces(width: 2))
  }

  func testValidEncodeThenDecodeHasIndependentLiteralOracles() throws {
    let quote = try LiteralQuoteRule(opening: "\"", closing: "\"", escape: "\\", multiline: false)
    let value = try definition(keywords: ["let", "café", "cafe\u{301}"], quotes: [quote])
    let bytes: Data
    do { bytes = try LanguageProfileCodec.encodeDefinition(value) } catch {
      return XCTFail("A valid export was refused: \(error)")
    }
    guard let result = decoded(bytes) else { return }
    XCTAssertEqual(result.id, profileID)
    XCTAssertEqual(
      result.keywords.map { Array($0.utf16) },
      [
        [108, 101, 116], [99, 97, 102, 233], [99, 97, 102, 101, 769],
      ])
    XCTAssertEqual(result.indentation, .spaces(width: 2))
    XCTAssertEqual(result.blockComment, .init(opening: "(*", closing: "*)"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      [
        "version", "id", "name", "fileExtensions", "keywords", "lineComment",
        "blockComment", "quotes", "highlightDecimalNumbers", "indentation",
      ])
    XCTAssertEqual(object["version"] as? Int, 1)
    XCTAssertNil(object["generation"])
    XCTAssertNil(object["revision"])
  }

  func testNullableFieldsAreExplicitAndNoLexicalMarkersIsValid() throws {
    let value = try definition(
      keywords: [], line: nil, block: nil, indentation: .tabs(width: 3))
    XCTAssertTrue(value.keywords.isEmpty)
    XCTAssertNil(value.lineComment)
    XCTAssertNil(value.blockComment)
    let bytes: Data
    do { bytes = try LanguageProfileCodec.encodeDefinition(value) } catch {
      return XCTFail("Valid editing-only definition was refused: \(error)")
    }
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertTrue(object["lineComment"] is NSNull)
    XCTAssertTrue(object["blockComment"] is NSNull)
    guard let result = decoded(bytes) else { return }
    XCTAssertEqual(result.indentation, .tabs(width: 3))
    XCTAssertTrue(result.quotes.isEmpty)
    XCTAssertNil(result.lineComment)
    XCTAssertNil(result.blockComment)
  }

  func testDefinitionAndEditingEqualityUseRawDelimiterIdentity() throws {
    let composed = try LiteralQuoteRule(
      opening: "é", closing: "!", escape: nil, multiline: false)
    let decomposed = try LiteralQuoteRule(
      opening: "e\u{301}", closing: "!", escape: nil, multiline: false)
    XCTAssertNotEqual(composed, decomposed)
    let composedBlock = BlockCommentDelimiters(opening: "é", closing: "!")
    let decomposedBlock = BlockCommentDelimiters(opening: "e\u{301}", closing: "!")
    XCTAssertNotEqual(composedBlock, decomposedBlock)
    XCTAssertNotEqual(
      ResolvedLanguageEditing(lineComment: "é", blockComment: nil, indentation: .legacy),
      ResolvedLanguageEditing(lineComment: "e\u{301}", blockComment: nil, indentation: .legacy))
    XCTAssertNotEqual(
      try definition(line: nil, block: nil, quotes: [composed]),
      try definition(line: nil, block: nil, quotes: [decomposed]))
    XCTAssertNotEqual(
      try definition(line: nil, block: composedBlock),
      try definition(line: nil, block: decomposedBlock))
    XCTAssertNotEqual(
      try definition(line: "é", block: nil),
      try definition(line: "e\u{301}", block: nil))
    XCTAssertNotEqual(
      try definition(keywords: ["café"]), try definition(keywords: ["cafe\u{301}"]))
    XCTAssertEqual(
      composed,
      try LiteralQuoteRule(
        opening: "é", closing: "!", escape: nil, multiline: false))
    let firstProof = ResolvedLanguageProfile(
      requestedID: .custom(profileID), catalogGeneration: 1, definitionRevision: 1,
      displayLabel: "Demo", builtinLanguage: nil, definition: nil,
      editing: .init(lineComment: "é", blockComment: nil, indentation: .legacy), warning: nil)
    let changedProof = ResolvedLanguageProfile(
      requestedID: .custom(profileID), catalogGeneration: 1, definitionRevision: 1,
      displayLabel: "Demo", builtinLanguage: nil, definition: nil,
      editing: .init(lineComment: "e\u{301}", blockComment: nil, indentation: .legacy), warning: nil
    )
    XCTAssertNotEqual(firstProof, changedProof)
  }

  func testCanonicalDistinctOpenersAndKeywordsRemainSeparatelyValid() throws {
    let first = try LiteralQuoteRule(opening: "é", closing: "!", escape: nil, multiline: false)
    let second = try LiteralQuoteRule(
      opening: "e\u{301}", closing: "?", escape: nil, multiline: false)
    let value = try definition(
      keywords: ["café", "cafe\u{301}"], line: nil, block: nil, quotes: [first, second])
    XCTAssertEqual(
      value.keywords.map { Array($0.utf16) },
      [
        [99, 97, 102, 233], [99, 97, 102, 101, 769],
      ])
    XCTAssertEqual(value.quotes.map { Array($0.opening.utf16) }, [[233], [101, 769]])
  }

  func testValidDefinitionFieldBoundaries() throws {
    let extensions = (0..<16).map { "abcdefghijklmn" + String(format: "%02d", $0) }
    let keywords = (0..<1024).map {
      "k" + String(format: "%04d", $0) + String(repeating: "x", count: 27)
    }  // 1,024 distinct 32-unit identifiers = exactly 32,768 units.
    let quotes = try (0..<4).map {
      try LiteralQuoteRule(
        opening: "q\($0)" + String(repeating: "x", count: 14),
        closing: "z\($0)" + String(repeating: "x", count: 14),
        escape: "\\", multiline: true)
    }
    let value = try definition(
      name: String(repeating: "😀", count: 80), extensions: extensions, keywords: keywords,
      line: String(repeating: "#", count: 32),
      block: .init(
        opening: String(repeating: "(", count: 32),
        closing: String(repeating: ")", count: 32)),
      quotes: quotes, indentation: .spaces(width: 1))
    XCTAssertEqual(value.name.unicodeScalars.count, 80)
    XCTAssertEqual(value.fileExtensions.count, 16)
    XCTAssertEqual(value.keywords.count, 1024)
    XCTAssertEqual(value.keywords.reduce(0) { $0 + $1.utf16.count }, 32768)
    XCTAssertEqual(value.indentation, .spaces(width: 1))
    XCTAssertEqual(try definition(indentation: .tabs(width: 8)).indentation, .tabs(width: 8))
    XCTAssertEqual(try definition(keywords: [String(repeating: "a", count: 64)]).keywords.count, 1)
  }

  func testInvalidNamesExtensionsAndWidthsRefuse() {
    for name in ["", String(repeating: "a", count: 81), "bad\nname", "bad\u{0}name"] {
      rejects({ _ = try self.definition(name: name) }, "name")
    }
    for extensions in [
      [""], ["Demo"], [".demo"], ["a/b"], ["a\\b"], ["é"], ["a-a"],
      [String(repeating: "a", count: 17)], ["demo", "demo"],
      (0..<17).map { "x\($0)" },
    ] {
      rejects({ _ = try self.definition(extensions: extensions) }, "extensions")
    }
    for policy in [
      LanguageIndentation.spaces(width: 0), .spaces(width: 9),
      .tabs(width: 0), .tabs(width: 9),
    ] {
      rejects({ _ = try self.definition(indentation: policy) }, "indentation")
    }
  }

  func testKeywordIdentityValidityAndAggregateBoundsRefuse() {
    for words in [
      ["let", "let"], [""], ["1st"], ["\u{301}first"], ["😀"], ["bad word"], ["bad\nword"],
      [String(repeating: "a", count: 65)], (0..<1025).map { "k\($0)" },
    ] {
      rejects({ _ = try self.definition(keywords: words) }, "keyword rule")
    }
    var words = (0..<1024).map {
      "k" + String(format: "%04d", $0) + String(repeating: "x", count: 27)
    }
    words[0] += "x"  // 32,769 total, while every identifier remains <=64.
    rejects({ _ = try self.definition(keywords: words) }, "aggregate keyword units")
  }

  func testDelimiterBoundsEscapeAndAmbiguityRefuse() throws {
    for delimiter in ["", "\n", "\r", "\u{0}", String(repeating: "#", count: 33)] {
      rejects({ _ = try self.definition(line: delimiter) }, "line delimiter")
      rejects(
        {
          _ = try self.definition(block: .init(opening: delimiter, closing: "*)"))
        }, "block opening")
      rejects(
        {
          _ = try self.definition(block: .init(opening: "(*", closing: delimiter))
        }, "block closing")
    }
    for delimiter in ["", "\n", "\u{0}", String(repeating: "q", count: 17)] {
      rejects(
        {
          _ = try LiteralQuoteRule(
            opening: delimiter, closing: "\"", escape: nil, multiline: false)
        }, "quote opening")
      rejects(
        {
          _ = try LiteralQuoteRule(
            opening: "\"", closing: delimiter, escape: nil, multiline: false)
        }, "quote closing")
    }
    for escape in ["", "ab", "é", "\n", "\u{0}"] {
      rejects(
        {
          _ = try LiteralQuoteRule(
            opening: "\"", closing: "\"", escape: escape, multiline: false)
        }, "escape")
    }
    let quote = try LiteralQuoteRule(opening: "#", closing: "\"", escape: nil, multiline: false)
    rejects({ _ = try self.definition(quotes: [quote]) }, "line/quote equal opener")
    rejects(
      {
        _ = try self.definition(line: "(*", block: .init(opening: "(*", closing: "*)"))
      }, "line/block equal opener")
    let other = try LiteralQuoteRule(opening: "#", closing: "'", escape: nil, multiline: true)
    rejects(
      { _ = try self.definition(line: nil, quotes: [quote, other]) }, "duplicate quote opener")
    rejects(
      { _ = try self.definition(line: nil, quotes: Array(repeating: quote, count: 5)) },
      "quote count")
  }

  func testStrictCodecRejectsUnknownDuplicateMissingAndTypedFields() {
    let samples: [Data] = [
      changedJSON(#""version":1"#, #""version":2"#),
      changedJSON(#""version":1"#, #""version":1,"unknown":null"#),
      changedJSON(#""name":"Demo Language""#, #""name":"Demo Language","na\u006de":"Again""#),
      changedJSON(##""lineComment":"#","##, ""),
      changedJSON(##""lineComment":"#""##, #""lineComment":false"#),
      changedJSON(#""id":"00000000-0000-4000-8000-000000000004""#, #""id":"not-a-uuid""#),
      changedJSON(#""keywords":["let","café","cafe\u0301"]"#, #""keywords":["let","let"]"#),
      changedJSON(#""multiline":false"#, #""multiline":"false""#),
      changedJSON(#""highlightDecimalNumbers":true"#, #""highlightDecimalNumbers":null"#),
      changedJSON(#""name":"Demo Language""#, #""name":"\ud800""#),
      changedJSON(#""quotes":["#, #""quotes":[{"unknown":null},"#),
      Data(originalJSON + Data(" trailing".utf8)),
    ]
    for (index, bytes) in samples.enumerated() {
      rejects({ _ = try LanguageProfileCodec.decodeDefinition(bytes) }, "strict codec \(index)")
    }
  }

  func testDefinitionImportByteLimitAllowsExactBoundaryThenRejectsNextByte() {
    var bytes = originalJSON
    bytes.append(Data(repeating: 32, count: 65536 - bytes.count))
    guard let value = decoded(bytes) else { return }
    XCTAssertEqual(value.id, profileID)
    bytes.append(32)
    rejects({ _ = try LanguageProfileCodec.decodeDefinition(bytes) }, "65,537-byte import")
  }

  func testCatalogCapacityDuplicateIDAndExtensionOwnership() throws {
    let profiles = try (0..<64).map { index in
      try definition(
        id: UUID(uuidString: "00000000-0000-4000-8000-" + String(format: "%012d", index + 100))!,
        extensions: [])
    }
    let catalog = try LanguageCatalogSnapshot(definitions: profiles, overrides: [], generation: 1)
    XCTAssertEqual(catalog.definitions.count, 64)
    rejects(
      {
        _ = try LanguageCatalogSnapshot(
          definitions: profiles + [self.definition(id: self.otherID, extensions: [])],
          overrides: [], generation: 1)
      }, "65 profiles")
    let first = try definition()
    rejects(
      {
        _ = try LanguageCatalogSnapshot(
          definitions: [first, first], overrides: [], generation: 1)
      }, "duplicate UUID")
    let second = try definition(id: otherID, name: "Other")
    rejects(
      {
        _ = try LanguageCatalogSnapshot(
          definitions: [first, second], overrides: [], generation: 1)
      }, "custom extension collision")
  }

  func testManualStableIDSurvivesDuplicateNameAndRename() throws {
    let first = try definition()
    let other = try definition(id: otherID, extensions: ["other"])
    let snapshot = try LanguageCatalogSnapshot(
      definitions: [first, other], overrides: [], generation: 7)
    let resolved = snapshot.resolve(
      selection: .manual(.custom(otherID)), filename: "a.demo", builtinDetected: .plainText)
    XCTAssertEqual(resolved.requestedID, .custom(otherID))
    XCTAssertEqual(resolved.definition?.id, otherID)
    XCTAssertEqual(resolved.editing.indentation, .spaces(width: 2))
    XCTAssertEqual(resolved.catalogGeneration, 7)
    XCTAssertNil(resolved.warning)
    let renamed = try definition(id: otherID, name: "Renamed", extensions: ["other"])
    let next = try LanguageCatalogSnapshot(
      definitions: [first, renamed], overrides: [], generation: 8)
    let current = next.resolve(
      selection: .manual(.custom(otherID)), filename: "a.demo", builtinDetected: .plainText)
    XCTAssertEqual(current.requestedID, .custom(otherID))
    XCTAssertEqual(current.definition?.id, otherID)
    XCTAssertEqual(current.displayLabel, "Renamed")
  }

  func testAutomaticBuiltinExtensionWinsThenCustomThenDetectedFallback() throws {
    let collision = try definition(extensions: ["swift", "demo"])
    let catalog = try LanguageCatalogSnapshot(
      definitions: [collision], overrides: [], generation: 3)
    let builtin = catalog.resolve(
      selection: .automatic, filename: "file.swift", builtinDetected: .swift)
    XCTAssertEqual(builtin.requestedID, .builtIn(.swift))
    XCTAssertEqual(builtin.builtinLanguage, .swift)
    XCTAssertNil(builtin.definition)
    let custom = catalog.resolve(
      selection: .automatic, filename: "file.demo", builtinDetected: .python)
    XCTAssertEqual(custom.requestedID, .custom(profileID))
    XCTAssertEqual(custom.definition?.id, profileID)
    let detected = catalog.resolve(
      selection: .automatic, filename: "script", builtinDetected: .python)
    XCTAssertEqual(detected.requestedID, .builtIn(.python))
    XCTAssertEqual(detected.builtinLanguage, .python)
    let manual = catalog.resolve(
      selection: .manual(.custom(profileID)), filename: "file.swift", builtinDetected: .swift)
    XCTAssertEqual(manual.requestedID, .custom(profileID))
    XCTAssertEqual(manual.definition?.id, profileID)
  }

  func testMissingManualIDRetainsReferenceAndSafeFallbackUntilReinstalled() throws {
    let empty = try LanguageCatalogSnapshot(definitions: [], overrides: [], generation: 4)
    let absent = empty.resolve(
      selection: .manual(.custom(profileID)), filename: "file.swift", builtinDetected: .swift)
    XCTAssertEqual(absent.requestedID, .custom(profileID))
    XCTAssertEqual(absent.builtinLanguage, .plainText)
    XCTAssertNil(absent.definition)
    XCTAssertNil(absent.editing.lineComment)
    XCTAssertNil(absent.editing.blockComment)
    XCTAssertEqual(absent.editing.indentation, .legacy)
    XCTAssertEqual(absent.warning, .missingProfile(profileID))
    let installed = try LanguageCatalogSnapshot(
      definitions: [definition()], overrides: [], generation: 5)
    let restored = installed.resolve(
      selection: .manual(.custom(profileID)), filename: "file.swift", builtinDetected: .swift)
    XCTAssertEqual(restored.requestedID, .custom(profileID))
    XCTAssertEqual(restored.definition?.id, profileID)
    XCTAssertNil(restored.warning)
  }

  func testBuiltinOverridesDistinguishInheritedDisabledAndLiteralPolicies() throws {
    let inherited = try BuiltInLanguageOverride(
      language: .swift, lineComment: .inherit, blockComment: .inherit, indentation: .legacy)
    let disabled = try BuiltInLanguageOverride(
      language: .swift, lineComment: .disabled, blockComment: .disabled,
      indentation: .tabs(width: 3))
    let literal = try BuiltInLanguageOverride(
      language: .swift, lineComment: .literal("#"),
      blockComment: .literal(.init(opening: "(*", closing: "*)")), indentation: .spaces(width: 2))
    let snapshots = try [inherited, disabled, literal].map {
      try LanguageCatalogSnapshot(definitions: [], overrides: [$0], generation: 1)
    }
    let values = snapshots.map {
      $0.resolve(selection: .manual(.builtIn(.swift)), filename: "a.swift", builtinDetected: .swift)
    }
    XCTAssertEqual(values[0].editing.lineComment, "//")
    XCTAssertEqual(values[0].editing.blockComment, .init(opening: "/*", closing: "*/"))
    XCTAssertEqual(values[0].editing.indentation, .legacy)
    XCTAssertNil(values[1].editing.lineComment)
    XCTAssertNil(values[1].editing.blockComment)
    XCTAssertEqual(values[1].editing.indentation, .tabs(width: 3))
    XCTAssertEqual(values[2].editing.lineComment, "#")
    XCTAssertEqual(values[2].editing.blockComment, .init(opening: "(*", closing: "*)"))
    XCTAssertEqual(values[2].editing.indentation, .spaces(width: 2))
    for value in values {
      XCTAssertEqual(value.requestedID, .builtIn(.swift))
      XCTAssertEqual(value.builtinLanguage, .swift)
      XCTAssertNil(value.definition)
    }
    rejects(
      {
        _ = try LanguageCatalogSnapshot(
          definitions: [], overrides: [inherited, disabled], generation: 1)
      }, "duplicate built-in override")
  }
}
