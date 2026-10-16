import Foundation

/// Closed XML markup-formatting refusals exposed by the planned Core API.
public enum XMLUnsupportedFeature: Equatable, Sendable {
  case doctype
  case declaration
  case entity
}

/// Fixed errors for malformed or deliberately unsupported XML input.
public enum XMLFormattingError: Error, Equatable, Sendable, LocalizedError {
  case malformed
  case unsupported(XMLUnsupportedFeature)

  public var errorDescription: String? {
    switch self {
    case .malformed:
      return "The XML document is malformed."
    case .unsupported(.doctype):
      return "XML document type declarations are not supported."
    case .unsupported(.declaration):
      return "This XML declaration is not supported."
    case .unsupported(.entity):
      return "Custom XML entities are not supported."
    }
  }
}

/// A bounded lexical formatter. Foundation validates syntax but never supplies output.
internal enum XMLMarkupFormatter {
  private static let bufferLimit = 2_000_000
  private static let markupLimit = 65_536

  static func format(
    _ text: String, lineEnding: LineEnding,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws -> String {
    try checkCancellation(isCancelled)
    // Admission inspects at most limit+1 bytes without allocating a full buffer.
    var admittedCount = 0
    for _ in text.utf8 {
      guard admittedCount < bufferLimit else { throw LanguageError.analysisLimit }
      if admittedCount % 1_024 == 0 { try checkCancellation(isCancelled) }
      admittedCount += 1
    }
    try checkCancellation(isCancelled)
    var input: [UInt8] = []
    input.reserveCapacity(admittedCount)
    for byte in text.utf8 {
      if input.count % 1_024 == 0 { try checkCancellation(isCancelled) }
      input.append(byte)
    }
    let scanner = Scanner(
      input: input, newline: Array(lineEnding.sequence.utf8), cancel: isCancelled)
    let output = try scanner.run()
    // Complete forbidden-construct/resource preflight precedes parser construction.
    try checkCancellation(isCancelled)
    let delegate = ValidationDelegate(cancel: isCancelled)
    let parser = XMLParser(data: Data(input))
    parser.externalEntityResolvingPolicy = .never
    parser.shouldResolveExternalEntities = false
    parser.allowedExternalEntityURLs = []
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    try checkCancellation(isCancelled)
    let parsed = parser.parse()
    try checkCancellation(isCancelled)
    if delegate.cancelled { throw LanguageError.cancelled }
    guard parsed, parser.parserError == nil, !delegate.failed, delegate.ended else {
      throw XMLFormattingError.malformed
    }
    let result = String(decoding: output, as: UTF8.self)
    try checkCancellation(isCancelled)
    return result
  }

  private static func checkCancellation(_ cancel: () -> Bool) throws {
    if cancel() { throw LanguageError.cancelled }
  }

  private struct Attribute {
    let name: Range<Int>
    let quotedValue: Range<Int>
  }

  private struct QualifiedName {
    let prefix: [UInt8]?
    let local: [UInt8]
  }

  private enum NamespaceDelta {
    case prefix([UInt8], previous: Int?)
    case defaultNamespace(Int)
  }

  private struct ElementFrame {
    let name: Range<Int>
    let deltas: [NamespaceDelta]
  }

  private struct ExpandedAttributeName: Hashable {
    let namespace: Int
    let local: [UInt8]
  }

  private static let xmlPrefix = Array("xml".utf8)
  private static let xmlnsPrefix = Array("xmlns".utf8)
  private static let xmlNamespace = Array("http://www.w3.org/XML/1998/namespace".utf8)
  private static let xmlnsNamespace = Array("http://www.w3.org/2000/xmlns/".utf8)

  private final class Scanner {
    let input: [UInt8]
    let newline: [UInt8]
    let cancel: @Sendable () -> Bool
    var index = 0
    var tokenStart: Int?
    var tokenCount = 0
    var stack: [ElementFrame] = []
    var prefixBindings: [[UInt8]: Int] = [xmlPrefix: 1]
    var defaultNamespace = 0
    // Identities0/1 are no namespace and the fixed implicit xml namespace.
    // Arrays share immutable COW storage; keys never retain large URI payloads.
    var namespaceValues: [[UInt8]] = [[], xmlNamespace]
    var namespaceBuckets: [Int: [Int]] = [:]
    // Every value starts from the same copied state within this scanner.
    let namespaceHasher = Hasher()
    var visitedNamespacePayloadBytes = 0
    var retainedNamespacePayloadBytes = 0
    var output: [UInt8] = []
    var declarationPosition = 0

    init(input: [UInt8], newline: [UInt8], cancel: @escaping @Sendable () -> Bool) {
      self.input = input
      self.newline = newline
      self.cancel = cancel
    }

    func run() throws -> [UInt8] {
      try checkCancellation(cancel)
      if matches([0xEF, 0xBB, 0xBF]) {
        try advance(3)
        declarationPosition = index
        try emit(0..<index)
      }
      while index < input.count {
        try checkCancellation(cancel)
        guard tokenCount < 100_000 else { throw LanguageError.analysisLimit }
        tokenCount += 1
        let start = index
        if input[index] != 60 {
          tokenStart = nil
          while index < input.count && input[index] != 60 {
            if input[index] == 38 { try reference() } else { try advance() }
          }
          try emit(start..<index)
          continue
        }
        tokenStart = start
        if matches(Array("<!--".utf8)) {
          try opaque(open: 4, close: Array("-->".utf8))
          try emit(start..<index)
        } else if matches(Array("<![CDATA[".utf8)) {
          try opaque(open: 9, close: Array("]]>".utf8))
          try emit(start..<index)
        } else if matches(Array("<!DOCTYPE".utf8)) {
          throw XMLFormattingError.unsupported(.doctype)
        } else if matches(Array("<!ENTITY".utf8)) {
          throw XMLFormattingError.unsupported(.entity)
        } else if matches(Array("<!".utf8)) {
          throw XMLFormattingError.unsupported(.declaration)
        } else if matches(Array("<?".utf8)) {
          try instruction(start: start)
          try emit(start..<index)
        } else if matches(Array("</".utf8)) {
          try advance(2)
          let closingName = try name()
          try whitespace()
          try require(62)
          _ = try qualifiedName(closingName)
          guard let frame = stack.last,
            input[frame.name].elementsEqual(input[closingName])
          else { throw XMLFormattingError.malformed }
          try restoreNamespaces(frame.deltas)
          stack.removeLast()
          try emit(start..<index)
        } else {
          try startTag()
        }
        tokenStart = nil
      }
      guard stack.isEmpty else { throw XMLFormattingError.malformed }
      try checkCancellation(cancel)
      return output
    }

    /// All cursor movement is charged, including opaque and quoted regions.
    func advance(_ count: Int = 1) throws {
      for _ in 0..<count {
        guard index < input.count else { throw XMLFormattingError.malformed }
        if let tokenStart, index - tokenStart >= markupLimit {
          throw LanguageError.analysisLimit
        }
        if index % 1_024 == 0 { try checkCancellation(cancel) }
        index += 1
      }
    }

    func matches(_ value: [UInt8]) -> Bool {
      guard value.count <= input.count - index else { return false }
      return input[index..<(index + value.count)].elementsEqual(value)
    }

    func require(_ byte: UInt8) throws {
      guard index < input.count, input[index] == byte else { throw XMLFormattingError.malformed }
      try advance()
    }

    func isWhitespace(_ byte: UInt8) -> Bool {
      byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    func whitespace() throws {
      while index < input.count && isWhitespace(input[index]) { try advance() }
    }

    func name() throws -> Range<Int> {
      let start = index
      while index < input.count {
        let byte = input[index]
        if isWhitespace(byte) || byte == 47 || byte == 62 || byte == 61 || byte == 63
          || byte == 60 || byte == 34 || byte == 39
        {
          break
        }
        guard index - start < 256 else { throw LanguageError.analysisLimit }
        try advance()
      }
      guard index > start else { throw XMLFormattingError.malformed }
      // Lexical names stay opaque bytes. The namespace layer checks QName/
      // NCName scalars; Foundation retains the remaining XML syntax checks.
      return start..<index
    }

    func attribute(references: Bool) throws -> Attribute {
      let attributeName = try name()
      try whitespace()
      try require(61)
      try whitespace()
      guard index < input.count, input[index] == 34 || input[index] == 39 else {
        throw XMLFormattingError.malformed
      }
      let start = index
      let quote = input[index]
      try advance()
      while index < input.count && input[index] != quote {
        if input[index] == 60 { throw XMLFormattingError.malformed }
        if references && input[index] == 38 { try reference() } else { try advance() }
      }
      try require(quote)
      return Attribute(name: attributeName, quotedValue: start..<index)
    }

    func startTag() throws {
      try require(60)
      let elementName = try name()
      let containingDepth = stack.count
      guard containingDepth < 128 else { throw LanguageError.analysisLimit }
      var attributes: [Attribute] = []
      while true {
        let beforeWhitespace = index
        try whitespace()
        if matches(Array("/>".utf8)) || matches([62]) { break }
        guard index > beforeWhitespace else { throw XMLFormattingError.malformed }
        guard attributes.count < 256 else { throw LanguageError.analysisLimit }
        attributes.append(try attribute(references: true))
      }
      let empty = matches(Array("/>".utf8))
      let delimiter = index
      try advance(empty ? 2 : 1)
      let deltas = try validateNamespaces(element: elementName, attributes: attributes)
      if empty {
        try restoreNamespaces(deltas)
      } else {
        stack.append(ElementFrame(name: elementName, deltas: deltas))
      }

      // Calculate the complete emitted markup size before any token append.
      // Every term is bounded by input, depth and attribute admission above.
      var size = 1 + elementName.count + (empty ? 2 : 1)
      if !attributes.isEmpty {
        size += newline.count + containingDepth * 2
        for attribute in attributes {
          size +=
            newline.count + (containingDepth + 1) * 2
            + attribute.name.count + 1 + attribute.quotedValue.count
        }
      }
      guard size <= markupLimit, size <= bufferLimit - output.count else {
        throw LanguageError.analysisLimit
      }
      try emit([60])
      try emit(elementName)
      for attribute in attributes {
        try emit(newline)
        try indent((containingDepth + 1) * 2)
        try emit(attribute.name)
        try emit([61])
        try emit(attribute.quotedValue)
      }
      if !attributes.isEmpty {
        try emit(newline)
        try indent(containingDepth * 2)
      }
      try emit(delimiter..<index)
    }

    func qualifiedName(_ range: Range<Int>) throws -> QualifiedName {
      try checkCancellation(cancel)
      guard !range.isEmpty, range.count <= 256 else { throw XMLFormattingError.malformed }
      var colon: Int?
      for offset in range {
        if input[offset] == 58 {
          guard colon == nil else { throw XMLFormattingError.malformed }
          colon = offset
        }
      }
      if let colon {
        let prefix = range.lowerBound..<colon
        let local = (colon + 1)..<range.upperBound
        try validateNCName(prefix)
        try validateNCName(local)
        return QualifiedName(prefix: Array(input[prefix]), local: Array(input[local]))
      }
      try validateNCName(range)
      return QualifiedName(prefix: nil, local: Array(input[range]))
    }

    func validateNCName(_ range: Range<Int>) throws {
      try checkCancellation(cancel)
      guard !range.isEmpty, range.count <= 256,
        let value = String(bytes: input[range], encoding: .utf8)
      else { throw XMLFormattingError.malformed }
      var first = true
      for scalar in value.unicodeScalars {
        try checkCancellation(cancel)
        let code = scalar.value
        let start: Bool
        switch code {
        case 65...90, 95, 97...122, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF,
          0x370...0x37D, 0x37F...0x1FFF, 0x200C...0x200D, 0x2070...0x218F,
          0x2C00...0x2FEF, 0x3001...0xD7FF, 0xF900...0xFDCF, 0xFDF0...0xFFFD,
          0x10000...0xEFFFF:
          start = true
        default: start = false
        }
        let continuation =
          start || code == 45 || code == 46 || (48...57).contains(code)
          || code == 0xB7 || (0x300...0x36F).contains(code) || (0x203F...0x2040).contains(code)
        guard first ? start : continuation else { throw XMLFormattingError.malformed }
        first = false
      }
    }

    func validateNamespaces(element: Range<Int>, attributes: [Attribute]) throws -> [NamespaceDelta]
    {
      try checkCancellation(cancel)
      let elementName = try qualifiedName(element)
      var names: [QualifiedName] = []
      var rawNames: Set<[UInt8]> = []
      for attribute in attributes {
        try checkCancellation(cancel)
        let raw = Array(input[attribute.name])
        guard rawNames.insert(raw).inserted else { throw XMLFormattingError.malformed }
        names.append(try qualifiedName(attribute.name))
      }
      var deltas: [NamespaceDelta] = []
      // Complete all declarations before resolving any uses on this tag.
      for (attribute, name) in zip(attributes, names) {
        try checkCancellation(cancel)
        let isDefault = name.prefix == nil && name.local == xmlnsPrefix
        guard isDefault || name.prefix == xmlnsPrefix else { continue }
        if !isDefault && name.local == xmlnsPrefix { throw XMLFormattingError.malformed }
        let payload =
          (attribute.quotedValue.lowerBound + 1)..<(attribute.quotedValue.upperBound - 1)
        let value = try normalizedNamespaceValue(payload)
        let isXML = try namespaceBytesEqual(value.bytes, xmlNamespace)
        let isXMLNS = try namespaceBytesEqual(value.bytes, xmlnsNamespace)
        let identity: Int
        if !isDefault && name.local == xmlPrefix {
          guard isXML else { throw XMLFormattingError.malformed }
          identity = 1
        } else {
          guard !isXML, !isXMLNS else { throw XMLFormattingError.malformed }
          if value.bytes.isEmpty {
            guard isDefault else { throw XMLFormattingError.malformed }
            identity = 0
          } else {
            identity = try internNamespace(value.bytes, bucket: value.bucket)
          }
        }
        if isDefault {
          deltas.append(.defaultNamespace(defaultNamespace))
          defaultNamespace = identity
        } else {
          deltas.append(.prefix(name.local, previous: prefixBindings[name.local]))
          prefixBindings[name.local] = identity
        }
      }
      guard elementName.prefix != xmlnsPrefix else { throw XMLFormattingError.malformed }
      _ = try namespaceIdentity(elementName, attribute: false)
      var expanded: Set<ExpandedAttributeName> = []
      for name in names {
        try checkCancellation(cancel)
        if name.prefix == xmlnsPrefix || (name.prefix == nil && name.local == xmlnsPrefix) {
          continue
        }
        let identity = try namespaceIdentity(name, attribute: true)
        let key = ExpandedAttributeName(namespace: identity, local: name.local)
        guard expanded.insert(key).inserted else { throw XMLFormattingError.malformed }
      }
      return deltas
    }

    func namespaceIdentity(_ name: QualifiedName, attribute: Bool) throws -> Int {
      try checkCancellation(cancel)
      if let prefix = name.prefix {
        guard let identity = prefixBindings[prefix] else { throw XMLFormattingError.malformed }
        return identity
      }
      return attribute ? 0 : defaultNamespace
    }

    func restoreNamespaces(_ deltas: [NamespaceDelta]) throws {
      for delta in deltas.reversed() {
        try checkCancellation(cancel)
        switch delta {
        case .prefix(let prefix, let previous): prefixBindings[prefix] = previous
        case .defaultNamespace(let previous): defaultNamespace = previous
        }
      }
    }

    func namespaceBytesEqual(_ lhs: [UInt8], _ rhs: [UInt8]) throws -> Bool {
      try checkCancellation(cancel)
      guard lhs.count == rhs.count else { return false }
      for offset in lhs.indices {
        if offset % 1_024 == 0 { try checkCancellation(cancel) }
        if lhs[offset] != rhs[offset] { return false }
      }
      return true
    }

    func internNamespace(_ bytes: [UInt8], bucket: Int) throws -> Int {
      try checkCancellation(cancel)
      for identity in namespaceBuckets[bucket] ?? [] {
        try checkCancellation(cancel)
        if try namespaceBytesEqual(bytes, namespaceValues[identity]) { return identity }
      }
      // Excludes the fixed implicit xml constant. All retained values plus this
      // candidate fit the original payload bytes visited, never more than2MB.
      guard retainedNamespacePayloadBytes <= visitedNamespacePayloadBytes,
        bytes.count <= visitedNamespacePayloadBytes - retainedNamespacePayloadBytes
      else {
        throw LanguageError.analysisLimit
      }
      let identity = namespaceValues.count
      namespaceValues.append(bytes)
      retainedNamespacePayloadBytes += bytes.count
      namespaceBuckets[bucket, default: []].append(identity)
      return identity
    }

    /// Decode comparison values once, without changing emitted attribute bytes.
    func normalizedNamespaceValue(_ payload: Range<Int>) throws -> (bytes: [UInt8], bucket: Int) {
      try checkCancellation(cancel)
      guard payload.count <= markupLimit,
        payload.count <= bufferLimit - visitedNamespacePayloadBytes
      else { throw LanguageError.analysisLimit }
      visitedNamespacePayloadBytes += payload.count
      var bytes: [UInt8] = []
      bytes.reserveCapacity(payload.count)
      var hasher = namespaceHasher
      var cursor = payload.lowerBound
      func read() throws -> UInt8 {
        guard cursor < payload.upperBound else { throw XMLFormattingError.malformed }
        if cursor % 1_024 == 0 { try checkCancellation(cancel) }
        let byte = input[cursor]
        cursor += 1
        return byte
      }
      func append(_ byte: UInt8) throws {
        guard bytes.count < payload.count else { throw LanguageError.analysisLimit }
        if bytes.count % 1_024 == 0 { try checkCancellation(cancel) }
        hasher.combine(byte)
        bytes.append(byte)
      }
      func appendScalar(_ scalar: UInt32) throws {
        let count = scalar < 0x80 ? 1 : (scalar < 0x800 ? 2 : (scalar < 0x10000 ? 3 : 4))
        guard count <= payload.count - bytes.count else { throw LanguageError.analysisLimit }
        switch count {
        case 1:
          try append(UInt8(scalar))
        case 2:
          try append(UInt8(0xC0 | (scalar >> 6)))
          try append(UInt8(0x80 | (scalar & 0x3F)))
        case 3:
          try append(UInt8(0xE0 | (scalar >> 12)))
          try append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
          try append(UInt8(0x80 | (scalar & 0x3F)))
        default:
          try append(UInt8(0xF0 | (scalar >> 18)))
          try append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
          try append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
          try append(UInt8(0x80 | (scalar & 0x3F)))
        }
      }
      while cursor < payload.upperBound {
        let byte = try read()
        if byte == 38 {
          let first = try read()
          if first == 35 {
            var digitByte = try read()
            let hex = digitByte == 120
            if hex { digitByte = try read() }
            let radix: UInt32 = hex ? 16 : 10
            var scalar: UInt32 = 0
            var digits = 0
            while digitByte != 59 {
              let digit: UInt32
              switch digitByte {
              case 48...57: digit = UInt32(digitByte - 48)
              case 65...70 where hex: digit = UInt32(digitByte - 65 + 10)
              case 97...102 where hex: digit = UInt32(digitByte - 97 + 10)
              default: throw XMLFormattingError.malformed
              }
              guard scalar <= (0x10FFFF - digit) / radix else { throw XMLFormattingError.malformed }
              scalar = scalar * radix + digit
              digits += 1
              digitByte = try read()
            }
            guard digits > 0,
              scalar == 9 || scalar == 10 || scalar == 13 || (0x20...0xD7FF).contains(scalar)
                || (0xE000...0xFFFD).contains(scalar) || (0x10000...0x10FFFF).contains(scalar)
            else { throw XMLFormattingError.malformed }
            // A referenced whitespace scalar is not literal whitespace: do not
            // send it through the literal normalization branch below.
            try appendScalar(scalar)
          } else {
            let start = cursor - 1
            var next = first
            while next != 59 { next = try read() }
            let name = start..<(cursor - 1)
            if equalASCII(name, "amp") {
              try append(38)
            } else if equalASCII(name, "lt") {
              try append(60)
            } else if equalASCII(name, "gt") {
              try append(62)
            } else if equalASCII(name, "apos") {
              try append(39)
            } else if equalASCII(name, "quot") {
              try append(34)
            } else {
              throw XMLFormattingError.unsupported(.entity)
            }
          }
        } else if byte == 13 {
          if cursor < payload.upperBound && input[cursor] == 10 { _ = try read() }
          try append(32)
        } else if byte == 10 || byte == 9 {
          try append(32)
        } else {
          try append(byte)
        }
      }
      try checkCancellation(cancel)
      return (bytes, hasher.finalize())
    }

    func opaque(open: Int, close: [UInt8]) throws {
      try advance(open)
      while index < input.count && !matches(close) { try advance() }
      guard matches(close) else { throw XMLFormattingError.malformed }
      try advance(close.count)
    }

    func instruction(start: Int) throws {
      try advance(2)
      let target = try name()
      if equalASCII(target, "xml", ignoringCase: true) {
        guard equalASCII(target, "xml"), start == declarationPosition else {
          throw XMLFormattingError.malformed
        }
        try declaration()
        return
      }
      try validateNCName(target)
      guard
        matches(Array("?>".utf8))
          || (index < input.count && isWhitespace(input[index]))
      else { throw XMLFormattingError.malformed }
      while index < input.count && !matches(Array("?>".utf8)) { try advance() }
      guard matches(Array("?>".utf8)) else { throw XMLFormattingError.malformed }
      try advance(2)
    }

    func declaration() throws {
      var field = 0
      var sawEncoding = false
      var sawStandalone = false
      while true {
        let beforeWhitespace = index
        try whitespace()
        if matches(Array("?>".utf8)) { break }
        guard index > beforeWhitespace else { throw XMLFormattingError.malformed }
        guard field < 3 else { throw XMLFormattingError.malformed }
        let item = try attribute(references: false)
        let value = (item.quotedValue.lowerBound + 1)..<(item.quotedValue.upperBound - 1)
        if field == 0 {
          guard equalASCII(item.name, "version") else { throw XMLFormattingError.malformed }
          guard equalASCII(value, "1.0") else {
            throw XMLFormattingError.unsupported(.declaration)
          }
        } else if equalASCII(item.name, "encoding"), !sawEncoding, !sawStandalone {
          sawEncoding = true
          guard equalASCII(value, "UTF-8", ignoringCase: true) else {
            throw XMLFormattingError.unsupported(.declaration)
          }
        } else if equalASCII(item.name, "standalone"), !sawStandalone {
          sawStandalone = true
          guard equalASCII(value, "yes") || equalASCII(value, "no") else {
            throw XMLFormattingError.malformed
          }
        } else {
          throw XMLFormattingError.malformed
        }
        field += 1
      }
      guard field > 0 else { throw XMLFormattingError.malformed }
      try advance(2)
    }

    func equalASCII(_ range: Range<Int>, _ value: String, ignoringCase: Bool = false) -> Bool {
      let expected = Array(value.utf8)
      guard range.count == expected.count else { return false }
      for (byte, other) in zip(input[range], expected) {
        let folded = ignoringCase && byte >= 65 && byte <= 90 ? byte + 32 : byte
        let foldedOther = ignoringCase && other >= 65 && other <= 90 ? other + 32 : other
        if folded != foldedOther { return false }
      }
      return true
    }

    func reference() throws {
      try require(38)
      if index < input.count && input[index] == 35 {
        try advance()
        let hex = index < input.count && input[index] == 120
        if hex { try advance() }
        let radix: UInt32 = hex ? 16 : 10
        var value: UInt32 = 0
        var digits = 0
        while index < input.count && input[index] != 59 {
          let byte = input[index]
          let digit: UInt32
          switch byte {
          case 48...57: digit = UInt32(byte - 48)
          case 65...70 where hex: digit = UInt32(byte - 65 + 10)
          case 97...102 where hex: digit = UInt32(byte - 97 + 10)
          default: throw XMLFormattingError.malformed
          }
          guard value <= (0x10FFFF - digit) / radix else { throw XMLFormattingError.malformed }
          value = value * radix + digit
          digits += 1
          try advance()
        }
        guard digits > 0,
          value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        else { throw XMLFormattingError.malformed }
      } else {
        let start = index
        while index < input.count && input[index] != 59 {
          let byte = input[index]
          guard !isWhitespace(byte), byte != 60, byte != 38, byte != 34, byte != 39 else {
            throw XMLFormattingError.malformed
          }
          try advance()
        }
        let entityName = start..<index
        guard !entityName.isEmpty else { throw XMLFormattingError.malformed }
        guard index < input.count else { throw XMLFormattingError.malformed }
        guard ["amp", "lt", "gt", "apos", "quot"].contains(where: { equalASCII(entityName, $0) })
        else { throw XMLFormattingError.unsupported(.entity) }
      }
      try require(59)
    }

    func indent(_ count: Int) throws { try emit(Array(repeating: UInt8(32), count: count)) }

    func emit(_ range: Range<Int>) throws {
      guard range.count <= bufferLimit - output.count else { throw LanguageError.analysisLimit }
      var cursor = range.lowerBound
      while cursor < range.upperBound {
        try checkCancellation(cancel)
        let end = min(range.upperBound, cursor + 1_024)
        output.append(contentsOf: input[cursor..<end])
        cursor = end
      }
    }

    func emit(_ bytes: [UInt8]) throws {
      guard bytes.count <= bufferLimit - output.count else { throw LanguageError.analysisLimit }
      // Only fixed delimiters, newline and <=256 spaces use this overload.
      try checkCancellation(cancel)
      output.append(contentsOf: bytes)
    }
  }

  /// Errors remain sticky even on SDKs where a namespace error need not make
  /// parse() false. Callback text is never used to construct output or errors.
  private final class ValidationDelegate: NSObject, XMLParserDelegate {
    let cancel: @Sendable () -> Bool
    var failed = false
    var cancelled = false
    var ended = false

    init(cancel: @escaping @Sendable () -> Bool) { self.cancel = cancel }

    func poll(_ parser: XMLParser) {
      if cancel() {
        let needsAbort = !cancelled
        cancelled = true
        if needsAbort { parser.abortParsing() }
      }
    }

    func reject(_ parser: XMLParser) {
      let needsAbort = !failed
      failed = true
      poll(parser)
      if needsAbort && !cancelled { parser.abortParsing() }
    }

    func parserDidStartDocument(_ parser: XMLParser) { poll(parser) }
    func parserDidEndDocument(_ parser: XMLParser) {
      poll(parser)
      ended = !failed && !cancelled
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { reject(parser) }
    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
      reject(parser)
    }
    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) { poll(parser) }
    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?
    ) { poll(parser) }
    func parser(
      _ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String
    ) {
      poll(parser)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { poll(parser) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { poll(parser) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
      poll(parser)
    }
    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) { poll(parser) }
    func parser(_ parser: XMLParser, foundComment comment: String) { poll(parser) }
    func parser(
      _ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?
    ) { poll(parser) }
    func parser(
      _ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?
    ) -> Data? {
      reject(parser)
      return nil
    }
    func parser(
      _ parser: XMLParser, foundNotationDeclarationWithName name: String,
      publicID: String?, systemID: String?
    ) { reject(parser) }
    func parser(
      _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
      publicID: String?, systemID: String?, notationName: String?
    ) { reject(parser) }
    func parser(
      _ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String,
      forElement elementName: String, type: String?, defaultValue: String?
    ) { reject(parser) }
    func parser(
      _ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String
    ) {
      reject(parser)
    }
    func parser(
      _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
    ) {
      reject(parser)
    }
    func parser(
      _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
      publicID: String?, systemID: String?
    ) { reject(parser) }
  }
}
