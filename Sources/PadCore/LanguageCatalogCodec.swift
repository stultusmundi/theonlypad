import Foundation

/// Persistent catalog envelope. Standalone profile import retains Task1's separate 64KiB API.
enum LanguageCatalogCodec {
  private typealias Value = BoundedProfileJSON.Value

  static func decode(_ data: Data) throws -> LanguageCatalogSnapshot {
    let value = try BoundedProfileJSON.parse(
      data,
      limits: .init(
        maximumBytes: CustomLanguageStore.maximumBytes,
        maximumDepth: 16, maximumValues: 100_000))
    guard case .object(let fields) = value,
      Set(fields.keys) == ["version", "generation", "profiles", "overrides"],
      case .number("1") = fields["version"],
      case .array(let records) = fields["profiles"],
      case .array(let overrideValues) = fields["overrides"]
    else { throw CustomLanguageStoreError.invalidCatalog }
    let generation = try unsigned(fields["generation"])
    guard records.count <= 64, overrideValues.count <= DocumentLanguage.allCases.count else {
      throw LanguageProfileError.limit
    }
    guard generation != 0 || (records.isEmpty && overrideValues.isEmpty) else {
      throw CustomLanguageStoreError.invalidCatalog
    }
    var definitions: [LiteralLanguageDefinition] = []
    var revisions: [UUID: UInt64] = [:]
    for record in records {
      guard case .object(let entry) = record, Set(entry.keys) == ["revision", "definition"],
        let value = entry["definition"]
      else { throw CustomLanguageStoreError.invalidCatalog }
      let revision = try unsigned(entry["revision"])
      guard revision > 0 else { throw CustomLanguageStoreError.invalidCatalog }
      // Pass the exact typed tree. No NSNumber/Double serialization may normalize
      // nested numeric spellings before the unchanged Task1 schema validation.
      let definition = try LanguageProfileCodec.decodeDefinitionValue(value)
      guard revisions[definition.id] == nil else { throw CustomLanguageStoreError.invalidCatalog }
      definitions.append(definition)
      revisions[definition.id] = revision
    }
    let overrides = try overrideValues.map { try decodeOverride($0) }
    return try LanguageCatalogSnapshot(
      definitions: definitions, overrides: overrides, generation: generation,
      definitionRevisions: revisions)
  }

  static func encode(_ snapshot: LanguageCatalogSnapshot) throws -> Data {
    guard
      snapshot.generation != 0
        || (snapshot.definitions.isEmpty && snapshot.overrides.isEmpty)
    else { throw CustomLanguageStoreError.invalidCatalog }
    var bytes = Data()
    func append(_ data: Data) throws {
      guard data.count <= CustomLanguageStore.maximumBytes - bytes.count else {
        throw CustomLanguageStoreError.tooLarge
      }
      bytes.append(data)
    }
    try append(Data("{\"version\":1,\"generation\":\(snapshot.generation),\"profiles\":[".utf8))
    for (index, definition) in snapshot.definitions.enumerated() {
      guard
        let revision = snapshot.resolve(
          selection: .manual(.custom(definition.id)), filename: "", builtinDetected: .plainText
        ).definitionRevision, revision > 0
      else { throw CustomLanguageStoreError.invalidCatalog }
      if index != 0 { try append(Data(",".utf8)) }
      try append(Data("{\"revision\":\(revision),\"definition\":".utf8))
      try append(LanguageProfileCodec.encodeDefinition(definition))
      try append(Data("}".utf8))
    }
    try append(Data("],\"overrides\":[".utf8))
    for (index, override) in snapshot.overrides.enumerated() {
      if index != 0 { try append(Data(",".utf8)) }
      let encoded = try JSONSerialization.data(
        withJSONObject: encodeOverride(override), options: [.sortedKeys, .withoutEscapingSlashes])
      try append(encoded)
    }
    try append(Data("]}".utf8))
    return bytes
  }

  private static func unsigned(_ value: Value?) throws -> UInt64 {
    guard case .number(let spelling) = value, let number = UInt64(spelling),
      spelling == String(number)
    else { throw CustomLanguageStoreError.invalidCatalog }
    return number
  }

