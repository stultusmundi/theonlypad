import Foundation

public enum LanguageProfileError: Error, Equatable { case invalid, limit, unimplemented }
public enum LanguageProfileID: Hashable, Sendable {
  case builtIn(DocumentLanguage)
  case custom(UUID)
}
public enum DocumentLanguageSelection: Equatable, Sendable {
  case automatic
  case manual(LanguageProfileID)
}
public enum LanguageIndentation: Equatable, Sendable {
  case legacy
  case spaces(width: Int)
  case tabs(width: Int)
}

private enum ProfileValidation {
  static func same(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let a?, let b?): return a.utf16.elementsEqual(b.utf16)
    default: return false
    }
  }
  static func same(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.0.utf16.elementsEqual($0.1.utf16) }
  }
  static func delimiter(_ text: String, maximum: Int) throws -> [UInt16] {
    let units = Array(text.utf16.prefix(maximum + 1))
    guard !units.isEmpty, units.count <= maximum,
      !units.contains(0), !units.contains(10), !units.contains(13),
      !units.contains(0x85), !units.contains(0x2028), !units.contains(0x2029)
    else { throw LanguageProfileError.invalid }
    return units
  }
  static func block(_ block: BlockCommentDelimiters?) throws {
    if let block {
      _ = try delimiter(block.opening, maximum: 32)
      _ = try delimiter(block.closing, maximum: 32)
    }
  }
  static func indentation(_ policy: LanguageIndentation) throws {
    switch policy {
    case .legacy: return
    case .spaces(let width), .tabs(let width):
      guard (1...8).contains(width) else { throw LanguageProfileError.invalid }
    }
  }
  static func letter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default: return false
    }
  }
  static func keyword(_ text: String) throws -> [UInt16] {
    let units = Array(text.utf16.prefix(65))
    guard !units.isEmpty, units.count <= 64, let first = text.unicodeScalars.first,
      first == "_" || letter(first)
    else { throw LanguageProfileError.invalid }
    for scalar in text.unicodeScalars.dropFirst() {
      if scalar == "_" || letter(scalar) { continue }
      switch scalar.properties.generalCategory {
      case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark: continue
      default: throw LanguageProfileError.invalid
      }
    }
    return units
  }
}

public struct LiteralQuoteRule: Equatable, Sendable {
  public let opening: String
  public let closing: String
  public let escape: String?
  public let multiline: Bool

  public init(opening: String, closing: String, escape: String?, multiline: Bool) throws {
    _ = try ProfileValidation.delimiter(opening, maximum: 16)
    _ = try ProfileValidation.delimiter(closing, maximum: 16)
    if let escape {
      let units = Array(escape.utf16.prefix(2))
      guard units.count == 1, (32...126).contains(units[0]) else {
        throw LanguageProfileError.invalid
      }
    }
    self.opening = opening
    self.closing = closing
    self.escape = escape
    self.multiline = multiline
  }
  public static func == (a: Self, b: Self) -> Bool {
    ProfileValidation.same(a.opening, b.opening)
      && ProfileValidation.same(a.closing, b.closing)
      && ProfileValidation.same(a.escape, b.escape) && a.multiline == b.multiline
  }
}

public struct ResolvedLanguageEditing: Equatable, Sendable {
  public let lineComment: String?
  public let blockComment: BlockCommentDelimiters?
  public let indentation: LanguageIndentation
  public init(
    lineComment: String?, blockComment: BlockCommentDelimiters?, indentation: LanguageIndentation
  ) {
    self.lineComment = lineComment
    self.blockComment = blockComment
    self.indentation = indentation
  }
  public static func == (a: Self, b: Self) -> Bool {
    ProfileValidation.same(a.lineComment, b.lineComment)
      && a.blockComment == b.blockComment && a.indentation == b.indentation
  }
}

