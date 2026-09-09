import AppKit
import PadCore

@MainActor
final class CommandPaletteController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private let commands: [CommandDescriptor]
  private var filtered: [CommandDescriptor]
  private let runCommand: (String) -> Void
  private let search = NSSearchField()
  private let table = NSTableView()

  init(commands: [CommandDescriptor], run: @escaping (String) -> Void) {
    self.commands = commands
    self.filtered = commands
    self.runCommand = run
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Command Palette"
    panel.isReleasedWhenClosed = false
    let content = NSView()
    panel.contentView = content
    search.placeholderString = "Search commands"
    search.setAccessibilityLabel("Search commands")
    search.delegate = self
    search.target = self
    search.action = #selector(performSelected)
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
    table.headerView = nil
    table.rowHeight = 30
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.doubleAction = #selector(performSelected)
    table.setAccessibilityLabel("Available commands")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    for child in [search, scroll] {
      child.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(child)
    }
    NSLayoutConstraint.activate([
      search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
    panel.center()
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    panel.initialFirstResponder = search
  }
  required init?(coder: NSCoder) { nil }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let command = filtered[row]
    return NSTextField(
      labelWithString: command.title + (command.shortcut.map { "    \($0)" } ?? ""))
  }
  func controlTextDidChange(_ obj: Notification) {
    filtered = commands.filter {
      search.stringValue.isEmpty || $0.title.localizedCaseInsensitiveContains(search.stringValue)
    }
    table.reloadData()
    if !filtered.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }
  @objc private func performSelected() {
    let row = table.selectedRow
    guard filtered.indices.contains(row) else { return }
    let id = filtered[row].id
    close()
    runCommand(id)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.moveDown(_:))
      || commandSelector == #selector(NSResponder.moveUp(_:))
    {
      let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let next = max(0, min(filtered.count - 1, table.selectedRow + delta))
      if filtered.indices.contains(next) {
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
      }
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      close()
      return true
    }
    return false
  }
}
