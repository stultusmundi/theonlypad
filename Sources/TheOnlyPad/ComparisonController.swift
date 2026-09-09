import AppKit
import PadCore

@MainActor
final class ComparisonController: NSWindowController, NSWindowDelegate {
  private let leftText: String
  private let leftName: String
  private let leftView = NSTextView()
  private let rightView = NSTextView()
  private let leftScroll = NSScrollView()
  private let rightScroll = NSScrollView()
  private let rightLabel = NSTextField(labelWithString: "Choose a right-hand file or paste text")
  private let status = NSTextField(
    wrappingLabelWithString: "Read-only comparison snapshot. Source documents are never changed.")
  private let previous = NSButton(title: "Previous Difference", target: nil, action: nil)
  private let next = NSButton(title: "Next Difference", target: nil, action: nil)
  private var generation = 0
  private var closed = false
  private var synchronizing = false
  private struct PreparedComparison: Sendable {
    let result: TextComparisonResult
    let left: [String]
    let right: [String]
  }
  private var worker: Task<PreparedComparison, Error>?
  private var comparison: TextComparisonResult?
  private var leftRanges: [NSRange] = [], rightRanges: [NSRange] = []
  private var differenceIndex = -1

  init(leftText: String, leftName: String) {
    self.leftText = leftText
    self.leftName = leftName
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = String(localized: "Read-only Comparison")
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 650, height: 360)
    buildContent()
    panel.center()
  }
  required init?(coder: NSCoder) { nil }
  deinit { NotificationCenter.default.removeObserver(self) }

  func windowWillClose(_ notification: Notification) {
    closed = true
    generation += 1
    worker?.cancel()
    worker = nil
    comparison = nil
    previous.isEnabled = false
    next.isEnabled = false
  }
  override func showWindow(_ sender: Any?) {
    closed = false
    super.showWindow(sender)
  }
  private func buildContent() {
    guard let content = window?.contentView else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    let choose = NSButton(title: "Choose Right File…", target: self, action: #selector(chooseFile))
    let paste = NSButton(title: "Paste Right Text", target: self, action: #selector(pasteText))
    previous.target = self
    previous.action = #selector(previousDifference)
    next.target = self
    next.action = #selector(nextDifference)
    previous.isEnabled = false
    next.isEnabled = false
    let controls = NSStackView(views: [choose, paste, previous, next])
    stack.addArrangedSubview(controls)
    let leftLabel = NSTextField(labelWithString: leftName + " — captured snapshot")
    leftLabel.lineBreakMode = .byTruncatingMiddle
    rightLabel.lineBreakMode = .byTruncatingMiddle
    let columns = NSStackView()
    columns.distribution = .fillEqually
    columns.spacing = 10
    for (label, scroll, view, accessibility) in [
      (leftLabel, leftScroll, leftView, "Left comparison snapshot"),
      (rightLabel, rightScroll, rightView, "Right comparison snapshot"),
    ] {
      let column = NSStackView(views: [label, scroll])
      column.orientation = .vertical
      column.alignment = .leading
      label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.borderType = .bezelBorder
      view.isEditable = false
      view.isSelectable = true
      view.isRichText = false
      view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      view.isHorizontallyResizable = true
      view.isVerticallyResizable = true
      view.minSize = NSSize(width: 0, height: 0)
      view.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      view.textContainer?.containerSize = view.maxSize
      view.textContainer?.widthTracksTextView = false
      view.textContainerInset = NSSize(width: 6, height: 6)
      view.setAccessibilityLabel(accessibility)
      scroll.documentView = view
      scroll.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
        object: scroll.contentView)
      columns.addArrangedSubview(column)
    }
    stack.addArrangedSubview(columns)
    columns.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    let legend = NSTextField(
      wrappingLabelWithString:
        "Read-only aligned rows • Yellow = changed • ∅ = alignment blank • Endings: ⏎LF / ⏎CRLF / ⏎CR / ⏎EOF. Tabs and control characters are escaped for display; sources remain exact."
    )
    stack.addArrangedSubview(legend)
    legend.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }
  @objc private func chooseFile() {
    let picker = NSOpenPanel()
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    guard picker.runModal() == .OK, let url = picker.url else { return }
    openRightFile(url)
  }
  @objc private func pasteText() {
    guard let text = NSPasteboard.general.string(forType: .string) else {
      status.stringValue = "The clipboard does not contain text."
      return
    }
    compare(rightText: text, rightName: "Pasted text")
  }
  func openRightFile(_ url: URL) {
    start(rightName: url.lastPathComponent) {
      try TextComparison.readFile(url, isCancelled: { Task.isCancelled })
    }
  }
  func compare(rightText: String, rightName: String) {
    start(rightName: rightName) { rightText }
  }
  private func start(rightName: String, load: @escaping @Sendable () throws -> String) {
    guard !closed else { return }
    generation += 1
    let revision = generation
    worker?.cancel()
    comparison = nil
    leftRanges = []
    rightRanges = []
    leftView.string = ""
    rightView.string = ""
    previous.isEnabled = false
    next.isEnabled = false
    rightLabel.stringValue = rightName + " — captured snapshot"
    status.stringValue = "Comparing snapshots…"
    let left = leftText
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let right = try load()
      let result = try TextComparison.compare(
        left: left, right: right, isCancelled: { Task.isCancelled })
      return try PreparedComparison(
        result: result, left: Self.displayRows(result, left: true),
        right: Self.displayRows(result, left: false))
    }
    worker = task
    Task { [weak self] in
      do {
        let result = try await task.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.worker = nil
        self.comparison = result.result
        self.render(result)
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.worker = nil
        self.status.stringValue = error.localizedDescription
      }
    }
  }
  enum DisplayError: Error, LocalizedError {
    case limit
    var errorDescription: String? {
      "Comparison display accepts at most 16,000 UTF-16 units per displayed row and 2 million per pane, including visible control-character escapes. Compare smaller excerpts or shorter lines."
    }
  }
  nonisolated static func displayRows(_ result: TextComparisonResult, left: Bool) throws -> [String]
  {
    var rows: [String] = []
    var lineNumber = 0
    var total = 0
    for row in result.rows {
      try Task.checkCancellation()
      let source = left ? row.left : row.right
      var value = "   ∅  \n"
      if let source {
        lineNumber += 1
        var body = source
        let marker: String
        if body.hasSuffix("\r\n") {
          body.removeLast()
          marker = "CRLF"
        } else if body.hasSuffix("\n") {
          body.removeLast()
          marker = "LF"
        } else if body.hasSuffix("\r") {
          body.removeLast()
          marker = "CR"
        } else {
          marker = "EOF"
        }
        value = String(format: "%4d  ", lineNumber)
        var units = value.utf16.count
        for scalar in body.unicodeScalars {
          if units.isMultiple(of: 4096) { try Task.checkCancellation() }
          let fragment: String
          if scalar == "\t" {
            fragment = "\\t"
          } else if scalar.value < 32 || (127...159).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
          {
            fragment = "\\u{" + String(scalar.value, radix: 16) + "}"
          } else {
            fragment = String(scalar)
          }
          units += fragment.utf16.count
          guard units <= 16_000 else { throw DisplayError.limit }
          value += fragment
        }
        value += " ⏎" + marker + "\n"
      }
      let count = value.utf16.count
      guard count <= 16_000, count <= 2_000_000 - total else { throw DisplayError.limit }
      total += count
      rows.append(value)
    }
    return rows
  }
  private func render(_ prepared: PreparedComparison) {
    let result = prepared.result
    let changed = Set(result.differenceRows)
    func fill(_ view: NSTextView, values: [String]) -> [NSRange] {
      let display = NSMutableAttributedString(string: "")
      var ranges: [NSRange] = []
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = 18
      paragraph.maximumLineHeight = 18
      for (index, value) in values.enumerated() {
        ranges.append(NSRange(location: display.length, length: value.utf16.count))
        display.append(
          NSAttributedString(
            string: value,
            attributes: [
              .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
              .foregroundColor: NSColor.textColor,
              .backgroundColor: changed.contains(index)
                ? NSColor.systemYellow.withAlphaComponent(0.25) : NSColor.textBackgroundColor,
              .paragraphStyle: paragraph,
            ]))
      }
      view.textStorage?.setAttributedString(display)
      view.sizeToFit()
      return ranges
    }
    synchronizing = true
    leftRanges = fill(leftView, values: prepared.left)
    rightRanges = fill(rightView, values: prepared.right)
    leftScroll.contentView.scroll(to: .zero)
    rightScroll.contentView.scroll(to: .zero)
    synchronizing = false
    differenceIndex = -1
    previous.isEnabled = !result.differenceRows.isEmpty
    next.isEnabled = !result.differenceRows.isEmpty
    status.stringValue =
      result.differenceRows.isEmpty
      ? "Snapshots are exactly equal."
      : "\(result.differenceRows.count) changed aligned rows. Read-only snapshots."
  }
  @objc private func scrolled(_ notification: Notification) {
    guard !synchronizing, let source = notification.object as? NSClipView else { return }
    let target = source === leftScroll.contentView ? rightScroll : leftScroll
    synchronizing = true
    target.contentView.scroll(
      to: NSPoint(x: target.contentView.bounds.origin.x, y: source.bounds.origin.y))
    target.reflectScrolledClipView(target.contentView)
    synchronizing = false
  }
  @objc private func nextDifference() { navigate(forward: true) }
  @objc private func previousDifference() { navigate(forward: false) }
  private func navigate(forward: Bool) {
    guard !closed, let comparison, !comparison.differenceRows.isEmpty else { return }
    let count = comparison.differenceRows.count
    differenceIndex =
      differenceIndex < 0
      ? (forward ? 0 : count - 1) : (differenceIndex + (forward ? 1 : count - 1)) % count
    let row = comparison.differenceRows[differenceIndex]
    leftView.setSelectedRange(leftRanges[row])
    rightView.setSelectedRange(rightRanges[row])
    leftView.scrollRangeToVisible(leftRanges[row])
    status.stringValue =
      "Difference \(differenceIndex + 1) of \(count) — aligned row \(row + 1). Read-only snapshots."
  }
}
