import Foundation

public enum SearchMode: Sendable { case literal, escaped, regex }
public struct SearchQuery: Sendable {
  public let pattern: String
  public let mode: SearchMode
  public let caseSensitive: Bool
  public let wholeWord: Bool
  public init(
    pattern: String, mode: SearchMode, caseSensitive: Bool = true, wholeWord: Bool = false
  ) {
    self.pattern = pattern
    self.mode = mode
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
  }
}
public enum SearchExecutionOperation: Sendable, Equatable {
  case find
  case replace(template: String)
}
public struct SearchExecutionOutput: Sendable, Equatable {
  public let matches: [NSRange]
  public let replacement: String?
  public init(matches: [NSRange], replacement: String?) {
    self.matches = matches
    self.replacement = replacement
  }
}
public enum SearchError: Error, Equatable {
  case invalidScope, invalidEscape, invalidPattern, invalidReplacement, textLimit, matchLimit,
    outputLimit, cancelled, timedOut, engineFailure
}
/// Synchronous bounded search. Call from a worker, never from the UI thread.
/// Time limits are cooperative ICU progress checks, not process-isolated deadlines.
public struct SearchService {
  typealias MatchCallback = (
    NSTextCheckingResult?, NSRegularExpression.MatchingFlags, UnsafeMutablePointer<ObjCBool>
  ) -> Void
  typealias MatchEnumerator = (
    NSRegularExpression, String, NSRegularExpression.MatchingOptions, NSRange, MatchCallback
  ) -> Void

  private let maxTextUTF16: Int
  private let maxMatches: Int
  private let maxOutputUTF16: Int
  private let timeLimit: TimeInterval
  private let isCancelled: () -> Bool
  private let enumerateMatches: MatchEnumerator

  public init(
    maxTextUTF16: Int = 10_000_000, maxMatches: Int = 100_000,
    maxOutputUTF16: Int = 20_000_000, timeLimit: TimeInterval = 1,
    isCancelled: @escaping () -> Bool = { false }
  ) {
    self.init(
      maxTextUTF16: maxTextUTF16, maxMatches: maxMatches, maxOutputUTF16: maxOutputUTF16,
      timeLimit: timeLimit, isCancelled: isCancelled,
      enumerateMatches: { expression, text, options, range, callback in
        expression.enumerateMatches(in: text, options: options, range: range, using: callback)
      })
  }

  init(
    maxTextUTF16: Int = 10_000_000, maxMatches: Int = 100_000,
    maxOutputUTF16: Int = 20_000_000, timeLimit: TimeInterval = 1,
    isCancelled: @escaping () -> Bool = { false },
    enumerateMatches: @escaping MatchEnumerator
  ) {
    self.maxTextUTF16 = max(0, maxTextUTF16)
    self.maxMatches = max(0, maxMatches)
    self.maxOutputUTF16 = max(0, maxOutputUTF16)
    self.timeLimit = timeLimit.isFinite ? max(0, timeLimit) : 0
    self.isCancelled = isCancelled
    self.enumerateMatches = enumerateMatches
  }

  public func matches(_ query: SearchQuery, in text: String, scope: NSRange? = nil) throws
    -> [NSRange]
  {
    try execute(query, in: text, scope: scope, operation: .find).matches
  }

  public func execute(
    _ query: SearchQuery, in text: String, scope: NSRange? = nil,
    operation: SearchExecutionOperation
  ) throws -> SearchExecutionOutput {
    let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
    let (regex, results) = try search(query, text: text, scope: scope, deadline: deadline)
    let replacement: String?
    switch operation {
    case .find:
      replacement = nil
    case .replace(let template):
      replacement = try buildReplacement(
        mode: query.mode, regex: regex, results: results, text: text, template: template,
        deadline: deadline)
    }
    return SearchExecutionOutput(matches: results.map(\.range), replacement: replacement)
  }

  public func replacing(_ query: SearchQuery, in text: String, with replacement: String) throws
    -> String
  {
    try execute(query, in: text, operation: .replace(template: replacement)).replacement!
  }

  private func buildReplacement(
    mode: SearchMode, regex: NSRegularExpression, results: [NSTextCheckingResult], text: String,
    template: String, deadline: TimeInterval
  ) throws -> String {
    guard template.utf16.count <= 4096 else { throw SearchError.outputLimit }
    let parts =
      mode == .regex
      ? try replacementParts(template, groups: regex.numberOfCaptureGroups)
      : [.literal(template)]
    let original = text as NSString
    var output = ""
    var outputCount = 0
    var position = 0
    func append(_ part: String) throws {
      try check(deadline)
      let count = part.utf16.count
      guard count <= maxOutputUTF16 - outputCount else { throw SearchError.outputLimit }
      output += part
      outputCount += count
    }
    func appendRange(_ range: NSRange) throws {
      try check(deadline)
      guard range.length <= maxOutputUTF16 - outputCount else { throw SearchError.outputLimit }
      // Check the length before Foundation allocates a substring of a capture.
      try append(original.substring(with: range))
    }
    for result in results {
      try appendRange(NSRange(location: position, length: result.range.location - position))
      for part in parts {
        switch part {
        case .literal(let value): try append(value)
        case .capture(let group):
          let range = result.range(at: group)
          if range.location != NSNotFound { try appendRange(range) }
        }
      }
      position = NSMaxRange(result.range)
    }
    try appendRange(NSRange(location: position, length: original.length - position))
    return output
  }

