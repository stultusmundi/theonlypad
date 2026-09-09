import Foundation

public struct OutlineSymbol: Equatable, Sendable {
  public let name: String
  public let kind: String
  public let line: Int
  public let range: NSRange
}
public enum OutlineError: Error, LocalizedError {
  case unavailable, limit, cancelled
  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return
        "Outline unavailable for this language. Supported: Swift, Python, JavaScript, TypeScript and Markdown."
    case .limit:
      return
        "Outline limit reached: 2 million UTF-16 units, 20,000 lines, 10,000 symbols or 512 units per name."
    case .cancelled: return "Outline analysis cancelled."
    }
  }
}
/// Bounded lexical declaration discovery. This is not a semantic parser.
public enum DocumentOutline {
  public static func symbols(
    in text: String, language: DocumentLanguage, isCancelled: () -> Bool = { false }
  ) throws -> [OutlineSymbol] {
    guard [.swift, .python, .javascript, .typescript, .markdown].contains(language) else {
      throw OutlineError.unavailable
    }
    guard text.utf16.count <= 2_000_000 else { throw OutlineError.limit }
    if isCancelled() { throw OutlineError.cancelled }
    let source = Array(text.utf16)
    let lines = try lineRanges(source, isCancelled: isCancelled)
    if language == .markdown { return try headings(source, lines: lines, isCancelled: isCancelled) }
    let masked = try mask(source, language: language, isCancelled: isCancelled)
    let identifier = #"[\p{L}_$][\p{L}\p{M}\p{N}_$]*"#
    let pattern: String
    switch language {
    case .swift:
      pattern =
        #"^[ \t]*(?:(?:public|private|fileprivate|internal|open|final|static|class|nonisolated|distributed|override|mutating|nonmutating|indirect|package)[ \t]+)*(func|struct|class|enum|protocol|actor|extension)[ \t]+("#
        + "`[^`\\r\\n]+`|" + identifier + "(?:\\." + identifier + ")*)"
    case .python:
      pattern = #"^[ \t]*(?:async[ \t]+)?(def|class)[ \t]+("# + identifier + ")"
    default:
      let kinds = language == .typescript ? "function|class|interface|type|enum" : "function|class"
      pattern =
        #"^[ \t]*(?:(?:export|default|async|declare|abstract)[ \t]+)*("# + kinds + #")[ \t]+("#
        + identifier + ")"
    }
    let regex = try NSRegularExpression(pattern: pattern)
    var symbols: [OutlineSymbol] = []
    for (number, line) in lines.enumerated() {
      if isCancelled() { throw OutlineError.cancelled }
      let value = String(decoding: masked[line.location..<NSMaxRange(line)], as: UTF16.self)
      guard
        let match = regex.firstMatch(
          in: value, range: NSRange(location: 0, length: value.utf16.count))
      else { continue }
      let nameRange = match.range(at: 2)
      let range = NSRange(location: line.location + nameRange.location, length: nameRange.length)
      guard symbols.count < 10_000, range.length <= 512 else { throw OutlineError.limit }
      symbols.append(
        OutlineSymbol(
          name: String(decoding: source[range.location..<NSMaxRange(range)], as: UTF16.self),
          kind: (value as NSString).substring(with: match.range(at: 1)), line: number + 1,
          range: range))
    }
    if isCancelled() { throw OutlineError.cancelled }
    return symbols
  }
  private static func lineRanges(_ source: [UInt16], isCancelled: () -> Bool) throws -> [NSRange] {
    var lines: [NSRange] = []
    var start = 0
    var index = 0
    var nextCheck = 0
    while index < source.count {
      if index >= nextCheck {
        if isCancelled() { throw OutlineError.cancelled }
        nextCheck = index + 4096
      }
      if source[index] == 10 || source[index] == 13 {
        lines.append(NSRange(location: start, length: index - start))
        guard lines.count < 20_000 else { throw OutlineError.limit }
        index += source[index] == 13 && index + 1 < source.count && source[index + 1] == 10 ? 2 : 1
        start = index
      } else {
        index += 1
      }
    }
    lines.append(NSRange(location: start, length: source.count - start))
    return lines
  }
  private static func mask(_ source: [UInt16], language: DocumentLanguage, isCancelled: () -> Bool)
    throws -> [UInt16]
  {
    var result = source
    var index = 0
    var nextCheck = 0
    let slash = language != .python
    func matches(_ offset: Int, _ value: UInt16) -> Bool {
      offset < source.count && source[offset] == value
    }
    func check(_ offset: Int) throws {
      if offset >= nextCheck {
        if isCancelled() { throw OutlineError.cancelled }
        nextCheck = offset + 4096
      }
    }
    func blank(_ start: Int, _ end: Int) throws {
      for offset in start..<end {
        if offset.isMultiple(of: 4096), isCancelled() { throw OutlineError.cancelled }
        if source[offset] != 10 && source[offset] != 13 { result[offset] = 32 }
      }
    }
    while index < source.count {
      try check(index)
      let start = index
      if (!slash && source[index] == 35) || (slash && matches(index, 47) && matches(index + 1, 47))
      {
        while index < source.count && source[index] != 10 && source[index] != 13 {
          try check(index)
          index += 1
        }
        try blank(start, index)
        continue
      }
      if slash && matches(index, 47) && matches(index + 1, 42) {
        var depth = 1
        index += 2
        while index < source.count && depth > 0 {
          try check(index)
          if language == .swift && matches(index, 47) && matches(index + 1, 42) {
            depth += 1
            index += 2
          } else if matches(index, 42) && matches(index + 1, 47) {
            depth -= 1
            index += 2
          } else {
            index += 1
          }
        }
        try blank(start, index)
        continue
      }
      var hashes = 0
      var quoteIndex = index
      if language == .swift {
        while matches(quoteIndex, 35) {
          hashes += 1
          quoteIndex += 1
          try check(quoteIndex)
        }
        if hashes > 0 && !matches(quoteIndex, 34) {
          index = quoteIndex
          continue
        }
      }
      let quote = quoteIndex < source.count ? source[quoteIndex] : 0
      let template = (language == .javascript || language == .typescript) && quote == 96
      if quote == 34 || quote == 39 || template {
        let triple =
          !template && (language == .python || language == .swift) && matches(quoteIndex + 1, quote)
          && matches(quoteIndex + 2, quote)
        let length = triple ? 3 : 1
        index = quoteIndex + length
        while index < source.count {
          try check(index)
          if matches(index, 92) {
            var escapeEnd = index + 1
            while escapeEnd < source.count && escapeEnd < index + 1 + hashes
              && source[escapeEnd] == 35
            { escapeEnd += 1 }
            if escapeEnd == index + 1 + hashes {
              index = min(source.count, escapeEnd + 1)
              continue
            }
          }
          if matches(index, quote)
            && (!triple || (matches(index + 1, quote) && matches(index + 2, quote)))
          {
            var end = index + length
            while end < source.count && end < index + length + hashes && source[end] == 35 {
              end += 1
            }
            if end == index + length + hashes {
              index = end
              break
            }
          }
          index += 1
        }
        try blank(start, index)
        continue
      }
      index += 1
    }
    return result
  }
  private static func headings(_ source: [UInt16], lines: [NSRange], isCancelled: () -> Bool) throws
    -> [OutlineSymbol]
  {
    var symbols: [OutlineSymbol] = []
    var fence: (UInt16, Int)?
    var htmlComment = false
    for (number, line) in lines.enumerated() {
      if isCancelled() { throw OutlineError.cancelled }
      var value = Array(source[line.location..<NSMaxRange(line)])
      var leading = 0
      while leading < value.count && value[leading] == 32 { leading += 1 }
      func delimiter() -> (UInt16, Int, Int)? {
        guard leading <= 3, leading < value.count, value[leading] == 96 || value[leading] == 126
        else { return nil }
        let marker = value[leading]
        var end = leading
        while end < value.count && value[end] == marker { end += 1 }
        return end - leading >= 3 ? (marker, end - leading, end) : nil
      }
      if let active = fence {
        if let mark = delimiter(), mark.0 == active.0, mark.1 >= active.1,
          value[mark.2...].allSatisfy({ $0 == 32 || $0 == 9 })
        {
          fence = nil
        }
        continue
      }
      var index = 0
      func at(_ offset: Int, _ bytes: [UInt16]) -> Bool {
        offset + bytes.count <= value.count
          && value[offset..<(offset + bytes.count)].elementsEqual(bytes)
      }
      while index < value.count {
        if index.isMultiple(of: 4096), isCancelled() { throw OutlineError.cancelled }
        if !htmlComment && at(index, [60, 33, 45, 45]) {
          htmlComment = true
          value.replaceSubrange(index..<(index + 4), with: [32, 32, 32, 32])
          index += 4
          continue
        }
        if htmlComment {
          if at(index, [45, 45, 62]) {
            value.replaceSubrange(index..<(index + 3), with: [32, 32, 32])
            index += 3
            htmlComment = false
          } else {
            value[index] = 32
            index += 1
          }
        } else {
          index += 1
        }
      }
      if let mark = delimiter() {
        fence = (mark.0, mark.1)
        continue
      }
      guard leading <= 3 else { continue }
      var end = leading
      while end < value.count && value[end] == 35 { end += 1 }
      let level = end - leading
      guard (1...6).contains(level), end == value.count || value[end] == 32 || value[end] == 9
      else { continue }
      while end < value.count && (value[end] == 32 || value[end] == 9) { end += 1 }
      let start = end
      var finish = value.count
      while finish > start && (value[finish - 1] == 32 || value[finish - 1] == 9) { finish -= 1 }
      var closing = finish
      while closing > start && value[closing - 1] == 35 { closing -= 1 }
      if closing < finish && closing > start
        && (value[closing - 1] == 32 || value[closing - 1] == 9)
      {
        finish = closing
        while finish > start && (value[finish - 1] == 32 || value[finish - 1] == 9) { finish -= 1 }
      }
      guard finish > start else { continue }
      guard symbols.count < 10_000, finish - start <= 512 else { throw OutlineError.limit }
      let range = NSRange(location: line.location + start, length: finish - start)
      symbols.append(
        OutlineSymbol(
          name: String(decoding: source[range.location..<NSMaxRange(range)], as: UTF16.self),
          kind: "heading \(level)", line: number + 1, range: range))
    }
    return symbols
  }
}
