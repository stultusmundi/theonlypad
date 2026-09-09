import AppKit
import PadCore

private actor MarkdownPreviewWorker {
  static let shared = MarkdownPreviewWorker()
  func parse(_ text: String) throws -> [MarkdownPreviewBlock] {
    try MarkdownPreview.parse(text, isCancelled: { Task.isCancelled })
  }
}

@MainActor
final class MarkdownPreviewController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  private let output = NSTextView()
  private let status = NSTextField(wrappingLabelWithString: "Rendering snapshot…")
  private var job: Task<[MarkdownPreviewBlock], Error>?
  private var generation = 0
  private var closed = false

  init(text: String) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = String(localized: "Markdown Preview")
    window.isReleasedWhenClosed = false
    window.delegate = self
    output.isEditable = false
    output.isSelectable = true
    output.isAutomaticLinkDetectionEnabled = false
    output.isRichText = true
    output.textContainerInset = NSSize(width: 18, height: 16)
    output.isVerticallyResizable = true
    output.autoresizingMask = [.width]
    output.textContainer?.widthTracksTextView = true
    output.setAccessibilityLabel(String(localized: "Markdown snapshot preview"))
    let scroll = NSScrollView()
    scroll.documentView = output
    scroll.hasVerticalScroller = true
    let disclosure = NSTextField(
      wrappingLabelWithString: String(
        localized:
          "Snapshot preview: headings, lists, emphasis and code. HTML, image and link markup stays literal and inactive; nothing is fetched. Long lines stay literal. Reopen Preview to update."
      ))
    let stack = NSStackView(views: [disclosure, scroll, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    window.contentView = stack
    for view in [disclosure, scroll, status] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    window.minSize = NSSize(width: 400, height: 320)
    window.center()
    generation += 1
    let request = generation
    let work = Task.detached(priority: .userInitiated) {
      try await MarkdownPreviewWorker.shared.parse(text)
    }
    job = work
    Task { [weak self] in
      do {
        let blocks = try await work.value
        guard let self, !self.closed, self.generation == request else { return }
        self.render(blocks)
        self.status.stringValue = String(
          localized: "Read-only snapshot • No active links or external resources")
        self.job = nil
      } catch {
        guard let self, !self.closed, self.generation == request else { return }
        self.status.stringValue = error.localizedDescription
        self.job = nil
      }
    }
  }
  required init?(coder: NSCoder) { nil }

  func windowWillClose(_ notification: Notification) {
    closed = true
    generation += 1
    job?.cancel()
    job = nil
    onClose?()
  }

  private func render(_ blocks: [MarkdownPreviewBlock]) {
    let result = NSMutableAttributedString(string: "")
    let base = NSFont.systemFont(ofSize: 14)
    let code = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    for block in blocks {
      let paragraph = NSMutableParagraphStyle()
      paragraph.paragraphSpacing = 7
      if block.kind == .list { paragraph.headIndent = 18 }
      var blockFont = base
      if case .heading(let level) = block.kind {
        blockFont = .systemFont(ofSize: CGFloat(29 - level * 2), weight: .bold)
        paragraph.paragraphSpacingBefore = 9
      }
      for run in block.runs {
        var font = run.code ? code : blockFont
        if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        if run.code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
        // Only this explicit allowlist reaches NSTextView. Never .link or .attachment.
        result.append(NSAttributedString(string: run.text, attributes: attributes))
      }
      result.append(
        NSAttributedString(
          string: "\n", attributes: [.font: blockFont, .paragraphStyle: paragraph]))
    }
    output.textStorage?.setAttributedString(result)
  }
}
