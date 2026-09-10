import AppKit

/// One captured choice, consumed before callbacks. Owner validates all endpoint identities.
@MainActor final class DocumentMoveDestinationController: NSWindowController, NSWindowDelegate {
  private let choices: NativeDocumentMoveChoices
  private let onChoose: (NativeDocumentMoveTarget) -> Void
  private let onCancel: () -> Void
  private let destinations = NSPopUpButton()
  private var completed = false
  private let targets: [NativeDocumentMoveTarget]
  private let move = NSButton(title: "Move", target: nil, action: nil)
  init(
    choices: NativeDocumentMoveChoices,
    onChoose: @escaping (NativeDocumentMoveTarget) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.choices = choices
    targets = choices.destinations.map { .existing($0) } + [.newWindow]
    self.onChoose = onChoose
    self.onCancel = onCancel
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 190), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Move Document to Window"
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let explanation =
      "Choose a window. The document and its undo history move together. This action is not recorded in macros."
    let message = NSTextField(
      wrappingLabelWithString: explanation
        + (choices.newWindowRefusalReason.map { " New Window is unavailable: " + $0 } ?? ""))
    destinations.setAccessibilityIdentifier("document.move.destinations")
    destinations.setAccessibilityLabel("Destination window")
    destinations.menu?.autoenablesItems = false
    for destination in choices.destinations { destinations.addItem(withTitle: destination.title) }
    destinations.addItem(withTitle: "New Window")
    destinations.lastItem?.isEnabled = choices.newWindowRefusalReason == nil
    destinations.target = self
    destinations.action = #selector(selectionChanged)
    destinations.isEnabled = choices.newWindowRefusalReason == nil || !choices.destinations.isEmpty
    move.target = self
    move.action = #selector(confirm)
    move.setAccessibilityIdentifier("document.move.confirm")
    selectionChanged()
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
  @objc private func selectionChanged() {
    move.isEnabled = !completed && destinations.selectedItem?.isEnabled == true
  }
  @objc private func confirm() {
    guard !completed, targets.indices.contains(destinations.indexOfSelectedItem),
      destinations.selectedItem?.isEnabled == true
    else { return }
    let target = targets[destinations.indexOfSelectedItem]
    if target == .newWindow && choices.newWindowRefusalReason != nil { return }
    completed = true
    close()
    onChoose(target)
  }
  @objc private func cancelChoice() { close() }
  func windowWillClose(_ notification: Notification) {
    guard !completed else { return }
    completed = true
    onCancel()
  }
}
