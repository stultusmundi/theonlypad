// Read-only native preview of a bounded explicit selected set of saved files.
import AppKit
import PadCore

enum FolderReplacementPreviewChooserKind: Equatable { case folder, files }

@MainActor
protocol FolderReplacementPreviewChoosing: AnyObject {
  func begin(
    kind: FolderReplacementPreviewChooserKind, seed: URL?, owner: NSWindow,
    completion: @escaping @MainActor ([URL]?) -> Void
  ) throws -> UUID
  func cancel(requestID: UUID)
}

@MainActor
private final class FolderReplacementPreviewNativeChooser: FolderReplacementPreviewChoosing {
  private var panels: [UUID: NSOpenPanel] = [:]

  func begin(
    kind: FolderReplacementPreviewChooserKind, seed: URL?, owner: NSWindow,
    completion: @escaping @MainActor ([URL]?) -> Void
  ) throws -> UUID {
    let id = UUID()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = kind == .folder
    panel.canChooseFiles = kind == .files
    panel.allowsMultipleSelection = kind == .files
    panel.resolvesAliases = false
    panel.directoryURL = seed
    panel.prompt = kind == .folder ? "Choose Folder" : "Choose Files"
    panel.message =
      kind == .folder
      ? "Choose the folder containing the saved files to preview."
      : "Choose 1 or 2 saved regular UTF-8 files. Changes are not applied."
    // Own the exact panel before entering the SDK; completion may reenter its recipient.
    panels[id] = panel
    panel.beginSheetModal(for: owner) { [weak self] response in
      guard let self, self.panels[id] === panel else { return }
      self.panels.removeValue(forKey: id)
      completion(response == .OK ? panel.urls : nil)
    }
    return id
  }

  func cancel(requestID: UUID) {
    guard let panel = panels.removeValue(forKey: requestID) else { return }
    panel.cancel(nil)
  }
}

@MainActor
enum FolderReplacementPreviewComposition {
  static let lane = FolderReplacementPreviewWorkLane()
}

