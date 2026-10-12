import Foundation

// Internal diagnostic seam: every observation is adjacent to a real cancellation check.
enum CustomLanguageLexerCheckpointPhase: Equatable, Sendable {
  case preflight, scan, comment, quote, identifier, number
}

public enum CustomLanguageLexer {
  private static let maximumInputUnits = 2_000_000
  private static let maximumTokens = 100_000
  private static let checkpointInterval = 4_096

  public static func tokens(
    in text: String, definition: LiteralLanguageDefinition,
    isCancelled: () -> Bool = { false }
  ) throws -> [SyntaxToken] {
    try tokens(in: text, definition: definition, isCancelled: isCancelled, onCheckpoint: nil)
  }

  static func tokens(
    in text: String, definition: LiteralLanguageDefinition,
    isCancelled: () -> Bool,
    onCheckpoint: ((CustomLanguageLexerCheckpointPhase, Int) -> Void)?
  ) throws -> [SyntaxToken] {
    func checkpoint(_ phase: CustomLanguageLexerCheckpointPhase, _ consumed: Int) throws {
      onCheckpoint?(phase, consumed)
      if isCancelled() { throw CancellationError() }
    }

    // A streaming preflight refuses at the first excess unit. No input array or
    // whole-document scalar conversion is needed, either here or in the scanner.
    try checkpoint(.preflight, 0)
    let units = text.utf16
    var inputCount = 0
    var preflightCheckpoint = 0
    for _ in units {
      inputCount += 1
      if inputCount - preflightCheckpoint >= checkpointInterval {
        try checkpoint(.preflight, inputCount)
        preflightCheckpoint = inputCount
      }
      if inputCount > maximumInputUnits {
        try checkpoint(.preflight, inputCount)
        throw LanguageError.analysisLimit
      }
    }
    try checkpoint(.preflight, inputCount)

    // LiteralLanguageDefinition is an immutable validated value: <=1,024 words,
    // <=64 units each, <=32,768 units total; two comments and at most four quotes.
    // Compilation is bounded and polls before each small allocation. Raw unit
    // keys preserve canonically distinct spellings without String equality.
    var keywords = Set<[UInt16]>()
    var maximumKeywordUnits = 0
    for word in definition.keywords {
      try checkpoint(.preflight, inputCount)
      let key = Array(word.utf16)
      keywords.insert(key)
      maximumKeywordUnits = max(maximumKeywordUnits, key.count)
    }
    try checkpoint(.preflight, inputCount)
    let lineOpening = definition.lineComment.map { Array($0.utf16) }
    let blockOpening = definition.blockComment.map { Array($0.opening.utf16) }
    let blockClosing = definition.blockComment.map { Array($0.closing.utf16) }
    var quotes: [CompiledQuote] = []
    for rule in definition.quotes {
      try checkpoint(.preflight, inputCount)
      quotes.append(
        CompiledQuote(
          opening: Array(rule.opening.utf16), closing: Array(rule.closing.utf16),
          escape: rule.escape?.utf16.first, multiline: rule.multiline))
    }
    quotes.sort { $0.opening.count > $1.opening.count }
    try checkpoint(.preflight, inputCount)

    var position = units.startIndex
    var offset = 0
    var phase: CustomLanguageLexerCheckpointPhase = .scan
    var lastCheckpoint = 0
    var result: [SyntaxToken] = []

    func begin(_ nextPhase: CustomLanguageLexerCheckpointPhase) throws {
      phase = nextPhase
      try checkpoint(phase, offset)
      lastCheckpoint = offset
    }
    func advance(_ count: Int) throws {
      for _ in 0..<count {
        position = units.index(after: position)
        offset += 1
        if offset - lastCheckpoint >= checkpointInterval {
          try checkpoint(phase, offset)
          lastCheckpoint = offset
        }
      }
    }
    func finishPhase() throws {
      try checkpoint(phase, offset)
      lastCheckpoint = offset
    }
    func matches(_ marker: [UInt16]) -> Bool {
      var probe = position
      for unit in marker {
        guard probe != units.endIndex, units[probe] == unit else { return false }
        probe = units.index(after: probe)
      }
      return true
    }
    func scalar() -> (value: Unicode.Scalar, width: Int) {
      let first = units[position]
      if (0xD800...0xDBFF).contains(first) {
        let next = units.index(after: position)
        if next != units.endIndex {
          let second = units[next]
          if (0xDC00...0xDFFF).contains(second) {
            let value = 0x10000 + (UInt32(first) - 0xD800) * 0x400 + UInt32(second) - 0xDC00
            if let scalar = Unicode.Scalar(value) { return (scalar, 2) }
          }
        }
      }
      return (Unicode.Scalar(UInt32(first)) ?? "\u{FFFD}", 1)
    }
    func isLineEnd() -> Bool { units[position] == 13 || units[position] == 10 }
    func append(_ kind: TokenKind, from start: Int) throws {
      guard result.count < maximumTokens else { throw LanguageError.analysisLimit }
      result.append(
        SyntaxToken(range: NSRange(location: start, length: offset - start), kind: kind))
    }

    try begin(.scan)
    while position != units.endIndex {
      if phase != .scan { try begin(.scan) }
      let start = offset
      let lineMatches = lineOpening.map { matches($0) } ?? false
      let blockMatches = blockOpening.map { matches($0) } ?? false
      if lineMatches || blockMatches {
        try begin(.comment)
        let useBlock =
          blockMatches && (!lineMatches || (blockOpening?.count ?? 0) > (lineOpening?.count ?? 0))
        if useBlock, let opening = blockOpening, let closing = blockClosing {
          try advance(opening.count)
          while position != units.endIndex {
            if matches(closing) {
              try advance(closing.count)
              break
            }
            try advance(scalar().width)
          }
        } else if let opening = lineOpening {
          try advance(opening.count)
          while position != units.endIndex, !isLineEnd() {
            try advance(scalar().width)
          }
        }
        try finishPhase()
        try append(.comment, from: start)
        continue
      }

      if let quote = quotes.first(where: { matches($0.opening) }) {
        try begin(.quote)
        try advance(quote.opening.count)
        while position != units.endIndex {
          if !quote.multiline && isLineEnd() { break }
          if let escape = quote.escape, units[position] == escape {
            try advance(1)
            if position == units.endIndex { break }
            if !quote.multiline && isLineEnd() { break }
            try advance(scalar().width)
          } else if matches(quote.closing) {
            try advance(quote.closing.count)
            break
          } else {
            try advance(scalar().width)
          }
        }
        try finishPhase()
        try append(.string, from: start)
        continue
      }

      let nextScalar = scalar()
      if isIdentifierStart(nextScalar.value) {
        let identifierStart = position
        try begin(.identifier)
        try advance(nextScalar.width)
        while position != units.endIndex {
          let next = scalar()
          guard isIdentifierContinuation(next.value) else { break }
          try advance(next.width)
        }
        try finishPhase()
        // Long identifiers allocate no keyword key; small candidates use one
        // bounded exact lookup, never a per-character loop over all keywords.
        if offset - start <= maximumKeywordUnits,
          keywords.contains(Array(units[identifierStart..<position]))
        {
          try append(.keyword, from: start)
        }
        continue
      }

      if definition.highlightDecimalNumbers, (48...57).contains(units[position]) {
        try begin(.number)
        repeat {
          try advance(1)
        } while position != units.endIndex && (48...57).contains(units[position])
        try finishPhase()
        try append(.number, from: start)
        continue
      }
      try advance(nextScalar.width)
    }
    try finishPhase()
    return result
  }

  private struct CompiledQuote {
    let opening: [UInt16]
    let closing: [UInt16]
    let escape: UInt16?
    let multiline: Bool
  }

  private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "_" { return true }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default: return false
    }
  }

  private static func isIdentifierContinuation(_ scalar: Unicode.Scalar) -> Bool {
    if isIdentifierStart(scalar) { return true }
    switch scalar.properties.generalCategory {
    case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return false
    }
  }
}