public struct LiteralLanguageDefinition: Equatable, Sendable {
  public let id: UUID
  public let name: String
  public let fileExtensions: [String]
  public let keywords: [String]
  public let lineComment: String?
  public let blockComment: BlockCommentDelimiters?
  public let quotes: [LiteralQuoteRule]
  public let highlightDecimalNumbers: Bool
  public let indentation: LanguageIndentation

  public init(
    id: UUID, name: String, fileExtensions: [String], keywords: [String],
    lineComment: String?, blockComment: BlockCommentDelimiters?, quotes: [LiteralQuoteRule],
    highlightDecimalNumbers: Bool, indentation: LanguageIndentation
  ) throws {
    let nameScalars = Array(name.unicodeScalars.prefix(81))
    guard !nameScalars.isEmpty, nameScalars.count <= 80,
      nameScalars.allSatisfy({
        let category = $0.properties.generalCategory
        return category != .control && category != .lineSeparator && category != .paragraphSeparator
      })
    else { throw LanguageProfileError.invalid }
    guard fileExtensions.count <= 16, keywords.count <= 1024, quotes.count <= 4 else {
      throw LanguageProfileError.limit
    }
    var extensions = Set<String>()
    for ext in fileExtensions {
      let bytes = Array(ext.utf8.prefix(17))
      guard !bytes.isEmpty, bytes.count <= 16,
        bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
        extensions.insert(ext).inserted
      else { throw LanguageProfileError.invalid }
    }
    var words = Set<[UInt16]>()
    var total = 0
    for keyword in keywords {
      let units = try ProfileValidation.keyword(keyword)
      guard words.insert(units).inserted else { throw LanguageProfileError.invalid }
      guard units.count <= 32768 - total else { throw LanguageProfileError.limit }
      total += units.count
    }
    var openers = Set<[UInt16]>()
    if let lineComment {
      openers.insert(try ProfileValidation.delimiter(lineComment, maximum: 32))
    }
    try ProfileValidation.block(blockComment)
    if let blockComment {
      guard openers.insert(Array(blockComment.opening.utf16)).inserted else {
        throw LanguageProfileError.invalid
      }
    }
    for quote in quotes {
      guard openers.insert(Array(quote.opening.utf16)).inserted else {
        throw LanguageProfileError.invalid
      }
    }
    try ProfileValidation.indentation(indentation)
    self.id = id
    self.name = name
    self.fileExtensions = fileExtensions
    self.keywords = keywords
    self.lineComment = lineComment
    self.blockComment = blockComment
    self.quotes = quotes
    self.highlightDecimalNumbers = highlightDecimalNumbers
    self.indentation = indentation
  }
  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && ProfileValidation.same(a.name, b.name)
      && ProfileValidation.same(a.fileExtensions, b.fileExtensions)
      && ProfileValidation.same(a.keywords, b.keywords)
      && ProfileValidation.same(a.lineComment, b.lineComment)
      && a.blockComment == b.blockComment && a.quotes == b.quotes
      && a.highlightDecimalNumbers == b.highlightDecimalNumbers && a.indentation == b.indentation
  }
}

