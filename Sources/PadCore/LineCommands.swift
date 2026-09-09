import Foundation

public struct LineCommandResult: Equatable, Sendable {
  public let text: String
  public let selection: NSRange
  public init(text: String, selection: NSRange) {
    self.text = text
    self.selection = selection
  }
}
public enum LineCommandError: Error, LocalizedError {
  case invalidSelection, invalidTabWidth, textLimit, lineLimit
  public var errorDescription: String? {
    switch self {
    case .invalidSelection:
      return
        "The selection is outside the document or divides a Unicode scalar. Select the text again."
    case .invalidTabWidth: return "Tab conversion requires a tab width from 1 through 32."
    case .textLimit:
      return
        "Line commands are limited to 20 million UTF-16 units in this build. Copy a smaller excerpt to a new tab."
    case .lineLimit:
      return
        "Line commands are limited to 200,000 logical lines in this build. Copy a smaller excerpt to a new tab."
    }
  }
}
public enum LineCommand: String, CaseIterable, Sendable {
  case duplicate, delete, moveUp, moveDown, join, tabsToSpaces, spacesToTabs
  public func apply(to text: String, selection: NSRange, tabWidth: Int = 4) throws
    -> LineCommandResult
  {
    let maximum = 20_000_000
    guard text.utf16.count <= maximum else { throw LineCommandError.textLimit }
    guard (1...32).contains(tabWidth) else { throw LineCommandError.invalidTabWidth }
    let units = Array(text.utf16)
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= units.count, selection.length <= units.count - selection.location
    else { throw LineCommandError.invalidSelection }
    func boundary(_ offset: Int) -> Bool {
      offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
    }
    guard boundary(selection.location), boundary(NSMaxRange(selection)) else {
      throw LineCommandError.invalidSelection
    }
    var lines = try Self.lines(units)
    func lineAt(_ offset: Int) -> Int {
      lines.lastIndex(where: { $0.start <= offset }) ?? 0
    }
    let first = lineAt(selection.location)
    var last = lineAt(selection.length == 0 ? selection.location : NSMaxRange(selection) - 1)
    let caretColumn = min(selection.location - lines[first].start, lines[first].body.utf16.count)
    var targetFirst = first
    var targetLast = last
    var targetColumn = caretColumn
    switch self {
    case .moveUp, .moveDown:
      guard self == .moveUp ? first > 0 : last + 1 < lines.count else {
        return .init(text: text, selection: selection)
      }
      let low = self == .moveUp ? first - 1 : first
      let high = self == .moveUp ? last : last + 1
      var content = lines[low...high].map(\.body)
      if self == .moveUp {
        content.append(content.removeFirst())
      } else {
        content.insert(content.removeLast(), at: 0)
      }
      for (index, body) in content.enumerated() { lines[low + index].body = body }
      targetFirst += self == .moveUp ? -1 : 1
      targetLast += self == .moveUp ? -1 : 1
    case .duplicate:
      guard lines.count + last - first + 1 <= 200_000 else { throw LineCommandError.lineLimit }
      let block = Array(lines[first...last])
      if lines[last].ending.isEmpty {
        lines[last].ending = lines[..<last].last(where: { !$0.ending.isEmpty })?.ending ?? "\n"
      }
      lines.insert(contentsOf: block, at: last + 1)
      targetFirst = last + 1
      targetLast = targetFirst + block.count - 1
    case .delete:
      let deletingEnd = last == lines.count - 1
      let location = lines[first].start
      lines.removeSubrange(first...last)
      if deletingEnd, !lines.isEmpty { lines[lines.count - 1].ending = "" }
      let result = try Self.render(lines, maximum: maximum)
      return .init(
        text: result, selection: NSRange(location: min(location, result.utf16.count), length: 0))
    case .join:
      if first == last { last = min(last + 1, lines.count - 1) }
      guard last > first else { return .init(text: text, selection: selection) }
      targetColumn = lines[first].body.utf16.count
      let body = lines[first...last].map(\.body).joined(separator: " ")
      let ending = lines[last].ending
      lines.replaceSubrange(first...last, with: [Line(body: body, ending: ending, start: 0)])
      targetLast = first
    case .tabsToSpaces, .spacesToTabs:
      var projected = units.count
      for index in first...last {
        let old = lines[index].body
        let converted = try convertTabs(
          old, width: tabWidth, maximum: maximum,
          caret: index == first && selection.length == 0 ? caretColumn : nil)
        let growth = converted.text.utf16.count - old.utf16.count
        guard growth <= maximum - projected else { throw LineCommandError.textLimit }
        projected += growth
        if index == first, selection.length == 0 {
          targetColumn = converted.caret
        }
        lines[index].body = converted.text
      }
    }
    let result = try Self.render(lines, maximum: maximum)
    let start = lines[..<targetFirst].reduce(0) { $0 + $1.length }
    let length = lines[targetFirst...targetLast].reduce(0) { $0 + $1.length }
    let resultRange =
      selection.length == 0
      ? NSRange(location: start + min(targetColumn, lines[targetFirst].body.utf16.count), length: 0)
      : NSRange(location: start, length: length)
    return .init(text: result, selection: resultRange)
  }

