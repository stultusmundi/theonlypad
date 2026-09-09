import AppKit
import PadCore

@MainActor
final class MacroManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  var onCancel: (() -> Void)? { didSet { updateControls() } }
  private let onReplay: (EditorMacro, Int) -> Void
  private let library = MacroLibrary(directory: MacroLibrary.defaultDirectory)
  private var macros: [EditorMacro] = []
  private var busy = false
  private var reloadPending = false
  private var validLibrary = false
  private let table = NSTableView()
  private let nameField = NSTextField()
  private let countField = NSTextField(string: "1")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let renameButton = NSButton(title: String(localized: "Rename"), target: nil, action: nil)
  private let deleteButton = NSButton(title: String(localized: "Delete…"), target: nil, action: nil)
  private let replayButton = NSButton(title: String(localized: "Replay"), target: nil, action: nil)
  private let cancelButton = NSButton(
    title: String(localized: "Cancel Replay"), target: nil, action: nil)
  private let reloadButton = NSButton(title: String(localized: "Reload"), target: nil, action: nil)

  init(onReplay: @escaping (EditorMacro, Int) -> Void) {
    self.onReplay = onReplay
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 450), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = String(localized: "Saved Macros")
    panel.isReleasedWhenClosed = false
    buildContent()
    panel.center()
    panel.initialFirstResponder = table
    reload()
  }
  required init?(coder: NSCoder) { nil }

  private func buildContent() {
    guard let content = window?.contentView else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
    ])
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("macro"))
    column.title = String(localized: "Macro")
    column.width = 560
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 26
    table.allowsEmptySelection = true
    table.setAccessibilityLabel(String(localized: "Saved macros"))
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true

    nameField.placeholderString = String(localized: "Macro name")
    nameField.setAccessibilityLabel(String(localized: "Macro name"))
    nameField.target = self
    nameField.action = #selector(rename)
    let names = NSStackView(views: [nameField, renameButton, deleteButton])
    names.spacing = 8
    stack.addArrangedSubview(names)
    names.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 1
    formatter.maximum = 10_000
    formatter.allowsFloats = false
    countField.formatter = formatter
    countField.integerValue = 1
    countField.setAccessibilityLabel(String(localized: "Repeat count"))
    countField.widthAnchor.constraint(equalToConstant: 70).isActive = true
    let controls = NSStackView(views: [
      NSTextField(labelWithString: String(localized: "Repeat")), countField, replayButton,
      cancelButton, reloadButton,
    ])
    controls.spacing = 10
    stack.addArrangedSubview(controls)
    status.textColor = .secondaryLabelColor
    status.setAccessibilityLabel(String(localized: "Macro library status"))
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (button, action) in [
      (renameButton, #selector(rename)), (deleteButton, #selector(deleteMacro)),
      (replayButton, #selector(replay)), (cancelButton, #selector(cancelReplay)),
      (reloadButton, #selector(reloadAction)),
    ] {
      button.target = self
      button.action = action
    }
  }

  private var selected: EditorMacro? {
    macros.indices.contains(table.selectedRow) ? macros[table.selectedRow] : nil
  }

  func numberOfRows(in tableView: NSTableView) -> Int { macros.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let macro = macros[row]
    return NSTextField(labelWithString: "\(macro.name) — \(macro.commands.count) commands")
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    nameField.stringValue = selected?.name ?? ""
    updateControls()
  }
  private func updateControls() {
    let editable = !busy && validLibrary && selected != nil
    nameField.isEnabled = editable
    renameButton.isEnabled = editable
    deleteButton.isEnabled = editable
    replayButton.isEnabled = editable
    countField.isEnabled = editable
    reloadButton.isEnabled = !busy
    cancelButton.isEnabled = onCancel != nil
  }

  func reload() {
    guard !busy else {
      reloadPending = true
      return
    }
    fetch(after: nil)
  }
  @objc private func reloadAction() { reload() }

  private func fetch(after mutation: (@Sendable (MacroLibrary) throws -> Void)?) {
    let selectedID = selected?.id
    busy = true
    updateControls()
    status.stringValue = String(localized: "Loading macro library…")
    let library = library
    Task {
      do {
        let loaded = try await Task.detached {
          try mutation?(library)
          return try library.load()
        }.value
        macros = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        validLibrary = true
        table.reloadData()
        if !macros.isEmpty {
          let row = macros.firstIndex { $0.id == selectedID } ?? 0
          table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          nameField.stringValue = macros[row].name
        } else {
          nameField.stringValue = ""
        }
        status.stringValue =
          macros.isEmpty
          ? String(localized: "No saved macros. Record a macro in the editor to add one.")
          : String(localized: "Replay applies to the editor window behind this panel.")
      } catch {
        validLibrary = false
        macros = []
        table.reloadData()
        nameField.stringValue = ""
        status.stringValue = error.localizedDescription
        present(error)
      }
      busy = false
      updateControls()
      if reloadPending {
        reloadPending = false
        reload()
      }
    }
  }

  @objc private func rename() {
    guard !busy, validLibrary, let macro = selected else { return }
    let name = nameField.stringValue
    fetch { try $0.rename(id: macro.id, to: name) }
  }

  @objc private func deleteMacro() {
    guard !busy, validLibrary, let macro = selected, let window else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Delete saved macro?")
    alert.informativeText = macro.name
    alert.addButton(withTitle: String(localized: "Delete"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.fetch { try $0.delete(id: macro.id) }
    }
  }

  @objc private func replay() {
    guard !busy, validLibrary, let macro = selected else { return }
    guard let number = countField.objectValue as? NSNumber, (1...10_000).contains(number.intValue),
      number.doubleValue == Double(number.intValue),
      macro.commands.count <= 10_000 / number.intValue
    else {
      present(MacroError.workLimit)
      return
    }
    status.stringValue =
      onCancel == nil
      ? String(localized: "Replay requested.")
      : String(localized: "Replay requested. Use Cancel Replay to stop the pending operation.")
    onReplay(macro, number.intValue)
  }

  @objc private func cancelReplay() {
    onCancel?()
    status.stringValue = String(localized: "Replay cancellation requested.")
  }

  private func present(_ error: Error) {
    if let window, window.isVisible { NSAlert(error: error).beginSheetModal(for: window) }
  }
}
