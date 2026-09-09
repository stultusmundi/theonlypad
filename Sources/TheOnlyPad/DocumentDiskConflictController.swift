import AppKit

@MainActor private final class DiskConflictPanel: NSPanel {
  var onCancel: (() -> Void)?
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Presented only by an explicit owner action. Handlers must revalidate their captured context.
@MainActor final class DocumentDiskConflictController: NSWindowController, NSWindowDelegate {
  struct Action {
    let title: String
    let accessibilityID: String
    let handler: () -> Void
  }
  private var actions: [Action]
  private var actionButtons: [NSButton] = []
  private let closeButton = NSButton(title: "", target: nil, action: nil)
  private var consumed = false

  init(documentName: String, explanation: String, actions: [Action]) {
    self.actions = actions
    let panel = DiskConflictPanel(
      contentRect: NSRect(
        x: 0, y: 0, width: 520,
        height: max(220, 148 + 40 * (actions.count + 1))),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.isReleasedWhenClosed = false
    panel.title = NSLocalizedString("Resolve File Change", comment: "Disk conflict panel title")
    panel.delegate = self
    panel.onCancel = { [weak self] in self?.close() }
    let content = NSView()
    panel.contentView = content
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    let name = NSTextField(wrappingLabelWithString: documentName)
    name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    name.setAccessibilityIdentifier("document.diskConflictName")
    name.setAccessibilityLabel(documentName)
    stack.addArrangedSubview(name)
    let reason = NSTextField(wrappingLabelWithString: explanation)
    reason.setAccessibilityIdentifier("document.diskConflictExplanation")
    reason.setAccessibilityLabel(explanation)
    stack.addArrangedSubview(reason)
    for action in actions {
      let button = NSButton(title: action.title, target: self, action: #selector(invoke(_:)))
      button.bezelStyle = .rounded
      button.setAccessibilityIdentifier(action.accessibilityID)
      button.setAccessibilityLabel(action.title)
      actionButtons.append(button)
      stack.addArrangedSubview(button)
    }
    closeButton.title = NSLocalizedString("Close", comment: "Dismiss disk conflict panel")
    closeButton.bezelStyle = .rounded
    closeButton.target = self
    closeButton.action = #selector(closePanel(_:))
    closeButton.keyEquivalent = "\u{1b}"
    closeButton.setAccessibilityIdentifier("document.closeDiskConflict")
    closeButton.setAccessibilityLabel(closeButton.title)
    stack.addArrangedSubview(closeButton)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
      name.widthAnchor.constraint(equalTo: stack.widthAnchor),
      reason.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    panel.initialFirstResponder = closeButton
  }
  required init?(coder: NSCoder) { nil }

  private func consume() {
    consumed = true
    for button in actionButtons { button.isEnabled = false }
    closeButton.isEnabled = false
    actions.removeAll()
  }
  override func close() {
    guard !consumed else { return }
    consume()
    super.close()
  }
  override func showWindow(_ sender: Any?) {
    guard !consumed else { return }
    super.showWindow(sender)
  }
  func windowWillClose(_ notification: Notification) { consume() }
  @objc private func closePanel(_ sender: NSButton) { close() }
  @objc private func invoke(_ sender: NSButton) {
    guard !consumed, sender.isEnabled,
      let index = actionButtons.firstIndex(where: { $0 === sender }),
      actions.indices.contains(index)
    else { return }
    let handler = actions[index].handler
    close()
    handler()
  }
}
