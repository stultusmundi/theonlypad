import Foundation

public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let command = Self(rawValue: 1)
  public static let option = Self(rawValue: 2)
  public static let control = Self(rawValue: 4)
  public static let shift = Self(rawValue: 8)
  static let tokens: [(String, Self)] = [
    ("alt", .option), ("cmd", .command), ("ctrl", .control), ("shift", .shift),
  ]
  var names: [String] { Self.tokens.compactMap { contains($0.1) ? $0.0 : nil } }
  static func parse(_ names: [String]) throws -> Self {
    guard Set(names).count == names.count else { throw ShortcutError.invalidShortcut }
    var result: Self = []
    for name in names {
      guard let value = tokens.first(where: { $0.0 == name })?.1 else {
        throw ShortcutError.invalidShortcut
      }
      result.insert(value)
    }
    return result
  }
}
public enum ShortcutError: Error, Equatable {
  case invalidShortcut, invalidProfile, unsupportedVersion, duplicateKey, duplicateCommand,
    tooLarge, invalidCatalog
}

/// Character-based menu equivalent. No physical-key or active-layout mapping occurs here.
public struct KeyboardShortcut: Hashable, Sendable {
  public let key: String
  public let modifiers: ShortcutModifiers
  public init(key: String, modifiers: ShortcutModifiers) throws {
    guard modifiers.contains(.command), modifiers.rawValue & ~UInt8(15) == 0 else {
      throw ShortcutError.invalidShortcut
    }
    var flags = modifiers
    if key == "up" || key == "down" {
      self.key = key
    } else {
      guard key.utf8.count == 1, let byte = key.utf8.first,
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || [91, 93, 47, 44, 61].contains(byte)
      else { throw ShortcutError.invalidShortcut }
      if (65...90).contains(byte) { flags.insert(.shift) }
      self.key = key.lowercased()
    }
    self.modifiers = flags
  }
  public init(canonicalString: String) throws {
    guard canonicalString.utf8.count <= 64 else { throw ShortcutError.invalidShortcut }
    let parts = canonicalString.split(separator: "+", omittingEmptySubsequences: false).map(
      String.init)
    guard let key = parts.last, parts.count >= 2 else { throw ShortcutError.invalidShortcut }
    try self.init(key: key, modifiers: ShortcutModifiers.parse(Array(parts.dropLast())))
  }
  public var canonicalString: String { (modifiers.names + [key]).joined(separator: "+") }
}

public enum ShortcutPolicy {
  public static let protectedCommands: [String: String] = [
    "edit.undo": "cmd+z", "edit.redo": "cmd+shift+z", "edit.cut": "cmd+x", "edit.copy": "cmd+c",
    "edit.paste": "cmd+v", "edit.selectAll": "cmd+a", "file.close": "cmd+w",
  ]
  public static func isReserved(_ shortcut: KeyboardShortcut) -> Bool {
    let value = shortcut.canonicalString
    if protectedCommands.values.contains(value) { return true }
    if [
      "cmd+h", "alt+cmd+h", "cmd+q", "alt+cmd+q", "cmd+m", "alt+cmd+m", "cmd+ctrl+q", "cmd+shift+q",
    ].contains(value) {
      return true
    }
    return shortcut.modifiers.contains(.shift) && ["3", "4", "5", "6"].contains(shortcut.key)
  }
}
