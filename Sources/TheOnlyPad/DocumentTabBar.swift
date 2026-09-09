import AppKit
import PadCore

@MainActor
private final class DraggableTabButton: NSButton {
  var beginDrag: ((NSEvent) -> Void)?
  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window else { return }
    let start = event.locationInWindow
    highlight(true)
    defer { highlight(false) }
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if next.type == .leftMouseUp {
        if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
        return
      }
      let point = next.locationInWindow
      if hypot(point.x - start.x, point.y - start.y) >= 4 {
        highlight(false)
        beginDrag?(next)
        return
      }
    }
  }
}

@MainActor
private final class TabCanvas: NSView { override var isFlipped: Bool { true } }

/// Presentation and callback routing only. The owner confirms dirty closes and
/// updates model order; the strip never saves, closes or edits document content.
@MainActor
final class DocumentTabBar: NSView, NSDraggingSource {
  var onSelect: ((UUID) -> Void)?
  var onClose: ((UUID) -> Void)?
  var onPin: ((UUID) -> Void)?
  var onMove: ((UUID, Int) -> Void)?
  var onCloseOthers: ((UUID) -> Void)?
  var onCloseRight: ((UUID) -> Void)?

  private static let pasteboardType = NSPasteboard.PasteboardType(
    AppIdentity.bundleIdentifier + ".document-tab")
  private let scroll = NSScrollView()
  private let canvas = TabCanvas()
  private let insertionMark = NSView()
  private var items: [TabItem] = []
  private var selectedID: UUID?
  private var buttons: [DraggableTabButton] = []
  private var closeButtons: [NSButton] = []
  private var widths: [CGFloat] = []
  private var dropTarget: Int?

  override init(frame: NSRect = .zero) {
    super.init(frame: frame)
    scroll.documentView = canvas
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    addSubview(scroll)
    setAccessibilityLabel("Document tabs")
    scroll.setAccessibilityLabel("Scrollable document tabs")
    insertionMark.wantsLayer = true
    insertionMark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    insertionMark.isHidden = true
    canvas.addSubview(insertionMark)
    registerForDraggedTypes([Self.pasteboardType])
  }
  required init?(coder: NSCoder) { nil }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