public enum LineCommentOverride: Equatable, Sendable {
  case inherit, disabled
  case literal(String)
  public static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.inherit, .inherit), (.disabled, .disabled): return true
    case (.literal(let a), .literal(let b)): return a.utf16.elementsEqual(b.utf16)
    default: return false
    }
  }
}
public enum BlockCommentOverride: Equatable, Sendable {
  case inherit, disabled
  case literal(BlockCommentDelimiters)
}
public struct BuiltInLanguageOverride: Equatable, Sendable {
  public let language: DocumentLanguage
  public let lineComment: LineCommentOverride
  public let blockComment: BlockCommentOverride
  public let indentation: LanguageIndentation
  public init(
    language: DocumentLanguage, lineComment: LineCommentOverride,
    blockComment: BlockCommentOverride, indentation: LanguageIndentation
  ) throws {
    let inherited = LanguageConfiguration(language: language)
    let effectiveLine: String?
    switch lineComment {
    case .inherit: effectiveLine = inherited.lineComment
    case .disabled: effectiveLine = nil
    case .literal(let text):
      _ = try ProfileValidation.delimiter(text, maximum: 32)
      effectiveLine = text
    }
    let effectiveBlock: BlockCommentDelimiters?
    switch blockComment {
    case .inherit: effectiveBlock = inherited.blockComment
    case .disabled: effectiveBlock = nil
    case .literal(let block):
      try ProfileValidation.block(block)
      effectiveBlock = block
    }
    if let effectiveLine, let effectiveBlock,
      effectiveLine.utf16.elementsEqual(effectiveBlock.opening.utf16)
    {
      throw LanguageProfileError.invalid
    }
    try ProfileValidation.indentation(indentation)
    self.language = language
    self.lineComment = lineComment
    self.blockComment = blockComment
    self.indentation = indentation
  }
}

public enum LanguageProfileWarning: Equatable, Sendable { case missingProfile(UUID) }
public struct ResolvedLanguageProfile: Equatable, Sendable {
  public let requestedID: LanguageProfileID
  public let catalogGeneration: UInt64
  /// Nil for a draft/unversioned definition; only a supplying store can bind an installed revision.
  public let definitionRevision: UInt64?
  public let displayLabel: String
  public let builtinLanguage: DocumentLanguage?
  public let definition: LiteralLanguageDefinition?
  public let editing: ResolvedLanguageEditing
  public let warning: LanguageProfileWarning?
  public static func == (a: Self, b: Self) -> Bool {
    a.requestedID == b.requestedID && a.catalogGeneration == b.catalogGeneration
      && a.definitionRevision == b.definitionRevision
      && ProfileValidation.same(a.displayLabel, b.displayLabel)
      && a.builtinLanguage == b.builtinLanguage && a.definition == b.definition
      && a.editing == b.editing && a.warning == b.warning
  }
}

public struct LanguageCatalogSnapshot: Sendable {
  public let definitions: [LiteralLanguageDefinition]
  public let overrides: [BuiltInLanguageOverride]
  public let generation: UInt64
  private let installedDefinitionRevisions: [UUID: UInt64]?

  public init(
    definitions: [LiteralLanguageDefinition], overrides: [BuiltInLanguageOverride],
    generation: UInt64
  ) throws {
    try self.init(
      definitions: definitions, overrides: overrides, generation: generation,
      installedRevisions: nil)
  }

  /// Validated installed revisions; this immutable value is not a file read receipt.
  public init(
    definitions: [LiteralLanguageDefinition], overrides: [BuiltInLanguageOverride],
    generation: UInt64,
    definitionRevisions: [UUID: UInt64]
  ) throws {
    try self.init(
      definitions: definitions, overrides: overrides, generation: generation,
      installedRevisions: definitionRevisions)
  }

  private init(
    definitions: [LiteralLanguageDefinition], overrides: [BuiltInLanguageOverride],
    generation: UInt64,
    installedRevisions: [UUID: UInt64]?
  ) throws {
    guard definitions.count <= 64, overrides.count <= DocumentLanguage.allCases.count else {
      throw LanguageProfileError.limit
    }
    var ids = Set<UUID>()
    var extensions = Set<String>()
    for definition in definitions {
      guard ids.insert(definition.id).inserted else { throw LanguageProfileError.invalid }
      for ext in definition.fileExtensions {
        guard extensions.insert(ext).inserted else { throw LanguageProfileError.invalid }
      }
    }
    var builtins = Set<DocumentLanguage>()
    for override in overrides {
      guard builtins.insert(override.language).inserted else { throw LanguageProfileError.invalid }
    }
    if let installedRevisions {
      guard installedRevisions.count == ids.count,
        Set(installedRevisions.keys) == ids,
        installedRevisions.values.allSatisfy({ $0 > 0 })
      else { throw LanguageProfileError.invalid }
    }
    self.definitions = definitions
    self.overrides = overrides
    self.generation = generation
    self.installedDefinitionRevisions = installedRevisions
  }

