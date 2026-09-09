import AppKit
import PadCore
import UniformTypeIdentifiers

@MainActor
final class PreferencesController: NSWindowController, NSSearchFieldDelegate {
  private let store: SettingsStore
  private let saveSettings: @Sendable (EditorSettings) throws -> Void
  private let onApply: (EditorSettings) -> Void
  private var current = EditorSettings.defaults
  private var loaded = false
  private var busy = false
  private let search = NSSearchField()
  private let theme = NSPopUpButton()
  private let font = NSPopUpButton()
  private let fontSize = NSSlider(value: 13, minValue: 8, maxValue: 36, target: nil, action: nil)
  private let sizeLabel = NSTextField(labelWithString: "13 pt")
  private let wrap = NSButton(
    checkboxWithTitle: String(localized: "Wrap long lines"), target: nil, action: nil)
  private let tabWidth = NSPopUpButton()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let importButton = NSButton(title: String(localized: "Import…"), target: nil, action: nil)
  private let exportButton = NSButton(title: String(localized: "Export…"), target: nil, action: nil)
  private let resetButton = NSButton(title: String(localized: "Reset…"), target: nil, action: nil)
  private var rows: [(String, NSView)] = []

  init(
    store: SettingsStore = SettingsStore(directory: SettingsStore.defaultDirectory),
    saveSettings: (@Sendable (EditorSettings) throws -> Void)? = nil,
    onApply: @escaping (EditorSettings) -> Void
  ) {
    self.store = store
    self.saveSettings = saveSettings ?? { try store.save($0) }
    self.onApply = onApply
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 570, height: 425), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.title = String(localized: "Preferences")
    window.isReleasedWhenClosed = false
    buildContent()
    window.center()
    window.initialFirstResponder = search
    load()
  }

  required init?(coder: NSCoder) { nil }

  private func buildContent() {
    guard let content = window?.contentView else { return }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
    ])
    search.placeholderString = String(localized: "Search preferences")
    search.setAccessibilityLabel(String(localized: "Search preferences"))
    search.delegate = self
    stack.addArrangedSubview(search)
    search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    theme.addItems(withTitles: [
      String(localized: "System"), String(localized: "Light"), String(localized: "Dark"),
    ])
    font.addItem(withTitle: EditorSettings.systemMonospacedFontName)
    font.addItems(withTitles: NSFontManager.shared.availableFonts.sorted())
    fontSize.numberOfTickMarks = 29
    fontSize.allowsTickMarkValuesOnly = true
    fontSize.isContinuous = false
    tabWidth.addItems(withTitles: (2...8).map(String.init))

    func row(_ title: String, terms: String, controls: [NSView]) {
      let label = NSTextField(labelWithString: title)
      label.widthAnchor.constraint(equalToConstant: 100).isActive = true
      let row = NSStackView(views: [label] + controls)
      row.orientation = .horizontal
      row.spacing = 10
      row.alignment = .centerY
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      rows.append((title + " " + terms, row))
      for control in controls { control.setAccessibilityLabel(title) }
    }
    row(String(localized: "Appearance"), terms: "theme system light dark", controls: [theme])
    row(String(localized: "Font"), terms: "typeface family monospaced", controls: [font])
    row(String(localized: "Font size"), terms: "text points zoom", controls: [fontSize, sizeLabel])
    fontSize.widthAnchor.constraint(equalToConstant: 270).isActive = true
    row(String(localized: "Wrapping"), terms: "word wrap long lines", controls: [wrap])
    row(String(localized: "Tab width"), terms: "indentation spaces", controls: [tabWidth])
    font.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
    for control in settingControls {
      control.target = self
      control.action = #selector(changed(_:))
    }

    let buttons = NSStackView(views: [importButton, exportButton, resetButton])
    buttons.orientation = .horizontal
    buttons.spacing = 10
    stack.addArrangedSubview(buttons)
    importButton.target = self
    importButton.action = #selector(importPreferences)
    exportButton.target = self
    exportButton.action = #selector(exportPreferences)
    resetButton.target = self
    resetButton.action = #selector(resetPreferences)
    status.textColor = .secondaryLabelColor
    status.setAccessibilityLabel(String(localized: "Preferences status"))
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private var settingControls: [NSControl] { [theme, font, fontSize, wrap, tabWidth] }

  private func setBusy(_ value: Bool) {
    busy = value
    for control in settingControls { control.isEnabled = loaded && !value }
    importButton.isEnabled = !value
    resetButton.isEnabled = !value
    exportButton.isEnabled = loaded && !value
  }

  private func display(_ settings: EditorSettings) {
    current = settings
    theme.selectItem(at: EditorTheme.allCases.firstIndex(of: settings.theme) ?? 0)
    font.selectItem(withTitle: settings.fontName)
    fontSize.doubleValue = settings.fontSize
    sizeLabel.stringValue = "\(settings.fontSize.formatted()) pt"
    wrap.state = settings.wrap ? .on : .off
    tabWidth.selectItem(withTitle: String(settings.tabWidth))
  }

  private func requireAvailableFont(_ settings: EditorSettings) throws {
    guard
      settings.fontName == EditorSettings.systemMonospacedFontName
        || NSFont(name: settings.fontName, size: settings.fontSize) != nil
    else {
      throw SettingsError.invalidField(
        String(
          localized:
            "The selected font is not installed on this Mac. Choose an installed font before importing."
        ))
    }
  }

  private func load() {
    setBusy(true)
    status.stringValue = String(localized: "Loading preferences…")
    let store = store
    Task {
      do {
        let settings = try await Task.detached { try store.load() }.value
        try requireAvailableFont(settings)
        loaded = true
        display(settings)
        status.stringValue = String(localized: "Changes are saved automatically.")
      } catch {
        status.stringValue = String(
          localized:
            "Stored preferences could not be loaded. Import a valid file or reset explicitly.")
        present(error)
      }
      setBusy(false)
    }
  }

  @objc private func changed(_ sender: NSControl) {
    guard loaded, !busy else { return }
    let settings = EditorSettings(
      theme: EditorTheme.allCases[max(0, theme.indexOfSelectedItem)],
      fontSize: min(36, max(8, fontSize.doubleValue)),
      fontName: font.titleOfSelectedItem ?? EditorSettings.systemMonospacedFontName,
      wrap: wrap.state == .on, tabWidth: Int(tabWidth.titleOfSelectedItem ?? "4") ?? 4)
    persist(settings)
  }

  private func persist(_ settings: EditorSettings) {
    do {
      try requireAvailableFont(settings)
      try settings.validated()
    } catch {
      display(current)
      present(error)
      return
    }
    setBusy(true)
    status.stringValue = String(localized: "Saving preferences…")
    let saveSettings = saveSettings
    Task {
      do {
        try await Task.detached { try saveSettings(settings) }.value
        loaded = true
        display(settings)
        onApply(settings)
        status.stringValue = String(localized: "Preferences saved.")
      } catch {
        let saveError = error
        if case FileStoreError.publicationUncertain = error {
          do {
            let store = store
            let observed = try await Task.detached { try store.load() }.value
            try requireAvailableFont(observed)
            loaded = true
            display(observed)
            onApply(observed)
            present(saveError)
            status.stringValue = String(
              localized:
                "Save was not confirmed. Current disk values are shown; change a setting to save again."
            )
          } catch {
            loaded = false
            display(current)
            present(saveError)
            status.stringValue = String(
              localized:
                "Save was not confirmed and stored preferences could not be read. Import a valid file or reset explicitly."
            )
          }
        } else {
          display(current)
          present(error)
          status.stringValue = String(localized: "Preferences were not changed.")
        }
      }
      setBusy(false)
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    for (terms, row) in rows {
      row.isHidden = !query.isEmpty && !terms.localizedCaseInsensitiveContains(query)
    }
  }

  @objc private func importPreferences() {
    guard let window, !busy else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.setBusy(true)
      let store = self.store
      Task { @MainActor in
        do {
          let settings = try await Task.detached {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            return try store.importData(data)
          }.value
          self.setBusy(false)
          self.persist(settings)
        } catch {
          self.setBusy(false)
          self.present(error)
        }
      }
    }
  }

  @objc private func exportPreferences() {
    guard let window, loaded, !busy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = AppIdentity.name + "-preferences.json"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.setBusy(true)
      let settings = self.current
      let store = self.store
      Task { @MainActor in
        do {
          try await Task.detached {
            try store.exportData(settings).write(to: url, options: .atomic)
          }.value
          self.status.stringValue = String(localized: "Preferences exported.")
        } catch { self.present(error) }
        self.setBusy(false)
      }
    }
  }

  @objc private func resetPreferences() {
    guard let window, !busy else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Reset preferences?")
    alert.informativeText = String(
      localized:
        "Restore the default appearance, font, wrapping and tab width. Documents will not be changed."
    )
    alert.addButton(withTitle: String(localized: "Reset"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { self?.persist(.defaults) }
    }
  }

  private func present(_ error: Error) {
    if let window, window.isVisible {
      NSAlert(error: error).beginSheetModal(for: window)
    } else {
      status.stringValue = error.localizedDescription
    }
  }
}
