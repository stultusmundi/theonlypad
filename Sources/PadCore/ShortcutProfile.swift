import Foundation

public enum ShortcutAssignment: Equatable, Sendable {
  case disabled
  case assigned(KeyboardShortcut)
}
public struct ShortcutOverride: Equatable, Sendable {
  public let commandID: String
  public let assignment: ShortcutAssignment
  public init(commandID: String, assignment: ShortcutAssignment) {
    self.commandID = commandID
    self.assignment = assignment
  }
}
public struct ShortcutProfile: Equatable, Sendable {
  public static let maximumBytes = 262144
  public static let maximumRecords = 1024
  public let records: [ShortcutOverride]
  public init(records: [ShortcutOverride] = []) throws {
    guard records.count <= Self.maximumRecords else { throw ShortcutError.tooLarge }
    var ids = Set<String>()
    for record in records {
      guard Self.validID(record.commandID) else { throw ShortcutError.invalidProfile }
      guard ids.insert(record.commandID).inserted else { throw ShortcutError.duplicateCommand }
    }
    self.records = records
  }
  public static var defaults: Self { try! Self() }
  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 256
      && id.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || [45, 46, 95].contains($0)
      }
  }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw ShortcutError.tooLarge }
    var parser = StrictShortcutJSON(bytes: Array(data))
    let root = try parser.parse()
    guard case .object(let object) = root, Set(object.keys) == ["version", "overrides"],
      case .number(let version) = object["version"]
    else { throw ShortcutError.invalidProfile }
    guard version == "1" else { throw ShortcutError.unsupportedVersion }
    guard case .array(let records) = object["overrides"], records.count <= maximumRecords else {
      throw ShortcutError.invalidProfile
    }
    let decoded = try records.map { value -> ShortcutOverride in
      guard case .object(let record) = value, Set(record.keys) == ["commandID", "assignment"],
        case .string(let id) = record["commandID"],
        case .object(let assignment) = record["assignment"],
        case .string(let kind) = assignment["kind"]
      else { throw ShortcutError.invalidProfile }
      switch kind {
      case "disabled":
        guard Set(assignment.keys) == ["kind"] else { throw ShortcutError.invalidProfile }
        return ShortcutOverride(commandID: id, assignment: .disabled)
      case "assigned":
        guard Set(assignment.keys) == ["kind", "key", "modifiers"],
          case .string(let key) = assignment["key"],
          case .array(let flags) = assignment["modifiers"]
        else { throw ShortcutError.invalidProfile }
        let names = try flags.map { flag -> String in
          guard case .string(let name) = flag else { throw ShortcutError.invalidProfile }
          return name
        }
        return ShortcutOverride(
          commandID: id,
          assignment: .assigned(
            try KeyboardShortcut(key: key, modifiers: ShortcutModifiers.parse(names))))
      default: throw ShortcutError.invalidProfile
      }
    }
    return try Self(records: decoded)
  }
  public func encode() throws -> Data {
    let overrides: [[String: Any]] = records.map { record in
      let assignment: [String: Any]
      switch record.assignment {
      case .disabled: assignment = ["kind": "disabled"]
      case .assigned(let shortcut):
        assignment = [
          "kind": "assigned", "key": shortcut.key, "modifiers": shortcut.modifiers.names,
        ]
      }
      return ["commandID": record.commandID, "assignment": assignment]
    }
    let data = try JSONSerialization.data(
      withJSONObject: ["version": 1, "overrides": overrides], options: [.sortedKeys])
    guard data.count <= Self.maximumBytes else { throw ShortcutError.tooLarge }
    return data
  }
}
public struct ShortcutConflict: Equatable, Sendable {
  public enum Reason: Equatable, Sendable { case collision, reserved, protectedCommand }
  public let reason: Reason
  public let commandIDs: [String]
  public let shortcut: KeyboardShortcut?
}
public struct ShortcutComposition: Sendable {
  public let registry: CommandRegistry
  public let conflicts: [ShortcutConflict]
  public let unavailableCommandIDs: [String]
  public let usesDefaults: Bool
  public let catalogRevision: UUID
}
public enum ShortcutComposer {
  public static func build(
    catalog: [CommandDescriptor], profile: ShortcutProfile, catalogRevision: UUID
  ) throws -> ShortcutComposition {
    guard catalog.count <= 4096 else { throw ShortcutError.invalidCatalog }
    var defaults = CommandRegistry()
    var original: [String: KeyboardShortcut] = [:]
    var ids = Set<String>()
    for command in catalog {
      guard ShortcutProfile.validID(command.id), ids.insert(command.id).inserted else {
        throw ShortcutError.invalidCatalog
      }
      do {
        if let string = command.shortcut {
          let shortcut = try KeyboardShortcut(canonicalString: string)
          if ShortcutPolicy.isReserved(shortcut)
            && ShortcutPolicy.protectedCommands[command.id] != shortcut.canonicalString
          {
            throw ShortcutError.invalidCatalog
          }
          original[command.id] = shortcut
        }
        if let protected = ShortcutPolicy.protectedCommands[command.id],
          original[command.id]?.canonicalString != protected
        {
          throw ShortcutError.invalidCatalog
        }
        try defaults.register(command)
      } catch { throw ShortcutError.invalidCatalog }
    }
    var effective = original
    var conflicts: [ShortcutConflict] = []
    for record in profile.records {
      let assigned: KeyboardShortcut?
      switch record.assignment {
      case .disabled: assigned = nil
      case .assigned(let value): assigned = value
      }
      if let protected = ShortcutPolicy.protectedCommands[record.commandID],
        assigned?.canonicalString != protected
      {
        conflicts.append(
          .init(reason: .protectedCommand, commandIDs: [record.commandID], shortcut: assigned))
      }
      if let assigned, ShortcutPolicy.isReserved(assigned),
        ShortcutPolicy.protectedCommands[record.commandID] != assigned.canonicalString
      {
        conflicts.append(
          .init(reason: .reserved, commandIDs: [record.commandID], shortcut: assigned))
      }
      effective[record.commandID] = assigned
    }
    var owners: [KeyboardShortcut: [String]] = [:]
    for (id, shortcut) in effective { owners[shortcut, default: []].append(id) }
    for shortcut in owners.keys.sorted(by: { $0.canonicalString < $1.canonicalString }) {
      if let commandIDs = owners[shortcut], commandIDs.count > 1 {
        conflicts.append(
          .init(reason: .collision, commandIDs: commandIDs.sorted(), shortcut: shortcut))
      }
    }
    var registry = defaults
    if conflicts.isEmpty {
      registry = CommandRegistry()
      for command in catalog {
        try registry.register(
          .init(
            id: command.id, title: command.title, shortcut: effective[command.id]?.canonicalString))
      }
    }
    return ShortcutComposition(
      registry: registry, conflicts: conflicts,
      unavailableCommandIDs: profile.records.map(\.commandID).filter { !ids.contains($0) },
      usesDefaults: !conflicts.isEmpty, catalogRevision: catalogRevision)
  }
}

