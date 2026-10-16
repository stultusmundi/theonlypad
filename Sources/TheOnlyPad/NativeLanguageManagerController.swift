// SPDX-License-Identifier: MIT
import AppKit
import PadCore

@MainActor private final class LanguageManagerWindow: NSWindow {
  var beforeClose: (@MainActor () -> Void)?
  private var closing = false

  override func close() {
    guard !closing else { return }
    closing = true
    let callback = beforeClose
    beforeClose = nil
    callback?()
    super.close()
  }
}

/// Read-only catalog presentation. No Store, task, document or mutation authority lives here.
@MainActor
final class NativeLanguageManagerController: NSWindowController,
  NSTableViewDataSource, NSTableViewDelegate
{
  private let session: NativeLanguageManagerSession
  private var onRetire: (@MainActor (NativeLanguageManagerController) -> Void)?
  private var retired = false
  private var renderedDeliveryID: UUID?
  private let tableView = NSTableView()
  private let detailTextView = NSTextView()
  private let overrideTextView = NSTextView()
  private let statusField = NSTextField(wrappingLabelWithString: "Catalog has not been loaded.")
  private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
  private let closeButton = NSButton(title: "Close", target: nil, action: nil)
  private var renderedDefinitions: [LiteralLanguageDefinition] = []
  private var renderedOverrides: [BuiltInLanguageOverride] = []
  private var selectedDefinition: LiteralLanguageDefinition?

  init(
    session: NativeLanguageManagerSession,
    onRetire: @escaping @MainActor (NativeLanguageManagerController) -> Void
  ) {
    self.session = session
    self.onRetire = onRetire
    let panel = LanguageManagerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Custom Languages"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 640, height: 650)
    panel.beforeClose = { [weak self] in self?.retire() }

    let content = NSView()
    panel.contentView = content
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
    stack.addArrangedSubview(NSTextField(labelWithString: "Custom language definitions"))
    stack.addArrangedSubview(statusField)
    statusField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("language.name"))
    column.title = "Name"
    column.width = 700
    tableView.addTableColumn(column)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = true
    let tableScroll = NSScrollView()
    tableScroll.documentView = tableView
    tableScroll.hasVerticalScroller = true
    tableScroll.borderType = .bezelBorder
    stack.addArrangedSubview(tableScroll)
    tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    stack.addArrangedSubview(NSTextField(labelWithString: "Selected definition"))
    let detailScroll = Self.readOnlyScroll(detailTextView)
    stack.addArrangedSubview(detailScroll)
    detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    stack.addArrangedSubview(NSTextField(labelWithString: "Built-in language overrides"))
    let overrideScroll = Self.readOnlyScroll(overrideTextView)
    stack.addArrangedSubview(overrideScroll)
    overrideScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    overrideScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 75).isActive = true
    let buttons = NSStackView(views: [refreshButton, closeButton])
    buttons.spacing = 10
    stack.addArrangedSubview(buttons)
    refreshButton.target = self
    refreshButton.action = #selector(refresh(_:))
    closeButton.target = self
    closeButton.action = #selector(closePanel(_:))
    closeButton.keyEquivalent = "\u{1b}"
    for (view, id, label) in [
      (tableView as NSView, "languages.definitions", "Custom language definitions"),
      (detailTextView, "languages.details", "Selected language details"),
      (overrideTextView, "languages.overrides", "Built-in language overrides"),
      (statusField, "languages.status", "Language catalog status"),
      (refreshButton, "languages.refresh", "Refresh language catalog"),
      (closeButton, "languages.close", "Close language catalog"),
    ] {
      view.setAccessibilityIdentifier(id)
      view.setAccessibilityLabel(label)
    }
    session.onChange = { [weak self] snapshot in self?.render(snapshot) }
  }

  required init?(coder: NSCoder) { nil }

  private static func readOnlyScroll(_ text: NSTextView) -> NSScrollView {
    text.isEditable = false
    text.isRichText = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainerInset = NSSize(width: 6, height: 6)
    text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 160))
    text.frame = scroll.contentView.bounds
    text.minSize = .zero
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
  }

  private func retire() {
    guard !retired else { return }
    retired = true
    let callback = onRetire
    onRetire = nil
    // App clears its exact slot before detach releases observers or native close notifications.
    callback?(self)
    session.detach()
  }

  override func close() {
    guard !retired else { return }
    retire()
    super.close()
  }

  override func showWindow(_ sender: Any?) {
    guard !retired, session.isAttached else { return }
    super.showWindow(sender)
  }

  @objc private func refresh(_ sender: NSButton) {
    guard !retired else { return }
    _ = session.requestRefresh()
  }

  @objc private func closePanel(_ sender: NSButton) { close() }

  func numberOfRows(in tableView: NSTableView) -> Int { renderedDefinitions.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let id = renderedDeliveryID, canRender(id),
      renderedDefinitions.indices.contains(row)
    else { return nil }
    let definition = renderedDefinitions[row]
    let identifier = NSUserInterfaceItemIdentifier("language.name.cell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? NSTableCellView()
    if cell.textField == nil {
      cell.identifier = identifier
      let field = NSTextField(labelWithString: "")
      field.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(field)
      cell.textField = field
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
    }
    guard canRender(id) else { return nil }
    cell.textField?.stringValue = definition.name
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let id = renderedDeliveryID, canRender(id) else { return }
    let row = tableView.selectedRow
    selectedDefinition = renderedDefinitions.indices.contains(row) ? renderedDefinitions[row] : nil
    renderDetails(id)
  }

  private func canRender(_ id: UUID) -> Bool {
    !retired && session.isCurrentDelivery(id)
  }

  private func render(_ snapshot: NativeLanguageManagerCatalogSnapshot) {
    let id = snapshot.deliveryID
    guard canRender(id) else { return }
    let definitions = snapshot.read.current?.catalog.definitions ?? []
    let selection = selectedDefinition.flatMap { previous in
      definitions.first { $0.id == previous.id }
    }
    renderedDeliveryID = id
    renderedDefinitions = definitions
    renderedOverrides = snapshot.read.current?.catalog.overrides ?? []
    selectedDefinition = selection
    tableView.reloadData()
    guard canRender(id) else { return }
    // reloadData may notify selection changes. Restore the captured UUID only in this delivery.
    selectedDefinition = selection
    if let selection, let row = definitions.firstIndex(where: { $0.id == selection.id }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
    guard canRender(id) else { return }
    renderDetails(id)
    guard canRender(id) else { return }
    overrideTextView.string =
      renderedOverrides.isEmpty
      ? "No built-in language overrides."
      : renderedOverrides.map { Self.overrideText($0) }.joined(separator: "\n")
    guard canRender(id) else { return }
    statusField.stringValue = Self.statusText(snapshot)
    guard canRender(id) else { return }
    let mutation = snapshot.mutation
    let active: Bool
    if case .active = snapshot.read.lifetime { active = true } else { active = false }
    refreshButton.isEnabled =
      active && mutation.activeOperation == nil
      && mutation.preparedQuitID == nil && mutation.unresolved == nil
  }

  private func renderDetails(_ id: UUID) {
    guard canRender(id) else { return }
    detailTextView.string =
      selectedDefinition.map { Self.definitionText($0) }
      ?? "Select a custom language to view its definition."
  }

  private static func statusText(_ snapshot: NativeLanguageManagerCatalogSnapshot) -> String {
    if case .invalidated = snapshot.read.lifetime { return "The language catalog is closed." }
    if snapshot.mutation.preparedQuitID != nil { return "Preparing to quit. Refresh is paused." }
    if let operation = snapshot.mutation.activeOperation {
      switch operation.kind {
      case .load: return "Loading the language catalog…"
      case .inspect: return "Inspecting the language catalog…"
      case .apply: return "Saving the language catalog…"
      case .repair: return "Repairing the language catalog…"
      case .verify: return "Verifying the pending catalog change…"
      case .retry, .retryFailedAttempt: return "Retrying the catalog change…"
      case .discardAndReload: return "Reloading after the confirmed discard…"
      }
    }
    if snapshot.mutation.unresolved != nil {
      return "An unresolved catalog change requires review. Refresh is unavailable."
    }
    if snapshot.read.failure != nil {
      return snapshot.read.current == nil
        ? "The language catalog could not be loaded. Refresh to try again."
        : "Refresh failed. Showing the last confirmed language catalog."
    }
    guard let catalog = snapshot.read.current?.catalog else {
      return "Catalog has not been loaded."
    }
    return
      "\(catalog.definitions.count) custom languages; \(catalog.overrides.count) built-in overrides."
  }

  private static func indentationText(_ value: LanguageIndentation) -> String {
    switch value {
    case .legacy: return "legacy"
    case .spaces(let width): return "spaces \(width)"
    case .tabs(let width): return "tabs \(width)"
    }
  }

  private static func definitionText(_ value: LiteralLanguageDefinition) -> String {
    var lines = [
      "Name: \(value.name)", "ID: \(value.id.uuidString)",
      "Extensions: \(value.fileExtensions.joined(separator: ", "))",
      "Keywords: \(value.keywords.joined(separator: ", "))",
      "Line comment: \(value.lineComment ?? "none")",
      "Block comment: \(value.blockComment.map { "\($0.opening) → \($0.closing)" } ?? "none")",
    ]
    if value.quotes.isEmpty {
      lines.append("Quotes: none")
    } else {
      lines.append("Quotes:")
      for quote in value.quotes {
        lines.append(
          "  \(quote.opening) → \(quote.closing); escape: \(quote.escape ?? "none"); multiline: \(quote.multiline ? "yes" : "no")"
        )
      }
    }
    lines.append("Decimal numbers: \(value.highlightDecimalNumbers ? "yes" : "no")")
    lines.append("Indentation: \(indentationText(value.indentation))")
    return lines.joined(separator: "\n")
  }

  private static func overrideText(_ value: BuiltInLanguageOverride) -> String {
    let line: String
    switch value.lineComment {
    case .inherit: line = "inherited"
    case .disabled: line = "disabled"
    case .literal(let text): line = text
    }
    let block: String
    switch value.blockComment {
    case .inherit: block = "inherited"
    case .disabled: block = "disabled"
    case .literal(let delimiters): block = "\(delimiters.opening) → \(delimiters.closing)"
    }
    return
      "\(value.language.rawValue): line comment \(line); block comment \(block); indentation \(indentationText(value.indentation))"
  }
}
