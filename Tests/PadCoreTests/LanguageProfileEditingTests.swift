import Foundation
import XCTest

@testable import PadCore

final class LanguageProfileEditingTests: XCTestCase {
  // Whole-range adapter: original seven expected outputs remain exact.
  private func profileIndentation(
    _ command: LanguageIndentationCommand, text: String, profile: ResolvedLanguageProfile
  ) throws -> String {
    try LanguageIndentationEditing.apply(
      command: command, text: text, selection: NSRange(location: 0, length: text.utf16.count),
      policy: profile.editing.indentation
    ).text
  }

  private func custom(
    line: String? = "##", block: BlockCommentDelimiters? = .init(opening: "<:", closing: ":>"),
    indentation: LanguageIndentation = .legacy
  ) throws -> ResolvedLanguageProfile {
    let definition = try LiteralLanguageDefinition(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, name: "Editing",
      fileExtensions: ["edit"], keywords: [], lineComment: line, blockComment: block, quotes: [],
      highlightDecimalNumbers: false, indentation: indentation)
    return try LanguageCatalogSnapshot(definitions: [definition], overrides: [], generation: 1)
      .resolve(
        selection: .manual(.custom(definition.id)), filename: "file.swift", builtinDetected: .swift)
  }

  func testCustomLineCommentRoundTripPreservesMixedEndingsAndEmojiSelection() throws {
    let profile = try custom()
    let original = "  😀\r\n\tbeta\n"
    let expected = "  ## 😀\r\n\t## beta\n"
    let changed: LineCommandResult
    do {
      changed = try LanguageEditing.toggleLineComment(
        text: original, selection: NSRange(location: 0, length: 12), profile: profile)
    } catch { return XCTFail("Valid custom line operation refused: \(error)") }
    XCTAssertEqual(Array(changed.text.utf16), Array(expected.utf16))
    XCTAssertEqual(changed.selection, NSRange(location: 0, length: 18))
    let restored = try LanguageEditing.toggleLineComment(
      text: changed.text, selection: changed.selection, profile: profile)
    XCTAssertEqual(Array(restored.text.utf16), Array(original.utf16))
    XCTAssertEqual(restored.selection, NSRange(location: 0, length: 12))
  }

  func testCanonicallyDistinctExistingLinePrefixIsNotRemoved() throws {
    let profile = try custom(line: "é", block: nil)
    let input = "e\u{301} beta"
    let changed: LineCommandResult
    do {
      changed = try LanguageEditing.toggleLineComment(
        text: input, selection: NSRange(location: 0, length: 0), profile: profile)
    } catch { return XCTFail("Valid raw-prefix operation refused: \(error)") }
    XCTAssertEqual(Array(changed.text.utf16), Array("é e\u{301} beta".utf16))
    XCTAssertEqual(changed.selection, NSRange(location: 2, length: 0))
    let restored = try LanguageEditing.toggleLineComment(
      text: changed.text, selection: changed.selection, profile: profile)
    XCTAssertEqual(Array(restored.text.utf16), Array(input.utf16))
    XCTAssertEqual(restored.selection, NSRange(location: 0, length: 0))
  }

  func testRawBlockSafetyAcceptsDistinctSpellingButRefusesActualDelimiter() throws {
    let profile = try custom(line: nil, block: .init(opening: "é", closing: "!"))
    let input = "e\u{301} 😀"
    let changed: LineCommandResult
    do {
      changed = try LanguageEditing.toggleBlockComment(
        text: input, selection: NSRange(location: 0, length: 5), profile: profile)
    } catch { return XCTFail("Canonically distinct raw content must remain safe: \(error)") }
    XCTAssertEqual(Array(changed.text.utf16), Array("ée\u{301} 😀!".utf16))
    XCTAssertEqual(changed.selection, NSRange(location: 0, length: 7))
    let restored = try LanguageEditing.toggleBlockComment(
      text: changed.text, selection: changed.selection, profile: profile)
    XCTAssertEqual(Array(restored.text.utf16), Array(input.utf16))
    XCTAssertEqual(restored.selection, NSRange(location: 0, length: 5))
    for unsafe in ["é inside", "inside !"] {
      do {
        _ = try LanguageEditing.toggleBlockComment(
          text: unsafe, selection: NSRange(location: 0, length: unsafe.utf16.count),
          profile: profile)
        XCTFail("Actual raw comment delimiter must be refused")
      } catch LanguageEditingError.unsafeBlockContent {} catch {
        XCTFail("Expected unsafe-content refusal, got \(error)")
      }
    }
  }