@MainActor
final class FolderReplacementPreviewController: NSWindowController, NSWindowDelegate,
  NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate
{
  let patternView = NSTextView()
  let replacementView = NSTextView()
  let originalView = NSTextView()
  let proposedView = NSTextView()
  let caseButton = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
  let wholeWordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
  let chooseFolderButton = NSButton(title: "Choose Folder…", target: nil, action: nil)
  let chooseFilesButton = NSButton(title: "Choose Files…", target: nil, action: nil)
  let previewButton = NSButton(title: "Preview", target: nil, action: nil)
  let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  let closeButton = NSButton(title: "Close", target: nil, action: nil)
  let instructionLabel = NSTextField(
    wrappingLabelWithString:
      "Preview saved files only. Choose 1–2 regular UTF-8 files in this folder. Each original/proposed file is limited to 1 MiB; at most 1000 matches. Changes are not applied."
  )
  let statusLabel = NSTextField(wrappingLabelWithString: "Ready")
  let summaryLabel = NSTextField(wrappingLabelWithString: "")
  let excerptLabel = NSTextField(wrappingLabelWithString: "")
  let selectedFilesTable = NSTableView()
  let resultsTable = NSTableView()
  private let folderLabel = NSTextField(labelWithString: "Choose a folder")
  private(set) var rootURL: URL?
  private(set) var selectedURLs: [URL] = []
  private(set) var display: FolderReplacementPreviewDisplay?
  private let state = FolderReplacementPreviewWorkState()
  var phase: FolderReplacementPreviewWorkPhase { state.phase }
  var isClosed: Bool { state.phase == .closed }
  var hasActiveRequest: Bool { state.activeRequestID != nil }
  var onClose: (() -> Void)?
  var onRefresh: (() -> Void)?
  let workLane: FolderReplacementPreviewWorkLane
  private let chooser: any FolderReplacementPreviewChoosing
  private var pendingChooser: (generation: UUID, requestID: UUID?)?
  private var presentationIntent = UUID()
  private var updatingResultSelection = false

  init(
    root: URL? = nil, seedQuery: SearchQuery? = nil,
    lane: FolderReplacementPreviewWorkLane? = nil,
    chooser: (any FolderReplacementPreviewChoosing)? = nil
  ) {
    rootURL = root
    workLane = lane ?? FolderReplacementPreviewComposition.lane
    self.chooser = chooser ?? FolderReplacementPreviewNativeChooser()
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Read-only Replacement Preview"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 740, height: 560)
    panel.delegate = self
    buildContent(panel)
    caseButton.state = .on
    if let seedQuery {
      if case .literal = seedQuery.mode {
        patternView.string = seedQuery.pattern
        caseButton.state = seedQuery.caseSensitive ? .on : .off
        wholeWordButton.state = seedQuery.wholeWord ? .on : .off
      } else {
        statusLabel.stringValue = "Enter a literal pattern for this preview."
      }
    }
    folderLabel.stringValue = root?.path(percentEncoded: false) ?? "Choose a folder"
    refreshControls()
    panel.initialFirstResponder = patternView
  }

  required init?(coder: NSCoder) { return nil }

  func chooseFolder() throws { try choose(.folder) }
  func chooseFiles() throws { try choose(.files) }

  private func choose(_ kind: FolderReplacementPreviewChooserKind) throws {
    guard !isClosed, !hasActiveRequest, let window else { return }
    let generation = UUID()
    presentationIntent = generation
    invalidateChooser()
    guard presentationIntent == generation, !isClosed, !hasActiveRequest else { return }
    pendingChooser = (generation, nil)
    refreshControls()
    do {
      let returnedID = try chooser.begin(kind: kind, seed: rootURL, owner: window) {
        [weak self] urls in
        guard let self, !self.isClosed, self.pendingChooser?.generation == generation else {
          return
        }
        self.pendingChooser = nil
        if let urls {
          if kind == .folder {
            if urls.count == 1, let root = urls.first {
              self.rootURL = root
              self.folderLabel.stringValue = root.path(percentEncoded: false)
              self.selectedURLs = []
              self.clearFacts()
              _ = try? self.state.requestCancellation()
              self.statusLabel.stringValue = "Folder changed. Choose 1 or 2 files."
            } else {
              self.statusLabel.stringValue = "Choose one folder."
            }
          } else {
            self.clearFacts()
            _ = try? self.state.requestCancellation()
            if (1...2).contains(urls.count) {
              self.selectedURLs = urls
              self.statusLabel.stringValue = "Ready to preview saved files."
            } else {
              self.selectedURLs = []
              self.statusLabel.stringValue = "Choose 1 or 2 files."
            }
          }
          self.selectedFilesTable.reloadData()
        }
        self.refreshControls()
        self.onRefresh?()
      }
      // A synchronous callback or recipient close may have consumed/invalidated our intent.
      if pendingChooser?.generation == generation, !isClosed {
        pendingChooser = (generation, returnedID)
      } else {
        chooser.cancel(requestID: returnedID)
      }
    } catch {
      if pendingChooser?.generation == generation { pendingChooser = nil }
      if !isClosed, presentationIntent == generation {
        statusLabel.stringValue = "Could not choose files: \(error)"
        refreshControls()
        onRefresh?()
      }
      throw error
    }
  }

  private func invalidateChooser() {
    let id = pendingChooser?.requestID
    pendingChooser = nil
    if let id { chooser.cancel(requestID: id) }
  }

  func preview() throws -> Bool {
    guard !isClosed else { return false }
    guard !hasActiveRequest, pendingChooser == nil else {
      statusLabel.stringValue = "Preview busy; finish the current request first."
      return false
    }
    guard let root = rootURL else { return refuse("Choose a folder first.") }
    guard (1...2).contains(selectedURLs.count) else { return refuse("Choose 1 or 2 files.") }
    guard !patternView.string.isEmpty else { return refuse("Enter a nonempty literal pattern.") }
    guard patternView.string.utf8.count <= 4096, replacementView.string.utf8.count <= 4096 else {
      return refuse("Pattern and replacement are limited to 4096 UTF-8 bytes each.")
    }
    let input = FolderReplacementPreviewInput(
      root: root, files: selectedURLs,
      query: SearchQuery(
        pattern: patternView.string, mode: .literal,
        caseSensitive: caseButton.state == .on, wholeWord: wholeWordButton.state == .on),
      replacement: replacementView.string)
    presentationIntent = UUID()
    let id = UUID()
    let generation = try state.begin(requestID: id)
    clearFacts()
    statusLabel.stringValue = "Preparing preview…"
    refreshControls()
    do {
      let admitted = try workLane.start(
        input, requestID: id,
        publish: { [weak self] request, outcome in
          guard let self else { return }
          do {
            guard
              try self.state.publish(requestID: request, generation: generation, outcome: outcome)
            else { return }
            self.present(outcome)
            self.refreshControls()
            self.onRefresh?()
          } catch {
            if !self.isClosed {
              self.statusLabel.stringValue = "Could not present preview: \(error)"
            }
          }
        },
        settled: { [weak self] request in
          guard let self else { return }
          do {
            guard try self.state.acknowledgeSettlement(requestID: request) else { return }
            guard !self.isClosed else { return }
            if self.phase == .inputReady {
              self.statusLabel.stringValue = "Ready; previous preview discarded."
            }
            self.refreshControls()
            self.onRefresh?()
          } catch {
            if !self.isClosed {
              self.statusLabel.stringValue = "Could not settle preview: \(error)"
            }
          }
        })
      if !admitted {
        _ = try state.rejectAdmission(requestID: id)
        statusLabel.stringValue = "Preview worker busy; finish the current request first."
        refreshControls()
        onRefresh?()
      }
      return admitted
    } catch {
      _ = try state.rejectAdmission(requestID: id)
      statusLabel.stringValue = "Could not start preview: \(error)"
      refreshControls()
      onRefresh?()
      throw error
    }
  }

  private func refuse(_ message: String) -> Bool {
    presentationIntent = UUID()
    clearFacts()
    statusLabel.stringValue = message
    refreshControls()
    onRefresh?()
    return false
  }

  func cancelPreview() throws {
    guard !isClosed else { return }
    presentationIntent = UUID()
    let id = try state.requestCancellation()
    clearFacts()
    if let id { try workLane.cancel(requestID: id) }
    statusLabel.stringValue =
      id == nil
      ? "Preview discarded." : "Cancellation requested; finishing current work."
    refreshControls()
    onRefresh?()
  }

  func inputsDidChange() throws {
    guard !isClosed else { return }
    let intent = UUID()
    presentationIntent = intent
    invalidateChooser()
    guard !isClosed, presentationIntent == intent else { return }
    let id = try state.requestCancellation()
    clearFacts()
    if let id { try workLane.cancel(requestID: id) }
    statusLabel.stringValue =
      id == nil
      ? "Inputs changed. Run Preview for saved files."
      : "Cancellation requested; finishing current work."
    refreshControls()
    onRefresh?()
  }

  func selectResult(at index: Int) throws {
    guard !isClosed, !updatingResultSelection else { return }
    updatingResultSelection = true
    defer { updatingResultSelection = false }
    guard let display, display.rows.indices.contains(index) else {
      resultsTable.deselectAll(nil)
      originalView.string = ""
      proposedView.string = ""
      excerptLabel.stringValue = ""
      return
    }
    if resultsTable.selectedRow != index {
      resultsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    let row = display.rows[index]
    originalView.string = row.originalExcerpt
    proposedView.string = row.proposedExcerpt
    let anchor =
      row.proposedAnchorUTF16.map { "Replacement anchor: UTF-16 offset \($0)." }
      ?? "No original match; showing the beginning."
    let empty = row.proposedExcerpt.isEmpty ? " Proposed excerpt is empty." : ""
    excerptLabel.stringValue =
      "Excerpts around the first original match; \(row.matches) matches in this file. Additional changes may be outside these excerpts. \(anchor)\(empty)"
  }

  private func clearFacts() {
    display = nil
    resultsTable.deselectAll(nil)
    resultsTable.reloadData()
    originalView.string = ""
    proposedView.string = ""
    summaryLabel.stringValue = ""
    excerptLabel.stringValue = ""
  }

  private func present(_ outcome: FolderReplacementPreviewWorkOutcome) {
    clearFacts()
    switch outcome {
    case .ready(let ready):
      display = ready
      resultsTable.reloadData()
      let changed = ready.rows.filter(\.wouldChange).count
      let matches = ready.matchCount == 1 ? "match" : "matches"
      let files = changed == 1 ? "file" : "files"
      summaryLabel.stringValue = "\(ready.matchCount) \(matches); \(changed) \(files) would change."
      statusLabel.stringValue = "Read-only preview ready. Changes are not applied."
      if !ready.rows.isEmpty {
        resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try? selectResult(at: 0)
      }
    case .failed(let failure):
      switch failure {
      case .core(let message): statusLabel.stringValue = "Preview refused: \(message)"
      case .io(let domain, let code):
        statusLabel.stringValue = "Preview failed: \(domain) (\(code))"
      case .other(let message): statusLabel.stringValue = "Preview failed: \(message)"
      }
    case .cancelled:
      statusLabel.stringValue = "Preview cancelled; results discarded."
    }
  }

  private func refreshControls() {
    let enabled = !isClosed && !hasActiveRequest && pendingChooser == nil
    patternView.isEditable = enabled
    replacementView.isEditable = enabled
    for button in [
      caseButton, wholeWordButton, chooseFolderButton, chooseFilesButton, previewButton,
    ] {
      button.isEnabled = enabled
    }
    cancelButton.isEnabled = !isClosed && phase == .running
    closeButton.isEnabled = !isClosed
  }

  func parentInvalidated() throws { close() }

  override func close() {
    guard invalidateForClose() else { return }
    super.close()
  }

  private func invalidateForClose() -> Bool {
    guard !isClosed else { return false }
    presentationIntent = UUID()
    let id = try? state.close()
    invalidateChooser()
    if let id { try? workLane.cancel(requestID: id) }
    clearFacts()
    refreshControls()
    let notify = onClose
    onClose = nil
    onRefresh = nil
    notify?()
    return true
  }

  func windowWillClose(_ notification: Notification) { _ = invalidateForClose() }

  func textDidChange(_ notification: Notification) { perform { try inputsDidChange() } }
  @objc private func changeOptions() { perform { try inputsDidChange() } }
  @objc private func pickFolder() { perform { try chooseFolder() } }
  @objc private func pickFiles() { perform { try chooseFiles() } }
  @objc private func runPreview() { perform { _ = try preview() } }
  @objc private func stopPreview() { perform { try cancelPreview() } }
  @objc private func closePanel() { close() }

  private func perform(_ action: () throws -> Void) {
    let intent = presentationIntent
    do { try action() } catch {
      guard !isClosed, presentationIntent == intent else { return }
      statusLabel.stringValue = "Preview failed: \(error)"
      onRefresh?()
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    tableView === selectedFilesTable ? selectedURLs.count : (display?.rows.count ?? 0)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let text: String
    if tableView === selectedFilesTable {
      guard selectedURLs.indices.contains(row) else { return nil }
      text = selectedURLs[row].path(percentEncoded: false)
    } else {
      guard let display, display.rows.indices.contains(row) else { return nil }
      let entry = display.rows[row]
      switch tableColumn?.identifier.rawValue {
      case "matches": text = String(entry.matches)
      case "source": text = String(entry.sourceBytes)
      case "output": text = String(entry.outputBytes)
      case "bom": text = entry.hasBOM ? "Yes" : "No"
      case "change": text = entry.wouldChange ? "Yes" : "No"
      default: text = entry.path
      }
    }
    let cell = NSTextField(labelWithString: text)
    cell.lineBreakMode = .byTruncatingMiddle
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard notification.object as? NSTableView === resultsTable else { return }
    try? selectResult(at: resultsTable.selectedRow)
  }

  private func buildContent(_ panel: NSPanel) {
    let content = NSView()
    panel.contentView = content
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
    ])
    for (view, id, label) in [
      (patternView as NSView, "pattern", "Literal pattern"),
      (replacementView, "replacement", "Literal replacement; empty deletes"),
      (originalView, "original", "Original saved-file excerpt"),
      (proposedView, "proposed", "Proposed replacement excerpt; read-only"),
      (chooseFolderButton, "folder", "Choose preview folder"),
      (chooseFilesButton, "files", "Choose one or two saved files"),
      (caseButton, "caseSensitive", "Case sensitive literal matching"),
      (wholeWordButton, "wholeWord", "Whole word literal matching"),
      (previewButton, "preview", "Preview saved-file replacement"),
      (cancelButton, "cancel", "Cancel replacement preview"),
      (closeButton, "close", "Close replacement preview"),
      (statusLabel, "status", "Replacement preview status"),
      (summaryLabel, "summary", "Complete selected-set preview counts"),
      (resultsTable, "results", "Complete selected-file preview facts"),
      (selectedFilesTable, "selectedFiles", "Selected saved files"),
    ] {
      view.identifier = NSUserInterfaceItemIdentifier("folderPreview.\(id)")
      view.setAccessibilityIdentifier("folderPreview.\(id)")
      view.setAccessibilityLabel(label)
    }
    for view in [patternView, replacementView, originalView, proposedView] {
      view.isRichText = false
      view.importsGraphics = false
      view.isSelectable = true
      view.isAutomaticQuoteSubstitutionEnabled = false
      view.isAutomaticDashSubstitutionEnabled = false
      view.isAutomaticTextReplacementEnabled = false
      view.isAutomaticSpellingCorrectionEnabled = false
      view.isContinuousSpellCheckingEnabled = false
      view.isGrammarCheckingEnabled = false
      view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      view.textContainerInset = NSSize(width: 5, height: 5)
      view.isHorizontallyResizable = false
      view.isVerticallyResizable = true
      view.autoresizingMask = [.width]
      view.textContainer?.widthTracksTextView = true
      view.textContainer?.containerSize = NSSize(
        width: 800, height: CGFloat.greatestFiniteMagnitude)
    }
    originalView.isEditable = false
    proposedView.isEditable = false
    patternView.delegate = self
    replacementView.delegate = self
    for (button, action) in [
      (chooseFolderButton, #selector(pickFolder)), (chooseFilesButton, #selector(pickFiles)),
      (previewButton, #selector(runPreview)), (cancelButton, #selector(stopPreview)),
      (closeButton, #selector(closePanel)), (caseButton, #selector(changeOptions)),
      (wholeWordButton, #selector(changeOptions)),
    ] {
      button.target = self
      button.action = action
    }
    instructionLabel.font = .systemFont(ofSize: 11)
    instructionLabel.textColor = .secondaryLabelColor
    stack.addArrangedSubview(instructionLabel)
    let folderRow = NSStackView(views: [chooseFolderButton, folderLabel, chooseFilesButton])
    folderRow.spacing = 8
    folderLabel.lineBreakMode = .byTruncatingMiddle
    folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    stack.addArrangedSubview(folderRow)
    configureTable(selectedFilesTable, columns: [("file", "Selected saved files", 730)])
    let files = tableScroll(selectedFilesTable)
    files.heightAnchor.constraint(equalToConstant: 48).isActive = true
    stack.addArrangedSubview(files)
    let editors = NSStackView(views: [
      textColumn("Literal pattern", view: patternView, minimumHeight: 48),
      textColumn("Literal replacement (empty deletes)", view: replacementView, minimumHeight: 48),
    ])
    editors.distribution = .fillEqually
    editors.spacing = 10
    stack.addArrangedSubview(editors)
    let actions = NSStackView(views: [
      caseButton, wholeWordButton, previewButton, cancelButton, closeButton,
    ])
    actions.spacing = 10
    stack.addArrangedSubview(actions)
    configureTable(
      resultsTable,
      columns: [
        ("path", "Relative path", 280), ("matches", "Matches", 65), ("source", "Source bytes", 100),
        ("output", "Proposed bytes", 105), ("bom", "BOM", 45), ("change", "Would change", 100),
      ])
    let results = tableScroll(resultsTable)
    results.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    stack.addArrangedSubview(results)
    stack.addArrangedSubview(summaryLabel)
    excerptLabel.font = .systemFont(ofSize: 11)
    excerptLabel.textColor = .secondaryLabelColor
    stack.addArrangedSubview(excerptLabel)
    let viewers = NSStackView(views: [
      textColumn("Original excerpt", view: originalView, minimumHeight: 100),
      textColumn("Proposed excerpt — read-only", view: proposedView, minimumHeight: 100),
    ])
    viewers.spacing = 10
    viewers.distribution = .fillEqually
    stack.addArrangedSubview(viewers)
    stack.addArrangedSubview(statusLabel)
    for view in [
      instructionLabel, folderRow, files, editors, actions, results,
      summaryLabel, excerptLabel, viewers, statusLabel,
    ] as [NSView] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }

  private func configureTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
    for (id, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.dataSource = self
    table.delegate = self
    table.allowsMultipleSelection = false
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  }

  private func tableScroll(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
  }

  private func textColumn(_ title: String, view: NSTextView, minimumHeight: CGFloat) -> NSStackView
  {
    let label = NSTextField(labelWithString: title)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = view
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    let column = NSStackView(views: [label, scroll])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 3
    label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
  }
}
