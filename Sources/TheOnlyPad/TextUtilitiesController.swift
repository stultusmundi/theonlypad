import AppKit
import PadCore

@MainActor
final class TextUtilitiesController: NSWindowController, NSWindowDelegate {
  private let input: String
  private let onReplace: (String) -> Void
  private let pasteboard: NSPasteboard
  private let operation = NSPopUpButton()
  private let output = NSTextView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let copyButton = NSButton(
    title: String(localized: "Copy Output"), target: nil, action: nil)
  private let replaceButton = NSButton(
    title: String(localized: "Replace"), target: nil, action: nil)
  private var result: String?
  private var resultOperation: TextUtilityOperation?
  private var generation = 0
  private var job: Task<String, Error>?
  private var closed = false

  init(text: String, pasteboard: NSPasteboard = .general, onReplace: @escaping (String) -> Void) {
    self.input = text
    self.onReplace = onReplace
    self.pasteboard = pasteboard
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = String(localized: "Text Utilities")
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 480, height: 350)
    buildContent()
    panel.initialFirstResponder = operation
    panel.center()
    refreshPreview()
  }
  required init?(coder: NSCoder) { nil }

  override func showWindow(_ sender: Any?) {
    if closed {
      closed = false
      refreshPreview()
    }
    super.showWindow(sender)
  }
  func windowWillClose(_ notification: Notification) {
    closed = true
    generation += 1
    job?.cancel()
    job = nil
    result = nil
    copyButton.isEnabled = false
    replaceButton.isEnabled = false
  }
  private func buildContent() {
    guard let content = window?.contentView else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
    let explanation = NSTextField(
      wrappingLabelWithString: String(
        localized:
          "Preview uses the text captured when this panel opened. Replace applies only after you choose it. Checksums are copy-only."
      ))
    stack.addArrangedSubview(explanation)
    explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    operation.addItems(withTitles: TextUtilityOperation.allCases.map(\.title))
    operation.setAccessibilityLabel(String(localized: "Text operation"))
    operation.target = self
    operation.action = #selector(refreshPreview)
    stack.addArrangedSubview(operation)
    output.isEditable = false
    output.isSelectable = true
    output.isRichText = false
    output.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    output.setAccessibilityLabel(String(localized: "Converted output preview"))
    output.textContainerInset = NSSize(width: 8, height: 8)
    output.isVerticallyResizable = true
    output.autoresizingMask = [.width]
    output.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.documentView = output
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    status.textColor = .secondaryLabelColor
    status.setAccessibilityLabel(String(localized: "Conversion status"))
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let buttons = NSStackView(views: [copyButton, replaceButton])
    buttons.spacing = 10
    stack.addArrangedSubview(buttons)
    copyButton.target = self
    copyButton.action = #selector(copyOutput)
    replaceButton.target = self
    replaceButton.action = #selector(replace)
  }
  private var selectedOperation: TextUtilityOperation {
    TextUtilityOperation.allCases[max(0, operation.indexOfSelectedItem)]
  }

  @objc private func refreshPreview() {
    job?.cancel()
    generation += 1
    let revision = generation
    let selection = selectedOperation
    let source = input
    result = nil
    resultOperation = nil
    copyButton.isEnabled = false
    replaceButton.isEnabled = false
    output.string = ""
    status.stringValue = String(localized: "Converting captured text…")
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let result = try TextUtilities.process(source, operation: selection)
      try Task.checkCancellation()
      return result
    }
    job = worker
    Task { [weak self] in
      do {
        let converted = try await worker.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.result = converted
        self.resultOperation = selection
        self.output.string = converted
        self.copyButton.isEnabled = true
        self.replaceButton.isEnabled = selection.allowsReplacement
        self.status.stringValue =
          selection.allowsReplacement
          ? String(localized: "Preview ready. Copy it or replace the captured editor text.")
          : String(
            localized: "SHA-256 checksum ready. Copy Output is available; replacement is disabled.")
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.status.stringValue = error.localizedDescription
      }
    }
  }
  @objc private func copyOutput() {
    guard !closed, resultOperation == selectedOperation, let result else { return }
    pasteboard.clearContents()
    pasteboard.setString(result, forType: .string)
    status.stringValue = String(localized: "Output copied.")
  }
  @objc private func replace() {
    guard !closed, resultOperation == selectedOperation, selectedOperation.allowsReplacement,
      let result
    else { return }
    onReplace(result)
  }
}
