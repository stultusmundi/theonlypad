import Foundation

public struct BlockCommentDelimiters: Equatable, Sendable {
  public let opening: String
  public let closing: String
}
public struct LanguageConfiguration: Sendable {
  public let lineComment: String?
  public let blockComment: BlockCommentDelimiters?
  /// A recommendation, not an override of user indentation settings.
  public let indentation: String
  public init(language: DocumentLanguage) {
    switch language {
    case .swift, .javascript, .typescript, .c, .cpp, .java, .rust, .go:
      lineComment = "//"
      blockComment = .init(opening: "/*", closing: "*/")
    case .python, .shell, .yaml, .toml:
      lineComment = "#"
      blockComment = nil
    case .css:
      lineComment = nil
      blockComment = .init(opening: "/*", closing: "*/")
    case .html, .xml, .markdown:
      lineComment = nil
      blockComment = .init(opening: "<!--", closing: "-->")
    case .json, .plainText:
      lineComment = nil
      blockComment = nil
    }
    switch language {
    case .go: indentation = "\t"
    case .swift, .python, .c, .cpp, .java, .rust, .plainText: indentation = "    "
    default: indentation = "  "
    }
  }
}
public enum LanguageEditingError: Error, LocalizedError {
  case unsupported, invalidSelection, limit, unsafeBlockContent
  public var errorDescription: String? {
    switch self {
    case .unsupported:
      return
        "This comment form is not supported for the selected language. Choose a supported language or another comment command."
    case .invalidSelection:
      return
        "The selection is outside the document or divides a Unicode scalar. Select the text again."
    case .limit:
      return
        "Comment commands accept up to 2 million UTF-16 units and 20,000 lines. Select a smaller document."
    case .unsafeBlockContent:
      return
        "The selection contains comment delimiters or unsafe HTML/XML comment text. Use line comments or adjust the selection."
    }
  }
}

/// Textual comment operations, not a semantic parser; string literals and embedded languages are not inferred.
public enum LanguageEditing {
  private static let maximum = 2_000_000
  private struct Line {
    let start: Int
    let bodyEnd: Int
    let end: Int
  }
  private struct Edit {
    let start: Int
    let removed: Int
    let inserted: [UInt16]
  }

  public static func toggleLineComment(
    text: String, selection: NSRange, language: DocumentLanguage,
    isCancelled: () -> Bool = { false }
  ) throws -> LineCommandResult {
    let units = try validated(text, selection: selection)
    guard let delimiter = LanguageConfiguration(language: language).lineComment else {
      throw LanguageEditingError.unsupported
    }
    var lines: [Line] = []
    var start = 0
    var cursor = 0
    while cursor < units.count {
      if cursor.isMultiple(of: 4096), isCancelled() { throw CancellationError() }
      if units[cursor] == 10 || units[cursor] == 13 {
        let bodyEnd = cursor
        cursor += units[cursor] == 13 && cursor + 1 < units.count && units[cursor + 1] == 10 ? 2 : 1
        lines.append(.init(start: start, bodyEnd: bodyEnd, end: cursor))
        start = cursor
        guard lines.count < 20_000 else { throw LanguageEditingError.limit }
      } else {
        cursor += 1
      }
    }
    lines.append(.init(start: start, bodyEnd: units.count, end: units.count))
    let first = lines.lastIndex(where: { $0.start <= selection.location }) ?? 0
    let endpoint = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
    let last = lines.lastIndex(where: { $0.start <= endpoint }) ?? first
    let marker = Array(delimiter.utf16)
    var prefixes: [(offset: Int, commented: Bool)] = []
    for line in lines[first...last] {
      if isCancelled() { throw CancellationError() }
      var offset = line.start
      while offset < line.bodyEnd && (units[offset] == 32 || units[offset] == 9) { offset += 1 }
      let commented =
        marker.count <= line.bodyEnd - offset
        && units[offset..<(offset + marker.count)].elementsEqual(marker)
      prefixes.append((offset, commented))
    }
    let remove = prefixes.allSatisfy(\.commented)
    let edits = prefixes.enumerated().map { index, prefix -> Edit in
      if remove {
        var count = marker.count
        if prefix.offset + count < lines[first + index].bodyEnd, units[prefix.offset + count] == 32
        {
          count += 1
        }
        return Edit(start: prefix.offset, removed: count, inserted: [])
      }
      return Edit(start: prefix.offset, removed: 0, inserted: marker + [32])
    }
    let changed = try applying(edits, to: units, isCancelled: isCancelled)
    let delta = edits.reduce(0) { $0 + $1.inserted.count - $1.removed }
    let resultSelection: NSRange
    if selection.length == 0 {
      var position = selection.location
      for edit in edits {
        if selection.location >= edit.start + edit.removed {
          position += edit.inserted.count - edit.removed
        } else if selection.location >= edit.start {
          position = edit.start + edit.inserted.count
        }
      }
      resultSelection = NSRange(location: position, length: 0)
    } else {
      resultSelection = NSRange(
        location: lines[first].start, length: lines[last].end - lines[first].start + delta)
    }
    return .init(text: changed, selection: resultSelection)
  }

