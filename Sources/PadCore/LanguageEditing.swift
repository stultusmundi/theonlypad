import Foundation

public struct BlockCommentDelimiters: Equatable, Sendable {
  public let opening: String
  public let closing: String

  public init(opening: String, closing: String) {
    self.opening = opening
    self.closing = closing
  }
  public static func == (left: Self, right: Self) -> Bool {
    left.opening.utf16.elementsEqual(right.opening.utf16)
      && left.closing.utf16.elementsEqual(right.closing.utf16)
  }
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

// Profile-taking entry points are separately bounded and raw-UTF16 literal.
// Existing language-taking methods above remain byte-exact for compatibility.
extension LanguageEditing {
  public static func toggleLineComment(
    text: String, selection: NSRange, profile: ResolvedLanguageProfile,
    isCancelled: () -> Bool = { false }
  ) throws -> LineCommandResult {
    var work = BoundedLanguageEditing()
    do {
      let units = try work.read(text, isCancelled: isCancelled)
      try work.validate(selection, in: units)
      let lines = try work.lines(in: units, isCancelled: isCancelled)
      guard let delimiter = profile.editing.lineComment else {
        throw LanguageEditingError.unsupported
      }
      // A validated profile bounds this literal to <=32 units.
      let marker = Array(delimiter.utf16)
      let touched = try work.touched(lines, selection: selection, isCancelled: isCancelled)
      var prefixes: [(offset: Int, commented: Bool)] = []
      var remove = true
      for index in touched.first...touched.last {
        try work.step(isCancelled)
        let line = lines[index]
        var offset = line.start
        while offset < line.bodyEnd, units[offset] == 32 || units[offset] == 9 {
          try work.step(isCancelled)
          offset += 1
        }
        let commented = try work.matches(
          marker, in: units, at: offset,
          end: line.bodyEnd, isCancelled: isCancelled)
        prefixes.append((offset, commented))
        if !commented { remove = false }
      }
      var edits: [BoundedLanguageEditing.Edit] = []
      for index in prefixes.indices {
        try work.step(isCancelled)
        let prefix = prefixes[index]
        if remove {
          var count = marker.count
          if prefix.offset + count < lines[touched.first + index].bodyEnd,
            units[prefix.offset + count] == 32
          {
            count += 1
          }
          edits.append(.init(start: prefix.offset, removed: count, inserted: []))
        } else {
          edits.append(.init(start: prefix.offset, removed: 0, inserted: marker + [32]))
        }
      }
      let changed = try work.applying(edits, to: units, isCancelled: isCancelled)
      let mapped = try work.selection(
        selection, lines: lines, first: touched.first,
        last: touched.last, edits: edits, isCancelled: isCancelled)
      try work.check(isCancelled)
      return LineCommandResult(text: changed, selection: mapped)
    } catch let error as BoundedLanguageEditing.Failure {
      switch error {
      case .invalidSelection: throw LanguageEditingError.invalidSelection
      case .textLimit, .lineLimit: throw LanguageEditingError.limit
      }
    }
  }

  public static func toggleBlockComment(
    text: String, selection: NSRange, profile: ResolvedLanguageProfile,
    isCancelled: () -> Bool = { false }
  ) throws -> LineCommandResult {
    var work = BoundedLanguageEditing()
    do {
      let units = try work.read(text, isCancelled: isCancelled)
      try work.validate(selection, in: units)
      _ = try work.lines(in: units, isCancelled: isCancelled)
      guard let delimiter = profile.editing.blockComment else {
        throw LanguageEditingError.unsupported
      }
      // Both literals are authenticated by the immutable resolved profile.
      let opening = Array(delimiter.opening.utf16)
      let closing = Array(delimiter.closing.utf16)
      let start = selection.location
      let end = start + selection.length
      var isWrapped = false
      if selection.length >= opening.count + closing.count {
        let hasOpening = try work.matches(
          opening, in: units, at: start,
          end: end, isCancelled: isCancelled)
        if hasOpening {
          isWrapped = try work.matches(
            closing, in: units, at: end - closing.count,
            end: end, isCancelled: isCancelled)
        }
      }
      var replacement: [UInt16] = []
      if isWrapped {
        try work.copy(
          (start + opening.count)..<(end - closing.count), from: units,
          into: &replacement, isCancelled: isCancelled)
      } else {
        if try work.contains(opening, in: units, range: start..<end, isCancelled: isCancelled) {
          throw LanguageEditingError.unsafeBlockContent
        }
        if try work.contains(closing, in: units, range: start..<end, isCancelled: isCancelled) {
          throw LanguageEditingError.unsafeBlockContent
        }
        if opening == [60, 33, 45, 45] {
          if try work.contains([45, 45], in: units, range: start..<end, isCancelled: isCancelled) {
            throw LanguageEditingError.unsafeBlockContent
          }
          if start < end, units[end - 1] == 45 {
            throw LanguageEditingError.unsafeBlockContent
          }
        }
        guard opening.count + closing.count <= BoundedLanguageEditing.maximumUnits - units.count
        else {
          throw LanguageEditingError.limit
        }
        try work.copy(
          0..<opening.count, from: opening, into: &replacement, isCancelled: isCancelled)
        try work.copy(start..<end, from: units, into: &replacement, isCancelled: isCancelled)
        try work.copy(
          0..<closing.count, from: closing, into: &replacement, isCancelled: isCancelled)
      }
      let edit = BoundedLanguageEditing.Edit(
        start: start, removed: selection.length,
        inserted: replacement)
      let result = try work.applying([edit], to: units, isCancelled: isCancelled)
      try work.check(isCancelled)
      return LineCommandResult(
        text: result,
        selection: NSRange(location: start, length: replacement.count))
    } catch let error as BoundedLanguageEditing.Failure {
      switch error {
      case .invalidSelection: throw LanguageEditingError.invalidSelection
      case .textLimit, .lineLimit: throw LanguageEditingError.limit
      }
    }
  }
}
