import AppKit

@MainActor
final class RecentFilesController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  private(set) var paths: [String]
  private(set) var isBusy = false
  var statusMessage: String { status.stringValue }
  var onClose: (() -> Void)?
  private let onOpen: @MainActor (URL, @escaping @MainActor () -> Bool) async throws -> Void
  private let onRemove: @MainActor (String) -> Void
  private let onClear: @MainActor () -> Void
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let openButton = NSButton(
    title: NSLocalizedString("Open", comment: "Recent files"), target: nil, action: nil)
  private let removeButton = NSButton(
    title: NSLocalizedString("Remove From List", comment: "Recent files"), target: nil, action: nil)
  private let clearButton = NSButton(
    title: NSLocalizedString("Clear List", comment: "Recent files"), target: nil, action: nil)
  private var generation = 0
  private var closed = false
  private var suspended = false
  private var task: Task<Void, Never>?

  init(
    paths: [String],
    onOpen: @escaping @MainActor (URL, @escaping @MainActor () -> Bool) async throws -> Void,
    onRemove: @escaping @MainActor (String) -> Void,
    onClear: @escaping @MainActor () -> Void
  ) {
    self.paths = paths
    self.onOpen = onOpen
    self.onRemove = onRemove
    self.onClear = onClear
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = NSLocalizedString("Recent Files", comment: "Recent files")
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 480, height: 280)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
    ])
    let note = NSTextField(
      wrappingLabelWithString: NSLocalizedString(
        "Up to 50 successfully opened local files, most recent first. Removing an entry or clearing the list never deletes files.",
        comment: "Recent files"))
    stack.addArrangedSubview(note)
    note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("path"))
    column.title = NSLocalizedString("File", comment: "Recent files")
    column.width = 660
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 42
    table.target = self
    table.doubleAction = #selector(openSelected)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    let buttons = NSStackView(views: [openButton, removeButton, clearButton])
    buttons.spacing = 12
    stack.addArrangedSubview(buttons)
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (view, identifier, label) in [
      (table as NSView, "recents.files", "Recent files"),
      (status, "recents.status", "Recent file status"),
      (openButton, "recents.open", "Open selected recent file"),
      (removeButton, "recents.remove", "Remove selected entry from recent files"),
      (clearButton, "recents.clear", "Clear recent files list"),
    ] {
      view.identifier = .init(identifier)
      view.setAccessibilityIdentifier(identifier)
      view.setAccessibilityLabel(NSLocalizedString(label, comment: "Recent files accessibility"))
    }
    openButton.target = self
    openButton.action = #selector(openSelected)
    openButton.keyEquivalent = "\r"
    removeButton.target = self
    removeButton.action = #selector(removeSelected)
    clearButton.target = self
    clearButton.action = #selector(clearList)
    panel.initialFirstResponder = table
    reload(selected: paths.first)
    refresh()
    panel.center()
  }
  required init?(coder: NSCoder) { nil }
  func windowWillClose(_ notification: Notification) {
    guard !closed else { return }
    closed = true
    invalidate()
    onClose?()
  }
  override func close() {
    windowWillClose(Notification(name: NSWindow.willCloseNotification))
    super.close()
  }
  func update(paths: [String], openedPath: String? = nil) {
    guard !closed else { return }
    let selection = selectedPath
    invalidate()
    self.paths = paths
    status.stringValue = ""
    reload(selected: selection)
    refresh()
    if let openedPath, !suspended {
      status.stringValue = String(
        format: NSLocalizedString("Opened %@.", comment: "Recent files"),
        URL(fileURLWithPath: openedPath).lastPathComponent)
    }
  }
  func setSuspended(_ value: Bool) {
    guard !closed, suspended != value else { return }
    suspended = value
    invalidate()
    status.stringValue = ""
    refresh()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { paths.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard paths.indices.contains(row) else { return nil }
    let path = paths[row]
    return NSTextField(
      wrappingLabelWithString: URL(fileURLWithPath: path).lastPathComponent + "\n" + path)
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if isBusy { invalidate() }
    status.stringValue = ""
    refresh()
  }
  private var selectedPath: String? {
    paths.indices.contains(table.selectedRow) ? paths[table.selectedRow] : nil
  }
  private func invalidate() {
    generation += 1
    task?.cancel()
    task = nil
    isBusy = false
  }
  private func reload(selected path: String?) {
    table.reloadData()
    if let path, let index = paths.firstIndex(of: path) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
  }
  private func refresh() {
    openButton.isEnabled = !closed && !suspended && !isBusy && selectedPath != nil
    removeButton.isEnabled = openButton.isEnabled
    clearButton.isEnabled = !closed && !suspended && !isBusy && !paths.isEmpty
    table.isEnabled = !closed && !suspended && !isBusy
    if suspended {
      status.stringValue = NSLocalizedString(
        "Recent files are unavailable while quitting.", comment: "Recent files")
    } else if isBusy {
      status.stringValue = NSLocalizedString("Opening…", comment: "Recent files")
    } else if paths.isEmpty {
      status.stringValue = NSLocalizedString("No recent files.", comment: "Recent files")
    }
  }
  @objc private func openSelected() {
    guard !closed, !suspended, !isBusy, let path = selectedPath else { return }
    isBusy = true
    generation += 1
    let request = generation
    let open = onOpen
    refresh()
    task = Task { [weak self] in
      do {
        try await open(URL(fileURLWithPath: path)) { [weak self] in
          guard let self else { return false }
          return !self.closed && self.generation == request && self.selectedPath == path
        }
        guard let self, !self.closed, self.generation == request else { return }
        self.status.stringValue = NSLocalizedString("Opened.", comment: "Recent files")
      } catch {
        guard let self, !self.closed, self.generation == request else { return }
        self.status.stringValue = error.localizedDescription
      }
      guard let self, !self.closed, self.generation == request else { return }
      self.isBusy = false
      self.task = nil
      self.refresh()
    }
  }
  @objc private func removeSelected() {
    guard !closed, !suspended, !isBusy, let path = selectedPath else { return }
    onRemove(path)
    paths.removeAll { $0 == path }
    status.stringValue = ""
    reload(selected: paths.first)
    refresh()
  }
  @objc private func clearList() {
    guard !closed, !suspended, !isBusy else { return }
    onClear()
    paths.removeAll()
    status.stringValue = ""
    reload(selected: nil)
    refresh()
  }
}
