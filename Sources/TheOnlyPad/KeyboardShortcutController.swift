import AppKit
import PadCore

@MainActor
final class KeyboardShortcutController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate, NSSearchFieldDelegate
{
  private var snapshot: ShortcutEditorSnapshot
  private let actions: ShortcutEditorActions
  private(set) var draft: ShortcutProfile
  private var baseline: ShortcutProfile
  private var baselineRevision: UUID
  private var updateGeneration = UUID()
  private var semanticGeneration = UUID()
  private var draftGeneration = UUID()
  private var operationID: UUID?
  private var closed = false
  private var stale = false
  private var message = ""
  private var rows: [String] = []
  private var selectedID: String?
  private var composition: ShortcutComposition?
  private var recordContext: (String, UUID)?
  private let search = NSSearchField()
  private let table = NSTableView()
  private let reason = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 72))
  private let selected = NSTextField(labelWithString: "Choose a command")
  private let recorder = ShortcutRecorderView()
  private var buttons: [String: NSButton] = [:]
  var onClose: (() -> Void)?
  var isBusy: Bool { operationID != nil }
  init(snapshot: ShortcutEditorSnapshot, actions: ShortcutEditorActions) {
    self.snapshot = snapshot
    self.actions = actions
    draft = snapshot.profile
    baseline = snapshot.profile
    baselineRevision = snapshot.profileRevision
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 850, height: 640),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Keyboard Shortcuts"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 650, height: 500)
    super.init(window: window)
    window.delegate = self
    build()
    window.initialFirstResponder = search
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("Use init") }
  private func build() {
    guard let content = window?.contentView else { return }
    search.placeholderString = "Search commands"
    search.delegate = self
    search.setAccessibilityIdentifier("shortcuts.search")
    search.setAccessibilityLabel("Search keyboard shortcut commands")
    for (id, title, width) in [
      ("command", "Command", 400.0), ("shortcut", "Shortcut", 150.0), ("kind", "Assignment", 180.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.dataSource = self
    table.delegate = self
    table.allowsMultipleSelection = false
    table.setAccessibilityIdentifier("shortcuts.commands")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.sizeToFit()
    scroll.documentView = table
    reason.setAccessibilityIdentifier("shortcuts.reason")
    status.setAccessibilityIdentifier("shortcuts.status")
    status.isEditable = false
    status.isSelectable = true
    status.isRichText = false
    status.font = .systemFont(ofSize: 13)
    status.drawsBackground = false
    status.minSize = .zero
    status.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    status.isVerticallyResizable = true
    status.isHorizontallyResizable = false
    status.autoresizingMask = [.width]
    status.textContainer?.widthTracksTextView = true
    let statusScroll = NSScrollView()
    statusScroll.hasVerticalScroller = true
    statusScroll.documentView = status
    statusScroll.setAccessibilityLabel("Shortcut conflicts and storage status")
    statusScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
    selected.setAccessibilityIdentifier("shortcuts.selection")
    let edits = NSStackView(views: [
      button("record", "Record", #selector(recordShortcut(_:))),
      button("disable", "Disable", #selector(disableSelected(_:))),
      button("inherit", "Use Default", #selector(inheritSelected(_:))), recorder,
    ])
    edits.orientation = .horizontal
    let recoveryRow = NSStackView(views: [
      button("recovery", "Recover", #selector(recoverOwner(_:)))
    ])
    let filesRow = NSStackView(views: [
      button("import", "Import…", #selector(importDraft(_:))),
      button("export", "Export…", #selector(exportDraft(_:))),
      button("reset", "Restore Defaults", #selector(resetDraft(_:))),
    ])
    let footer = NSStackView(views: [
      button("reload", "Reload Current", #selector(reloadCurrent(_:))),
      button("cancel", "Cancel", #selector(cancelDraft(_:))),
      button("apply", "Apply", #selector(applyDraft(_:))),
    ])
    let stack = NSStackView(views: [
      search, scroll, selected, reason, edits, statusScroll, recoveryRow, filesRow, footer,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
      search.widthAnchor.constraint(equalTo: stack.widthAnchor),
      statusScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      reason.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    recorder.onCaptured = { [weak self] shortcut in
      guard let self, let (id, generation) = self.recordContext, self.selectedID == id,
        self.draftGeneration == generation
      else { return }
      self.recordContext = nil
      self.setAssignment(.assigned(shortcut), for: id)
    }
    recorder.onCancel = { [weak self] in
      self?.recordContext = nil
      self?.refresh()
    }
    recorder.onError = { [weak self] error in
      guard let self, !self.closed else { return }
      self.message = error.localizedDescription
      self.refresh()
    }
  }
  private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.setAccessibilityIdentifier("shortcuts.\(id)")
    buttons[id] = b
    return b
  }
  private func title(_ id: String) -> String {
    snapshot.catalog.first { $0.id == id }?.title ?? "Unavailable command (\(id))"
  }
  private func assignment(_ id: String) -> ShortcutAssignment? {
    draft.records.first { $0.commandID == id }?.assignment
  }
  private func shortcut(_ id: String) -> KeyboardShortcut? {
    if let assignment = assignment(id) {
      if case .assigned(let value) = assignment { return value }
      return nil
    }
    return snapshot.catalog.first { $0.id == id }?.shortcut.flatMap {
      try? KeyboardShortcut(canonicalString: $0)
    }
  }
  private func equal(_ a: ShortcutProfile, _ b: ShortcutProfile) -> Bool {
    a.records.sorted { $0.commandID < $1.commandID }
      == b.records.sorted { $0.commandID < $1.commandID }
  }
  private var dirty: Bool { !equal(draft, baseline) }
  private func refresh() {
    guard !closed else { return }
    var explanations: [String] = []
    if let persistent = snapshot.status, !persistent.isEmpty { explanations.append(persistent) }
    if stale {
      explanations.append(
        "Shortcut settings changed elsewhere. Your draft is preserved. Reload Current before applying."
      )
    }
    do {
      composition = try ShortcutComposer.build(
        catalog: snapshot.catalog, profile: draft, catalogRevision: snapshot.catalogRevision)
      for conflict in composition!.conflicts.prefix(20) {
        let names = conflict.commandIDs.map(title).joined(separator: " and ")
        switch conflict.reason {
        case .collision:
          explanations.append(
            "\(names) both use \(NativeKeyboardShortcut.display(conflict.shortcut)). Change one assignment."
          )
        case .reserved:
          explanations.append(
            "\(names): \(NativeKeyboardShortcut.display(conflict.shortcut)) is reserved by the system or application."
          )
        case .protectedCommand:
          explanations.append(
            "\(names) is a standard system editing shortcut and cannot be changed.")
        }
      }
      if composition!.conflicts.count > 20 {
        explanations.append("More conflicts remain. Review the other assignments.")
      }
    } catch {
      composition = nil
      explanations.append(
        "The command catalog could not be validated. Reload the current commands.")
    }
    if !message.isEmpty { explanations.append(message) }
    if isBusy { explanations.append("Working…") }
    status.string = explanations.joined(separator: "\n")
    let all =
      snapshot.catalog.map(\.id)
      + draft.records.map(\.commandID).filter { id in !snapshot.catalog.contains { $0.id == id } }
    rows = all.filter {
      search.stringValue.isEmpty || title($0).localizedCaseInsensitiveContains(search.stringValue)
    }
    table.reloadData()
    if let selectedID, let index = rows.firstIndex(of: selectedID) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    let protected = selectedID.map { ShortcutPolicy.protectedCommands[$0] != nil } ?? false
    selected.stringValue =
      selectedID.map { "\(title($0)) — \(NativeKeyboardShortcut.display(shortcut($0)))" }
      ?? "Choose a command"
    reason.stringValue =
      protected
      ? "Standard system editing shortcut. This command is read-only."
      : (selectedID == nil
        ? "Choose a command to edit its draft assignment."
        : "Changes remain a draft until Apply. Unavailable commands are retained but cannot execute.")
    for (id, b) in buttons { b.isEnabled = id == "cancel" || !isBusy }
    for id in ["record", "disable", "inherit"] {
      buttons[id]?.isEnabled = !isBusy && selectedID != nil && !protected
    }
    buttons["apply"]?.isEnabled =
      !isBusy && !stale && snapshot.canApply && dirty && composition?.conflicts.isEmpty == true
    buttons["reload"]?.isEnabled = !isBusy && (stale || dirty)
    buttons["recovery"]?.isHidden = snapshot.recoveryTitle == nil || actions.recover == nil
    buttons["recovery"]?.title = snapshot.recoveryTitle ?? "Recover"
    recorder.isHidden = recordContext == nil
    search.isEnabled = !isBusy
    table.isEnabled = !isBusy
  }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let id = rows[row]
    let value: String
    switch column?.identifier.rawValue {
    case "shortcut": value = NativeKeyboardShortcut.display(shortcut(id))
    case "kind":
      value =
        ShortcutPolicy.protectedCommands[id] != nil
        ? "Standard (read-only)" : assignment(id) == nil ? "Default" : "Custom"
    default: value = title(id)
    }
    return NSTextField(labelWithString: value)
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !closed else { return }
    let id = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    guard selectedID != id else { return }
    recorder.stop()
    recordContext = nil
    selectedID = id
    refresh()
  }
  func controlTextDidChange(_ notification: Notification) {
    guard !isBusy, !closed else { return }
    recorder.stop()
    recordContext = nil
    refresh()
  }
  func setAssignment(_ assignment: ShortcutAssignment?, for id: String) {
    guard !closed, !isBusy, ShortcutPolicy.protectedCommands[id] == nil,
      snapshot.catalog.contains(where: { $0.id == id })
        || draft.records.contains(where: { $0.commandID == id })
    else { return }
    var records = draft.records.filter { $0.commandID != id }
    if let assignment { records.append(ShortcutOverride(commandID: id, assignment: assignment)) }
    do {
      draft = try ShortcutProfile(records: records)
      draftGeneration = UUID()
      message = ""
      refresh()
    } catch {
      message = "This draft exceeds the supported shortcut profile limits."
      refresh()
    }
  }
  func update(_ value: ShortcutEditorSnapshot) {
    guard !closed else { return }
    recorder.stop()
    recordContext = nil
    updateGeneration = UUID()
    if value.catalogRevision != snapshot.catalogRevision
      || value.profileRevision != snapshot.profileRevision
    {
      semanticGeneration = UUID()
    }
    if value.profileRevision != baselineRevision {
      if dirty {
        stale = true
      } else {
        draft = value.profile
        baseline = value.profile
        baselineRevision = value.profileRevision
        stale = false
      }
    }
    snapshot = value
    refresh()
  }
  @objc private func recordShortcut(_ sender: Any?) {
    guard !closed, !isBusy, let id = selectedID, ShortcutPolicy.protectedCommands[id] == nil else {
      return
    }
    recordContext = (id, draftGeneration)
    recorder.isHidden = false
    if !recorder.start() {
      recordContext = nil
      message = "Activate this window to record a shortcut."
      refresh()
    }
  }
  @objc private func disableSelected(_ sender: Any?) {
    if let selectedID { setAssignment(.disabled, for: selectedID) }
  }
  @objc private func inheritSelected(_ sender: Any?) {
    if let selectedID { setAssignment(nil, for: selectedID) }
  }
  @objc private func resetDraft(_ sender: Any?) {
    guard !closed, !isBusy else { return }
    recorder.stop()
    recordContext = nil
    draft = .defaults
    draftGeneration = UUID()
    message = "Defaults are a draft. Apply to save them."
    refresh()
  }
  @objc private func reloadCurrent(_ sender: Any?) {
    guard !closed, !isBusy else { return }
    recorder.stop()
    recordContext = nil
    draft = snapshot.profile
    baseline = snapshot.profile
    baselineRevision = snapshot.profileRevision
    stale = false
    message = ""
    draftGeneration = UUID()
    refresh()
  }
  private enum ResultValue {
    case applied(ShortcutEditorSnapshot)
    case recovered(ShortcutEditorSnapshot)
    case imported(ShortcutProfile?)
    case exported(Bool)
  }
  private func perform(
    submitted: ShortcutProfile? = nil, _ work: @escaping @MainActor () async throws -> ResultValue
  ) {
    guard !closed, !isBusy else { return }
    recorder.stop()
    recordContext = nil
    let id = UUID()
    let generation = updateGeneration
    let semantic = semanticGeneration
    operationID = id
    message = ""
    refresh()
    Task { [weak self] in
      let result: Result<ResultValue, Error>
      do { result = .success(try await work()) } catch { result = .failure(error) }
      guard let self, !self.closed, self.operationID == id else { return }
      self.operationID = nil
      // Errors belong to this authorized still-live operation even if a catalog
      // update occurred. Never hide an uncertain export/save behind that update.
      if case .failure(let error) = result {
        self.message = error.localizedDescription
        self.refresh()
        return
      }
      if self.semanticGeneration != semantic {
        let matchesLatest: Bool
        switch result {
        case .success(.applied(let value)):
          matchesLatest =
            submitted.map { self.equal($0, value.profile) } == true
            && value.profileRevision == self.snapshot.profileRevision
            && value.catalogRevision == self.snapshot.catalogRevision
            && self.equal(value.profile, self.snapshot.profile)
        case .success(.recovered(let value)):
          matchesLatest =
            value.profileRevision == self.snapshot.profileRevision
            && value.catalogRevision == self.snapshot.catalogRevision
            && self.equal(value.profile, self.snapshot.profile)
        default: matchesLatest = false
        }
        guard matchesLatest else {
          self.refresh()
          return
        }
      }
      switch result {
      case .failure(let error): self.message = error.localizedDescription
      case .success(.applied(let value)):
        // A matching receipt acknowledges our draft, but must not replace
        // newer owner busy/recovery/status fields published with that receipt.
        if self.updateGeneration == generation { self.snapshot = value }
        self.draft = value.profile
        self.baseline = value.profile
        self.baselineRevision = value.profileRevision
        self.stale = false
        self.message = "Shortcut settings saved."
      case .success(.recovered(let value)):
        self.update(self.updateGeneration == generation ? value : self.snapshot)
      case .success(.imported(let profile)):
        if let profile {
          self.draft = profile
          self.draftGeneration = UUID()
          self.message = "Imported into the draft. Review conflicts and Apply to save."
        }
      case .success(.exported(let saved)): if saved { self.message = "Shortcut profile exported." }
      }
      self.refresh()
    }
  }
  @objc func applyDraft(_ sender: Any?) {
    guard !closed, !isBusy, !stale, snapshot.canApply, dirty, composition?.conflicts.isEmpty == true
    else { return }
    let profile = draft
    let cat = snapshot.catalogRevision
    let revision = baselineRevision
    let apply = actions.apply
    perform(submitted: profile) { .applied(try await apply(profile, cat, revision)) }
  }
  @objc private func recoverOwner(_ sender: Any?) {
    guard let action = actions.recover else { return }
    perform { .recovered(try await action()) }
  }
  @objc private func importDraft(_ sender: Any?) {
    let action = actions.importProfile
    perform { .imported(try await action()) }
  }
  @objc private func exportDraft(_ sender: Any?) {
    let action = actions.exportProfile
    let profile = draft
    perform { .exported(try await action(profile)) }
  }
  @objc func cancelDraft(_ sender: Any?) {
    retire()
    window?.close()
  }
  private func retire() {
    guard !closed else { return }
    closed = true
    operationID = nil
    recorder.stop()
    recordContext = nil
    onClose?()
  }
  func windowWillClose(_ notification: Notification) { retire() }
}
