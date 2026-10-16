// SPDX-License-Identifier: MIT
import AppKit
import PadCore

@MainActor private final class LanguageManagerWindow: NSWindow {
  var beforeClose: (@MainActor () -> Void)?
  private var requestingClose = false
  private var committed = false
  override func close() {
    guard !requestingClose, !committed else { return }
    requestingClose = true
    beforeClose?()
    // Refusal restores the guard; a later clean Close must remain usable.
    requestingClose = false
  }
  override func cancelOperation(_ sender: Any?) { close() }
  fileprivate func commitClose() {
    guard !committed else { return }
    committed = true
    beforeClose = nil
    super.close()
  }
}

/// One catalog presentation and a bounded local draft; App owns the sole catalog observer.
@MainActor
final class NativeLanguageManagerController: NSWindowController,
  NSTableViewDataSource, NSTableViewDelegate
{
  private let session: NativeLanguageManagerSession
  private var onRetire: (@MainActor (NativeLanguageManagerController) -> Void)?
  private var retired = false
  private enum Installation: Equatable { case candidate, installed }
  private var installation: Installation = .candidate
  private var renderedDeliveryID: UUID?
  private var renderedViewID: UUID?
  private var restoringSelection = false
  private var rowTargets: [NativeLanguageManagerTarget] = []
  private var rowNames: [String] = []
  private var definitionEditor: NativeLanguageDefinitionEditorController?
  private let newDefinitionButton = NSButton(title: "New", target: nil, action: nil)
  private let editDefinitionButton = NSButton(title: "Edit", target: nil, action: nil)
  private let deleteDefinitionButton = NSButton(title: "Delete", target: nil, action: nil)
  private let revertDefinitionButton = NSButton(title: "Revert Change", target: nil, action: nil)
  private let saveDraftButton = NSButton(title: "Save", target: nil, action: nil)
  private let discardDraftButton = NSButton(title: "Discard Draft", target: nil, action: nil)
  private let builtInPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let editBuiltInButton = NSButton(
    title: "Edit Built-in Override", target: nil, action: nil)
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
    panel.beforeClose = { [weak self] in self?.close() }

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
    builtInPopup.addItems(withTitles: DocumentLanguage.allCases.map(\.rawValue))
    let builtInControls = NSStackView(views: [builtInPopup, editBuiltInButton])
    stack.addArrangedSubview(builtInControls)
    editBuiltInButton.target = self
    editBuiltInButton.action = #selector(editBuiltIn(_:))
    let editButtons = NSStackView(views: [
      newDefinitionButton, editDefinitionButton,
      deleteDefinitionButton, revertDefinitionButton, saveDraftButton, discardDraftButton,
    ])
    editButtons.spacing = 8
    stack.addArrangedSubview(editButtons)
    for (button, action) in [
      (newDefinitionButton, #selector(newDefinition(_:))),
      (editDefinitionButton, #selector(editDefinition(_:))),
      (deleteDefinitionButton, #selector(deleteDefinition(_:))),
      (revertDefinitionButton, #selector(revertDefinition(_:))),
      (saveDraftButton, #selector(saveDraft(_:))),
      (discardDraftButton, #selector(discardDraft(_:))),
    ] {
      button.target = self
      button.action = action
    }
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

  /// App transitions the exact still-live construction candidate before installing its slot.
  /// This transition can only narrow close admission; it cannot reopen candidate cleanup.
  func installPresentation(for originalSession: NativeLanguageManagerSession) -> Bool {
    guard !retired, installation == .candidate, session === originalSession,
      session.isUninstalledPresentation
    else { return false }
    installation = .installed
    return true
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

  /// Captured around a native field-editor callout by App's quit admission.
  struct DepartureFrame: Equatable {
    let deliveryID: UUID?
    let draftID: UUID?
    let epoch: UUID?
    let viewID: UUID?
    let formID: UUID?
  }
  var departureFrame: DepartureFrame {
    let state = session.editState
    return .init(
      deliveryID: session.snapshot?.deliveryID, draftID: state?.draftID,
      epoch: state?.rawEpoch, viewID: state?.viewID, formID: state?.activeForm?.handle.id)
  }
  var canDepart: Bool { !retired && session.canDepart }
  func flushForDeparture() -> Bool {
    guard !retired, let window else { return false }
    let frame = departureFrame
    if let field = window.firstResponder as? NSTextView, field.hasMarkedText() { return false }
    guard window.makeFirstResponder(nil), !retired, session.isAttached,
      departureFrame == frame
    else { return false }
    // Any active child is independently a departure veto, even after a successful Save.
    return session.canDepart
  }
  func explainDepartureVeto() {
    guard !retired, session.isAttached else { return }
    statusField.stringValue =
      "Finish or discard the open form, then Save or Discard Draft before closing."
  }
  override func close() {
    guard !retired else { return }
    if installation == .candidate, session.isUninstalledPresentation {
      // Constructor reentry may reject this never-installed candidate. It has no local work
      // and no App delivery; retire only its own callback/session/window, exactly once.
      retire()
      commitNativeClose()
      return
    }
    let frame = departureFrame
    guard flushForDeparture(), !retired, departureFrame == frame, session.canDepart else {
      explainDepartureVeto()
      return
    }
    // Admission precedes retirement. No second attached/current test after our own detach.
    retire()
    commitNativeClose()
  }
  func closeAfterCommittedRetirement(_ receipt: LanguageManagerCommittedRetirement) {
    guard !retired, receipt.consume(for: self, session: session) else { return }
    retired = true
    onRetire = nil
    commitNativeClose()
  }
  private func commitNativeClose() {
    let child = definitionEditor
    definitionEditor = nil
    tableView.delegate = nil
    tableView.dataSource = nil
    child?.retire()
    (window as? LanguageManagerWindow)?.commitClose()
  }

  override func showWindow(_ sender: Any?) {
    guard !retired, session.isAttached else { return }
    super.showWindow(sender)
    if !retired { definitionEditor?.showWindow(sender) }
  }

  @objc private func refresh(_ sender: NSButton) {
    guard flushAction() else { return }
    if case .unavailable = session.requestRefresh() {
      explainDepartureVeto()
    }
  }

  @objc private func closePanel(_ sender: NSButton) { close() }

  func numberOfRows(in tableView: NSTableView) -> Int { rowTargets.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let id = renderedDeliveryID, canRender(id, view: renderedViewID),
      rowNames.indices.contains(row)
    else { return nil }
    let view = renderedViewID
    let name = rowNames[row]
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
    guard canRender(id, view: view) else { return nil }
    cell.textField?.stringValue = name
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !restoringSelection, let id = renderedDeliveryID, canRender(id) else { return }
    let row = tableView.selectedRow
    let target = rowTargets.indices.contains(row) ? rowTargets[row] : nil
    if case .definition(let definitionID)? = target {
      selectedDefinition = renderedDefinitions.first { $0.id == definitionID }
    } else {
      selectedDefinition = nil
    }
    session.select(target)
    if canRender(id) { renderDetails(id) }
  }

  private func canRender(_ id: UUID) -> Bool {
    !retired && session.isCurrentDelivery(id)
  }
  private func canRender(_ id: UUID, view: UUID?) -> Bool {
    canRender(id) && session.editState?.viewID == view
  }

  private func render(_ snapshot: NativeLanguageManagerCatalogSnapshot) {
    let id = snapshot.deliveryID
    guard canRender(id) else { return }
    let edit = session.editState
    let view = edit?.viewID
    let definitions = snapshot.read.current?.catalog.definitions ?? []
    // The inspector remains confirmed and read-only, including while the staged rows differ.
    renderedDeliveryID = id
    renderedViewID = view
    renderedDefinitions = definitions
    renderedOverrides = snapshot.read.current?.catalog.overrides ?? []
    let previousSelection = selectedDefinition?.id
    var targets: [NativeLanguageManagerTarget] = []
    var names: [String] = []
    if let edit {
      for raw in edit.definitions {
        targets.append(.definition(raw.id))
        let installed = definitions.first { $0.id == raw.id }
        let changed = session.isChanged(.definition(raw.id))
        let suffix = installed == nil ? " (added, unsaved)" : (changed ? " (changed, unsaved)" : "")
        names.append(raw.name + suffix)
      }
      for deleted in session.deletedDefinitions {
        targets.append(.definition(deleted.id))
        names.append(deleted.name + " (deleted, unsaved)")
      }
    } else {
      targets = definitions.map { .definition($0.id) }
      names = definitions.map(\.name)
    }
    let target =
      edit?.selectedTarget ?? previousSelection.map { NativeLanguageManagerTarget.definition($0) }
    rowTargets = targets
    rowNames = names
    restoringSelection = true
    tableView.reloadData()
    guard canRender(id, view: view) else {
      restoringSelection = false
      return
    }
    if let target, let row = targets.firstIndex(of: target) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(nil)
    }
    restoringSelection = false
    guard canRender(id, view: view) else { return }
    if case .definition(let selectedID)? = target {
      selectedDefinition = definitions.first { $0.id == selectedID }
    } else {
      selectedDefinition = nil
    }
    renderDetails(id)
    guard canRender(id, view: view) else { return }
    overrideTextView.string =
      renderedOverrides.isEmpty
      ? "No built-in language overrides."
      : renderedOverrides.map { Self.overrideText($0) }.joined(separator: "\n")
    guard canRender(id, view: view) else { return }
    statusField.stringValue = Self.statusText(snapshot) + draftStatus(edit)
    guard canRender(id, view: view) else { return }
    let mutation = snapshot.mutation
    let active: Bool
    if case .active = snapshot.read.lifetime { active = true } else { active = false }
    let writable = active && mutation.preparedQuitID == nil && edit != nil
    refreshButton.isEnabled =
      active && mutation.activeOperation == nil
      && mutation.preparedQuitID == nil && mutation.unresolved == nil
      && edit?.isDirty != true && edit?.isStale != true && edit?.activeForm == nil
    guard canRender(id, view: view) else { return }
    newDefinitionButton.isEnabled = writable && edit?.activeForm == nil
    guard canRender(id, view: view) else { return }
    editDefinitionButton.isEnabled = writable && target != nil && edit?.activeForm == nil
    guard canRender(id, view: view) else { return }
    deleteDefinitionButton.isEnabled =
      writable && edit?.activeForm == nil
      && {
        if case .definition(let selectedID)? = target {
          return edit?.definitions.contains { $0.id == selectedID } == true
        }
        return false
      }()
    guard canRender(id, view: view) else { return }
    revertDefinitionButton.isEnabled = writable && target != nil && edit?.activeForm == nil
    guard canRender(id, view: view) else { return }
    saveDraftButton.isEnabled =
      writable && mutation.activeOperation == nil && mutation.unresolved == nil
      && edit?.isStale != true && edit?.saveOperationID == nil
    guard canRender(id, view: view) else { return }
    discardDraftButton.isEnabled =
      writable && edit?.activeForm == nil && mutation.activeOperation == nil
      && mutation.unresolved == nil && edit?.saveOperationID == nil
    guard canRender(id, view: view) else { return }
    editBuiltInButton.isEnabled = writable && edit?.activeForm == nil
    guard canRender(id, view: view) else { return }
    synchronizeEditor(edit?.activeForm, delivery: id, view: view)
  }
  private func draftStatus(_ edit: NativeLanguageManagerEditState?) -> String {
    guard let edit else { return " Editing is unavailable for catalogs beyond the UI bounds." }
    if edit.isStale { return " Local draft is stale; Discard Draft to use the current catalog." }
    if !edit.issues.isEmpty {
      return " Invalid raw fields are retained. Correct them before saving."
    }
    if edit.isDirty { return " Unsaved local changes." }
    return ""
  }
  private func synchronizeEditor(
    _ form: NativeLanguageManagerFormSnapshot?, delivery: UUID, view: UUID?
  ) {
    guard canRender(delivery, view: view) else { return }
    if let form {
      if definitionEditor?.matches(form.handle) != true {
        let old = definitionEditor
        definitionEditor = nil
        old?.retire()
        guard canRender(delivery, view: view), session.editState?.activeForm?.handle === form.handle
        else { return }
        let candidate = NativeLanguageDefinitionEditorController(
          handle: form.handle, session: session)
        guard canRender(delivery, view: view),
          session.editState?.activeForm?.handle === form.handle,
          definitionEditor == nil
        else {
          candidate.retire()
          return
        }
        definitionEditor = candidate
        if let parent = window, let child = candidate.window {
          parent.addChildWindow(child, ordered: .above)
        }
        guard canRender(delivery, view: view), definitionEditor === candidate,
          session.editState?.activeForm?.handle === form.handle
        else { return }
        candidate.render(form.raw)
        guard canRender(delivery, view: view), definitionEditor === candidate else { return }
        if window?.isVisible == true { candidate.showWindow(nil) }
      } else {
        definitionEditor?.render(form.raw)
      }
    } else if let previous = definitionEditor {
      definitionEditor = nil
      previous.retire()
    }
  }

  private func flushAction() -> Bool {
    guard !retired, session.isAttached else { return false }
    if let definitionEditor { return definitionEditor.flush() }
    guard let window else { return false }
    let frame = departureFrame
    if let field = window.firstResponder as? NSTextView, field.hasMarkedText() { return false }
    return window.makeFirstResponder(nil) && !retired && session.isAttached
      && departureFrame == frame
  }
  @objc private func newDefinition(_ sender: NSButton) {
    guard flushAction() else { return }
    if case .refused(let reason) = session.beginNewDefinition() { explain(reason) }
  }
  @objc private func editDefinition(_ sender: NSButton) {
    guard flushAction(), let state = session.editState, let target = state.selectedTarget else {
      return
    }
    if case .refused(let reason) = session.beginEdit(
      target: target,
      expectedDraftID: state.draftID, expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }
  @objc private func editBuiltIn(_ sender: NSButton) {
    let index = builtInPopup.indexOfSelectedItem
    guard DocumentLanguage.allCases.indices.contains(index), flushAction(),
      let state = session.editState
    else { return }
    if case .refused(let reason) = session.beginEdit(
      target: .builtIn(DocumentLanguage.allCases[index]),
      expectedDraftID: state.draftID, expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }
  @objc private func deleteDefinition(_ sender: NSButton) {
    guard flushAction(), let state = session.editState,
      case .definition(let id)? = state.selectedTarget
    else { return }
    if case .refused(let reason) = session.stageDelete(
      profileID: id,
      expectedDraftID: state.draftID, expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }
  @objc private func revertDefinition(_ sender: NSButton) {
    guard flushAction(), let state = session.editState, let target = state.selectedTarget else {
      return
    }
    if case .refused(let reason) = session.revertChange(
      target: target,
      expectedDraftID: state.draftID, expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }
  @objc private func saveDraft(_ sender: NSButton) {
    guard flushAction(), let state = session.editState else { return }
    if case .refused(let reason) = session.requestSave(
      expectedDraftID: state.draftID,
      expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }
  @objc private func discardDraft(_ sender: NSButton) {
    guard flushAction(), let state = session.editState else { return }
    if case .refused(let reason) = session.discardDraft(
      expectedDraftID: state.draftID,
      expectedEpoch: state.rawEpoch)
    {
      explain(reason)
    }
  }

  private func explain(_ refusal: NativeLanguageManagerEditRefusal) {
    guard !retired, let snapshot = session.snapshot, session.isCurrentDelivery(snapshot.deliveryID)
    else { return }
    let message: String
    switch refusal {
    case .boundExceeded:
      message =
        "The local draft exceeds a language, list, quote or text limit. Existing input is retained."
    case .invalid: message = "Correct the invalid fields before saving. Raw input is retained."
    case .formInProgress:
      message = "Finish or discard the current form before changing another language."
    case .staleBase:
      message = "The catalog changed. Discard Draft to start from its confirmed current version."
    case .busy: message = "Wait for the current catalog operation. Newer raw input is retained."
    case .catalog:
      message = "The catalog is reserved, busy or has an unresolved change. The draft is retained."
    case .wrongDraft, .wrongEpoch:
      message = "The draft changed during this action. Try the action again."
    case .noWriteReceipt:
      message = "No confirmed writable catalog is available. The draft is retained."
    case .detached, .unavailable:
      message = "Editing is currently unavailable. Existing input is retained."
    }
    statusField.stringValue = message
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