  public static func toggleBlockComment(
    text: String, selection: NSRange, language: DocumentLanguage,
    isCancelled: () -> Bool = { false }
  ) throws -> LineCommandResult {
    let units = try validated(text, selection: selection)
    if isCancelled() { throw CancellationError() }
    var lineCount = 1
    for index in units.indices {
      if index.isMultiple(of: 4096), isCancelled() { throw CancellationError() }
      if units[index] == 10
        || (units[index] == 13 && (index + 1 == units.count || units[index + 1] != 10))
      {
        lineCount += 1
        guard lineCount <= 20_000 else { throw LanguageEditingError.limit }
      }
    }
    guard let delimiters = LanguageConfiguration(language: language).blockComment else {
      throw LanguageEditingError.unsupported
    }
    let opening = Array(delimiters.opening.utf16)
    let closing = Array(delimiters.closing.utf16)
    let selected = Array(units[selection.location..<NSMaxRange(selection)])
    let replacement: [UInt16]
    if selected.count >= opening.count + closing.count,
      selected.prefix(opening.count).elementsEqual(opening),
      selected.suffix(closing.count).elementsEqual(closing)
    {
      replacement = Array(selected.dropFirst(opening.count).dropLast(closing.count))
    } else {
      let content = String(decoding: selected, as: UTF16.self)
      guard !content.contains(delimiters.opening), !content.contains(delimiters.closing),
        delimiters.opening != "<!--" || (!content.contains("--") && !content.hasSuffix("-"))
      else { throw LanguageEditingError.unsafeBlockContent }
      replacement = opening + selected + closing
    }
    let result = try applying(
      [Edit(start: selection.location, removed: selection.length, inserted: replacement)],
      to: units, isCancelled: isCancelled)
    return .init(
      text: result, selection: NSRange(location: selection.location, length: replacement.count))
  }

  private static func validated(_ text: String, selection: NSRange) throws -> [UInt16] {
    guard text.utf16.count <= maximum else { throw LanguageEditingError.limit }
    let units = Array(text.utf16)
    guard selection.location >= 0, selection.length >= 0, selection.location <= units.count,
      selection.length <= units.count - selection.location
    else { throw LanguageEditingError.invalidSelection }
    for offset in [selection.location, NSMaxRange(selection)] {
      guard offset == units.count || !(0xDC00...0xDFFF).contains(units[offset]) else {
        throw LanguageEditingError.invalidSelection
      }
    }
    return units
  }
  private static func applying(_ edits: [Edit], to units: [UInt16], isCancelled: () -> Bool) throws
    -> String
  {
    let length = units.count + edits.reduce(0) { $0 + $1.inserted.count - $1.removed }
    guard length <= maximum else { throw LanguageEditingError.limit }
    var result: [UInt16] = []
    result.reserveCapacity(length)
    var cursor = 0
    for edit in edits {
      if isCancelled() { throw CancellationError() }
      result.append(contentsOf: units[cursor..<edit.start])
      result.append(contentsOf: edit.inserted)
      cursor = edit.start + edit.removed
    }
    result.append(contentsOf: units[cursor...])
    if isCancelled() { throw CancellationError() }
    return String(decoding: result, as: UTF16.self)
  }
}
