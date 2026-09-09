import AppKit
import PadCore

@MainActor struct ShortcutRecorderEnvironment {
  var prepare: (NSView) -> Bool
  var ownsFocus: (NSView) -> Bool
  var ownsEvent: (NSView, NSEvent) -> Bool
  var add: (@escaping (NSEvent) -> NSEvent?) -> Any?
  var remove: (Any) -> Void
  static var live: Self {
    Self(
      prepare: { view in
        guard let window = view.window, window.isKeyWindow else { return false }
        return window.makeFirstResponder(view)
      },
      ownsFocus: { view in view.window?.isKeyWindow == true && view.window?.firstResponder === view
      },
      ownsEvent: { view, event in
        guard let window = view.window else { return false }
        return event.window === window
          || (window.windowNumber > 0 && event.windowNumber == window.windowNumber)
      },
      add: { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
      remove: { NSEvent.removeMonitor($0) })
  }
}
@MainActor final class ShortcutRecorderView: NSView {
  var onCaptured: ((KeyboardShortcut) -> Void)?
  var onCancel: (() -> Void)?
  var onError: ((Error) -> Void)?
  private(set) var isRecording = false
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var recordingID: UUID?
  private let label = NSTextField(labelWithString: "Click to record shortcut")
  private let environment: ShortcutRecorderEnvironment
  init(environment: ShortcutRecorderEnvironment? = nil) {
    self.environment = environment ?? .live
    super.init(frame: .zero)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Record keyboard shortcut")
    setAccessibilityIdentifier("shortcuts.recorder")
  }
  override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 32) }
  override var acceptsFirstResponder: Bool { true }
  override func accessibilityPerformPress() -> Bool { start() }
  override func mouseDown(with event: NSEvent) { _ = start() }
  override func resignFirstResponder() -> Bool {
    cancel()
    return super.resignFirstResponder()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { cancel() }
    super.viewWillMove(toWindow: newWindow)
  }
  deinit {
    let cleanup = environment
    let previous = monitor
    let tokens = observers
    Task { @MainActor in
      if let previous { cleanup.remove(previous) }
      for observer in tokens { NotificationCenter.default.removeObserver(observer) }
    }
  }
  private func update(_ text: String) {
    label.stringValue = text
    setAccessibilityValue(text)
  }
  required init?(coder: NSCoder) { fatalError("Use init") }
  @discardableResult func start() -> Bool {
    guard !isRecording, environment.prepare(self), environment.ownsFocus(self) else { return false }
    isRecording = true
    let id = UUID()
    recordingID = id
    update("Press shortcut; Escape cancels")
    if let window {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.cancel() }
          })
      }
    }
    let added = environment.add { [weak self] event in
      guard let self, self.recordingID == id else { return event }
      return self.receive(event)
    }
    guard recordingID == id else {
      if let added { environment.remove(added) }
      return false
    }
    guard let added else {
      stop()
      onError?(NativeShortcutError.monitorUnavailable)
      return false
    }
    monitor = added
    return true
  }
  func stop() {
    isRecording = false
    recordingID = nil
    let previous = monitor
    monitor = nil
    let tokens = observers
    observers = []
    for token in tokens { NotificationCenter.default.removeObserver(token) }
    update("Click to record shortcut")
    if let previous { environment.remove(previous) }
  }
  private func cancel() {
    guard isRecording else { return }
    stop()
    onCancel?()
  }
  private func receive(_ event: NSEvent) -> NSEvent? {
    guard isRecording else { return event }
    guard environment.ownsFocus(self) else {
      cancel()
      return event
    }
    guard environment.ownsEvent(self, event) else { return event }
    if event.keyCode == 53 {
      cancel()
      return nil
    }
    if event.keyCode == 48 {
      cancel()
      return event
    }
    do {
      let shortcut = try NativeKeyboardShortcut.capture(event)
      stop()
      update(NativeKeyboardShortcut.display(shortcut))
      onCaptured?(shortcut)
    } catch { onError?(error) }
    return nil
  }
}
