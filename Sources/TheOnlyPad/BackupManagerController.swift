import AppKit
import PadCore

@MainActor
final class BackupManagerController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  var onClose: (() -> Void)?
  private let store: BackupStore
  private let onRestore: @MainActor (BackupRecord, Data) async throws -> Void
  private var records: [BackupRecord] = []
  private var generation = 0
  private var busy = false
  private var closed = false
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "Loading backups…")
  private let recordID = NSTextField()
  private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
  private let restoreButton = NSButton(title: "Restore as New Tab", target: nil, action: nil)
  private let deleteButton = NSButton(title: "Delete Selected or UUID…", target: nil, action: nil)

  init(
    directory: URL = BackupStore.defaultDirectory,
    onRestore: @escaping @MainActor (BackupRecord, Data) async throws -> Void
  ) {
    self.store = BackupStore(directory: directory)
    self.onRestore = onRestore
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Saved File Backups"
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 640, height: 400)
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
      wrappingLabelWithString:
        "Backups preserve original saved bytes and encoding. Restore opens a new tab; it does not write to the original path. Limits: 100 records, 100 MB each, 500 MB total. Records are never removed automatically."
    )
    stack.addArrangedSubview(note)
    note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("backup"))
    column.title = "Original path · Created · Bytes · Encoding"
    column.width = 700
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 44
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    let buttons = NSStackView(views: [reloadButton, restoreButton, deleteButton])
    buttons.spacing = 10
    stack.addArrangedSubview(buttons)
    stack.addArrangedSubview(
      NSTextField(
        labelWithString:
          "Record UUID (also used to remove a reported corrupt or incomplete record):"))
    stack.addArrangedSubview(recordID)
    recordID.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (view, id, label) in [
      (table as NSView, "backups.records", "Saved backups"),
      (status, "backups.status", "Backup status"), (recordID, "backups.id", "Backup record UUID"),
      (reloadButton, "backups.reload", "Reload backups"),
      (restoreButton, "backups.restore", "Restore backup as new tab"),
      (deleteButton, "backups.delete", "Delete backup with confirmation"),
    ] {
      view.identifier = .init(id)
      view.setAccessibilityLabel(label)
    }
    reloadButton.target = self
    reloadButton.action = #selector(reload)
    restoreButton.target = self
    restoreButton.action = #selector(restore)
    deleteButton.target = self
    deleteButton.action = #selector(confirmDelete)
    panel.center()
    reload()
  }
  required init?(coder: NSCoder) { nil }
  func windowWillClose(_ notification: Notification) {
    closed = true
    generation += 1
    onClose?()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { records.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let record = records[row]
    let field = NSTextField(
      wrappingLabelWithString:
        "\(record.originalPath)\n\(record.createdAt.formatted(date: .abbreviated, time: .standard)) · \(record.byteCount) bytes · \(record.encoding.rawValue)"
    )
    return field
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if records.indices.contains(table.selectedRow) {
      recordID.stringValue = records[table.selectedRow].id.uuidString
    }
    updateControls()
  }
  private func updateControls() {
    reloadButton.isEnabled = !busy && !closed
    restoreButton.isEnabled = !busy && !closed && records.indices.contains(table.selectedRow)
    deleteButton.isEnabled = !busy && !closed
    recordID.isEnabled = !busy && !closed
    table.isEnabled = !busy && !closed
  }
  private func showError(_ error: Error) {
    status.stringValue = error.localizedDescription
    if let error = error as? BackupStoreError {
      switch error {
      case .corrupt(let id), .incomplete(let id), .committedButNotSynced(let id):
        recordID.stringValue = id.uuidString
      default: break
      }
    }
  }
  @objc private func reload() {
    guard !busy, !closed else { return }
    busy = true
    generation += 1
    let revision = generation
    updateControls()
    status.stringValue = "Validating backups…"
    let store = store
    Task { [weak self] in
      do {
        let records = try await Task.detached { try store.list() }.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.records = records
        self.table.reloadData()
        self.table.deselectAll(nil)
        self.recordID.stringValue = ""
        self.status.stringValue =
          records.isEmpty
          ? "No backups." : "\(records.count) verified backups. Select one to restore or delete."
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.records = []
        self.table.reloadData()
        self.table.deselectAll(nil)
        self.recordID.stringValue = ""
        self.showError(error)
      }
      guard let self, !self.closed, self.generation == revision else { return }
      self.busy = false
      self.updateControls()
    }
  }
  @objc private func restore() {
    guard !busy, !closed, records.indices.contains(table.selectedRow) else { return }
    let id = records[table.selectedRow].id
    let store = store
    busy = true
    generation += 1
    let revision = generation
    updateControls()
    status.stringValue = "Reading and verifying backup…"
    Task { [weak self] in
      do {
        let snapshot = try await Task.detached { try store.snapshot(id: id) }.value
        guard let self, !self.closed, self.generation == revision else { return }
        try await self.onRestore(snapshot.record, snapshot.data)
        guard !self.closed, self.generation == revision else { return }
        self.status.stringValue = "Backup sent to a new tab. Original file unchanged."
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.showError(error)
      }
      guard let self, !self.closed, self.generation == revision else { return }
      self.busy = false
      self.updateControls()
    }
  }
  @objc private func confirmDelete() {
    guard !busy, !closed, let window else { return }
    guard
      let id = UUID(
        uuidString: recordID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      status.stringValue = "Select a backup or enter the UUID reported for a damaged record."
      return
    }
    let alert = NSAlert()
    alert.messageText = "Delete this backup permanently?"
    alert.informativeText =
      "Record \(id.uuidString). Only this backup record will be removed. The original file is unchanged."
    alert.addButton(withTitle: "Delete Backup")
    alert.addButton(withTitle: "Cancel")
    busy = true
    updateControls()
    alert.beginSheetModal(for: window) { [weak self] result in
      guard let self, !self.closed else { return }
      self.busy = false
      if result == .alertFirstButtonReturn { self.delete(id) } else { self.updateControls() }
    }
  }
  private func delete(_ id: UUID) {
    busy = true
    generation += 1
    let revision = generation
    updateControls()
    let store = store
    Task { [weak self] in
      do {
        try await Task.detached { try store.remove(id: id) }.value
        guard let self, !self.closed, self.generation == revision else { return }
        self.busy = false
        self.reload()
      } catch {
        guard let self, !self.closed, self.generation == revision else { return }
        self.busy = false
        self.showError(error)
        self.updateControls()
      }
    }
  }
}
