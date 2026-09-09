import AppKit
import PadCore

private final class LargeFileSearchCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// Read-only rendering of bounded byte windows; never writes to the opened file.
@MainActor
final class LargeFileWindowController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  private static let pageSize = 65_536
  private let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
  private let status = NSTextField(labelWithString: "Opening byte window…")
  private let hex = NSTextField(labelWithString: "")
  private let offsetField = NSTextField(string: "0")
  private let previous = NSButton(title: "Previous", target: nil, action: nil)
  private let next = NSButton(title: "Next", target: nil, action: nil)
  private let go = NSButton(title: "Go to byte", target: nil, action: nil)
  private let query = NSTextField(string: "")
  private let search = NSButton(title: "Find UTF-8 text", target: nil, action: nil)
  private let cancel = NSButton(title: "Cancel Search", target: nil, action: nil)
  private let matches = NSPopUpButton(frame: .zero, pullsDown: false)
  private let searchStatus = NSTextField(
    labelWithString: "UTF-8 literal search. Up to 1000 results.")
  private var reader: LargeFileReader?
  private var offset: Int64 = 0
  private var pageBytes = 0
  private var loading = true
  private var searching = false
  private var closed = false
  private var foundOffsets: [Int64] = []
  private var pageRequest = UUID()
  private var searchRequest = UUID()
  private var cancellation: LargeFileSearchCancellation?
  private var pageTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?

  init(url: URL) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.title = url.lastPathComponent + " — Read-only large-file view"
    window.representedURL = url
    window.minSize = NSSize(width: 780, height: 450)
    window.center()
    buildContent(window)
    updateControls()
    let pageSize = Self.pageSize
    let request = pageRequest
    pageTask = Task { [weak self] in
      do {
        let (reader, bytes) = try await Task.detached(priority: .userInitiated) {
          let reader = try LargeFileReader(url: url)
          return (reader, try reader.readWindow(offset: 0, length: pageSize))
        }.value
        guard let self, !self.closed, self.pageRequest == request else { return }
        self.reader = reader
        self.display(bytes, at: 0)
      } catch {
        guard let self, !self.closed, self.pageRequest == request else { return }
        self.fail(error)
      }
    }
  }

  required init?(coder: NSCoder) { nil }

  private func buildContent(_ window: NSWindow) {
    text.identifier = .init("large.text")
    text.setAccessibilityLabel("Read-only byte window text")
    text.isRichText = false
    text.isEditable = false
    text.isSelectable = true
    text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
    let scroll = NSScrollView()
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let warning = NSTextField(
      wrappingLabelWithString:
        "Read-only byte window, UTF-8 display may replace split/invalid characters; original file unchanged. "
        + "Only this 64 KiB page is displayed. Editing and saving are unavailable.")
    warning.setAccessibilityLabel("Byte display limitations")
    warning.font = .systemFont(ofSize: 12)
    offsetField.identifier = .init("large.offset")
    offsetField.setAccessibilityLabel("Byte offset, starting at zero")
    offsetField.target = self
    offsetField.action = #selector(goToOffset)
    offsetField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    query.identifier = .init("large.query")
    query.placeholderString = "Exact UTF-8 text to find"
    query.setAccessibilityLabel("Literal UTF-8 search text")
    query.target = self
    query.action = #selector(startSearch)
    query.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    configure(previous, id: "large.previous", action: #selector(previousPage))
    configure(next, id: "large.next", action: #selector(nextPage))
    configure(go, id: "large.go", action: #selector(goToOffset))
    configure(search, id: "large.search", action: #selector(startSearch))
    configure(cancel, id: "large.cancel", action: #selector(cancelSearch))
    matches.identifier = .init("large.matches")
    matches.setAccessibilityLabel("Search match byte offsets")
    matches.target = self
    matches.action = #selector(selectMatch)
    matches.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    status.identifier = .init("large.status")
    status.setAccessibilityLabel("Byte window status")
    searchStatus.identifier = .init("large.searchStatus")
    searchStatus.setAccessibilityLabel("Search status")
    for field in [status, searchStatus, hex] {
      field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      field.lineBreakMode = .byTruncatingTail
    }
    let navigation = NSStackView(views: [
      previous, next, NSTextField(labelWithString: "Offset:"), offsetField, go,
    ])
    let searchRow = NSStackView(views: [query, search, cancel, matches])
    for row in [navigation, searchRow] {
      row.orientation = .horizontal
      row.spacing = 8
    }
    let stack = NSStackView(views: [
      warning, navigation, status, hex, scroll, searchRow, searchStatus,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    window.contentView = stack
    for view in [warning, navigation, status, hex, scroll, searchRow, searchStatus] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
      if view !== scroll { view.setContentHuggingPriority(.required, for: .vertical) }
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    window.initialFirstResponder = text
  }

  private func configure(_ button: NSButton, id: String, action: Selector) {
    button.identifier = .init(id)
    button.target = self
    button.action = action
    button.setAccessibilityLabel(button.title)
  }

  private func display(_ bytes: Data, at offset: Int64) {
    self.offset = offset
    pageBytes = bytes.count
    loading = false
    offsetField.stringValue = String(offset)
    text.string = String(decoding: bytes, as: UTF8.self)
    text.setSelectedRange(NSRange(location: 0, length: 0))
    text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    hex.stringValue =
      "First bytes (hex): "
      + bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
    status.stringValue =
      "Bytes \(offset)..<\(offset + Int64(bytes.count)) of \(reader?.identity.size ?? 0) — read-only"
    updateControls()
  }

  private func navigate(to requestedOffset: Int64) {
    guard let reader, !closed, !loading else { return }
    guard requestedOffset >= 0, requestedOffset <= reader.identity.size else {
      status.stringValue =
        "Invalid byte offset. Enter a number from 0 through \(reader.identity.size)."
      return
    }
    loading = true
    pageRequest = UUID()
    let request = pageRequest
    let size = Self.pageSize
    status.stringValue = "Reading byte window…"
    updateControls()
    pageTask = Task { [weak self] in
      do {
        let bytes = try await Task.detached(priority: .userInitiated) {
          try reader.readWindow(offset: requestedOffset, length: size)
        }.value
        guard let self, !self.closed, self.pageRequest == request else { return }
        self.display(bytes, at: requestedOffset)
      } catch {
        guard let self, !self.closed, self.pageRequest == request else { return }
        self.fail(error)
      }
    }
  }

  @objc private func previousPage() { navigate(to: max(0, offset - Int64(Self.pageSize))) }
  @objc private func nextPage() {
    if let reader { navigate(to: min(reader.identity.size, offset + Int64(Self.pageSize))) }
  }
  @objc private func goToOffset() {
    guard let value = Int64(offsetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      status.stringValue = "Invalid byte offset. Enter a whole number starting at zero."
      return
    }
    navigate(to: value)
  }

  @objc private func startSearch() {
    guard let reader, !closed, !searching else { return }
    let pattern = Data(query.stringValue.utf8)
    guard !pattern.isEmpty, pattern.count <= 65_536 else {
      searchStatus.stringValue = "Enter 1 through 65536 UTF-8 bytes to search."
      return
    }
    foundOffsets = []
    matches.removeAllItems()
    searching = true
    searchRequest = UUID()
    let request = searchRequest
    let token = LargeFileSearchCancellation()
    cancellation = token
    searchStatus.stringValue = "Searching…"
    updateControls()
    searchTask = Task { [weak self] in
      do {
        let offsets = try await Task.detached(priority: .userInitiated) {
          try reader.searchLiteral(pattern, limit: 1000, cancellation: { token.isCancelled })
        }.value
        guard let self, !self.closed, self.searchRequest == request else { return }
        self.searching = false
        self.foundOffsets = offsets
        self.matches.addItems(withTitles: offsets.map { "Byte \($0)" })
        self.searchStatus.stringValue = "\(offsets.count) matches. Select a byte offset to view it."
        self.updateControls()
      } catch {
        guard let self, !self.closed, self.searchRequest == request else { return }
        self.searching = false
        if error as? LargeFileError == .changed {
          self.fail(error)
        } else if error as? LargeFileError == .cancelled {
          self.searchStatus.stringValue = "Search cancelled."
        } else if error as? LargeFileError == .resultLimit {
          self.searchStatus.stringValue =
            "More than 1000 matches. Narrow the query; no partial results are shown."
        } else {
          self.searchStatus.stringValue = "Search failed: \(error.localizedDescription)"
        }
        self.updateControls()
      }
    }
  }

  @objc private func cancelSearch() {
    cancellation?.cancel()
    searchTask?.cancel()
    searchRequest = UUID()
    searching = false
    searchStatus.stringValue = "Search cancelled."
    updateControls()
  }

  @objc private func selectMatch() {
    let index = matches.indexOfSelectedItem
    guard foundOffsets.indices.contains(index) else { return }
    navigate(to: foundOffsets[index])
  }

  private func fail(_ error: Error) {
    cancellation?.cancel()
    searchRequest = UUID()
    pageRequest = UUID()
    reader = nil
    loading = false
    searching = false
    text.string = ""
    hex.stringValue = ""
    foundOffsets = []
    matches.removeAllItems()
    if error as? LargeFileError == .changed {
      status.stringValue =
        "File changed or moved. Close and reopen this viewer to read its current bytes."
    } else {
      status.stringValue =
        "Cannot read this file: \(error.localizedDescription). Close and reopen to retry."
    }
    searchStatus.stringValue = "Search unavailable until the file is reopened."
    updateControls()
  }

  private func updateControls() {
    let ready = reader != nil && !closed
    previous.isEnabled = ready && !loading && offset > 0
    next.isEnabled = ready && !loading && offset + Int64(pageBytes) < (reader?.identity.size ?? 0)
    go.isEnabled = ready && !loading
    offsetField.isEnabled = ready && !loading
    search.isEnabled = ready && !searching
    query.isEnabled = ready && !searching
    cancel.isEnabled = searching && !closed
    matches.isEnabled = ready && !loading && !searching && !foundOffsets.isEmpty
  }

  func windowWillClose(_ notification: Notification) {
    closed = true
    cancellation?.cancel()
    pageTask?.cancel()
    searchTask?.cancel()
    onClose?()
  }
}