  func testBuiltinOverrideDisablesLineCommentsAndUsesLiteralBlockMarker() throws {
    let override = try BuiltInLanguageOverride(
      language: .swift, lineComment: .disabled,
      blockComment: .literal(.init(opening: "<:", closing: ":>")), indentation: .spaces(width: 3))
    let profile = try LanguageCatalogSnapshot(definitions: [], overrides: [override], generation: 1)
      .resolve(
        selection: .manual(.builtIn(.swift)), filename: "file.swift", builtinDetected: .swift)
    do {
      _ = try LanguageEditing.toggleLineComment(
        text: "swift", selection: NSRange(location: 0, length: 5), profile: profile)
      XCTFail("Explicit disabled line comments must refuse")
    } catch LanguageEditingError.unsupported {} catch {
      XCTFail("Expected unsupported refusal, got \(error)")
    }
    let changed: LineCommandResult
    do {
      changed = try LanguageEditing.toggleBlockComment(
        text: "swift", selection: NSRange(location: 0, length: 5), profile: profile)
    } catch { return XCTFail("Valid builtin override refused: \(error)") }
    XCTAssertEqual(changed.text, "<:swift:>")
    XCTAssertEqual(changed.selection, NSRange(location: 0, length: 9))
    XCTAssertEqual(try profileIndentation(.indent, text: "swift", profile: profile), "   swift")
    // The legacy entry point remains independent of catalog overrides.
    XCTAssertEqual(
      try LanguageEditing.toggleLineComment(
        text: "swift", selection: NSRange(location: 0, length: 5), language: .swift
      ).text, "// swift")
  }

  func testExplicitSpacesAndTabsPreserveMixedSeparatorsAndRoundTrip() throws {
    let input = "😀\r\nbeta\rcafe\u{301}\n"
    for width in [1, 3, 8] {
      let spaces = try custom(indentation: .spaces(width: width))
      let prefix = String(repeating: " ", count: width)
      let expected = prefix + "😀\r\n" + prefix + "beta\r" + prefix + "cafe\u{301}\n"
      let changed = try profileIndentation(.indent, text: input, profile: spaces)
      XCTAssertEqual(Array(changed.utf16), Array(expected.utf16))
      XCTAssertEqual(
        Array(try profileIndentation(.outdent, text: changed, profile: spaces).utf16),
        Array(input.utf16))
      XCTAssertEqual(
        try profileIndentation(.outdent, text: "  x\n\ty", profile: spaces),
        String(repeating: " ", count: max(0, 2 - width)) + "x\ny")
      let tabs = try custom(indentation: .tabs(width: width))
      let tabbed = try profileIndentation(.indent, text: input, profile: tabs)
      XCTAssertEqual(Array(tabbed.utf16), Array("\t😀\r\n\tbeta\r\tcafe\u{301}\n".utf16))
      XCTAssertEqual(
        Array(try profileIndentation(.outdent, text: tabbed, profile: tabs).utf16),
        Array(input.utf16))
    }
  }

  func testLegacyAndMissingProfilePreserveExistingBehavior() throws {
    let catalog = try LanguageCatalogSnapshot(definitions: [], overrides: [], generation: 0)
    let legacy = catalog.resolve(selection: .automatic, filename: "file.go", builtinDetected: .go)
    XCTAssertEqual(
      try profileIndentation(.indent, text: "x\r\ny", profile: legacy), "    x\r\n    y")
    XCTAssertEqual(try profileIndentation(.outdent, text: "   x\r\n\ty", profile: legacy), "x\r\ny")
    let missingID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
    let missing = catalog.resolve(
      selection: .manual(.custom(missingID)), filename: "file.swift", builtinDetected: .swift)
    XCTAssertEqual(missing.warning, .missingProfile(missingID))
    XCTAssertEqual(try profileIndentation(.indent, text: "x", profile: missing), "    x")
    for block in [false, true] {
      do {
        if block {
          _ = try LanguageEditing.toggleBlockComment(
            text: "x", selection: NSRange(location: 0, length: 1), profile: missing)
        } else {
          _ = try LanguageEditing.toggleLineComment(
            text: "x", selection: NSRange(location: 0, length: 1), profile: missing)
        }
        XCTFail("Missing profile fallback has no comment syntax")
      } catch LanguageEditingError.unsupported {} catch {
        XCTFail("Expected unsupported fallback, got \(error)")
      }
    }
  }

  func testCommentProfileCancellationAndScalarSelectionRefuseWithoutResult() throws {
    let profile = try custom()
    for block in [false, true] {
      do {
        if block {
          _ = try LanguageEditing.toggleBlockComment(
            text: "😀", selection: NSRange(location: 0, length: 2), profile: profile,
            isCancelled: { true })
        } else {
          _ = try LanguageEditing.toggleLineComment(
            text: "😀", selection: NSRange(location: 0, length: 2), profile: profile,
            isCancelled: { true })
        }
        XCTFail("Cancelled profile edit cannot return a result")
      } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
      do {
        if block {
          _ = try LanguageEditing.toggleBlockComment(
            text: "😀", selection: NSRange(location: 1, length: 0), profile: profile)
        } else {
          _ = try LanguageEditing.toggleLineComment(
            text: "😀", selection: NSRange(location: 1, length: 0), profile: profile)
        }
        XCTFail("Selection may not divide a supplementary scalar")
      } catch LanguageEditingError.invalidSelection {} catch {
        XCTFail("Expected invalid scalar selection, got \(error)")
      }
    }
  }
}
