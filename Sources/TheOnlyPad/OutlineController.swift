import AppKit
import PadCore

private final class OutlineTable: NSTableView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, let doubleAction {
      _ = NSApp.sendAction(doubleAction, to: target, from: self)
    } else {
      super.keyDown(with: event)
    }
  }
}
@MainActor
final class OutlineController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  var onClose: (() -> Void)?
  private let snapshot: String
  private let onSelect: (NSRange, String) -> Void
  private var symbols: [OutlineSymbol] = []
  private var filtered: [OutlineSymbol] = []
  private var generation = 0
  private var closed = false
  private var work: Task<[OutlineSymbol], Error>?
  private let table = OutlineTable()
  private let search = NSSearchField()
  private let status = NSTextField(wrappingLabelWithString: "Analyzing captured text…")

  init(text: String, language: DocumentLanguage, onSelect: @escaping (NSRange, String) -> Void) {
    self.snapshot = text
    self.onSelect = onSelect
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Document Outline — " + language.rawValue
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 470, height: 320)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
    ])
    let explanation = NSTextField(
      wrappingLabelWithString:
        "Captured lexical outline, not semantic analysis. Swift/Python/JS/TS named declarations and Markdown ATX headings. Reopen this panel to refresh after edits. Complex embedded syntax may be omitted."
    )
    explanation.textColor = .secondaryLabelColor
    stack.addArrangedSubview(explanation)
    explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    search.placeholderString = "Filter names or kinds"
    search.delegate = self
    search.target = self
    search.action = #selector(selectSymbol)
    search.isEnabled = false
    stack.addArrangedSubview(search)
    search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("symbol"))
    column.title = "Kind · Name · Line"
    column.width = 560
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(selectSymbol)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (view, id, label) in [
      (table as NSView, "outline.symbols", "Document outline symbols"),
      (search, "outline.filter", "Filter outline symbols"),
      (status, "outline.status", "Outline status"),
    ] {
      view.identifier = .init(id)
      view.setAccessibilityLabel(label)
    }
    panel.initialFirstResponder = search
    panel.center()
    generation += 1
    let revision = generation
    let job = Task.detached(priority: .userInitiated) {
      try DocumentOutline.symbols(in: text, language: language, isCancelled: { Task.isCancelled })
    }
    work = job
    Task { [weak self] in
      do {
        let found = try await job.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.work = nil
        self.symbols = found
        self.search.isEnabled = true
        self.filter()
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.work = nil
        self.status.stringValue = error.localizedDescription
      }
    }
  }
  required init?(coder: NSCoder) { nil }
  deinit { work?.cancel() }
  func windowWillClose(_ notification: Notification) {
    closed = true
    generation += 1
    work?.cancel()
    work = nil
    onClose?()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let symbol = filtered[row]
    return NSTextField(labelWithString: "\(symbol.kind) · \(symbol.name) · line \(symbol.line)")
  }
  func controlTextDidChange(_ obj: Notification) { if search.isEnabled { filter() } }
  private func filter() {
    guard !closed else { return }
    work?.cancel()
    generation += 1
    let revision = generation
    let query = search.stringValue
    let symbols = symbols
    filtered = []
    table.reloadData()
    table.deselectAll(nil)
    status.stringValue = "Filtering captured outline…"
    let job = Task.detached { () throws -> [OutlineSymbol] in
      var result: [OutlineSymbol] = []
      for (index, symbol) in symbols.enumerated() {
        if index.isMultiple(of: 64) { try Task.checkCancellation() }
        if query.isEmpty || symbol.name.localizedCaseInsensitiveContains(query)
          || symbol.kind.localizedCaseInsensitiveContains(query)
        {
          result.append(symbol)
        }
      }
      try Task.checkCancellation()
      return result
    }
    work = job
    Task { [weak self] in
      do {
        let result = try await job.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.work = nil
        self.filtered = result
        self.table.reloadData()
        if !result.isEmpty {
          self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        self.status.stringValue =
          symbols.isEmpty
          ? "No supported declarations in this captured text."
          : "\(result.count) of \(symbols.count) symbols. Return or double-click to navigate."
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.work = nil
        self.status.stringValue = error.localizedDescription
      }
    }
  }
  @objc private func selectSymbol() {
    guard !closed, filtered.indices.contains(table.selectedRow) else { return }
    onSelect(filtered[table.selectedRow].range, snapshot)
  }
}
