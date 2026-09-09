import AppKit
import PadCore

struct UnresolvedSessionEntry: Equatable, Sendable {
  let windowID: UUID
  let metadata: SessionTab
  var errorMessage: String
  let hasRecovery: Bool
  init(windowID: UUID, metadata: SessionTab, errorMessage: String, hasRecovery: Bool = false) {
    self.windowID = windowID
    self.metadata = metadata
    self.errorMessage = errorMessage
    self.hasRecovery = hasRecovery
  }
}

struct SessionResolvedFile: Sendable {
  let url: URL?
  let originalBytes: Data?
  let decoded: DecodedDocument
  let resolvedViewState: RestoredViewState?
  let utf16Count: Int
  init(
    url: URL?, originalBytes: Data?, decoded: DecodedDocument,
    resolvedViewState: RestoredViewState? = nil
  ) {
    self.url = url
    self.originalBytes = originalBytes
    self.decoded = decoded
    self.resolvedViewState = resolvedViewState
    self.utf16Count = decoded.text.utf16.count
  }
}

/// Read callbacks must only read/validate. Document import belongs in onResolved, after stale-result checks.
@MainActor
final class SessionRestorationController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate
{
  private(set) var entries: [UnresolvedSessionEntry]
  private(set) var isBusy = false
  var onClose: (() -> Void)?
  private let onRetry: @MainActor (UnresolvedSessionEntry) async throws -> SessionResolvedFile
  private let onLocate: @MainActor (UnresolvedSessionEntry, URL) async throws -> SessionResolvedFile
  private let onResolved: @MainActor (UnresolvedSessionEntry, SessionResolvedFile) throws -> Void
  private let onRemove: @MainActor (UnresolvedSessionEntry) async throws -> Void
  private var generation = 0
  private var closed = false
  private var task: Task<Void, Never>?
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let retryButton = NSButton(
    title: NSLocalizedString("Retry", comment: "Session restoration"), target: nil, action: nil)
  private let locateButton = NSButton(
    title: NSLocalizedString("Locate…", comment: "Session restoration"), target: nil, action: nil)
  private let removeButton = NSButton(
    title: NSLocalizedString("Remove…", comment: "Session restoration"), target: nil, action: nil)

