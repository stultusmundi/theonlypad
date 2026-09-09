import AppKit
import PadCore

@MainActor final class Receiver: NSObject {
  var hits = 0
  @objc func invoke(_ sender: Any?) { hits += 1 }
}
@main struct Harness {
  @MainActor static func main() async {
    _ = NSApplication.shared
    var failures = 0
    func check(_ value: Bool, _ label: String) {
      print("\(value ? "PASS":"FAIL") \(label)")
      if !value { failures += 1 }
    }
    let receiver = Receiver()
    let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
      (45, [.command], "cmd+n"), (6, [.command, .shift], "cmd+shift+z"),
      (30, [.command, .shift], "cmd+shift+]"), (24, [.command, .shift], "cmd+shift+="),
      (44, [.command, .option], "alt+cmd+/"), (126, [.command, .option], "alt+cmd+up"),
      (125, [.command, .option], "alt+cmd+down"),
    ]
    for (code, flags, canonical) in cases {
      let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
      cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
      let event = NSEvent(cgEvent: cg)!
      let value = try? NativeKeyboardShortcut.capture(event)
      check(value?.canonicalString == canonical, "capture \(canonical)")
      let item = NSMenuItem(
        title: "Synthetic", action: #selector(Receiver.invoke(_:)), keyEquivalent: "")
      item.target = receiver
      NativeKeyboardShortcut.configure(
        item, shortcut: try! KeyboardShortcut(canonicalString: canonical))
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.addItem(item)
      let before = receiver.hits
      check(
        menu.performKeyEquivalent(with: event) && receiver.hits == before + 1,
        "menu dispatch \(canonical)")
      check(NativeKeyboardShortcut.display(value).contains("⌘"), "render command symbol")
    }
    var handler: ((NSEvent) -> NSEvent?)?
    var removed = 0
    var eligible = true
    var matchingWindow = true
    let environment = ShortcutRecorderEnvironment(
      prepare: { _ in eligible }, ownsFocus: { _ in eligible },
      ownsEvent: { _, _ in matchingWindow },
      add: {
        handler = $0
        return NSObject()
      },
      remove: { _ in
        removed += 1
        handler = nil
      })
    let recorder = ShortcutRecorderView(environment: environment)
    var captures = 0
    recorder.onCaptured = { _ in captures += 1 }
    check(
      recorder.start() && recorder.isRecording && handler != nil,
      "recorder installs scoped local monitor")
    let q = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!
    q.flags = .maskCommand
    if let handler {
      check(handler(NSEvent(cgEvent: q)!) == nil, "recorded CmdQ consumed before menu dispatch")
    } else {
      check(false, "recorded CmdQ consumed before menu dispatch")
    }
    check(
      captures == 1 && !recorder.isRecording && removed == 1,
      "capture retires monitor before callback")
    eligible = false
    check(!recorder.start(), "unfocused start refused")
    func event(
      _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [.command],
      repeatKey: Bool = false
    ) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey,
        keyCode: code)!
    }
    for (e, name) in [
      (event(45, "n", []), "bare key"), (event(45, "n", repeatKey: true), "repeat"),
      (event(45, ""), "dead key"), (event(45, "ab"), "multiscalar"), (event(36, "\r"), "Return"),
      (event(122, String(UnicodeScalar(NSF1FunctionKey)!)), "F1"),
    ] {
      do {
        _ = try NativeKeyboardShortcut.capture(e)
        check(false, "reject \(name)")
      } catch { check(!(error.localizedDescription.isEmpty), "reject \(name)") }
    }
    let ambiguous = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
      context: nil, characters: "e\u{301}", charactersIgnoringModifiers: "e", isARepeat: false,
      keyCode: 14)!
    do {
      _ = try NativeKeyboardShortcut.capture(ambiguous)
      check(false, "reject multiscalar characters despite single ignored key")
    } catch { check(true, "reject multiscalar characters despite single ignored key") }
    let cleared = NSMenuItem(title: "clear", action: nil, keyEquivalent: "n")
    NativeKeyboardShortcut.configure(cleared, shortcut: nil)
    check(
      cleared.keyEquivalent.isEmpty && cleared.keyEquivalentModifierMask.isEmpty,
      "clear key and mask")
    var cancels = 0
    var errors = 0
    recorder.onCancel = { cancels += 1 }
    recorder.onError = { _ in errors += 1 }
    eligible = true
    _ = recorder.start()
    check(
      handler?(event(36, "\r")) == nil && errors == 1 && recorder.isRecording,
      "Return consumed without accidental Apply")
    check(
      handler?(event(53, "\u{1b}", [])) == nil && cancels == 1 && !recorder.isRecording,
      "Escape consumes and cancels")
    _ = recorder.start()
    let tab = event(48, "\t", [])
    check(
      handler?(tab) === tab && cancels == 2 && !recorder.isRecording, "Tab cancels and propagates")
    _ = recorder.start()
    eligible = false
    let unrelated = event(45, "n")
    check(
      handler?(unrelated) === unrelated && !recorder.isRecording && cancels == 3,
      "lost focus cancels and propagates")
    eligible = true
    _ = recorder.start()
    matchingWindow = false
    let foreignEvent = event(45, "n")
    let beforeForeign = captures
    check(
      handler?(foreignEvent) === foreignEvent && recorder.isRecording && captures == beforeForeign,
      "event from another window propagates without canceling active scope")
    matchingWindow = true
    recorder.stop()
    _ = recorder.start()
    recorder.stop()
    recorder.stop()
    check(!recorder.isRecording && handler == nil, "explicit owner stop is idempotent")
    _ = recorder.start()
    let obsolete = handler!
    recorder.stop()
    _ = recorder.start()
    let beforeStale = captures
    check(
      obsolete(event(45, "n")) != nil && captures == beforeStale && recorder.isRecording,
      "old monitor callback cannot capture into new recording")
    recorder.stop()
    let beforeLifetime = removed
    weak var weakView: ShortcutRecorderView?
    do {
      let temporary = ShortcutRecorderView(environment: environment)
      weakView = temporary
      _ = temporary.start()
    }
    for _ in 0..<50 { await Task.yield() }
    check(
      weakView == nil && handler == nil && removed == beforeLifetime + 1,
      "teardown releases view and removes local monitor")
    let hidden = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
      backing: .buffered, defer: false)
    let actual = ShortcutRecorderView()
    hidden.contentView = actual
    check(!actual.start() && !actual.isRecording, "actual hidden non-key window cannot record")
    let scoped = ShortcutRecorderView(environment: environment)
    hidden.contentView = scoped
    var windowCancel = 0
    scoped.onCancel = { windowCancel += 1 }
    _ = scoped.start()
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: hidden)
    check(
      !scoped.isRecording && windowCancel == 1,
      "resign-key notification stops injected active scope")
    _ = scoped.start()
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: hidden)
    check(
      !scoped.isRecording && windowCancel == 2,
      "window-close notification stops injected active scope")
    _ = scoped.start()
    _ = scoped.resignFirstResponder()
    check(!scoped.isRecording, "responder resignation stops recording")
    _ = scoped.start()
    scoped.removeFromSuperview()
    check(!scoped.isRecording, "view removal stops recording")
    var deniedEnvironment = environment
    deniedEnvironment.add = { _ in nil }
    let denied = ShortcutRecorderView(environment: deniedEnvironment)
    var deniedErrors = 0
    denied.onError = { _ in deniedErrors += 1 }
    check(
      !denied.start() && !denied.isRecording && deniedErrors == 1,
      "monitor admission failure reports error and retires recording")
    exit(failures == 0 ? 0 : 1)
  }
}