  public func resolve(
    selection: DocumentLanguageSelection, filename: String, builtinDetected: DocumentLanguage
  ) -> ResolvedLanguageProfile {
    let requested: LanguageProfileID
    switch selection {
    case .manual(let id): requested = id
    case .automatic:
      let byFilename = LanguageService.detect(filename: filename, text: "")
      if byFilename != .plainText {
        requested = .builtIn(byFilename)
      } else {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let custom = definitions.first(where: { $0.fileExtensions.contains(ext) }) {
          requested = .custom(custom.id)
        } else {
          requested = .builtIn(builtinDetected)
        }
      }
    }
    switch requested {
    case .custom(let id):
      guard let definition = definitions.first(where: { $0.id == id }) else {
        return ResolvedLanguageProfile(
          requestedID: requested, catalogGeneration: generation, definitionRevision: nil,
          displayLabel: "Profile missing — plain text", builtinLanguage: .plainText,
          definition: nil,
          editing: .init(lineComment: nil, blockComment: nil, indentation: .legacy),
          warning: .missingProfile(id))
      }
      return ResolvedLanguageProfile(
        requestedID: requested, catalogGeneration: generation,
        definitionRevision: installedDefinitionRevisions?[id], displayLabel: definition.name,
        builtinLanguage: nil, definition: definition,
        editing: .init(
          lineComment: definition.lineComment, blockComment: definition.blockComment,
          indentation: definition.indentation), warning: nil)
    case .builtIn(let language):
      let inherited = LanguageConfiguration(language: language)
      var line = inherited.lineComment
      var block = inherited.blockComment
      var policy = LanguageIndentation.legacy
      if let override = overrides.first(where: { $0.language == language }) {
        switch override.lineComment {
        case .inherit: break
        case .disabled: line = nil
        case .literal(let value): line = value
        }
        switch override.blockComment {
        case .inherit: break
        case .disabled: block = nil
        case .literal(let value): block = value
        }
        policy = override.indentation
      }
      return ResolvedLanguageProfile(
        requestedID: requested, catalogGeneration: generation, definitionRevision: nil,
        displayLabel: language.rawValue, builtinLanguage: language, definition: nil,
        editing: .init(lineComment: line, blockComment: block, indentation: policy), warning: nil)
    }
  }
}

public enum LanguageProfileCodec {
  private typealias Value = BoundedProfileJSON.Value
  public static func decodeDefinition(_ data: Data) throws -> LiteralLanguageDefinition {
    let value = try BoundedProfileJSON.parse(
      data, limits: .init(maximumBytes: 65536, maximumDepth: 16, maximumValues: 8192))
    return try decodeDefinitionValue(value)
  }