  private static func decodeOverride(_ value: Value) throws -> BuiltInLanguageOverride {
    guard case .object(let fields) = value,
      Set(fields.keys) == ["language", "lineComment", "blockComment", "indentation"],
      case .string(let name) = fields["language"], let language = DocumentLanguage(rawValue: name)
    else { throw CustomLanguageStoreError.invalidCatalog }
    return try BuiltInLanguageOverride(
      language: language, lineComment: line(fields["lineComment"]),
      blockComment: block(fields["blockComment"]), indentation: indentation(fields["indentation"]))
  }

  private static func line(_ value: Value?) throws -> LineCommentOverride {
    guard case .object(let fields) = value, case .string(let kind) = fields["kind"] else {
      throw CustomLanguageStoreError.invalidCatalog
    }
    switch kind {
    case "inherit", "disabled":
      guard Set(fields.keys) == ["kind"] else { throw CustomLanguageStoreError.invalidCatalog }
      return kind == "inherit" ? .inherit : .disabled
    case "literal":
      guard Set(fields.keys) == ["kind", "value"], case .string(let string) = fields["value"] else {
        throw CustomLanguageStoreError.invalidCatalog
      }
      return .literal(string)
    default: throw CustomLanguageStoreError.invalidCatalog
    }
  }

  private static func block(_ value: Value?) throws -> BlockCommentOverride {
    guard case .object(let fields) = value, case .string(let kind) = fields["kind"] else {
      throw CustomLanguageStoreError.invalidCatalog
    }
    switch kind {
    case "inherit", "disabled":
      guard Set(fields.keys) == ["kind"] else { throw CustomLanguageStoreError.invalidCatalog }
      return kind == "inherit" ? .inherit : .disabled
    case "literal":
      guard Set(fields.keys) == ["kind", "value"], case .object(let pair) = fields["value"],
        Set(pair.keys) == ["opening", "closing"],
        case .string(let opening) = pair["opening"], case .string(let closing) = pair["closing"]
      else { throw CustomLanguageStoreError.invalidCatalog }
      return .literal(.init(opening: opening, closing: closing))
    default: throw CustomLanguageStoreError.invalidCatalog
    }
  }

  private static func indentation(_ value: Value?) throws -> LanguageIndentation {
    guard case .object(let fields) = value, case .string(let kind) = fields["kind"] else {
      throw CustomLanguageStoreError.invalidCatalog
    }
    if kind == "legacy" {
      guard Set(fields.keys) == ["kind"] else { throw CustomLanguageStoreError.invalidCatalog }
      return .legacy
    }
    guard Set(fields.keys) == ["kind", "width"], case .number(let spelling) = fields["width"],
      let width = Int(spelling), (1...8).contains(width), spelling == String(width)
    else { throw CustomLanguageStoreError.invalidCatalog }
    switch kind {
    case "spaces": return .spaces(width: width)
    case "tabs": return .tabs(width: width)
    default: throw CustomLanguageStoreError.invalidCatalog
    }
  }

  private static func encodeOverride(_ override: BuiltInLanguageOverride) -> [String: Any] {
    let line: [String: Any]
    switch override.lineComment {
    case .inherit: line = ["kind": "inherit"]
    case .disabled: line = ["kind": "disabled"]
    case .literal(let value): line = ["kind": "literal", "value": value]
    }
    let block: [String: Any]
    switch override.blockComment {
    case .inherit: block = ["kind": "inherit"]
    case .disabled: block = ["kind": "disabled"]
    case .literal(let pair):
      block = ["kind": "literal", "value": ["opening": pair.opening, "closing": pair.closing]]
    }
    let policy: [String: Any]
    switch override.indentation {
    case .legacy: policy = ["kind": "legacy"]
    case .spaces(let width): policy = ["kind": "spaces", "width": width]
    case .tabs(let width): policy = ["kind": "tabs", "width": width]
    }
    return [
      "language": override.language.rawValue, "lineComment": line,
      "blockComment": block, "indentation": policy,
    ]
  }
}
