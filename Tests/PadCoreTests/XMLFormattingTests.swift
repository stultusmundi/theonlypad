import Foundation
import XCTest

@testable import PadCore

final class XMLFormattingTests: XCTestCase {
  func testMarkupLayoutAndIdempotence() throws {
    let source = "<r a = '1' b=\"2\"><x /></r>"
    let expected = "<r\n  a='1'\n  b=\"2\"\n><x/></r>"
    let first = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(first.utf8), Data(expected.utf8))
    let second = try LanguageService.formatXML(first)
    XCTAssertEqual(Data(second.utf8), Data(expected.utf8))

    let nested = try LanguageService.formatXML("<r><x a='1'/></r>")
    XCTAssertEqual(Data(nested.utf8), Data("<r><x\n    a='1'\n  /></r>".utf8))

    let noAttributes = try LanguageService.formatXML("<r   ><x  /></r>")
    XCTAssertEqual(Data(noAttributes.utf8), Data("<r><x/></r>".utf8))
    assertIdempotent(first)
    assertIdempotent(nested)
    assertIdempotent(noAttributes)
  }

  func testMixedContentAndSpaceScopesRemainExact() throws {
    let source =
      "  <p xml:space = 'preserve'> A <b k = 'v'> B </b> C <d xml:space=\"default\"> \n </d> </p>  "
    let expected =
      "  <p\n  xml:space='preserve'\n> A <b\n    k='v'\n  > B </b> C <d\n    xml:space=\"default\"\n  > \n </d> </p>  "
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    XCTAssertEqual(
      Data(try LanguageService.formatXML(formatted).utf8), Data(expected.utf8))
    assertIdempotent(formatted)
  }

  func testOpaqueCommentsCDATAAndProcessingInstructionsRemainExact() throws {
    let source =
      "<?xml-stylesheet href=\"file:///synthetic/not-read.xsl\"?><r b = '2'><!-- <!DOCTYPE r [<!ENTITY x SYSTEM 'https://example.invalid/x'>]> --><![CDATA[<x a='b'> &custom; ]]><?p <fake />?>😀e\u{301}<a c = \"3\"/></r>"
    let expected =
      "<?xml-stylesheet href=\"file:///synthetic/not-read.xsl\"?><r\n  b='2'\n><!-- <!DOCTYPE r [<!ENTITY x SYSTEM 'https://example.invalid/x'>]> --><![CDATA[<x a='b'> &custom; ]]><?p <fake />?>😀e\u{301}<a\n    c=\"3\"\n  /></r>"
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    XCTAssertEqual(Data(try LanguageService.formatXML(formatted).utf8), Data(expected.utf8))
    assertIdempotent(formatted)
  }

  func testQuotedValuesAndReferenceSpellingsArePreserved() throws {
    let source =
      "<r a = 'x &amp; &#x1F600; &#9;' b=\"tab\tcrlf\r\n&amp; &apos; &#x1F600;\" c = '&quot; &lt; &gt; &#65;'></r>"
    let expected =
      "<r\n  a='x &amp; &#x1F600; &#9;'\n  b=\"tab\tcrlf\r\n&amp; &apos; &#x1F600;\"\n  c='&quot; &lt; &gt; &#65;'\n></r>"
    let formatted = try LanguageService.formatXML(source)
    XCTAssertEqual(Data(formatted.utf8), Data(expected.utf8))
    XCTAssertEqual(Data(try LanguageService.formatXML(formatted).utf8), Data(expected.utf8))
  }

  func testUnicodeNamesNamespacesAndGeneratedLineEndings() throws {
    let source =
      "<π:根 xmlns:π = 'urn:例' π:属性='e\u{301}' plain='é'>left\r\nmiddle\rright\n<名 b = 'v'/></π:根>"
    let expectedCRLF =
      "<π:根\r\n  xmlns:π='urn:例'\r\n  π:属性='e\u{301}'\r\n  plain='é'\r\n>left\r\nmiddle\rright\n<名\r\n    b='v'\r\n  /></π:根>"
    let crlf = try LanguageService.formatXML(source, lineEnding: .crlf)
    XCTAssertEqual(Data(crlf.utf8), Data(expectedCRLF.utf8))
    assertIdempotent(crlf, lineEnding: .crlf)

    let expectedCR =
      "<π:根\r  xmlns:π='urn:例'\r  π:属性='e\u{301}'\r  plain='é'\r>left\r\nmiddle\rright\n<名\r    b='v'\r  /></π:根>"
    let cr = try LanguageService.formatXML(source, lineEnding: .cr)
    XCTAssertEqual(Data(cr.utf8), Data(expectedCR.utf8))
    assertIdempotent(cr, lineEnding: .cr)

    let expectedLF =
      "<π:根\n  xmlns:π='urn:例'\n  π:属性='e\u{301}'\n  plain='é'\n>left\r\nmiddle\rright\n<名\n    b='v'\n  /></π:根>"
    let lf = try LanguageService.formatXML(source, lineEnding: .lf)
    XCTAssertEqual(Data(lf.utf8), Data(expectedLF.utf8))
    assertIdempotent(lf, lineEnding: .lf)

    let precomposedAndDecomposed = "<r a='é' b='e\u{301}'/>"
    let distinction = try LanguageService.formatXML(precomposedAndDecomposed)
    XCTAssertEqual(
      Data(distinction.utf8), Data("<r\n  a='é'\n  b='e\u{301}'\n/>".utf8))
    assertIdempotent(distinction)
  }

  func testMalformedDocumentsRefuseWithoutPartialResult() {
    XCTAssertEqual(XMLFormattingError.malformed.errorDescription, "The XML document is malformed.")
    XCTAssertEqual(
      XMLFormattingError.unsupported(.doctype).errorDescription,
      "XML document type declarations are not supported.")
    XCTAssertEqual(
      XMLFormattingError.unsupported(.declaration).errorDescription,
      "This XML declaration is not supported.")
    XCTAssertEqual(
      XMLFormattingError.unsupported(.entity).errorDescription,
      "Custom XML entities are not supported.")
    let malformed = [
      "<r><x></r>",
      "<r>",
      "<r a='1' a='2'/>",
      "<r a=unquoted/>",
      "<r/><s/>",
      "outside<r/>",
      "<r><!-- unterminated</r>",
      "<r><![CDATA[unterminated</r>",
      "<r><?p unterminated</r>",
      "<r>bad ]]> text</r>",
      "<r>&#0;</r>",
      "<r>nul\u{0}</r>",
      "<p:r/>",
      "<r xmlns:xml='urn:not-the-xml-namespace'/>",
      "<r xmlns:xmlns='urn:reserved'/>",
      "<r xmlns:a='urn:same' xmlns:b='urn:same' a:x='1' b:x='2'/>",
    ]
    for source in malformed {
      assertFormattingError(.malformed) { try LanguageService.formatXML(source) }
    }
  }

  func testDeclarationAndEncodingPolicyIsExplicit() throws {
    let bomSource = "\u{FEFF}<?xml version='1.0' encoding='UTF-8'?><r a = '1'/>"
    let bomExpected = "\u{FEFF}<?xml version='1.0' encoding='UTF-8'?><r\n  a='1'\n/>"
    let bom = try LanguageService.formatXML(bomSource)
    XCTAssertEqual(Data(bom.utf8), Data(bomExpected.utf8))
    assertIdempotent(bom)

    let versionOnly = "<?xml version=\"1.0\"?><r a='1'/>"
    let formattedVersionOnly = try LanguageService.formatXML(versionOnly)
    XCTAssertEqual(
      Data(formattedVersionOnly.utf8), Data("<?xml version=\"1.0\"?><r\n  a='1'\n/>".utf8))
    assertIdempotent(formattedVersionOnly)

    for source in [
      "<?xml version='1.1'?><r/>",
      "<?xml version='1.0' encoding='UTF-16'?><r/>",
      "<?xml version='1.0' encoding='ISO-8859-1'?><r/>",
    ] {
      assertFormattingError(.unsupported(.declaration)) {
        try LanguageService.formatXML(source)
      }
    }
    assertFormattingError(.malformed) {
      try LanguageService.formatXML("<?xml version='1.0' standalone='maybe'?><r/>")
    }
  }

  func testDoctypeCustomEntitiesAndExternalFormsRefuse() throws {
    let doctypes = [
      "<!DOCTYPE r><r/>",
      "<!DOCTYPE r SYSTEM 'file:///synthetic/not-read.dtd'><r/>",
      "<!DOCTYPE r PUBLIC 'synthetic' 'https://example.invalid/not-read.dtd'><r/>",
      "<!DOCTYPE r [<!ENTITY x 'value'>]><r>&x;</r>",
      "<!DOCTYPE r [<!ENTITY % p SYSTEM 'file:///synthetic/not-read.dtd'>%p;]><r/>",
      "<!DOCTYPE r [<!ENTITY x SYSTEM 'https://example.invalid/not-read.ent'>]><r>&x;</r>",
    ]
    for source in doctypes {
      assertFormattingError(.unsupported(.doctype)) { try LanguageService.formatXML(source) }
    }
    for source in ["<r>&custom;</r>", "<r>&unknown;</r>"] {
      assertFormattingError(.unsupported(.entity)) { try LanguageService.formatXML(source) }
    }

    let opaque =
      "<r><!-- <!DOCTYPE x SYSTEM 'file:///synthetic/nope'> --><![CDATA[<!DOCTYPE x>]]></r>"
    XCTAssertEqual(Data(try LanguageService.formatXML(opaque).utf8), Data(opaque.utf8))
    assertIdempotent(opaque)
  }

  func testInclusiveResourceBoundsAndAmplificationRefusal() throws {
    let exactInput = "<r>" + String(repeating: "x", count: 1_999_993) + "</r>"
    XCTAssertEqual(exactInput.utf8.count, 2_000_000)
    let exactInputOutput = try LanguageService.formatXML(exactInput)
    XCTAssertEqual(Data(exactInputOutput.utf8), Data(exactInput.utf8))
    assertIdempotent(exactInputOutput)
    let overInput = "<r>" + String(repeating: "x", count: 1_999_994) + "</r>"
    XCTAssertEqual(overInput.utf8.count, 2_000_001)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(overInput) }

    let depth128 = String(repeating: "<r>", count: 128) + String(repeating: "</r>", count: 128)
    let formattedDepth128 = try LanguageService.formatXML(depth128)
    XCTAssertEqual(Data(formattedDepth128.utf8), Data(depth128.utf8))
    assertIdempotent(formattedDepth128)
    let depth129 = String(repeating: "<r>", count: 129) + String(repeating: "</r>", count: 129)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(depth129) }

    let attributes256 = (0..<256).map { "a\($0)='v'" }.joined(separator: " ")
    let source256 = "<r \(attributes256)/>"
    let formatted256 = try LanguageService.formatXML(source256)
    let expectedAttributes256 = (0..<256).map { "  a\($0)='v'" }.joined(separator: "\n")
    XCTAssertEqual(
      Data(formatted256.utf8), Data("<r\n\(expectedAttributes256)\n/>".utf8))
    assertIdempotent(formatted256)
    let attributes257 = (0..<257).map { "a\($0)='v'" }.joined(separator: " ")
    assertLanguageError(.analysisLimit) {
      try LanguageService.formatXML("<r \(attributes257)/>")
    }

    let name256 = String(repeating: "a", count: 256)
    let sourceName256 = "<\(name256)/>"
    let formattedName256 = try LanguageService.formatXML(sourceName256)
    XCTAssertEqual(Data(formattedName256.utf8), Data(sourceName256.utf8))
    assertIdempotent(formattedName256)
    let name257 = String(repeating: "a", count: 257)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML("<\(name257)/>") }

    let tokens100000 = "<r>" + String(repeating: "<i/>", count: 99_998) + "</r>"
    let formattedTokens100000 = try LanguageService.formatXML(tokens100000)
    XCTAssertEqual(Data(formattedTokens100000.utf8), Data(tokens100000.utf8))
    assertIdempotent(formattedTokens100000)
    let tokens100001 = "<r>" + String(repeating: "<i/>", count: 99_999) + "</r>"
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(tokens100001) }

    let exactMarkupPrefix = "<r\n  a='"
    let exactMarkupSuffix = "'\n>"
    let exactMarkupValue = String(
      repeating: "v", count: 65_536 - exactMarkupPrefix.utf8.count - exactMarkupSuffix.utf8.count)
    let exactMarkup = exactMarkupPrefix + exactMarkupValue + exactMarkupSuffix
    XCTAssertEqual(exactMarkup.utf8.count, 65_536)
    let exactMarkupDocument = exactMarkup + "</r>"
    let formattedExactMarkup = try LanguageService.formatXML(exactMarkupDocument)
    XCTAssertEqual(Data(formattedExactMarkup.utf8), Data(exactMarkupDocument.utf8))
    assertIdempotent(formattedExactMarkup)
    let overMarkup =
      exactMarkupPrefix + String(repeating: "v", count: exactMarkupValue.utf8.count + 1)
      + exactMarkupSuffix
    XCTAssertEqual(overMarkup.utf8.count, 65_537)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(overMarkup + "</r>") }

    let wrappers = 127
    let deepPrefix = String(repeating: "<w>", count: wrappers)
    let deepSuffix = String(repeating: "</w>", count: wrappers)
    let wideAttributes = (0..<256).map { index in
      "a\(String(format: "%03d", index))='\(String(repeating: "v", count: 220))'"
    }.joined(separator: " ")
    let expandedToken = deepPrefix + "<r \(wideAttributes)/>" + deepSuffix
    XCTAssertLessThan(expandedToken.utf8.count, 2_000_000)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(expandedToken) }

    let deepOpen = String(repeating: "<w>", count: wrappers)
    let deepClose = String(repeating: "</w>", count: wrappers)
    let attributes = (0..<32).map { "a\(String(format: "%02d", $0))='x'" }
    let compactAttributeTag = "<i " + attributes.joined(separator: " ") + "/>"
    let attributeIndent = String(repeating: " ", count: 256)
    let closeIndent = String(repeating: " ", count: 254)
    let formattedAttributeTag =
      "<i" + attributes.map { "\n\(attributeIndent)\($0)" }.joined()
      + "\n\(closeIndent)/>"
    XCTAssertLessThan(compactAttributeTag.utf8.count, 65_536)
    XCTAssertLessThan(formattedAttributeTag.utf8.count, 65_536)
    let siblingCount = 24
    let exactOutputWithoutPadding =
      deepOpen
      + String(repeating: formattedAttributeTag, count: siblingCount) + deepClose
    let paddingCount = 2_000_000 - exactOutputWithoutPadding.utf8.count
    let padding = String(repeating: "p", count: paddingCount)
    let exactOutputInput =
      deepOpen
      + String(repeating: compactAttributeTag, count: siblingCount) + padding + deepClose
    let exactOutput =
      deepOpen
      + String(repeating: formattedAttributeTag, count: siblingCount) + padding + deepClose
    XCTAssertEqual(exactOutput.utf8.count, 2_000_000)
    XCTAssertLessThan(exactOutputInput.utf8.count, 2_000_000)
    let formattedExactOutput = try LanguageService.formatXML(exactOutputInput)
    XCTAssertEqual(Data(formattedExactOutput.utf8), Data(exactOutput.utf8))
    assertIdempotent(formattedExactOutput)
    let overOutputInput =
      deepOpen
      + String(repeating: compactAttributeTag, count: siblingCount)
      + String(repeating: "p", count: paddingCount + 1) + deepClose
    XCTAssertLessThan(overOutputInput.utf8.count, 2_000_000)
    assertLanguageError(.analysisLimit) { try LanguageService.formatXML(overOutputInput) }
  }

  func testCooperativeCancellationRefusesBeforeReturningOutput() throws {
    assertLanguageError(.cancelled) {
      try LanguageService.formatXML("<r><a x='1'/></r>", isCancelled: { true })
    }

    let longText = String(repeating: "x", count: 350_000)
    let boundedMarkupPayload = String(repeating: "x", count: 50_000)
    let cancellationFixtures = [
      "<r a='\(boundedMarkupPayload)'/>",
      "<r>\(longText)</r>",
      "<r><!--\(boundedMarkupPayload)--></r>",
    ]
    for source in cancellationFixtures {
      let poller = CancellationAfterPolls(limit: 4)
      assertLanguageError(.cancelled) {
        try LanguageService.formatXML(source, isCancelled: { poller.shouldCancel() })
      }
    }

    let valid = try LanguageService.formatXML("<r a = 'v'><x/></r>", isCancelled: { false })
    XCTAssertEqual(Data(valid.utf8), Data("<r\n  a='v'\n><x/></r>".utf8))
    assertIdempotent(valid)
  }

  private func assertFormattingError(
    _ expected: XMLFormattingError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> String
  ) {
    do {
      _ = try operation()
      XCTFail("Expected XML formatting error \(expected).", file: file, line: line)
    } catch let actual as XMLFormattingError {
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
      XCTFail("Expected XMLFormattingError, received \(type(of: error)).", file: file, line: line)
    }
  }

  private func assertIdempotent(
    _ value: String,
    lineEnding: LineEnding = .lf,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let second = try LanguageService.formatXML(value, lineEnding: lineEnding)
      XCTAssertEqual(Data(second.utf8), Data(value.utf8), file: file, line: line)
    } catch {
      XCTFail("A successful formatted document must be admissible again.", file: file, line: line)
    }
  }

  private func assertLanguageError(
    _ expected: LanguageError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> String
  ) {
    do {
      _ = try operation()
      XCTFail("Expected LanguageError \(expected).", file: file, line: line)
    } catch let actual as LanguageError {
      switch (actual, expected) {
      case (.analysisLimit, .analysisLimit), (.cancelled, .cancelled): break
      default:
        XCTFail("Received the wrong LanguageError case.", file: file, line: line)
      }
    } catch {
      XCTFail("Expected LanguageError, received \(type(of: error)).", file: file, line: line)
    }
  }
}

private final class CancellationAfterPolls: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var count = 0

  init(limit: Int) { self.limit = limit }

  func shouldCancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count >= limit
  }
}
