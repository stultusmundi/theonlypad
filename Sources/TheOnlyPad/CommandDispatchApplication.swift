import AppKit

@MainActor final class KeyboardDispatchContext {
  private(set) var event: NSEvent?

  func withEvent<T>(_ event: NSEvent, perform: () throws -> T) rethrows -> T {
    let previous = self.event
    self.event = event.type == .keyDown ? event : nil
    defer { self.event = previous }
    return try perform()
  }
}

@objc(PadCommandApplication)
final class CommandDispatchApplication: NSApplication {
  private let keyboardDispatchContext = KeyboardDispatchContext()
  var keyboardDispatchEvent: NSEvent? { keyboardDispatchContext.event }

  override func sendEvent(_ event: NSEvent) {
    keyboardDispatchContext.withEvent(event) { super.sendEvent(event) }
  }
}