  private enum ReplacementPart {
    case literal(String)
    case capture(Int)
  }

  /// Numeric ICU-style captures: $0 is the match, $1... are groups. A backslash
  /// quotes the next scalar. Names and nonexistent groups are explicitly rejected.
  private func replacementParts(_ template: String, groups: Int) throws -> [ReplacementPart] {
    let scalars = Array(template.unicodeScalars)
    var index = 0
    var result: [ReplacementPart] = []
    var literal = ""
    func flush() {
      if !literal.isEmpty {
        result.append(.literal(literal))
        literal = ""
      }
    }
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      if scalar == "\\" {
        guard index < scalars.count else { throw SearchError.invalidReplacement }
        literal.unicodeScalars.append(scalars[index])
        index += 1
      } else if scalar == "$" {
        flush()
        guard index < scalars.count, (48...57).contains(scalars[index].value) else {
          throw SearchError.invalidReplacement
        }
        var group = Int(scalars[index].value - 48)
        guard group <= groups else { throw SearchError.invalidReplacement }
        index += 1
        // Consume only digits that continue to identify an existing group.
        while index < scalars.count, (48...57).contains(scalars[index].value) {
          let digit = Int(scalars[index].value - 48)
          guard group <= (groups - digit) / 10, group * 10 + digit <= groups else { break }
          group = group * 10 + digit
          index += 1
        }
        result.append(.capture(group))
      } else {
        literal.unicodeScalars.append(scalar)
      }
    }
    flush()
    return result
  }

  private func check(_ deadline: TimeInterval) throws {
    if isCancelled() { throw SearchError.cancelled }
    if ProcessInfo.processInfo.systemUptime >= deadline { throw SearchError.timedOut }
  }

  private func search(_ query: SearchQuery, text: String, scope: NSRange?, deadline: TimeInterval)
    throws -> (NSRegularExpression, [NSTextCheckingResult])
  {
    try check(deadline)
    let length = text.utf16.count
    guard length <= maxTextUTF16 else { throw SearchError.textLimit }
    let range = scope ?? NSRange(location: 0, length: length)
    guard range.location >= 0, range.length >= 0, range.location <= length,
      range.length <= length - range.location,
      isScalarBoundary(range.location, in: text),
      isScalarBoundary(range.location + range.length, in: text)
    else { throw SearchError.invalidScope }
    guard query.pattern.utf16.count <= 4096 else { throw SearchError.invalidPattern }
    var pattern: String
    switch query.mode {
    case .regex: pattern = query.pattern
    case .literal: pattern = NSRegularExpression.escapedPattern(for: query.pattern)
    case .escaped: pattern = NSRegularExpression.escapedPattern(for: try unescape(query.pattern))
    }
    if query.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
    var options: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
    if !query.caseSensitive { options.insert(.caseInsensitive) }
    let regex: NSRegularExpression
    do { regex = try NSRegularExpression(pattern: pattern, options: options) } catch {
      throw SearchError.invalidPattern
    }
    try check(deadline)
    var results: [NSTextCheckingResult] = []
    var failure: Error?
    // Transparent bounds prevent the edge of a selection becoming a fake word boundary.
    enumerateMatches(
      regex, text,
      [.reportProgress, .reportCompletion, .withTransparentBounds, .withoutAnchoringBounds], range
    ) { result, flags, stop in
      guard failure == nil else {
        stop.pointee = true
        return
      }
      do {
        if flags.contains(.internalError) { throw SearchError.engineFailure }
        try check(deadline)
        if let result {
          guard results.count < maxMatches else { throw SearchError.matchLimit }
          // Every result retains every capture range, including unmatched
          // groups. Bound aggregate storage independently of match count.
          guard results.count < 1_000_000 / (regex.numberOfCaptureGroups + 1) else {
            throw SearchError.matchLimit
          }
          results.append(result)
        }
      } catch {
        failure = error
        stop.pointee = true
      }
    }
    if let failure { throw failure }
    try check(deadline)
    return (regex, results)
  }

  private func isScalarBoundary(_ offset: Int, in text: String) -> Bool {
    let units = text.utf16
    let index = units.index(units.startIndex, offsetBy: offset)
    guard index != units.endIndex else { return true }
    // A low surrogate is never a valid starting offset in a well-formed Swift String.
    return !(0xDC00...0xDFFF).contains(units[index])
  }

  private func unescape(_ input: String) throws -> String {
    var output = ""
    var iterator = input.makeIterator()
    while let character = iterator.next() {
      if character != "\\" {
        output.append(character)
        continue
      }
      guard let escaped = iterator.next() else { throw SearchError.invalidEscape }
      switch escaped {
      case "n": output.append("\n")
      case "r": output.append("\r")
      case "t": output.append("\t")
      case "0": output.append("\0")
      case "\\": output.append("\\")
      default: throw SearchError.invalidEscape
      }
    }
    return output
  }
}