  /// Reuses the original definition schema with exact numeric tokens in a bounded catalog tree.
  static func decodeDefinitionValue(_ value: BoundedProfileJSON.Value) throws
    -> LiteralLanguageDefinition
  {
    guard case .object(let object) = value,
      Set(object.keys) == [
        "version", "id", "name", "fileExtensions", "keywords", "lineComment",
        "blockComment", "quotes", "highlightDecimalNumbers", "indentation",
      ], case .number("1") = object["version"],
      case .string(let idText) = object["id"], idText.utf8.count == 36,
      let id = UUID(uuidString: idText),
      case .string(let name) = object["name"],
      case .bool(let numbers) = object["highlightDecimalNumbers"],
      case .array(let quoteValues) = object["quotes"]
    else { throw LanguageProfileError.invalid }
    guard quoteValues.count <= 4 else { throw LanguageProfileError.limit }
    let extensions = try strings(object["fileExtensions"], maximum: 16)
    let keywords = try strings(object["keywords"], maximum: 1024)
    let line = try nullableString(object["lineComment"])
    let block: BlockCommentDelimiters?
    switch object["blockComment"] {
    case .null?: block = nil
    case .object(let fields)?:
      guard Set(fields.keys) == ["opening", "closing"],
        case .string(let opening) = fields["opening"],
        case .string(let closing) = fields["closing"]
      else { throw LanguageProfileError.invalid }
      block = .init(opening: opening, closing: closing)
    default: throw LanguageProfileError.invalid
    }
    let quotes = try quoteValues.map { quote -> LiteralQuoteRule in
      guard case .object(let fields) = quote,
        Set(fields.keys) == ["opening", "closing", "escape", "multiline"],
        case .string(let opening) = fields["opening"],
        case .string(let closing) = fields["closing"],
        case .bool(let multiline) = fields["multiline"]
      else { throw LanguageProfileError.invalid }
      return try .init(
        opening: opening, closing: closing, escape: nullableString(fields["escape"]),
        multiline: multiline)
    }
    guard case .object(let fields) = object["indentation"],
      case .string(let kind) = fields["kind"]
    else { throw LanguageProfileError.invalid }
    let policy: LanguageIndentation
    if kind == "legacy" {
      guard Set(fields.keys) == ["kind"] else { throw LanguageProfileError.invalid }
      policy = .legacy
    } else {
      guard Set(fields.keys) == ["kind", "width"], case .number(let widthText) = fields["width"],
        let width = Int(widthText), (1...8).contains(width), widthText == String(width)
      else { throw LanguageProfileError.invalid }
      switch kind {
      case "spaces": policy = .spaces(width: width)
      case "tabs": policy = .tabs(width: width)
      default: throw LanguageProfileError.invalid
      }
    }
    return try LiteralLanguageDefinition(
      id: id, name: name, fileExtensions: extensions, keywords: keywords,
      lineComment: line, blockComment: block, quotes: quotes,
      highlightDecimalNumbers: numbers, indentation: policy)
  }
  private static func strings(_ value: Value?, maximum: Int) throws -> [String] {
    guard case .array(let values) = value else { throw LanguageProfileError.invalid }
    guard values.count <= maximum else { throw LanguageProfileError.limit }
    return try values.map {
      guard case .string(let string) = $0 else { throw LanguageProfileError.invalid }
      return string
    }
  }
  private static func nullableString(_ value: Value?) throws -> String? {
    switch value {
    case .null?: return nil
    case .string(let string)?: return string
    default: throw LanguageProfileError.invalid
    }
  }

  public static func encodeDefinition(_ definition: LiteralLanguageDefinition) throws -> Data {
    var policy: [String: Any]
    switch definition.indentation {
    case .legacy: policy = ["kind": "legacy"]
    case .spaces(let width): policy = ["kind": "spaces", "width": width]
    case .tabs(let width): policy = ["kind": "tabs", "width": width]
    }
    let block: Any
    if let pair = definition.blockComment {
      block = ["opening": pair.opening, "closing": pair.closing]
    } else {
      block = NSNull()
    }
    let quotes: [[String: Any]] = definition.quotes.map {
      [
        "opening": $0.opening, "closing": $0.closing,
        "escape": $0.escape.map { $0 as Any } ?? NSNull(), "multiline": $0.multiline,
      ]
    }
    let object: [String: Any] = [
      "version": 1, "id": definition.id.uuidString.lowercased(), "name": definition.name,
      "fileExtensions": definition.fileExtensions, "keywords": definition.keywords,
      "lineComment": definition.lineComment.map { $0 as Any } ?? NSNull(),
      "blockComment": block, "quotes": quotes,
      "highlightDecimalNumbers": definition.highlightDecimalNumbers, "indentation": policy,
    ]
    let bytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard bytes.count <= 65536 else { throw LanguageProfileError.limit }
    return bytes
  }
}
