import Foundation
import XCTest

@testable import PadCore

final class XMLNamespaceFormattingTests: XCTestCase {
  func testDeclarationsApplyBeforeUsesAndDefaultNeverQualifiesAttributes() throws {
    let source =
      "<p:r p:x='1' xmlns:p='urn:p' xmlns='urn:p' x='2' xml:lang='en'><p:c/><child/></p:r>"
    let expected =
      "<p:r\n  p:x='1'\n  xmlns:p='urn:p'\n  xmlns='urn:p'\n  x='2'\n  xml:lang='en'\n><p:c/><child/></p:r>"
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    assertByteIdempotent(formatted)

    let explicitXML = "<r xmlns:xml='http://www.w3.org/XML/1998/namespace' xml:lang='en'/>"
    let expectedXML = "<r\n  xmlns:xml='http://www.w3.org/XML/1998/namespace'\n  xml:lang='en'\n/>"
    let formattedXML = try LanguageService.formatXML(explicitXML)
    XCTAssertEqual(Data(formattedXML.utf8), Data(expectedXML.utf8))
    assertByteIdempotent(formattedXML)
  }

  func testPrefixShadowAndEmptyTagScopesRestoreByExpandedAttributeIdentity() throws {
    let collisionAfterShadow =
      "<r xmlns:p='urn:outer'><x xmlns:p='urn:inner'><p:c/></x><a xmlns:q='urn:outer' p:v='1' q:v='2'/></r>"
    assertMalformed(collisionAfterShadow)

    let distinctAfterShadow =
      "<r xmlns:p='urn:outer'><x xmlns:p='urn:inner'><p:c/></x><a xmlns:q='urn:inner' p:v='1' q:v='2'/></r>"
    let expectedDistinct =
      "<r\n  xmlns:p='urn:outer'\n><x\n    xmlns:p='urn:inner'\n  ><p:c/></x><a\n    xmlns:q='urn:inner'\n    p:v='1'\n    q:v='2'\n  /></r>"
    let formattedDistinct = try LanguageService.formatXML(distinctAfterShadow)
    XCTAssertEqual(Data(formattedDistinct.utf8), Data(expectedDistinct.utf8))
    assertByteIdempotent(formattedDistinct)

    let emptyCollisionAfterShadow =
      "<r xmlns:p='urn:outer'><x xmlns:p='urn:inner'/><a xmlns:q='urn:outer' p:v='1' q:v='2'/></r>"
    assertMalformed(emptyCollisionAfterShadow)

    let emptyDistinctAfterShadow =
      "<r xmlns:p='urn:outer'><x xmlns:p='urn:inner'/><a xmlns:q='urn:inner' p:v='1' q:v='2'/></r>"
    let expectedEmptyDistinct =
      "<r\n  xmlns:p='urn:outer'\n><x\n    xmlns:p='urn:inner'\n  /><a\n    xmlns:q='urn:inner'\n    p:v='1'\n    q:v='2'\n  /></r>"
    let formattedEmptyDistinct = try LanguageService.formatXML(emptyDistinctAfterShadow)
    XCTAssertEqual(Data(formattedEmptyDistinct.utf8), Data(expectedEmptyDistinct.utf8))
    assertByteIdempotent(formattedEmptyDistinct)

    let emptyTagBindingMustNotEscape = "<r><x xmlns:p='urn:temporary'/><p:y/></r>"
    assertMalformed(emptyTagBindingMustNotEscape)

    let defaultScopeAndReset = "<r xmlns='urn:outer'><x xmlns=''><y/></x><z/></r>"
    let expectedDefaultScope = "<r\n  xmlns='urn:outer'\n><x\n    xmlns=''\n  ><y/></x><z/></r>"
    let formattedDefaultScope = try LanguageService.formatXML(defaultScopeAndReset)
    XCTAssertEqual(Data(formattedDefaultScope.utf8), Data(expectedDefaultScope.utf8))
    assertByteIdempotent(formattedDefaultScope)
  }

