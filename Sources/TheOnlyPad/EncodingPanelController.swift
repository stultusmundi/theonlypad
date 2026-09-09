import AppKit
import PadCore

@MainActor
final class EncodingPanelController: NSWindowController, NSWindowDelegate {
  private let encoding = NSPopUpButton(frame: .zero, pullsDown: false)
  private let bom = NSButton(
    checkboxWithTitle: "Include a byte-order mark (BOM) when saving", target: nil, action: nil)
  private let ending = NSPopUpButton(frame: .zero, pullsDown: false)
  private var endingWasChanged = false
  private let onConvert: (DocumentEncoding, Bool) -> Void
  private let onReopen: (DocumentEncoding) -> Void
  private let onLineEnding: (LineEnding) -> Void
  private static let encodings: [(DocumentEncoding, String)] = [
    (.utf8, "UTF-8"), (.utf16LE, "UTF-16 Little Endian"), (.utf16BE, "UTF-16 Big Endian"),
    (.windows1252, "Windows-1252"), (.latin1, "ISO-8859-1 (Latin-1)"),
  ]

  init(
    current: DecodedDocument,
    onConvert: @escaping (DocumentEncoding, Bool) -> Void,
    onReopen: @escaping (DocumentEncoding) -> Void,
    onLineEnding: @escaping (LineEnding) -> Void
  ) {
    self.onConvert = onConvert
    self.onReopen = onReopen
    self.onLineEnding = onLineEnding
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 410),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Encoding and Line Endings"
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    panel.contentView = content
    let explanation = NSTextField(
      wrappingLabelWithString:
        "Convert keeps the current text and changes how it will be saved. Reopen reads the file's existing bytes using the selected encoding; unsaved edits require confirmation. Characters that cannot be encoded must be resolved before conversion."
    )
    explanation.setAccessibilityLabel("Encoding action explanation")
    content.addArrangedSubview(explanation)
    content.addArrangedSubview(NSTextField(labelWithString: "Text encoding"))
    encoding.addItems(withTitles: Self.encodings.map(\.1))
    encoding.selectItem(at: Self.encodings.firstIndex { $0.0 == current.encoding } ?? 0)
    encoding.target = self
    encoding.action = #selector(encodingChanged)
    encoding.setAccessibilityLabel("Text encoding")
    content.addArrangedSubview(encoding)
    bom.state = current.hasBOM ? .on : .off
    bom.setAccessibilityLabel("Include byte-order mark")
    content.addArrangedSubview(bom)
    let encodingActions = NSStackView(views: [
      button("Convert Encoding", #selector(convertEncoding)),
      button("Reopen with Encoding", #selector(reopenEncoding)),
    ])
    encodingActions.spacing = 10
    content.addArrangedSubview(encodingActions)
    let detectedLabel = NSTextField(labelWithString: "Checking current line endings…")
    content.addArrangedSubview(detectedLabel)
    ending.addItems(withTitles: LineEnding.allCases.map(\.label))
    ending.target = self
    ending.action = #selector(endingChanged)
    Task { [weak self] in
      let detected = await Task.detached(priority: .utility) {
        LineEndings.detect(in: current.text)
      }.value
      guard let self else { return }
      switch detected {
      case .none: detectedLabel.stringValue = "Current line endings: none"
      case .mixed: detectedLabel.stringValue = "Current line endings: mixed"
      case .uniform(let value):
        detectedLabel.stringValue = "Current line endings: " + value.label
        if !self.endingWasChanged, let index = LineEnding.allCases.firstIndex(of: value) {
          self.ending.selectItem(at: index)
        }
      }
    }
    ending.setAccessibilityLabel("Target line ending")
    let endingActions = NSStackView(views: [
      ending, button("Convert Line Endings", #selector(convertLineEndings)),
    ])
    endingActions.spacing = 10
    content.addArrangedSubview(endingActions)
    let cancel = button("Cancel", #selector(cancelPanel))
    cancel.keyEquivalent = "\u{1B}"
    content.addArrangedSubview(cancel)
    for view in [explanation, encoding] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
    }
    encodingChanged()
    panel.center()
  }

  required init?(coder: NSCoder) { nil }

  func present(for parent: NSWindow) {
    guard let window else { return }
    parent.beginSheet(window)
  }

  private func button(_ title: String, _ selector: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: selector)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(title)
    return button
  }

  private var selectedEncoding: DocumentEncoding {
    Self.encodings[max(0, encoding.indexOfSelectedItem)].0
  }

  @objc private func encodingChanged() {
    bom.isEnabled = [.utf8, .utf16LE, .utf16BE].contains(selectedEncoding)
    if !bom.isEnabled { bom.state = .off }
  }

  @objc private func endingChanged() { endingWasChanged = true }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    dismiss()
    return false
  }

  private func dismiss() {
    if let window, let parent = window.sheetParent { parent.endSheet(window) }
    close()
  }

  @objc private func convertEncoding() {
    let selected = selectedEncoding
    let marker = bom.isEnabled && bom.state == .on
    dismiss()
    onConvert(selected, marker)
  }

  @objc private func reopenEncoding() {
    let selected = selectedEncoding
    dismiss()
    onReopen(selected)
  }

  @objc private func convertLineEndings() {
    let selected = LineEnding.allCases[max(0, ending.indexOfSelectedItem)]
    dismiss()
    onLineEnding(selected)
  }

  @objc private func cancelPanel() { dismiss() }
}