  /// Document IDs must be unique. Root editor owns canonical pinned-first order.
  func update(items: [TabItem], selectedID: UUID?) {
    precondition(Set(items.map(\.id)).count == items.count, "Tab identities must be unique")
    guard self.items != items || self.selectedID != selectedID else { return }
    let selectionChanged = self.selectedID != selectedID
    self.items = items
    self.selectedID = selectedID
    for button in buttons { button.removeFromSuperview() }
    for button in closeButtons { button.removeFromSuperview() }
    buttons = []
    closeButtons = []
    widths = []
    for (index, item) in items.enumerated() {
      let title = (item.pinned ? "📌 " : "") + (item.dirty ? "● " : "") + item.title
      let button = DraggableTabButton(title: title, target: self, action: #selector(selectTab(_:)))
      button.identifier = .init("tab.select." + item.id.uuidString)
      button.setAccessibilityIdentifier("tab.select." + item.id.uuidString)
      button.setButtonType(.toggle)
      button.bezelStyle = .rounded
      button.state = item.id == selectedID ? .on : .off
      button.font = .systemFont(ofSize: 12)
      button.lineBreakMode = .byTruncatingTail
      button.toolTip = item.title
      button.setAccessibilityLabel(
        item.title + (item.pinned ? ", pinned" : "") + (item.dirty ? ", unsaved changes" : "")
          + (item.id == selectedID ? ", selected" : ""))
      button.menu = contextMenu(for: index)
      button.beginDrag = { [weak self, weak button] event in
        guard let self, let button else { return }
        self.beginDragging(item.id, button: button, event: event)
      }
      let close = NSButton(title: "×", target: self, action: #selector(closeTab(_:)))
      close.identifier = .init("tab.close." + item.id.uuidString)
      close.setAccessibilityIdentifier("tab.close." + item.id.uuidString)
      close.isBordered = false
      close.toolTip = "Close " + item.title
      close.setAccessibilityLabel("Close " + item.title + (item.dirty ? ", unsaved changes" : ""))
      canvas.addSubview(button)
      canvas.addSubview(close)
      buttons.append(button)
      closeButtons.append(close)
      let measured = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
      ).width
      widths.append(min(240, max(110, measured + 32)) + 26)
    }
    canvas.addSubview(insertionMark, positioned: .above, relativeTo: nil)
    needsLayout = true
    layoutSubtreeIfNeeded()
    if selectionChanged, let index = items.firstIndex(where: { $0.id == selectedID }) {
      _ = canvas.scrollToVisible(buttons[index].frame.union(closeButtons[index].frame))
    }
  }

  override func layout() {
    super.layout()
    scroll.frame = bounds
    let width = widths.reduce(0, +)
    canvas.frame = NSRect(
      x: 0, y: 0, width: max(scroll.contentSize.width, width),
      height: max(36, scroll.contentSize.height))
    var x: CGFloat = 0
    for index in items.indices {
      buttons[index].frame = NSRect(x: x + 2, y: 3, width: widths[index] - 28, height: 30)
      closeButtons[index].frame = NSRect(x: x + widths[index] - 26, y: 5, width: 24, height: 26)
      x += widths[index]
    }
  }

  private func id(from sender: NSControl) -> UUID? {
    guard let text = sender.identifier?.rawValue.split(separator: ".").last else { return nil }
    return UUID(uuidString: String(text))
  }
  @objc private func selectTab(_ sender: NSButton) {
    guard let id = id(from: sender) else { return }
    // NSButton toggles before sending its action; model selection remains authoritative.
    sender.state = id == selectedID ? .on : .off
    onSelect?(id)
  }
  @objc private func closeTab(_ sender: NSButton) { if let id = id(from: sender) { onClose?(id) } }

  private func contextMenu(for index: Int) -> NSMenu {
    let item = items[index]
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ title: String, action: Selector, enabled: Bool = true) {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      entry.representedObject = item.id.uuidString
      entry.isEnabled = enabled
      menu.addItem(entry)
    }
    add(item.pinned ? "Unpin Tab" : "Pin Tab", action: #selector(pinTab(_:)))
    add("Close Tab", action: #selector(closeContext(_:)))
    add("Close Other Tabs", action: #selector(closeOthers(_:)), enabled: items.count > 1)
    add(
      "Close Tabs to the Right", action: #selector(closeRight(_:)), enabled: index < items.count - 1
    )
    menu.addItem(.separator())
    add(
      "Move Left", action: #selector(moveTabLeft(_:)),
      enabled: index > 0 && items[index - 1].pinned == item.pinned)
    add(
      "Move Right", action: #selector(moveTabRight(_:)),
      enabled: index + 1 < items.count && items[index + 1].pinned == item.pinned)
    return menu
  }
  private func contextID(_ sender: NSMenuItem) -> UUID? {
    guard let value = sender.representedObject as? String, let id = UUID(uuidString: value),
      items.contains(where: { $0.id == id })
    else { return nil }
    return id
  }
  @objc private func pinTab(_ sender: NSMenuItem) { if let id = contextID(sender) { onPin?(id) } }
  @objc private func closeContext(_ sender: NSMenuItem) {
    if let id = contextID(sender) { onClose?(id) }
  }
  @objc private func closeOthers(_ sender: NSMenuItem) {
    if let id = contextID(sender) { onCloseOthers?(id) }
  }
  @objc private func closeRight(_ sender: NSMenuItem) {
    if let id = contextID(sender) { onCloseRight?(id) }
  }
  @objc private func moveTabLeft(_ sender: NSMenuItem) { moveContext(sender, delta: -1) }
  @objc private func moveTabRight(_ sender: NSMenuItem) { moveContext(sender, delta: 1) }
  private func moveContext(_ sender: NSMenuItem, delta: Int) {
    guard let id = contextID(sender), let index = items.firstIndex(where: { $0.id == id }),
      items.indices.contains(index + delta), items[index + delta].pinned == items[index].pinned
    else { return }
    onMove?(id, index + delta)
  }

  private func beginDragging(_ id: UUID, button: NSView, event: NSEvent) {
    guard items.contains(where: { $0.id == id }) else { return }
    let payload = NSPasteboardItem()
    payload.setString(id.uuidString, forType: Self.pasteboardType)
    let draggingItem = NSDraggingItem(pasteboardWriter: payload)
    let image = NSImage(size: button.bounds.size)
    if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
      button.cacheDisplay(in: button.bounds, to: bitmap)
      image.addRepresentation(bitmap)
    }
    draggingItem.setDraggingFrame(button.bounds, contents: image)
    let session = button.beginDraggingSession(with: [draggingItem], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    insertionMark.isHidden = true
    dropTarget = nil
  }
  private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
    guard let source = sender.draggingSource as? DocumentTabBar, source === self,
      let value = sender.draggingPasteboard.string(forType: Self.pasteboardType),
      let id = UUID(uuidString: value), items.contains(where: { $0.id == id })
    else { return nil }
    return id
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let id = draggedID(sender), let source = items.firstIndex(where: { $0.id == id }) else {
      return []
    }
    let x = canvas.convert(sender.draggingLocation, from: nil).x
    var insertion = items.count
    for index in items.indices where x < buttons[index].frame.midX {
      insertion = index
      break
    }
    let target = insertion > source ? insertion - 1 : insertion
    let group = items.indices.filter { items[$0].pinned == items[source].pinned }
    guard let first = group.first, let last = group.last else { return [] }
    let clamped = min(last, max(first, target))
    dropTarget = clamped
    let boundary = clamped > source ? clamped + 1 : clamped
    let markX = widths.prefix(boundary).reduce(0, +)
    insertionMark.frame = NSRect(x: markX, y: 2, width: 2, height: 32)
    insertionMark.isHidden = false
    return .move
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    insertionMark.isHidden = true
    dropTarget = nil
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer {
      insertionMark.isHidden = true
      dropTarget = nil
    }
    guard let id = draggedID(sender), let target = dropTarget,
      let source = items.firstIndex(where: { $0.id == id }), items.indices.contains(target)
    else { return false }
    if source != target { onMove?(id, target) }
    return true
  }
}
