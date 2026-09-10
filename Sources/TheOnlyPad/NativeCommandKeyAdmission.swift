import AppKit
import PadCore

@MainActor struct PublishedCommandKey {
  let item: NSMenuItem
  let id: String
  let shortcut: KeyboardShortcut?
  let publication: Int
  let configuredKey: String
  let configuredMask: NSEvent.ModifierFlags

  init(item: NSMenuItem, id: String, shortcut: KeyboardShortcut?, publication: Int) {
    self.item = item
    self.id = id
    self.shortcut = shortcut
    self.publication = publication
    configuredKey = item.keyEquivalent
    configuredMask = item.keyEquivalentModifierMask
  }
}

@MainActor enum NativeCommandKeyAdmission {
  static func shouldReject(
    sender: NSMenuItem, snapshot: PublishedCommandKey?, publication: Int,
    scopedEvent: NSEvent?, currentEvent: NSEvent?
  ) -> Bool {
    guard let event = scopedEvent, event === currentEvent, event.type == .keyDown,
      event.modifierFlags.contains(.command),
      let snapshot, snapshot.publication == publication, snapshot.item === sender,
      sender.representedObject as? String == snapshot.id,
      snapshot.shortcut != nil, !snapshot.configuredKey.isEmpty,
      sender.userKeyEquivalent.isEmpty,
      sender.keyEquivalent == snapshot.configuredKey,
      sender.keyEquivalentModifierMask == snapshot.configuredMask
    else { return false }
    // AppKit owns character/layout localization. This gate compares only the
    // four configured modifiers, including repeated key-downs, during live delivery.
    let modeled: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    return event.modifierFlags.intersection(modeled)
      != snapshot.configuredMask.intersection(modeled)
  }
}