  init(
    entries: [UnresolvedSessionEntry],
    onRetry: @escaping @MainActor (UnresolvedSessionEntry) async throws -> SessionResolvedFile,
    onLocate:
      @escaping @MainActor (UnresolvedSessionEntry, URL) async throws -> SessionResolvedFile,
    onResolved: @escaping @MainActor (UnresolvedSessionEntry, SessionResolvedFile) throws -> Void,
    onRemove: @escaping @MainActor (UnresolvedSessionEntry) async throws -> Void
  ) {
    self.entries = entries
    self.onRetry = onRetry
    self.onLocate = onLocate
    self.onResolved = onResolved
    self.onRemove = onRemove
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = NSLocalizedString("Unresolved Session Tabs", comment: "Session restoration")
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 540, height: 300)
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
        "These tabs remain in your session until restored or explicitly removed. Locate reads a replacement file; it does not write to the original file.",
        comment: "Session restoration"))
    stack.addArrangedSubview(note)
    note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("record"))
    column.title = NSLocalizedString(
      "Original file or recovery record", comment: "Session restoration")
    column.width = 700
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 44
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    let buttons = NSStackView(views: [retryButton, locateButton, removeButton])
    buttons.spacing = 12
    stack.addArrangedSubview(buttons)
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (view, identifier, label) in [
      (table as NSView, "session.records", "Unresolved session records"),
      (status, "session.status", "Session restoration error"),
      (retryButton, "session.retry", "Retry selected session record"),
      (locateButton, "session.locate", "Locate selected session file"),
      (removeButton, "session.remove", "Remove selected session record with confirmation"),
    ] {
      view.identifier = .init(identifier)
      view.setAccessibilityLabel(
        NSLocalizedString(label, comment: "Session restoration accessibility"))
    }
    retryButton.target = self
    retryButton.action = #selector(retrySelected)
    locateButton.target = self
    locateButton.action = #selector(chooseLocation)
    removeButton.target = self
    removeButton.action = #selector(confirmRemoval)
    refresh()
    panel.center()
  }
  required init?(coder: NSCoder) { nil }
  func update(entries: [UnresolvedSessionEntry]) {
    guard !closed else { return }
    let selectedID = selected?.metadata.id
    invalidate()
    self.entries = entries
    table.reloadData()
    if let selectedID, let index = entries.firstIndex(where: { $0.metadata.id == selectedID }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    refresh()
  }
  private func invalidate() {
    generation += 1
    task?.cancel()
    task = nil
    isBusy = false
    if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
  }
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
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard entries.indices.contains(row) else { return nil }
    let entry = entries[row]
    return NSTextField(
      wrappingLabelWithString:
        "\(entry.metadata.originalPath ?? NSLocalizedString("Missing recovery", comment: "Session restoration"))\n\(entry.metadata.id.uuidString)"
    )
  }
  func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
  private var selected: UnresolvedSessionEntry? {
    entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
  }
  private func reloadRecords() {
    let id = selected?.metadata.id
    table.reloadData()
    if let id, let index = entries.firstIndex(where: { $0.metadata.id == id }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
  }
  private func refresh() {
    let enabled = !closed && !isBusy && selected != nil
    retryButton.isEnabled = enabled
    locateButton.isEnabled = enabled
    removeButton.isEnabled = enabled
    table.isEnabled = !isBusy && !closed
    status.stringValue =
      isBusy
      ? NSLocalizedString("Working…", comment: "Session restoration")
      : selected?.errorMessage
        ?? (entries.isEmpty
          ? NSLocalizedString("All session records resolved.", comment: "Session restoration")
          : NSLocalizedString("Select a record to view its error.", comment: "Session restoration"))
  }
  @objc private func retrySelected() {
    guard let entry = selected, !isBusy, !closed else { return }
    perform(entry) { try await self.onRetry(entry) }
  }
  func locateSelected(at url: URL) {
    guard let entry = selected, !isBusy, !closed else { return }
    confirmLocatedFile(entry, url: url)
  }
  private func confirmLocatedFile(_ entry: UnresolvedSessionEntry, url: URL) {
    guard entry.hasRecovery, let window else {
      perform(entry) { try await self.onLocate(entry, url) }
      return
    }
    isBusy = true
    generation += 1
    let request = generation
    refresh()
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Replace recovered unsaved text?", comment: "Session restoration")
    alert.informativeText = NSLocalizedString(
      "This tab has recovered unsaved text. Locating another file replaces that text with the selected file after it is read successfully. Use Retry to restore the recovered text instead.",
      comment: "Session restoration")
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Session restoration"))
    alert.addButton(
      withTitle: NSLocalizedString("Replace Recovered Text", comment: "Session restoration"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.closed, self.generation == request else { return }
      self.isBusy = false
      if response == .alertSecondButtonReturn {
        self.perform(entry) { try await self.onLocate(entry, url) }
      } else {
        self.refresh()
      }
    }
  }

  private func perform(
    _ entry: UnresolvedSessionEntry,
    read: @escaping @MainActor () async throws -> SessionResolvedFile
  ) {
    isBusy = true
    generation += 1
    let request = generation
    refresh()
    task = Task { [weak self] in
      do {
        let result = try await read()
        guard let self, !self.closed, request == self.generation else { return }
        try self.onResolved(entry, result)
        guard !self.closed, request == self.generation else { return }
        self.entries.removeAll { $0.metadata.id == entry.metadata.id }
      } catch {
        guard let self, !self.closed, request == self.generation else { return }
        self.record(error, for: entry)
      }
      guard let self, !self.closed, request == self.generation else { return }
      self.isBusy = false
      self.task = nil
      self.reloadRecords()
      self.refresh()
    }
  }
  private func record(_ error: Error, for entry: UnresolvedSessionEntry) {
    if let index = entries.firstIndex(where: { $0.metadata.id == entry.metadata.id }) {
      entries[index].errorMessage = error.localizedDescription
    }
  }
  @objc private func chooseLocation() {
    guard let entry = selected, !isBusy, !closed, let window else { return }
    isBusy = true
    generation += 1
    let request = generation
    refresh()
    let picker = NSOpenPanel()
    picker.canChooseDirectories = false
    picker.allowsMultipleSelection = false
    picker.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.closed, self.generation == request else { return }
      self.isBusy = false
      if response == .OK, let url = picker.url {
        self.confirmLocatedFile(entry, url: url)
      } else {
        self.refresh()
      }
    }
  }
  @objc private func confirmRemoval() {
    guard let entry = selected, !isBusy, !closed, let window else { return }
    isBusy = true
    generation += 1
    let request = generation
    refresh()
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Remove this unresolved session record?", comment: "Session restoration")
    alert.informativeText = NSLocalizedString(
      "This removes the remembered tab and discards any recovery snapshot for it, including unsaved text. The original file is not deleted.",
      comment: "Session restoration")
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Session restoration"))
    alert.addButton(withTitle: NSLocalizedString("Remove", comment: "Session restoration"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.closed, self.generation == request else { return }
      guard response == .alertSecondButtonReturn else {
        self.isBusy = false
        self.refresh()
        return
      }
      // Removal owns its commit even when this panel closes; only UI delivery is generation-guarded.
      let remove = self.onRemove
      Task { [weak self] in
        do {
          try await remove(entry)
          guard let self, !self.closed, self.generation == request else { return }
          self.entries.removeAll { $0.metadata.id == entry.metadata.id }
        } catch {
          guard let self, !self.closed, self.generation == request else { return }
          self.record(error, for: entry)
        }
        guard let self, !self.closed, self.generation == request else { return }
        self.isBusy = false
        self.reloadRecords()
        self.refresh()
      }
    }
  }
}
