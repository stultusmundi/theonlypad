import AppKit
import PadCore
import UniformTypeIdentifiers

@MainActor
final class ExtensionManagerController: NSWindowController, NSTableViewDataSource,
  NSTableViewDelegate
{
  var onChanged: (() -> Void)?
  private let onRun: (String, LineTransform) -> Void
  private let catalog = ExtensionCatalog(directory: ExtensionCatalog.defaultDirectory)
  private var entries: [InstalledExtension] = []
  private var busy = false
  private var reloadPending = false
  private let table = NSTableView()
  private let commands = NSPopUpButton()
  private let details = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let installButton = NSButton(
    title: String(localized: "Install…"), target: nil, action: nil)
  private let toggleButton = NSButton(title: String(localized: "Enable"), target: nil, action: nil)
  private let uninstallButton = NSButton(
    title: String(localized: "Uninstall…"), target: nil, action: nil)
  private let reloadButton = NSButton(title: String(localized: "Reload"), target: nil, action: nil)
  private let runButton = NSButton(
    title: String(localized: "Run Command"), target: nil, action: nil)

  init(onRun: @escaping (String, LineTransform) -> Void) {
    self.onRun = onRun
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = String(localized: "Local Extensions")
    panel.isReleasedWhenClosed = false
    buildContent()
    panel.initialFirstResponder = table
    panel.center()
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
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension"))
    column.title = String(localized: "Installed extension")
    column.width = 580
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 26
    table.setAccessibilityLabel(String(localized: "Installed extensions"))
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 205).isActive = true
    let management = NSStackView(views: [
      installButton, toggleButton, uninstallButton, reloadButton,
    ])
    management.spacing = 10
    stack.addArrangedSubview(management)
    details.textColor = .secondaryLabelColor
    stack.addArrangedSubview(details)
    details.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    commands.setAccessibilityLabel(String(localized: "Extension command"))
    let execution = NSStackView(views: [commands, runButton])
    execution.spacing = 10
    stack.addArrangedSubview(execution)
    commands.widthAnchor.constraint(lessThanOrEqualToConstant: 450).isActive = true
    status.textColor = .secondaryLabelColor
    status.setAccessibilityLabel(String(localized: "Extension status"))
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    for (button, action) in [
      (installButton, #selector(install)), (toggleButton, #selector(toggle)),
      (uninstallButton, #selector(uninstall)), (reloadButton, #selector(reloadAction)),
      (runButton, #selector(runCommand)),
    ] {
      button.target = self
      button.action = action
    }
  }
  private var selected: InstalledExtension? {
    entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
  }
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let entry = entries[row]
    let state = entry.enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    return NSTextField(
      labelWithString: "\(entry.manifest.name) \(entry.manifest.version) — \(state)")
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    commands.removeAllItems()
    if let selected {
      commands.addItems(withTitles: selected.manifest.commands.map(\.title))
      details.stringValue =
        "\(selected.id)\n"
        + String(
          localized:
            "Capability: text.transform. Commands edit document text only when you run them.")
    } else {
      details.stringValue = String(
        localized:
          "Install a declarative JSON extension manifest to add text-transformation commands. Windows Notepad++ plugin binaries are not supported."
      )
    }
    updateControls()
  }
  private func updateControls() {
    installButton.isEnabled = !busy
    reloadButton.isEnabled = !busy
    toggleButton.isEnabled = !busy && selected != nil
    toggleButton.title =
      selected?.enabled == true ? String(localized: "Disable") : String(localized: "Enable")
    uninstallButton.isEnabled = !busy && selected != nil
    commands.isEnabled = !busy && selected != nil
    runButton.isEnabled = !busy && selected?.enabled == true
  }
  func reload() {
    guard !busy else {
      reloadPending = true
      return
    }
    performMutation(nil)
  }
  @objc private func reloadAction() { reload() }
  private func finish() {
    busy = false
    updateControls()
    if reloadPending {
      reloadPending = false
      reload()
    }
  }
  private func performMutation(_ change: (@Sendable (ExtensionCatalog) throws -> Void)?) {
    let id = selected?.id
    busy = true
    updateControls()
    let catalog = catalog
    Task {
      do {
        let loaded = try await Task.detached {
          try change?(catalog)
          return try catalog.load()
        }.value
        entries = loaded.sorted {
          $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
        table.reloadData()
        if !entries.isEmpty {
          table.selectRowIndexes(
            IndexSet(integer: entries.firstIndex(where: { $0.id == id }) ?? 0),
            byExtendingSelection: false)
        }
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        status.stringValue =
          entries.isEmpty
          ? String(localized: "No installed extensions.")
          : String(
            localized:
              "New installations start disabled. Enable an extension before running its commands.")
      } catch {
        entries = []
        table.reloadData()
        commands.removeAllItems()
        status.stringValue = error.localizedDescription
        present(error)
      }
      onChanged?()
      finish()
    }
  }
  @objc private func install() {
    guard !busy, let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = String(
      localized:
        "Choose a declarative JSON extension manifest. Windows Notepad++ plugin binaries are not supported."
    )
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.busy = true
      self.updateControls()
      let catalog = self.catalog
      Task { @MainActor in
        do {
          let manifest = try await Task.detached { try catalog.inspect(url: url) }.value
          self.finish()
          let alert = NSAlert()
          alert.messageText = "Install \(manifest.name) \(manifest.version)?"
          let transforms = Set(manifest.commands.map { $0.transform.rawValue }).sorted().joined(
            separator: ", ")
          alert.informativeText =
            "\(manifest.id)\n"
            + String(
              localized:
                "Requested capability: text.transform. This declarative extension can offer the listed document transformations. It contains no executable code. Installation starts disabled."
            ) + "\n" + transforms
          alert.addButton(withTitle: String(localized: "Install Disabled"))
          alert.addButton(withTitle: String(localized: "Cancel"))
          alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
              self?.performMutation { _ = try $0.install(manifest) }
            }
          }
        } catch {
          self.finish()
          self.present(error)
        }
      }
    }
  }
  @objc private func toggle() {
    guard !busy, let entry = selected else { return }
    performMutation { try $0.setEnabled(id: entry.id, enabled: !entry.enabled) }
  }
  @objc private func uninstall() {
    guard !busy, let entry = selected, let window else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Uninstall extension?")
    alert.informativeText = entry.manifest.name
    alert.addButton(withTitle: String(localized: "Uninstall"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn {
        self?.performMutation { try $0.uninstall(id: entry.id) }
      }
    }
  }
  @objc private func runCommand() {
    guard !busy, let entry = selected, entry.enabled,
      entry.manifest.commands.indices.contains(commands.indexOfSelectedItem)
    else { return }
    let command = entry.manifest.commands[commands.indexOfSelectedItem]
    busy = true
    updateControls()
    let catalog = catalog
    Task {
      do {
        let approved = try await Task.detached {
          try catalog.load().contains {
            $0.id == entry.id && $0.enabled && $0.manifest.commands.contains(command)
          }
        }.value
        guard approved else { throw ExtensionCatalogError.missing }
        onRun(command.title, command.transform)
        status.stringValue = String(localized: "Command sent to the editor.")
      } catch {
        present(error)
        status.stringValue = error.localizedDescription
      }
      finish()
    }
  }
  private func present(_ error: Error) {
    if let window, window.isVisible { NSAlert(error: error).beginSheetModal(for: window) }
  }
}
