import AppKit

@MainActor private final class DiskConflictPanel: NSPanel {
  var onCancel: (() -> Void)?
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Presented only by an explicit owner action. Handlers must revalidate their captured context.
@MainActor final class DocumentDiskConflictController: NSWindowController, NSWindowDelegate {
  enum ActionRole: Equatable { case capturedContext, monitorControl }
  struct Action {
    let title: String
    let accessibilityID: String
    let role: ActionRole
    var handler: (() -> Void)?
    init(
      title: String, accessibilityID: String, role: ActionRole = .capturedContext,
      handler: @escaping () -> Void
    ) {
      self.title = title
      self.accessibilityID = accessibilityID
      self.role = role
      self.handler = handler
    }
  }
  private var actions: [Action]
  private var actionButtons: [NSButton] = []
  private let closeButton = NSButton(title: "", target: nil, action: nil)
  private var consumed = false
  private var stale = false
  private var explanationLabel: NSTextField?

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
    explanationLabel = reason
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

  /// Retire captured file credentials without replacing this panel or its monitor controls.
  func markStale() {
    guard !consumed, !stale else { return }
    stale = true
    let previousActions = actions
    // Keep old captures alive until no mutation remains; releasing them can also call out.
    defer { withExtendedLifetime(previousActions) {} }
    let contextIndices = previousActions.indices.filter {
      previousActions[$0].role == .capturedContext
    }
    let buttonsToDisable = contextIndices.map { actionButtons[$0] }
    for index in contextIndices { actions[index].handler = nil }
    // AppKit setters can call out. All records are already revoked before touching controls.
    for button in buttonsToDisable { button.isEnabled = false }
    guard !consumed else { return }
    let explanation = NSLocalizedString(
      "The file status changed. No file action was applied. Use Check Again, then close and reopen Resolve for current actions.",
      comment: "Disk conflict panel whose captured file status changed")
    explanationLabel?.stringValue = explanation
    explanationLabel?.setAccessibilityLabel(explanation)
  }

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
    guard let handler = actions[index].handler else { return }
    close()
    handler()
  }
}
