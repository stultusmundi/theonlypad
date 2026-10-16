// SPDX-License-Identifier: MIT
// Bounded presentation values. Core remains the validation and catalog authority.
import Foundation
import PadCore

enum NativeLanguageManagerTarget: Equatable {
  case definition(UUID)
  case builtIn(DocumentLanguage)
}
enum NativeLanguageManagerIndentationKind: Equatable { case legacy, spaces, tabs }
enum NativeLanguageManagerCommentKind: Equatable { case inherit, disabled, literal }
struct NativeLanguageManagerRawQuote {
  let rowID: UUID
  var opening: String
  var closing: String
  var escapeEnabled: Bool
  var escapeText: String
  var multiline: Bool
}
struct NativeLanguageManagerRawDefinition {
  let id: UUID
  var name: String
  var extensionsText: String
  var keywordsText: String
  var lineEnabled: Bool
  var lineText: String
  var blockEnabled: Bool
  var blockOpening: String
  var blockClosing: String
  var quotes: [NativeLanguageManagerRawQuote]
  var highlightDecimalNumbers: Bool
  var indentationKind: NativeLanguageManagerIndentationKind
  var widthText: String
}
struct NativeLanguageManagerRawOverride {
  let language: DocumentLanguage
  var lineKind: NativeLanguageManagerCommentKind
  var lineText: String
  var blockKind: NativeLanguageManagerCommentKind
  var blockOpening: String
  var blockClosing: String
  var indentationKind: NativeLanguageManagerIndentationKind
  var widthText: String
}
enum NativeLanguageManagerRawForm {
  case definition(NativeLanguageManagerRawDefinition)
  case builtIn(NativeLanguageManagerRawOverride)
}
struct NativeLanguageManagerFieldIssue {
  enum Reason { case invalid, limit, collision }
  let target: NativeLanguageManagerTarget
  let field: String
  let quoteRowID: UUID?
  let reason: Reason
}
enum NativeLanguageManagerEditRefusal {
  case detached, wrongDraft, wrongEpoch, formInProgress, boundExceeded, staleBase, busy
  case unavailable, noWriteReceipt
  case invalid([NativeLanguageManagerFieldIssue])
  case catalog(NativeLanguageCatalogMutationRefusal)
}
enum NativeLanguageManagerEditAdmission {
  case accepted
  case refused(NativeLanguageManagerEditRefusal)
}
enum NativeLanguageManagerFormAdmission {
  case opened(NativeLanguageManagerFormHandle)
  case refused(NativeLanguageManagerEditRefusal)
}
enum NativeLanguageManagerSaveAdmission {
  case started(UUID)
  case refused(NativeLanguageManagerEditRefusal)
}
struct NativeLanguageManagerFormSnapshot {
  let handle: NativeLanguageManagerFormHandle
  let raw: NativeLanguageManagerRawForm
}
struct NativeLanguageManagerEditState {
  let draftID: UUID
  let rawEpoch: UUID
  let viewID: UUID
  let basePublicationID: UUID
  let definitions: [NativeLanguageManagerRawDefinition]
  let overrides: [NativeLanguageManagerRawOverride]
  let selectedTarget: NativeLanguageManagerTarget?
  let activeForm: NativeLanguageManagerFormSnapshot?
  let issues: [NativeLanguageManagerFieldIssue]
  let isDirty: Bool
  let isStale: Bool
  let saveOperationID: UUID?
}

extension NativeLanguageManagerRawQuote: Equatable {
  static func == (a: Self, b: Self) -> Bool {
    a.rowID == b.rowID && a.opening.utf16.elementsEqual(b.opening.utf16)
      && a.closing.utf16.elementsEqual(b.closing.utf16)
      && a.escapeEnabled == b.escapeEnabled && a.escapeText.utf16.elementsEqual(b.escapeText.utf16)
      && a.multiline == b.multiline
  }
}
extension NativeLanguageManagerRawDefinition: Equatable {
  var strings: [String] {
    [name, extensionsText, keywordsText, lineText, blockOpening, blockClosing, widthText]
      + quotes.flatMap { [$0.opening, $0.closing, $0.escapeText] }
  }
  static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && NativeLanguageManagerRawValues.same(a.strings, b.strings)
      && a.lineEnabled == b.lineEnabled && a.blockEnabled == b.blockEnabled
      && a.quotes == b.quotes && a.highlightDecimalNumbers == b.highlightDecimalNumbers
      && a.indentationKind == b.indentationKind
  }
}
extension NativeLanguageManagerRawOverride: Equatable {
  var strings: [String] { [lineText, blockOpening, blockClosing, widthText] }
  static func == (a: Self, b: Self) -> Bool {
    a.language == b.language && NativeLanguageManagerRawValues.same(a.strings, b.strings)
      && a.lineKind == b.lineKind && a.blockKind == b.blockKind
      && a.indentationKind == b.indentationKind
  }
}
extension NativeLanguageManagerRawForm: Equatable {
  var target: NativeLanguageManagerTarget {
    switch self {
    case .definition(let d): return .definition(d.id)
    case .builtIn(let o): return .builtIn(o.language)
    }
  }
  var strings: [String] {
    switch self {
    case .definition(let d): return d.strings
    case .builtIn(let o): return o.strings
    }
  }
}

