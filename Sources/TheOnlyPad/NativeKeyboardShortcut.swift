import AppKit
import PadCore

enum NativeShortcutError: LocalizedError {
  case unsupported, commandRequired, repeated, monitorUnavailable
  var errorDescription: String? {
    switch self {
    case .monitorUnavailable:
      return "Shortcut recording could not start. Try again in the active Shortcuts window."
    case .unsupported:
      return
        "Use a Command shortcut with one supported letter, digit, punctuation key, or Up/Down arrow. Dead keys and multi-key sequences are not supported."
    case .commandRequired: return "Include the Command key in the shortcut."
    case .repeated: return "Release the key, then press the shortcut once."
    }
  }
}
@MainActor enum NativeKeyboardShortcut {
  static func capture(_ event: NSEvent) throws -> KeyboardShortcut {
    guard event.type == .keyDown else { throw NativeShortcutError.unsupported }
    guard !event.isARepeat else { throw NativeShortcutError.repeated }
    guard event.modifierFlags.contains(.command) else { throw NativeShortcutError.commandRequired }
    let ignored = event.charactersIgnoringModifiers ?? ""
    guard ignored.unicodeScalars.count == 1, (event.characters ?? "").unicodeScalars.count == 1
    else {
      throw NativeShortcutError.unsupported
    }
    var modifiers: ShortcutModifiers = [.command]
    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
    let key: String
    if event.specialKey == .upArrow || ignored == String(UnicodeScalar(NSUpArrowFunctionKey)!) {
      key = "up"
    } else if event.specialKey == .downArrow
      || ignored == String(UnicodeScalar(NSDownArrowFunctionKey)!)
    {
      key = "down"
    } else {
      guard !event.modifierFlags.contains(.function),
        let base = event.characters(byApplyingModifiers: []), base.unicodeScalars.count == 1
      else { throw NativeShortcutError.unsupported }
      key = base
    }
    do { return try KeyboardShortcut(key: key, modifiers: modifiers) } catch {
      throw NativeShortcutError.unsupported
    }
  }
  static func configure(_ item: NSMenuItem, shortcut: KeyboardShortcut?) {
    guard let shortcut else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }
    item.keyEquivalent =
      shortcut.key == "up"
      ? String(UnicodeScalar(NSUpArrowFunctionKey)!)
      : shortcut.key == "down" ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : shortcut.key
    var flags: NSEvent.ModifierFlags = []
    if shortcut.modifiers.contains(.command) { flags.insert(.command) }
    if shortcut.modifiers.contains(.option) { flags.insert(.option) }
    if shortcut.modifiers.contains(.control) { flags.insert(.control) }
    if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
    item.keyEquivalentModifierMask = flags
  }
  static func display(_ shortcut: KeyboardShortcut?) -> String {
    guard let shortcut else { return "None" }
    var result = ""
    for (flag, symbol) in [
      (ShortcutModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ] where shortcut.modifiers.contains(flag) { result += symbol }
    return result
      + (shortcut.key == "up" ? "↑" : shortcut.key == "down" ? "↓" : shortcut.key.uppercased())
  }
}