  private struct Line {
    var body: String
    var ending: String
    let start: Int
    var length: Int { body.utf16.count + ending.utf16.count }
  }
  private static func lines(_ units: [UInt16]) throws -> [Line] {
    var result: [Line] = []
    var start = 0
    var index = 0
    while index < units.count {
      if units[index] == 10 || units[index] == 13 {
        let count = units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
        guard result.count < 199_999 else { throw LineCommandError.lineLimit }
        result.append(
          Line(
            body: String(decoding: units[start..<index], as: UTF16.self),
            ending: String(decoding: units[index..<(index + count)], as: UTF16.self), start: start))
        index += count
        start = index
      } else {
        index += 1
      }
    }
    result.append(
      Line(body: String(decoding: units[start...], as: UTF16.self), ending: "", start: start))
    return result
  }
  private static func render(_ lines: [Line], maximum: Int) throws -> String {
    var count = 0
    var result = ""
    for line in lines {
      guard line.length <= maximum - count else { throw LineCommandError.textLimit }
      count += line.length
      result += line.body
      result += line.ending
    }
    return result
  }
  /// Maps the caret through the actual emitted chunks. A caret inside spaces
  /// compressed to one tab moves to the tab's trailing boundary (right affinity).
  /// Unchanged Unicode keeps its original scalar-relative UTF16 offset.
  private func convertTabs(_ text: String, width: Int, maximum: Int, caret: Int?) throws -> (
    text: String, caret: Int
  ) {
    var result = ""
    var column = 0
    var count = 0
    var consumed = 0
    var mapped = 0
    var index = text.startIndex
    func append(_ value: String, consuming sourceLength: Int, unchanged: Bool) throws {
      let outputLength = value.utf16.count
      guard outputLength <= maximum - count else { throw LineCommandError.textLimit }
      if let caret, caret >= consumed, caret <= consumed + sourceLength {
        if unchanged {
          mapped = count + caret - consumed
        } else {
          mapped = count + (caret == consumed ? 0 : outputLength)
        }
      }
      consumed += sourceLength
      count += outputLength
      result += value
    }
    while index < text.endIndex {
      let character = text[index]
      if character == "\t" {
        let advance = width - column % width
        try append(
          self == .tabsToSpaces ? String(repeating: " ", count: advance) : "\t", consuming: 1,
          unchanged: false)
        column += advance
        text.formIndex(after: &index)
      } else if character == " ", self == .spacesToTabs {
        var end = index
        var remaining = 0
        while end < text.endIndex, text[end] == " " {
          remaining += 1
          text.formIndex(after: &end)
        }
        while remaining > 0 {
          let advance = width - column % width
          if remaining >= advance {
            try append("\t", consuming: advance, unchanged: false)
            remaining -= advance
            column += advance
          } else {
            try append(
              String(repeating: " ", count: remaining), consuming: remaining, unchanged: true)
            column += remaining
            remaining = 0
          }
        }
        index = end
      } else {
        let value = String(character)
        try append(value, consuming: value.utf16.count, unchanged: true)
        column += 1
        text.formIndex(after: &index)
      }
    }
    return (result, mapped)
  }
}