/// Raw limits bound retained UI state, independently of Core's stricter validated limits.
enum NativeLanguageManagerRawValues {
  static func same(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0.utf16.elementsEqual($0.1.utf16) }
  }
  static func lines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
  }
  static func fits(
    definitions: [NativeLanguageManagerRawDefinition], overrides: [NativeLanguageManagerRawOverride]
  ) -> Bool {
    guard definitions.count <= 64, overrides.count <= DocumentLanguage.allCases.count else {
      return false
    }
    // Reject oversized metadata before collecting or inspecting any caller-owned text.
    for d in definitions {
      guard d.quotes.count <= 4, Set(d.quotes.map(\.rowID)).count == d.quotes.count
      else { return false }
    }
    var remaining = 2_097_152
    for text in definitions.flatMap(\.strings) + overrides.flatMap(\.strings) {
      let limit = min(65536, remaining)
      // Count only this bounded prefix, never the arbitrary original field. The extra unit
      // detects overflow without normalizing, splitting, truncating or retaining a copy.
      let count = text.utf16.prefix(limit + 1).count
      guard count <= limit else { return false }
      remaining -= count
    }
    // All list strings are now field- and aggregate-bounded. Core validates tokens later.
    for d in definitions {
      guard lines(d.extensionsText).count <= 16, lines(d.keywordsText).count <= 1024
      else { return false }
    }
    return true
  }
  static func indentation(_ value: LanguageIndentation)
    -> (NativeLanguageManagerIndentationKind, String)
  {
    switch value {
    case .legacy: return (.legacy, "")
    case .spaces(let w): return (.spaces, String(w))
    case .tabs(let w): return (.tabs, String(w))
    }
  }
  static func raw(_ d: LiteralLanguageDefinition) -> NativeLanguageManagerRawDefinition {
    let (kind, width) = indentation(d.indentation)
    return .init(
      id: d.id, name: d.name, extensionsText: d.fileExtensions.joined(separator: "\n"),
      keywordsText: d.keywords.joined(separator: "\n"), lineEnabled: d.lineComment != nil,
      lineText: d.lineComment ?? "", blockEnabled: d.blockComment != nil,
      blockOpening: d.blockComment?.opening ?? "", blockClosing: d.blockComment?.closing ?? "",
      quotes: d.quotes.map {
        .init(
          rowID: UUID(), opening: $0.opening, closing: $0.closing,
          escapeEnabled: $0.escape != nil, escapeText: $0.escape ?? "", multiline: $0.multiline)
      },
      highlightDecimalNumbers: d.highlightDecimalNumbers, indentationKind: kind, widthText: width)
  }
  static func raw(_ o: BuiltInLanguageOverride) -> NativeLanguageManagerRawOverride {
    let (kind, width) = indentation(o.indentation)
    let lineKind: NativeLanguageManagerCommentKind
    let line: String
    switch o.lineComment {
    case .inherit:
      lineKind = .inherit
      line = ""
    case .disabled:
      lineKind = .disabled
      line = ""
    case .literal(let s):
      lineKind = .literal
      line = s
    }
    let blockKind: NativeLanguageManagerCommentKind
    let opening: String
    let closing: String
    switch o.blockComment {
    case .inherit:
      blockKind = .inherit
      opening = ""
      closing = ""
    case .disabled:
      blockKind = .disabled
      opening = ""
      closing = ""
    case .literal(let p):
      blockKind = .literal
      opening = p.opening
      closing = p.closing
    }
    return .init(
      language: o.language, lineKind: lineKind, lineText: line,
      blockKind: blockKind, blockOpening: opening, blockClosing: closing,
      indentationKind: kind, widthText: width)
  }
  static func inherited(_ language: DocumentLanguage) -> NativeLanguageManagerRawOverride {
    .init(
      language: language, lineKind: .inherit, lineText: "", blockKind: .inherit,
      blockOpening: "", blockClosing: "", indentationKind: .legacy, widthText: "")
  }
  static func policy(_ kind: NativeLanguageManagerIndentationKind, _ text: String) throws
    -> LanguageIndentation
  {
    if kind == .legacy { return .legacy }
    guard let width = Int(text), text.utf16.elementsEqual(String(width).utf16),
      (1...8).contains(width)
    else { throw LanguageProfileError.invalid }
    return kind == .spaces ? .spaces(width: width) : .tabs(width: width)
  }
  static func definition(_ d: NativeLanguageManagerRawDefinition) throws
    -> LiteralLanguageDefinition
  {
    try .init(
      id: d.id, name: d.name, fileExtensions: lines(d.extensionsText),
      keywords: lines(d.keywordsText), lineComment: d.lineEnabled ? d.lineText : nil,
      blockComment: d.blockEnabled ? .init(opening: d.blockOpening, closing: d.blockClosing) : nil,
      quotes: d.quotes.map {
        try .init(
          opening: $0.opening, closing: $0.closing,
          escape: $0.escapeEnabled ? $0.escapeText : nil, multiline: $0.multiline)
      },
      highlightDecimalNumbers: d.highlightDecimalNumbers,
      indentation: policy(d.indentationKind, d.widthText))
  }
  static func builtInValue(_ o: NativeLanguageManagerRawOverride) throws -> BuiltInLanguageOverride
  {
    let line: LineCommentOverride
    switch o.lineKind {
    case .inherit: line = .inherit
    case .disabled: line = .disabled
    case .literal: line = .literal(o.lineText)
    }
    let block: BlockCommentOverride
    switch o.blockKind {
    case .inherit: block = .inherit
    case .disabled: block = .disabled
    case .literal: block = .literal(.init(opening: o.blockOpening, closing: o.blockClosing))
    }
    return try .init(
      language: o.language, lineComment: line, blockComment: block,
      indentation: policy(o.indentationKind, o.widthText))
  }
  static func issues(_ raw: NativeLanguageManagerRawForm) -> [NativeLanguageManagerFieldIssue] {
    let target = raw.target
    var issues: [NativeLanguageManagerFieldIssue] = []
    func check(_ field: String, row: UUID? = nil, _ operation: () throws -> Void) {
      do { try operation() } catch {
        issues.append(
          .init(
            target: target, field: field, quoteRowID: row,
            reason: (error as? LanguageProfileError) == .limit ? .limit : .invalid))
      }
    }
    switch raw {
    case .definition(let d):
      // Each field is evaluated by the actual Core initializer, not a substitute validator.
      func probe(
        name: String = "Draft", extensions: [String] = [], keywords: [String] = [],
        line: String? = nil, block: BlockCommentDelimiters? = nil
      ) throws {
        _ = try LiteralLanguageDefinition(
          id: d.id, name: name, fileExtensions: extensions,
          keywords: keywords, lineComment: line, blockComment: block, quotes: [],
          highlightDecimalNumbers: false, indentation: .legacy)
      }
      check("name") { try probe(name: d.name) }
      check("extensions") { try probe(extensions: lines(d.extensionsText)) }
      check("keywords") { try probe(keywords: lines(d.keywordsText)) }
      if d.lineEnabled { check("lineComment") { try probe(line: d.lineText) } }
      if d.blockEnabled {
        check("blockComment") {
          try probe(block: .init(opening: d.blockOpening, closing: d.blockClosing))
        }
      }
      for q in d.quotes {
        check("quote", row: q.rowID) {
          _ = try LiteralQuoteRule(
            opening: q.opening, closing: q.closing,
            escape: q.escapeEnabled ? q.escapeText : nil, multiline: q.multiline)
        }
      }
      check("indentation") { _ = try policy(d.indentationKind, d.widthText) }
      if issues.isEmpty { check("definition") { _ = try definition(d) } }
    case .builtIn(let o):
      check("override") { _ = try builtInValue(o) }
    }
    return issues
  }
  static func validated(
    definitions: [NativeLanguageManagerRawDefinition], overrides: [NativeLanguageManagerRawOverride]
  ) -> Result<NativeLanguageCatalogDraft, NativeLanguageManagerValidationError> {
    var issues =
      definitions.flatMap { self.issues(.definition($0)) }
      + overrides.flatMap { self.issues(.builtIn($0)) }
    guard issues.isEmpty else { return .failure(.init(issues: issues)) }
    do {
      let values = try definitions.map(definition)
      let overrides = try overrides.map(builtInValue)
      do { return .success(try .init(definitions: values, overrides: overrides)) } catch {
        // Core rejected the whole catalog; identify the conflicting staged entries for the UI.
        var ids = Set<UUID>()
        var extensions = Set<String>()
        for d in values {
          if !ids.insert(d.id).inserted {
            issues.append(
              .init(target: .definition(d.id), field: "id", quoteRowID: nil, reason: .collision))
          }
          for ext in d.fileExtensions where !extensions.insert(ext).inserted {
            issues.append(
              .init(
                target: .definition(d.id), field: "extensions", quoteRowID: nil, reason: .collision)
            )
          }
        }
        if issues.isEmpty, let first = definitions.first {
          issues.append(
            .init(
              target: .definition(first.id), field: "catalog", quoteRowID: nil, reason: .invalid))
        }
        return .failure(.init(issues: issues))
      }
    } catch {
      // Each value was just validated above without a callout; this is a defensive failure.
      return .failure(
        .init(
          issues: definitions.map {
            .init(
              target: .definition($0.id), field: "definition", quoteRowID: nil, reason: .invalid)
          }))
    }
  }
}
struct NativeLanguageManagerValidationError: Error {
  let issues: [NativeLanguageManagerFieldIssue]
}