/// Small bounded parser solely for this strict schema. Strings use Foundation's JSON decoding,
/// but object keys are checked before a dictionary can discard duplicates (including escapes).
private struct StrictShortcutJSON {
  indirect enum Value {
    case object([String: Value])
    case array([Value])
    case string(String)
    case number(String)
    case literal
  }
  let bytes: [UInt8]
  var index = 0
  mutating func parse() throws -> Value {
    let result = try value(depth: 0)
    whitespace()
    guard index == bytes.count else { throw ShortcutError.invalidProfile }
    return result
  }
  mutating func whitespace() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
  mutating func consume(_ byte: UInt8) -> Bool {
    whitespace()
    if index < bytes.count && bytes[index] == byte {
      index += 1
      return true
    }
    return false
  }
  mutating func string() throws -> String {
    whitespace()
    let start = index
    guard index < bytes.count && bytes[index] == 34 else { throw ShortcutError.invalidProfile }
    index += 1
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == 34 {
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) } catch
        { throw ShortcutError.invalidProfile }
      }
      if byte == 92 {
        guard index < bytes.count else { throw ShortcutError.invalidProfile }
        index += 1
      }
    }
    throw ShortcutError.invalidProfile
  }
  mutating func value(depth: Int) throws -> Value {
    guard depth <= 8 else { throw ShortcutError.invalidProfile }
    whitespace()
    guard index < bytes.count else { throw ShortcutError.invalidProfile }
    if consume(123) {
      var object: [String: Value] = [:]
      if consume(125) { return .object(object) }
      repeat {
        let key = try string()
        guard object[key] == nil else { throw ShortcutError.duplicateKey }
        guard consume(58) else { throw ShortcutError.invalidProfile }
        object[key] = try value(depth: depth + 1)
        if consume(125) { return .object(object) }
      } while consume(44)
      throw ShortcutError.invalidProfile
    }
    if consume(91) {
      var array: [Value] = []
      if consume(93) { return .array(array) }
      repeat {
        array.append(try value(depth: depth + 1))
        if consume(93) { return .array(array) }
      } while consume(44)
      throw ShortcutError.invalidProfile
    }
    if bytes[index] == 34 { return .string(try string()) }
    let start = index
    while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
    guard index > start else { throw ShortcutError.invalidProfile }
    let token = String(decoding: bytes[start..<index], as: UTF8.self)
    if ["true", "false", "null"].contains(token) { return .literal }
    // Numeric tokens are used only for version; reject non-JSON spellings before schema checking.
    guard
      token.range(
        of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil
    else { throw ShortcutError.invalidProfile }
    return .number(token)
  }
}
