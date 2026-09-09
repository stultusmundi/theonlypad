import AppKit
import PadCore

private final class WorkspaceScanCancellation: @unchecked Sendable {
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

@MainActor
private final class WorkspaceFileTable: NSTableView {
  var onReturn: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      onReturn?()
      return
    }
    super.keyDown(with: event)
  }
}

/// Flat quick-open file list, not a hierarchical folder tree. Discovery and open
/// validation run on workers; the editor callback owns actual document opening.
@MainActor
final class WorkspaceSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private(set) var rootURL: URL?
  var onRootChanged: ((URL) -> Void)?
  private let onOpen: (URL) -> Void
  private let choose = NSButton(title: "Open Folder…", target: nil, action: nil)
  private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
  private let filter = NSSearchField()
  private let table = WorkspaceFileTable()
  private let status = NSTextField(
    wrappingLabelWithString:
      "Choose a folder. Hidden files, symlinks and generated directories are skipped.")
  private let rootLabel = NSTextField(labelWithString: "Workspace — file list")
  private var entries: [WorkspaceEntry] = []
  private var visible: [WorkspaceEntry] = []
  private var request = UUID()
  private var filterRequest = UUID()
  private var scanning = false
  private var filtering = false
  private var scanCancellation: WorkspaceScanCancellation?

  init(onOpen: @escaping (URL) -> Void) {
    self.onOpen = onOpen
    super.init(frame: .zero)
    choose.identifier = .init("workspace.choose")
    choose.target = self
    choose.action = #selector(chooseFolder)
    choose.setAccessibilityLabel("Open workspace folder")
    cancel.identifier = .init("workspace.cancel")
    cancel.target = self
    cancel.action = #selector(cancelDiscovery)
    cancel.setAccessibilityLabel("Cancel workspace discovery")
    cancel.isEnabled = false
    filter.identifier = .init("workspace.filter")
    filter.placeholderString = "Filter relative file paths"
    filter.setAccessibilityLabel("Filter workspace files")
    filter.delegate = self
    filter.target = self
    filter.action = #selector(openSelected)
    filter.sendsSearchStringImmediately = true
    filter.isEnabled = false
    table.identifier = .init("workspace.files")
    table.setAccessibilityLabel("Workspace files, flat relative-path list")
    let column = NSTableColumn(identifier: .init("relativePath"))
    column.title = "Files (relative paths)"
    column.width = 260
    table.addTableColumn(column)
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.rowHeight = 24
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.onReturn = { [weak self] in self?.openSelected() }
    table.allowsMultipleSelection = false
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    rootLabel.lineBreakMode = .byTruncatingMiddle
    rootLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    status.identifier = .init("workspace.status")
    status.setAccessibilityLabel("Workspace discovery status")
    status.font = .systemFont(ofSize: 11)
    let controls = NSStackView(views: [choose, cancel])
    controls.orientation = .horizontal
    controls.spacing = 6
    let stack = NSStackView(views: [rootLabel, controls, filter, scroll, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
    for view in [rootLabel, controls, filter, scroll, status] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      if view !== scroll { view.setContentHuggingPriority(.required, for: .vertical) }
    }
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
  }

  required init?(coder: NSCoder) { nil }
  deinit { scanCancellation?.cancel() }

  @objc private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open Folder"
    panel.directoryURL = rootURL
    if let window {
      panel.beginSheetModal(for: window) { [weak self] response in
        if response == .OK, let url = panel.url { self?.openFolder(url) }
      }
    } else if panel.runModal() == .OK, let url = panel.url {
      openFolder(url)
    }
  }

  func openFolder(_ url: URL) {
    scanCancellation?.cancel()
    request = UUID()
    filterRequest = UUID()
    let request = request
    let token = WorkspaceScanCancellation()
    scanCancellation = token
    scanning = true
    filtering = false
    rootURL = nil
    entries = []
    visible = []
    table.reloadData()
    filter.isEnabled = false
    cancel.isEnabled = true
    rootLabel.stringValue = "Workspace — discovering files"
    status.stringValue = "Discovering… 0 paths visited."
    Task { [weak self] in
      do {
        let (root, entries) = try await Task.detached(priority: .userInitiated) {
          let found = try WorkspaceIndex.scan(
            root: url, isCancelled: { token.isCancelled },
            onProgress: { count in
              Task { @MainActor [weak self] in
                guard let self, self.request == request, self.scanning else { return }
                self.status.stringValue = "Discovering… \(count) paths visited."
              }
            })
          return (url.resolvingSymlinksInPath().standardizedFileURL, found)
        }.value
        guard let self, self.request == request else { return }
        self.scanning = false
        self.cancel.isEnabled = false
        self.rootURL = root
        self.rootLabel.stringValue = root.lastPathComponent + " — file list"
        self.rootLabel.toolTip = root.path
        self.entries = entries
        self.filter.isEnabled = true
        self.onRootChanged?(root)
        self.applyFilter()
      } catch {
        guard let self, self.request == request else { return }
        self.scanning = false
        self.cancel.isEnabled = false
        if error as? WorkspaceIndexError == .cancelled {
          self.status.stringValue = "Discovery cancelled. Choose a folder to restart."
        } else if error as? WorkspaceIndexError == .pathLimit {
          self.status.stringValue =
            "More than 50000 paths. Choose a smaller folder; no partial index is shown."
        } else {
          self.status.stringValue = "Cannot index folder: \(error.localizedDescription)"
        }
      }
    }
  }

  @objc private func cancelDiscovery() {
    scanCancellation?.cancel()
    request = UUID()
    filterRequest = UUID()
    scanning = false
    filtering = false
    cancel.isEnabled = false
    status.stringValue = "Discovery cancelled. Choose a folder to restart."
  }

  func controlTextDidChange(_ obj: Notification) { applyFilter() }
  private func applyFilter() {
    guard !scanning, rootURL != nil else { return }
    filterRequest = UUID()
    let generation = filterRequest
    let entries = entries
    let query = filter.stringValue
    filtering = true
    status.stringValue = "Filtering \(entries.count) files…"
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        WorkspaceIndex.filtered(entries, query: query)
      }.value
      guard let self, self.filterRequest == generation, !self.scanning else { return }
      self.visible = result
      self.filtering = false
      self.table.reloadData()
      if !result.isEmpty {
        self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      }
      self.status.stringValue =
        "\(result.count) of \(entries.count) files. Double-click or press Return to open."
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard visible.indices.contains(row) else { return nil }
    let field = NSTextField(labelWithString: visible[row].relativePath)
    field.lineBreakMode = .byTruncatingMiddle
    field.toolTip = visible[row].relativePath
    field.setAccessibilityLabel(visible[row].relativePath)
    return field
  }

  @objc private func openSelected() {
    guard !scanning, !filtering, let rootURL else { return }
    let row = table.selectedRow >= 0 ? table.selectedRow : 0
    guard visible.indices.contains(row) else { return }
    let entry = visible[row]
    let request = request
    Task { [weak self] in
      do {
        let url = try await Task.detached(priority: .userInitiated) {
          try WorkspaceIndex.validatedFile(entry.url, within: rootURL)
        }.value
        guard let self, self.request == request else { return }
        self.onOpen(url)
      } catch {
        guard let self, self.request == request else { return }
        self.status.stringValue =
          "Cannot open this entry safely. It may have moved or become a symlink. Refresh by opening the folder again."
      }
    }
  }
}
