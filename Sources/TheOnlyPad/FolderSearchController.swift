import AppKit
import PadCore

private final class FolderSearchCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
private final class FolderResultsTable: NSTableView {
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, let doubleAction {
      _ = NSApp.sendAction(doubleAction, to: target, from: self)
    } else {
      super.keyDown(with: event)
    }
  }
}
@MainActor
final class FolderSearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  typealias SearchOperation =
    @Sendable (
      URL, SearchQuery, [String], [String]
    ) throws -> FolderSearchReport

  var onClose: (() -> Void)?
  private let onOpen: (URL, NSRange, String) -> Void
  private let search: SearchOperation?
  private var root: URL?
  private var token: FolderSearchCancellation?
  private var generation = UUID()
  private var hits: [FolderSearchHit] = []
  private var resultRoot: URL?
  private let folder = NSTextField(labelWithString: "Choose a folder")
  private let query = NSSearchField()
  private let mode = NSPopUpButton()
  private let sensitive = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
  private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
  private let includes = NSTextField(string: "*")
  private let excludes = NSTextField(string: "")
  private let choose = NSButton(title: "Choose Folder…", target: nil, action: nil)
  private let run = NSButton(title: "Search", target: nil, action: nil)
  private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
  private let table = FolderResultsTable()
  private let status = NSTextField(wrappingLabelWithString: "Ready")

  init(
    root: URL? = nil, onOpen: @escaping (URL, NSRange, String) -> Void,
    search: SearchOperation? = nil
  ) {
    self.root = root
    self.onOpen = onOpen
    self.search = search
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 530),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Find in Folder"
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 600, height: 470)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView!.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
    ])
    folder.stringValue = root?.path ?? "Choose a folder"
    folder.lineBreakMode = .byTruncatingMiddle
    mode.addItems(withTitles: ["Literal", "Escaped", "Regex"])
    sensitive.state = .on
    for (view, id, label) in [
      (query as NSView, "folder.query", "Search pattern"), (run, "folder.run", "Search folder"),
      (cancel, "folder.cancel", "Cancel folder search"),
      (table, "folder.results", "Folder search matches"),
      (status, "folder.status", "Folder search status"),
      (includes, "folder.includes", "Include globs separated by semicolons"),
      (excludes, "folder.excludes", "Exclude globs separated by semicolons"),
    ] {
      view.identifier = .init(id)
      view.setAccessibilityLabel(label)
    }
    query.placeholderString = "Search pattern"
    query.target = self
    query.action = #selector(start)
    choose.target = self
    choose.action = #selector(pickFolder)
    run.target = self
    run.action = #selector(start)
    cancel.target = self
    cancel.action = #selector(stop)
    cancel.isEnabled = false
    let folderRow = NSStackView(views: [choose, folder])
    folderRow.spacing = 10
    stack.addArrangedSubview(folderRow)
    stack.addArrangedSubview(query)
    query.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let options = NSStackView(views: [mode, sensitive, wholeWord, run, cancel])
    options.spacing = 8
    stack.addArrangedSubview(options)
    let globRow = NSStackView(views: [
      NSTextField(labelWithString: "Include:"), includes, NSTextField(labelWithString: "Exclude:"),
      excludes,
    ])
    globRow.spacing = 8
    includes.widthAnchor.constraint(equalToConstant: 220).isActive = true
    excludes.widthAnchor.constraint(equalToConstant: 220).isActive = true
    stack.addArrangedSubview(globRow)
    let note = NSTextField(
      wrappingLabelWithString:
        "Recursive UTF-8 search. Hidden/symlink and .git, .build, node_modules paths excluded. Max 50,000 visited paths; 10 MB/file, 10,000 matches, 100 MB retained text. Binary/other encodings skipped. Globs: semicolon-separated; * and ?; case-sensitive; basename unless containing /. Regex timeouts are cooperative."
    )
    note.font = .systemFont(ofSize: 11)
    note.textColor = .secondaryLabelColor
    stack.addArrangedSubview(note)
    note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let column = NSTableColumn(identifier: .init("match"))
    column.title = "File — UTF-16 offset"
    column.width = 650
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openResult)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    panel.initialFirstResponder = query
    panel.center()
  }
  required init?(coder: NSCoder) { nil }
  deinit { token?.cancel() }
  func windowWillClose(_ notification: Notification) {
    stop()
    onClose?()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let hit = hits[row]
    return NSTextField(labelWithString: "\(hit.relativePath) — \(hit.range.location)")
  }
  @objc private func pickFolder() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] result in
      guard result == .OK, let self, let url = panel.url else { return }
      self.setRoot(url)
    }
  }
  func setRoot(_ url: URL) {
    stop()
    root = url
    folder.stringValue = url.path
    status.stringValue = "Folder changed. Run Search to find matches."
  }
  private func busy(_ value: Bool) {
    for button in [choose, run] { button.isEnabled = !value }
    cancel.isEnabled = value
  }
  @objc private func stop() {
    token?.cancel()
    token = nil
    generation = UUID()
    busy(false)
    status.stringValue = "Search cancelled; results discarded."
    hits = []
    resultRoot = nil
    table.deselectAll(nil)
    table.reloadData()
  }
  @objc private func start() {
    guard token == nil else { return }
    guard let root else {
      status.stringValue = "Choose a folder first."
      return
    }
    guard !query.stringValue.isEmpty else {
      status.stringValue = "Enter a search pattern."
      return
    }
    let modes: [SearchMode] = [.literal, .escaped, .regex]
    let request = SearchQuery(
      pattern: query.stringValue, mode: modes[mode.indexOfSelectedItem],
      caseSensitive: sensitive.state == .on, wholeWord: wholeWord.state == .on)
    func globs(_ field: NSTextField) -> [String] {
      field.stringValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter
      { !$0.isEmpty }
    }
    let include = globs(includes)
    let exclude = globs(excludes)
    let search = search
    let cancellation = FolderSearchCancellation()
    token = cancellation
    let id = UUID()
    generation = id
    busy(true)
    hits = []
    resultRoot = nil
    table.deselectAll(nil)
    table.reloadData()
    status.stringValue = "Discovering files…"
    Task { [weak self] in
      do {
        let (report, searchedRoot) = try await Task.detached {
          let searchedRoot = root.resolvingSymlinksInPath().standardizedFileURL
          let report: FolderSearchReport
          if let search {
            report = try search(root, request, include, exclude)
          } else {
            report = try FolderSearch.search(
              root: root, query: request, includes: include, excludes: exclude,
              isCancelled: { cancellation.cancelled },
              onProgress: { progress in
                if progress.filesProcessed.isMultiple(of: 32)
                  || progress.filesProcessed == progress.filesTotal
                {
                  Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.token != nil else { return }
                    self.status.stringValue =
                      "Searched \(progress.filesProcessed) of \(progress.filesTotal) files"
                  }
                }
              })
          }
          return (report, searchedRoot)
        }.value
        guard let self, self.generation == id else { return }
        self.resultRoot = searchedRoot
        self.hits = report.hits
        self.table.reloadData()
        self.token = nil
        self.busy(false)
        self.status.stringValue =
          "\(report.hits.count) matches. Skipped: \(report.skippedGlob) globs, \(report.skippedSize) size, \(report.skippedBinary) binary/encoding, \(report.skippedUnreadable) unreadable/changed."
      } catch {
        guard let self, self.generation == id else { return }
        self.token = nil
        self.busy(false)
        if error as? SearchError == .engineFailure {
          self.status.stringValue =
            "Search failed; no complete results. The search engine could not finish. Narrow the pattern and try again."
        } else {
          self.status.stringValue = "Search failed; no complete results: \(error)"
        }
      }
    }
  }
  @objc private func openResult() {
    guard hits.indices.contains(table.selectedRow), let resultRoot else { return }
    let hit = hits[table.selectedRow]
    let id = generation
    Task { [weak self] in
      do {
        let validated = try await Task.detached {
          try WorkspaceIndex.validatedFile(hit.url, within: resultRoot)
        }.value
        guard let self, self.generation == id else { return }
        self.onOpen(validated, hit.range, hit.originalText)
      } catch {
        guard let self, self.generation == id else { return }
        self.status.stringValue = "Cannot open changed or unsafe result: \(error)"
      }
    }
  }
}