  func testReservedNamespaceAliasesAndDeclarationNamesRefuse() {
    let malformed = [
      "<r xmlns:p='http://www.w3.org/XML/1998/namespace' p:a='1'/>",
      "<r xmlns='http://www.w3.org/2000/xmlns/'/>",
      "<r xmlns:p='http://www.w3.org/2000/xmlns/'/>",
      "<r xmlns:p='http://www.w3.org/XML/1998/namespace'/>",
      "<r xmlns='http://www.w3.org/XML/1998/namespace'/>",
      "<r xmlns:xmlns='urn:any'/>",
      "<r xmlns:p=''/>",
      "<r xmlns:p='urn:x' xmlns:p='urn:x'/>",
      "<xmlns:r/>",
      "<r xmlns:p='http:&#x2F;&#x2F;www.w3.org/XML/1998/namespace'/>",
      "<r xmlns:p='http:&#x2F;&#x2F;www.w3.org/2000/xmlns/'/>",
    ]
    for source in malformed { assertMalformed(source) }

    let legalControls = [
      (
        "<r xmlns=''><xmlns/><xmlfoo:item xmlns:xmlfoo='urn:ordinary'/></r>",
        "<r\n  xmlns=''\n><xmlns/><xmlfoo:item\n    xmlns:xmlfoo='urn:ordinary'\n  /></r>"
      ),
      (
        "<r xmlns:xml='http://www.w3.org/XML/1998/namespace' xml:lang='en'/>",
        "<r\n  xmlns:xml='http://www.w3.org/XML/1998/namespace'\n  xml:lang='en'\n/>"
      ),
      (
        "<r xmlns:XML='urn:ordinary' XML:x='1'/>",
        "<r\n  xmlns:XML='urn:ordinary'\n  XML:x='1'\n/>"
      ),
    ]
    for (source, expected) in legalControls {
      do {
        let formatted = try LanguageService.formatXML(source)
        XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(try LanguageService.formatXML(formatted).utf8), Data(expected.utf8))
      } catch {
        XCTFail("Expected legal namespace control, got \(type(of: error)).")
      }
    }
  }

  func testQNameNCNameScalarBoundariesAndPITargetRules() throws {
    let validNames = [
      "_a", "A", "\u{C0}x", "\u{D6}x", "\u{D8}x", "\u{F6}x", "\u{F8}x", "\u{2FF}x",
      "a\u{300}", "π", "根", "\u{EFFFF}",
    ]
    let validSource = "<r>" + validNames.map { "<\($0)/>" }.joined() + "</r>"
    let validExpected = validSource
    let validFormatted = try LanguageService.formatXML(validSource)
    XCTAssertEqual(Data(validFormatted.utf8), Data(validExpected.utf8))
    assertByteIdempotent(validFormatted)

    let invalidNames = [
      "<:a/>", "<a:/>", "<a:b:c/>", "<1a/>", "<\u{301}a/>", "<\u{37E}a/>", "<\u{F0000}a/>",
      "<r><?p:target data?></r>",
      "<r p:a='1'/>",
    ]
    for source in invalidNames { assertMalformed(source) }
  }

  func testNamespaceIdentityUsesExactPrefixLocalAndURIBytes() throws {
    let source =
      "<r xmlns:é='urn:one' xmlns:e\u{301}='urn:two' xmlns:p='urn:local' é:x='1' e\u{301}:x='2' p:é='3' p:e\u{301}='4'/>"
    let expected =
      "<r\n  xmlns:é='urn:one'\n  xmlns:e\u{301}='urn:two'\n  xmlns:p='urn:local'\n  é:x='1'\n  e\u{301}:x='2'\n  p:é='3'\n  p:e\u{301}='4'\n/>"
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    assertByteIdempotent(formatted)
    XCTAssertNotEqual(Data("é".utf8), Data("e\u{301}".utf8))

    assertMalformed("<é></e\u{301}>")

    let caseAndPercentDistinct =
      "<r xmlns:a='urn:Value' xmlns:b='urn:value' xmlns:c='urn:%41' xmlns:d='urn:A' a:k='1' b:k='2' c:m='3' d:m='4'/>"
    let expectedCaseAndPercent =
      "<r\n  xmlns:a='urn:Value'\n  xmlns:b='urn:value'\n  xmlns:c='urn:%41'\n  xmlns:d='urn:A'\n  a:k='1'\n  b:k='2'\n  c:m='3'\n  d:m='4'\n/>"
    let formattedCaseAndPercent = try LanguageService.formatXML(caseAndPercentDistinct)
    XCTAssertEqual(Data(formattedCaseAndPercent.utf8), Data(expectedCaseAndPercent.utf8))
    assertByteIdempotent(formattedCaseAndPercent)
  }

  func testNamespaceValueNormalizationIsSinglePassAndBytePreserving() throws {
    let equivalentReferences =
      "<r xmlns:p='urn:x&amp;y' xmlns:q='urn:x&#38;y' p:a='1' q:a='2'/>"
    assertMalformed(equivalentReferences)

    let literalWhitespaceCollisions = [
      "<r xmlns:p='urn:x\r\ny' xmlns:q='urn:x y' p:a='1' q:a='2'/>",
      "<r xmlns:p='urn:x\ry' xmlns:q='urn:x y' p:a='1' q:a='2'/>",
      "<r xmlns:p='urn:x\ny' xmlns:q='urn:x y' p:a='1' q:a='2'/>",
      "<r xmlns:p='urn:x\ty' xmlns:q='urn:x y' p:a='1' q:a='2'/>",
      "<r xmlns:p='urn:x&#32;y' xmlns:q='urn:x y' p:a='1' q:a='2'/>",
    ]
    for source in literalWhitespaceCollisions { assertMalformed(source) }

    let onePassReferenceLikeBytes =
      "<r xmlns:p='urn:x&amp;#38;y' xmlns:q='urn:x&amp;y' p:a='1' q:a='2'/>"
    let expectedOnePass =
      "<r\n  xmlns:p='urn:x&amp;#38;y'\n  xmlns:q='urn:x&amp;y'\n  p:a='1'\n  q:a='2'\n/>"
    let formattedOnePass = try LanguageService.formatXML(onePassReferenceLikeBytes)
    XCTAssertEqual(Data(formattedOnePass.utf8), Data(expectedOnePass.utf8))
    assertByteIdempotent(formattedOnePass)

  }

  func testNamespaceHeavyInputRespectsExistingCapsAndCancellationRemainsTyped() throws {
    let declarations = (0..<256).map { index in
      "xmlns:p\(String(format: "%03d", index))='u\(index)'"
    }
    let source = "<r " + declarations.joined(separator: " ") + "/>"
    XCTAssertLessThan(source.utf8.count, 2_000_000)
    XCTAssertLessThan(source.utf8.count, 65_536)
    let expectedAttributes = declarations.map { "  \($0)" }.joined(separator: "\n")
    let expected = "<r\n\(expectedAttributes)\n/>"
    XCTAssertLessThan(expected.utf8.count, 65_536)
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    assertByteIdempotent(formatted)

    let cancelledSource = "<r xmlns:p='urn:p'><p:x/></r>"
    let before = Data(cancelledSource.utf8)
    do {
      _ = try LanguageService.formatXML(cancelledSource, isCancelled: { true })
      XCTFail("Expected cancellation.")
    } catch let error as LanguageError {
      switch error {
      case .cancelled: break
      case .analysisLimit: XCTFail("Expected cancellation, received an analysis limit.")
      }
    } catch {
      XCTFail("Expected LanguageError, received \(type(of: error)).")
    }
    XCTAssertEqual(Data(cancelledSource.utf8), before)
  }

  private func assertByteIdempotent(
    _ formatted: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let second = try LanguageService.formatXML(formatted)
      XCTAssertEqual(Data(second.utf8), Data(formatted.utf8), file: file, line: line)
    } catch {
      XCTFail(
        "A successful result must be admissible again; got \(type(of: error)).", file: file,
        line: line)
    }
  }

  private func assertMalformed(
    _ source: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let original = Data(source.utf8)
    do {
      _ = try LanguageService.formatXML(source)
      XCTFail("Expected malformed XML refusal.", file: file, line: line)
    } catch let error as XMLFormattingError {
      XCTAssertEqual(error, .malformed, file: file, line: line)
    } catch {
      XCTFail("Expected XMLFormattingError, received \(type(of: error)).", file: file, line: line)
    }
    XCTAssertEqual(Data(source.utf8), original, file: file, line: line)
  }
}
