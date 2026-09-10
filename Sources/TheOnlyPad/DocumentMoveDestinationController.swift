import AppKit

/// One captured choice, consumed before callbacks. Owner validates all endpoint identities.
@MainActor final class DocumentMoveDestinationController: NSWindowController, NSWindowDelegate {
  private let choices: NativeDocumentMoveChoices
  private let onChoose: (NativeDocumentMoveDestination) -> Void
  private let onCancel: () -> Void
  private let destinations = NSPopUpButton()
  private var completed = false
  init(
    choices: NativeDocumentMoveChoices,
    onChoose: @escaping (NativeDocumentMoveDestination) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.choices = choices
    self.onChoose = onChoose
    self.onCancel = onCancel
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 190), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Move Document to Window"
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let message = NSTextField(
      wrappingLabelWithString: choices.destinations.isEmpty
        ? "Open another window, then choose Move Document to Window again."
        : "Choose an existing window. The document and its undo history move together. This action is not recorded in macros."
    )
    destinations.setAccessibilityIdentifier("document.move.destinations")
    destinations.setAccessibilityLabel("Destination window")
    for destination in choices.destinations { destinations.addItem(withTitle: destination.title) }
    destinations.isEnabled = !choices.destinations.isEmpty
    let move = NSButton(title: "Move", target: self, action: #selector(confirm))
    move.setAccessibilityIdentifier("document.move.confirm")
    move.isEnabled = !choices.destinations.isEmpty
    let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelChoice))
    cancel.setAccessibilityIdentifier("document.move.cancel")
    cancel.keyEquivalent = "\u{1b}"
    let buttons = NSStackView(views: [cancel, move])
    buttons.orientation = .horizontal
    let stack = NSStackView(views: [message, destinations, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20),
      destinations.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func confirm() {
    guard !completed, choices.destinations.indices.contains(destinations.indexOfSelectedItem) else {
      return
    }
    let destination = choices.destinations[destinations.indexOfSelectedItem]
    completed = true
    close()
    onChoose(destination)
  }
  @objc private func cancelChoice() { close() }
  func windowWillClose(_ notification: Notification) {
    guard !completed else { return }
    completed = true
    onCancel()
  }
}
