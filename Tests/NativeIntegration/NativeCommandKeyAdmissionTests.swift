import AppKit
import XCTest

@testable import PadCore
@testable import ShortcutApplication

@MainActor private final class UserEquivalentItem: NSMenuItem {
  var syntheticUserEquivalent = ""
  override var userKeyEquivalent: String { syntheticUserEquivalent }
}

@MainActor final class NativeCommandKeyAdmissionTests: XCTestCase {
  private func key(_ flags: NSEvent.ModifierFlags, text: String = "n", repeated: Bool = false)
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
      windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
      isARepeat: repeated, keyCode: 0)!
  }
  private func configured(_ canonical: String = "cmd+n") throws
    -> (NSMenuItem, PublishedCommandKey)
  {
    let item = UserEquivalentItem(title: "Synthetic", action: nil, keyEquivalent: "")
    item.representedObject = "synthetic.action"
    let shortcut = try KeyboardShortcut(canonicalString: canonical)
    NativeKeyboardShortcut.configure(item, shortcut: shortcut)
    return (
      item,
      PublishedCommandKey(
        item: item, id: "synthetic.action", shortcut: shortcut,
        publication: 7)
    )
  }
  private func rejects(
    _ sender: NSMenuItem, _ snapshot: PublishedCommandKey?,
    _ scoped: NSEvent?, _ current: NSEvent?, publication: Int = 7
  ) -> Bool {
    NativeCommandKeyAdmission.shouldReject(
      sender: sender, snapshot: snapshot,
      publication: publication, scopedEvent: scoped, currentEvent: current)
  }
  func testAllModeledModifierCombinationsPreserveAppKitCharacterAuthority() throws {
    for descriptor in ["n", "x", "/", "up", "down"] {
      for expected in 0..<8 {
        let names = ["alt", "ctrl", "shift"].enumerated().compactMap { bit, name in
          expected & (1 << bit) != 0 ? name : nil
        }
        let (item, snapshot) = try configured((names + ["cmd", descriptor]).joined(separator: "+"))
        for actual in 0..<8 {
          var flags: NSEvent.ModifierFlags = [.command]
          for (bit, flag) in [NSEvent.ModifierFlags.option, .control, .shift].enumerated()
          where actual & (1 << bit) != 0 { flags.insert(flag) }
          let event = key(flags, text: "unrelated localized characters", repeated: true)
          XCTAssertEqual(
            rejects(item, snapshot, event, event), expected != actual,
            "descriptor=\(descriptor), configured=\(expected), event=\(actual)")
        }
      }
    }
  }
  func testRepeatMismatchRejectsAndNonmodeledFlagsDoNotChangeAdmission() throws {
    let (item, snapshot) = try configured()
    for repeated in [false, true] {
      let event = key([.command, .option], repeated: repeated)
      XCTAssertTrue(rejects(item, snapshot, event, event))
    }
    let event = key([.command, .capsLock, .numericPad, .function], text: "")
    XCTAssertFalse(rejects(item, snapshot, event, event))
  }
  func testAbsentOrStaleProvenancePassesThrough() throws {
    let (item, snapshot) = try configured()
    let event = key([.command, .option])
    XCTAssertFalse(rejects(item, nil, event, event))
    XCTAssertFalse(rejects(item, snapshot, nil, event))
    XCTAssertFalse(rejects(item, snapshot, event, nil))
    XCTAssertFalse(rejects(item, snapshot, event, key([.command, .option])))
    XCTAssertFalse(rejects(item, snapshot, event, event, publication: 8))
    let (stale, _) = try configured()
    XCTAssertFalse(rejects(stale, snapshot, event, event))
    item.representedObject = "different.action"
    XCTAssertFalse(rejects(item, snapshot, event, event))
  }
  func testUnknownOverridesAndChangedConfigurationPassThrough() throws {
    let (item, snapshot) = try configured()
    let event = key([.command, .option])
    (item as! UserEquivalentItem).syntheticUserEquivalent = "x"
    XCTAssertFalse(rejects(item, snapshot, event, event))
    (item as! UserEquivalentItem).syntheticUserEquivalent = ""
    item.keyEquivalent = "x"
    XCTAssertFalse(rejects(item, snapshot, event, event))
    item.keyEquivalent = snapshot.configuredKey
    item.keyEquivalentModifierMask = [.command, .shift]
    XCTAssertFalse(rejects(item, snapshot, event, event))
    item.keyEquivalentModifierMask = snapshot.configuredMask
    let disabled = PublishedCommandKey(item: item, id: snapshot.id, shortcut: nil, publication: 7)
    XCTAssertFalse(rejects(item, disabled, event, event))
    item.keyEquivalent = ""
    let empty = PublishedCommandKey(
      item: item, id: snapshot.id, shortcut: snapshot.shortcut, publication: 7)
    XCTAssertFalse(rejects(item, empty, event, event))
  }
  func testNonkeyNoCommandAndNativeQuitPassThrough() throws {
    let (item, snapshot) = try configured()
    let event = key(.option)
    XCTAssertFalse(rejects(item, snapshot, event, event))
    let nonkey = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero,
      modifierFlags: [.command, .option], timestamp: 1, windowNumber: 0, context: nil,
      subtype: 0, data1: 0, data2: 0)!
    XCTAssertFalse(rejects(item, snapshot, nonkey, nonkey))
    let quit = NSMenuItem(
      title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    XCTAssertFalse(rejects(quit, nil, event, event))
  }
  func testNestedKeyNonkeyAndThrowRestoreExactOuterScope() throws {
    let context = KeyboardDispatchContext()
    let outer = key(.command)
    let inner = key([.command, .control])
    let nonkey = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero,
      modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
      subtype: 0, data1: 0, data2: 0)!
    enum Expected: Error { case unwind }
    XCTAssertNil(context.event)
    try context.withEvent(outer) {
      XCTAssertTrue(context.event === outer)
      context.withEvent(inner) { XCTAssertTrue(context.event === inner) }
      XCTAssertTrue(context.event === outer)
      context.withEvent(nonkey) {
        XCTAssertNil(context.event)
        context.withEvent(inner) { XCTAssertTrue(context.event === inner) }
        XCTAssertNil(context.event)
      }
      XCTAssertTrue(context.event === outer)
      do { try context.withEvent(inner) { throw Expected.unwind } } catch Expected.unwind {
        XCTAssertTrue(context.event === outer)
      }
    }
    XCTAssertNil(context.event)
    context.withEvent(nonkey) { XCTAssertNil(context.event) }
    XCTAssertNil(context.event)
  }
}
