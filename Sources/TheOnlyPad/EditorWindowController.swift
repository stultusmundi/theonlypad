import AppKit
import PadCore

@MainActor
private final class DocumentTextView: NSTextView {
  let documentUndo = UndoManager()
  override var undoManager: UndoManager? { documentUndo }
}

@MainActor
private final class EditorDocument {
  let id: UUID
  let editor: DocumentTextView
  let scroll: NSScrollView
  var url: URL?
  var originalBytes: Data?
  var savedText = ""
  var encoding: DocumentEncoding = .utf8
  var hasBOM = false
  var savedEncoding: DocumentEncoding = .utf8
  var savedHasBOM = false
  var pinned = false
  var saving = false
  var dirty: Bool {
    !editor.string.utf16.elementsEqual(savedText.utf16) || encoding != savedEncoding
      || hasBOM != savedHasBOM
  }
  var name: String { url?.lastPathComponent ?? recoveredName ?? "Untitled" }

  var language: DocumentLanguage = .plainText
  var manualLanguage = false
  var settingsApplied = false
  lazy var highlighter = NativeSyntaxHighlighter(editor: editor)
  var recoveryRevision: UInt64 = 0
  var recoveredName: String?

  init(id: UUID = UUID()) {
    self.id = id
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.allowsNonContiguousLayout = true
    editor = DocumentTextView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 650), textContainer: container)
    editor.isRichText = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.usesFindBar = true
    editor.isIncrementalSearchingEnabled = true
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainerInset = NSSize(width: 12, height: 10)
    container.widthTracksTextView = true
    scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = editor
    scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: editor)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    editor.setAccessibilityLabel("Document text")
  }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  var onClose: (() -> Void)?
  var onOpenLargeFile: ((URL) -> Void)?
  private static var pendingCloses: [UUID: (RecoveryCoordinator, Task<Error?, Never>)] = [:]
  private var documents: [EditorDocument] = []
  private var selectedID: UUID?
  private let tabs = NSPopUpButton(frame: .zero, pullsDown: false)
  private let tabBar = DocumentTabBar()
  private var closedDocuments: [EditorDocument] = []
  private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
  private let host = NSView()
  private let workspaceSplit = NSSplitView()
  private lazy var workspace = WorkspaceSidebar { [weak self] url in self?.open(url) }
  private let status = NSTextField(labelWithString: "")
  private var current: EditorDocument? { documents.first { $0.id == selectedID } }
  private var settings = EditorSettings.defaults
  private var loadingCount = 0
  private var preparingToQuit = false
  private var recoveryDebounce: Task<Void, Never>?
  private var recoveryWork: Task<Void, Never>?
  private var recoveryPeriodic: Task<Void, Never>?
  private let recovery = RecoveryCoordinator.shared
  private var recoveryFailureShown = false
  private var searchPanel: SearchPanelController?
  private var encodingPanel: EncodingPanelController?
  private var textUtilities: TextUtilitiesController?
  private var folderSearch: FolderSearchController?
  private var recordingDocumentID: UUID?
  private var recordedCommands: [MacroCommand] = []
  private var recordedUnits = 0
  private var macroSaving = false
  private var replayCancellation: MacroCancellation?
  var isRecordingMacro: Bool { recordingDocumentID != nil }

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 540, height: 360)
    window.center()
    tabs.target = self
    tabs.action = #selector(selectTab)
    tabs.setAccessibilityLabel("Open documents")
    languagePicker.addItems(withTitles: DocumentLanguage.allCases.map(\.rawValue))
    languagePicker.target = self
    languagePicker.action = #selector(selectLanguage)
    languagePicker.setAccessibilityLabel("Document language")
    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    configureTabBar()
    workspaceSplit.isVertical = true
    workspaceSplit.dividerStyle = .thin
    workspaceSplit.addSubview(workspace)
    workspaceSplit.addSubview(host)
    workspace.isHidden = true
    let stack = NSStackView(views: [tabBar, tabs, languagePicker, workspaceSplit, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    window.contentView = stack
    for view in [tabBar, tabs, languagePicker, workspaceSplit, status] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    }
    workspaceSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    tabBar.heightAnchor.constraint(equalToConstant: 34).isActive = true
    tabs.setContentHuggingPriority(.required, for: .vertical)
    languagePicker.setContentHuggingPriority(.required, for: .vertical)
    status.setContentHuggingPriority(.required, for: .vertical)
    newDocument()
    restoreRecovery()
    recoveryPeriodic = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        guard let self else { return }
        if !self.preparingToQuit { self.enqueueRecovery() }
      }
    }
  }

  required init?(coder: NSCoder) { fatalError("Use init()") }

  func newDocument() {
    guard !preparingToQuit else { return }
    let document = EditorDocument()
    document.editor.delegate = self
    documents.append(document)
    display(document)
  }

  func open(_ url: URL, encoding: DocumentEncoding? = nil, onOpened: (() -> Void)? = nil) {
    guard !preparingToQuit else { return }
    if let existing = documents.first(where: {
      $0.url?.standardizedFileURL == url.standardizedFileURL
    }) {
      display(existing)
      if let encoding { reload(encoding: encoding, onReload: onOpened) } else { onOpened?() }
      return
    }
    loadingCount += 1
    refresh()
    Task { [weak self] in
      do {
        let loaded = try await Task.detached(priority: .userInitiated) {
          () throws -> (Data, DecodedDocument)? in
          let values = try url.resourceValues(forKeys: [.fileSizeKey])
          if (values.fileSize ?? 0) > 100_000_000 { return nil }
          return try Self.read(url, encoding: encoding)
        }.value
        guard let self else { return }
        self.loadingCount -= 1
        guard let loaded else {
          self.refresh()
          if let onOpenLargeFile = self.onOpenLargeFile {
            onOpenLargeFile(url)
            if onOpened != nil {
              self.present(
                NSError(
                  domain: "TheOnlyPad", code: 13,
                  userInfo: [
                    NSLocalizedDescriptionKey:
                      "Opened the read-only byte viewer. Text-position navigation is unavailable above 100 MB."
                  ]))
            }
          } else {
            self.present(Self.largeFileError())
          }
          return
        }
        // Another asynchronous open may already have completed for this path.
        if let existing = self.documents.first(where: {
          $0.url?.standardizedFileURL == url.standardizedFileURL
        }) {
          self.display(existing)
          if let encoding {
            self.reload(encoding: encoding, onReload: onOpened)
          } else {
            onOpened?()
          }
          return
        }
        let document = EditorDocument()
        document.url = url
        document.originalBytes = loaded.0
        document.savedText = loaded.1.text
        document.encoding = loaded.1.encoding
        document.hasBOM = loaded.1.hasBOM
        document.savedEncoding = loaded.1.encoding
        document.savedHasBOM = loaded.1.hasBOM
        document.editor.string = loaded.1.text
        document.language = LanguageService.detect(
          filename: url.lastPathComponent, text: loaded.1.text)
        document.editor.delegate = self
        self.documents.append(document)
        self.display(document)
        onOpened?()
      } catch {
        guard let self else { return }
        self.loadingCount -= 1
        self.refresh()
        self.present(error)
      }
    }
  }

  nonisolated private static func read(_ url: URL, encoding: DocumentEncoding? = nil) throws -> (
    Data, DecodedDocument
  ) {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw FileStoreError.unsafeTarget }
    let maximum = 100_000_000
    guard (values.fileSize ?? maximum + 1) <= maximum else { throw largeFileError() }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
    guard bytes.count <= maximum else { throw largeFileError() }
    return (bytes, try DocumentCodec.decode(bytes, encoding: encoding))
  }

  nonisolated private static func largeFileError() -> NSError {
    NSError(
      domain: "TheOnlyPad", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Files larger than 100 MB cannot be opened yet. Use a smaller excerpt; bounded large-file viewing is not available in this build."
      ])
  }

  func execute(_ id: String) {
    guard !preparingToQuit else { return }
    switch id {
    case "file.openFolder":
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      workspace.isHidden = false
      workspaceSplit.adjustSubviews()
      workspaceSplit.setPosition(240, ofDividerAt: 0)
      workspace.openFolder(url)
    case "view.workspace":
      workspace.isHidden.toggle()
      workspaceSplit.adjustSubviews()
      if !workspace.isHidden { workspaceSplit.setPosition(240, ofDividerAt: 0) }
    case "file.reopenClosed": reopenClosed()
    case "file.nextTab": switchTab(delta: 1)
    case "file.previousTab": switchTab(delta: -1)
    case "file.openEncoding":
      let panel = NSOpenPanel()
      let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
      picker.addItems(withTitles: DocumentEncoding.allCases.map(\.rawValue))
      picker.setAccessibilityLabel("Encoding to read")
      panel.accessoryView = picker
      guard panel.runModal() == .OK, let url = panel.url else { return }
      open(url, encoding: DocumentEncoding.allCases[picker.indexOfSelectedItem])
    case "document.encoding": showEncoding()
    case "macro.start":
      guard let current, !current.saving, recordingDocumentID == nil, !macroSaving else { return }
      guard allowLeavingUnsavedRecording() else { return }
      recordedCommands = []
      recordedUnits = 0
      recordingDocumentID = current.id
      refresh()
    case "macro.stop": stopRecording()
    case "macro.discard":
      guard !macroSaving else { return }
      recordingDocumentID = nil
      recordedCommands = []
      recordedUnits = 0
      refresh()
    case "macro.cancel": cancelMacroReplay()
    case "file.new": newDocument()
    case "file.open":
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = true
      guard panel.runModal() == .OK else { return }
      for url in panel.urls { open(url) }
    case "file.save": if let current { save(current, saveAs: false) }
    case "file.print":
      guard let document = current else { return }
      guard document.editor.string.utf16.count <= 2_000_000 else {
        present(
          NSError(
            domain: "TheOnlyPad", code: 8,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Printing is limited to 2 million UTF-16 units. Copy a smaller excerpt to a new tab to print it."
            ]))
        return
      }
      DocumentPrinting.printDocument(
        text: document.editor.string,
        font: document.editor.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
        name: document.name)
    case "file.saveAs": if let current { save(current, saveAs: true) }
    case "file.saveAll":
      for document in documents where document.dirty { save(document, saveAs: false) }
    case "file.close": closeDocument()
    case "file.reload", "file.revert": reload()
    case "file.duplicate":
      if let source = current {
        let document = EditorDocument()
        document.editor.string = source.editor.string
        document.encoding = source.encoding
        document.language = source.language
        document.manualLanguage = source.manualLanguage
        document.hasBOM = source.hasBOM
        document.editor.delegate = self
        documents.append(document)
        display(document)
      }
    case "tool.formatJSON": formatJSON()
    case "edit.goToLine":
      let alert = NSAlert()
      alert.messageText = "Go to Line and Column"
      alert.informativeText =
        "Positions start at 1. Columns count visible characters in logical text order; columns beyond a line stop at its end."
      let form = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
      let line = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
      line.placeholderString = "Line (1-based)"
      line.setAccessibilityLabel("Line number")
      let column = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      column.stringValue = "1"
      column.placeholderString = "Column (1-based)"
      column.setAccessibilityLabel("Column number")
      form.addSubview(line)
      form.addSubview(column)
      alert.accessoryView = form
      alert.addButton(withTitle: "Go")
      alert.addButton(withTitle: "Cancel")
      alert.window.initialFirstResponder = line
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      guard let lineValue = Int(line.stringValue), let columnValue = Int(column.stringValue),
        lineValue > 0, columnValue > 0
      else {
        present(LaunchRequestError.invalidPosition)
        return
      }
      navigate(line: lineValue, column: columnValue)
    case "tool.textUtilities": showTextUtilities()
    case "edit.findFolder":
      folderSearch?.close()
      let panel = FolderSearchController(root: workspace.rootURL) {
        [weak self] url, range, snapshot in
        self?.open(url) { [weak self] in self?.selectSearchResult(range, snapshot: snapshot) }
      }
      folderSearch = panel
      panel.showWindow(nil)
    case "view.wrap": toggleWrap()
    case "edit.find":
      showSearch()
    default:
      if id.hasPrefix("edit."), let transform = LineTransform(rawValue: String(id.dropFirst(5))) {
        apply(transform)
      }
    }
  }

  private func save(_ document: EditorDocument, saveAs: Bool) {
    guard !document.saving else { return }
    var destination = document.url
    if saveAs || destination == nil {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = document.name == "Untitled" ? "Untitled.txt" : document.name
      panel.directoryURL = document.url?.deletingLastPathComponent()
      guard panel.runModal() == .OK, let url = panel.url else { return }
      destination = url
    }
    guard let destination else { return }
    let sameDestination = destination.standardizedFileURL == document.url?.standardizedFileURL
    let original = document.originalBytes
    let snapshot = DecodedDocument(
      text: document.editor.string, encoding: document.encoding, hasBOM: document.hasBOM)
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      do {
        let bytes = try await Task.detached(priority: .userInitiated) {
          let bytes = try DocumentCodec.encode(snapshot)
          // Save As is create-only until an overwrite confirmation can be
          // bound to a captured version. A later-created file must not be overwritten.
          let expected = sameDestination ? original : nil
          do {
            try AtomicFileStore().save(bytes, to: destination, expected: expected)
          } catch FileStoreError.externalChange where !sameDestination {
            throw NSError(
              domain: "TheOnlyPad", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Save As requires a new filename in this build. Choose an unused destination; an existing or newly created file will not be overwritten."
              ])
          }
          return bytes
        }.value
        document.url = destination
        document.originalBytes = bytes
        document.savedText = snapshot.text
        document.savedEncoding = snapshot.encoding
        document.savedHasBOM = snapshot.hasBOM
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        self?.updateLanguage(document)
        self?.scheduleRecovery()
      } catch {
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        self?.present(error)
      }
    }
  }

  private func reload(encoding: DocumentEncoding? = nil, onReload: (() -> Void)? = nil) {
    guard !isRecordingMacro else {
      let alert = NSAlert()
      alert.messageText = "Stop macro recording before reloading"
      alert.informativeText = "Reload replaces file bytes outside the recorded text-edit sequence."
      alert.runModal()
      return
    }
    guard let document = current, let url = document.url, !document.saving,
      confirmDiscard([document])
    else { return }
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      do {
        let loaded = try await Task.detached(priority: .userInitiated) {
          try Self.read(url, encoding: encoding)
        }.value
        document.editor.string = loaded.1.text
        document.savedText = loaded.1.text
        document.originalBytes = loaded.0
        document.encoding = loaded.1.encoding
        document.hasBOM = loaded.1.hasBOM
        document.savedEncoding = loaded.1.encoding
        document.savedHasBOM = loaded.1.hasBOM
        document.editor.documentUndo.removeAllActions()
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        self?.updateLanguage(document)
        self?.scheduleRecovery()
        onReload?()
      } catch {
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        self?.present(error)
      }
    }
  }

  private func showEncoding() {
    guard let document = current, !document.saving, let window else { return }
    let panel = EncodingPanelController(
      current: DecodedDocument(
        text: document.editor.string, encoding: document.encoding, hasBOM: document.hasBOM),
      onConvert: { [weak self, weak document] encoding, bom in
        guard let self, let document else { return }
        self.convertEncoding(document, encoding: encoding, bom: bom)
      },
      onReopen: { [weak self, weak document] encoding in
        guard let self, let document else { return }
        guard document.url != nil else {
          let alert = NSAlert()
          alert.messageText = "This scratch document has no file to reopen"
          alert.informativeText =
            "Use File → Open with Encoding to decode an existing file, or convert this scratch document's save encoding."
          alert.runModal()
          return
        }
        self.display(document)
        self.reload(encoding: encoding)
      },
      onLineEnding: { [weak self, weak document] ending in
        guard let self, let document, !document.saving else { return }
        let snapshot = document.editor.string
        document.saving = true
        document.editor.isEditable = false
        self.refresh()
        Task {
          let replacement = await Task.detached { LineEndings.convert(snapshot, to: ending) }.value
          document.saving = false
          document.editor.isEditable = true
          self.replaceDocumentText(
            document, expected: snapshot, replacement: replacement, action: "Convert Line Endings")
        }
      })
    encodingPanel = panel
    panel.present(for: window)
  }

  private func convertEncoding(_ document: EditorDocument, encoding: DocumentEncoding, bom: Bool) {
    guard !document.saving, !preparingToQuit else { return }
    let snapshot = DecodedDocument(text: document.editor.string, encoding: encoding, hasBOM: bom)
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      do {
        _ = try await Task.detached { try DocumentCodec.encode(snapshot) }.value
        document.saving = false
        document.editor.isEditable = true
        self?.setEncoding(document, encoding: encoding, bom: bom)
      } catch {
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        self?.present(error)
      }
    }
  }

  private func setEncoding(_ document: EditorDocument, encoding: DocumentEncoding, bom: Bool) {
    guard document.encoding != encoding || document.hasBOM != bom else {
      refresh()
      return
    }
    let previous = document.encoding
    let previousBOM = document.hasBOM
    document.editor.documentUndo.registerUndo(withTarget: self) { controller in
      controller.setEncoding(document, encoding: previous, bom: previousBOM)
    }
    document.encoding = encoding
    document.hasBOM = bom
    document.editor.documentUndo.setActionName("Convert Encoding")
    refresh()
    scheduleRecovery()
  }

  private func replaceDocumentText(
    _ document: EditorDocument, expected: String, replacement: String, action: String
  ) {
    guard !preparingToQuit, !document.saving,
      document.editor.string.utf16.elementsEqual(expected.utf16)
    else { return }
    let range = NSRange(location: 0, length: expected.utf16.count)
    guard document.editor.shouldChangeText(in: range, replacementString: replacement) else {
      return
    }
    document.editor.breakUndoCoalescing()
    document.editor.documentUndo.beginUndoGrouping()
    document.editor.textStorage?.replaceCharacters(in: range, with: replacement)
    document.editor.didChangeText()
    document.editor.documentUndo.endUndoGrouping()
    document.editor.documentUndo.setActionName(action)
    refresh()
  }

  func navigate(line: Int, column: Int) {
    guard let document = current else { return }
    let snapshot = document.editor.string
    Task { [weak self, weak document] in
      do {
        let offset = try await Task.detached(priority: .userInitiated) {
          try TextNavigation.utf16Offset(in: snapshot, line: line, column: column)
        }.value
        guard let self, let document, !self.preparingToQuit,
          self.documents.contains(where: { $0 === document })
        else { return }
        guard document.editor.string.utf16.elementsEqual(snapshot.utf16) else {
          throw NSError(
            domain: "TheOnlyPad", code: 14,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The document changed during navigation. Try Go to Line again."
            ])
        }
        let range = NSRange(location: offset, length: 0)
        document.editor.setSelectedRange(range)
        document.editor.scrollRangeToVisible(range)
        if self.current === document { self.window?.makeFirstResponder(document.editor) }
      } catch { self?.present(error) }
    }
  }

  func selectSearchResult(_ range: NSRange, snapshot: String) {
    guard let document = current else { return }
    guard document.editor.string.utf16.elementsEqual(snapshot.utf16),
      range.location >= 0, range.length >= 0,
      range.location <= snapshot.utf16.count,
      range.length <= snapshot.utf16.count - range.location,
      Range(range, in: snapshot) != nil
    else {
      present(
        NSError(
          domain: "TheOnlyPad", code: 11,
          userInfo: [
            NSLocalizedDescriptionKey:
              "This search result is stale. Search again before navigating to it."
          ]))
      return
    }
    document.editor.setSelectedRange(range)
    document.editor.scrollRangeToVisible(range)
    window?.makeFirstResponder(document.editor)
  }

  private func showTextUtilities() {
    guard let document = current, !document.saving else { return }
    let snapshot = document.editor.string
    let selected = document.editor.selectedRange()
    let range = selected.length == 0 ? NSRange(location: 0, length: snapshot.utf16.count) : selected
    let input = (snapshot as NSString).substring(with: range)
    textUtilities?.close()
    let panel = TextUtilitiesController(text: input) { [weak self, weak document] replacement in
      guard let self, let document else { return }
      guard !self.preparingToQuit, self.current === document, !document.saving,
        document.editor.string.utf16.elementsEqual(snapshot.utf16)
      else {
        self.present(
          NSError(
            domain: "TheOnlyPad", code: 12,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The source document changed. Open Text Conversions again to work with the current text."
            ]))
        return
      }
      let editor = document.editor
      guard editor.shouldChangeText(in: range, replacementString: replacement) else { return }
      editor.breakUndoCoalescing()
      editor.documentUndo.beginUndoGrouping()
      editor.textStorage?.replaceCharacters(in: range, with: replacement)
      editor.didChangeText()
      editor.documentUndo.endUndoGrouping()
      editor.documentUndo.setActionName("Text Conversion")
      editor.setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
      self.refresh()
    }
    textUtilities = panel
    panel.showWindow(nil)
  }

  private func showSearch() {
    guard let document = current else { return }
    let panel = SearchPanelController(
      snapshot: { [weak self, weak document] in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          !document.saving, !self.preparingToQuit
        else { return nil }
        return document.editor.string
      },
      select: { [weak self, weak document] range, expected in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          document.editor.string.utf16.elementsEqual(expected.utf16)
        else { return false }
        self.display(document)
        document.editor.setSelectedRange(range)
        document.editor.scrollRangeToVisible(range)
        return true
      },
      replace: { [weak self, weak document] expected, replacement in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          !document.saving, !self.preparingToQuit,
          document.editor.string.utf16.elementsEqual(expected.utf16)
        else { return false }
        let editor = document.editor
        let range = NSRange(location: 0, length: expected.utf16.count)
        guard editor.shouldChangeText(in: range, replacementString: replacement) else {
          return false
        }
        editor.breakUndoCoalescing()
        editor.documentUndo.beginUndoGrouping()
        editor.textStorage?.replaceCharacters(in: range, with: replacement)
        editor.didChangeText()
        editor.documentUndo.endUndoGrouping()
        editor.documentUndo.setActionName("Replace All")
        self.display(document)
        return true
      })
    searchPanel?.close()
    searchPanel = panel
    panel.showWindow(nil)
  }

  private func apply(_ transform: LineTransform) {
    guard let document = current, !document.saving else { return }
    let editor = document.editor
    let selection = editor.selectedRange()
    let range =
      selection.length == 0
      ? NSRange(location: 0, length: (editor.string as NSString).length) : selection
    let before = (editor.string as NSString).substring(with: range)
    let after = transform.apply(to: before)
    guard !before.utf16.elementsEqual(after.utf16),
      editor.shouldChangeText(in: range, replacementString: after)
    else { return }
    editor.breakUndoCoalescing()
    editor.documentUndo.beginUndoGrouping()
    editor.textStorage?.replaceCharacters(in: range, with: after)
    editor.didChangeText()
    editor.documentUndo.endUndoGrouping()
    editor.documentUndo.setActionName(transform.rawValue)
    editor.setSelectedRange(NSRange(location: range.location, length: (after as NSString).length))
    refresh()
  }

  private func updateLanguage(_ document: EditorDocument) {
    if !document.manualLanguage {
      document.language = LanguageService.detect(
        filename: document.name, text: document.editor.string)
    }
    document.highlighter.update(language: document.language)
    if document.id == selectedID {
      languagePicker.selectItem(withTitle: document.language.rawValue)
    }
    updateStatus()
  }

  @objc private func selectLanguage() {
    guard !preparingToQuit, let document = current,
      let title = languagePicker.titleOfSelectedItem,
      let language = DocumentLanguage(rawValue: title)
    else { return }
    document.manualLanguage = true
    document.language = language
    document.highlighter.update(language: language)
    updateStatus()
  }

  private func formatJSON() {
    guard let document = current, !document.saving else { return }
    let captured = document.editor.string
    Task { [weak self] in
      do {
        let formatted = try await Task.detached(priority: .userInitiated) {
          try LanguageService.formatJSON(captured)
        }.value
        guard let self, !self.preparingToQuit, !document.saving,
          self.documents.contains(where: { $0.id == document.id })
        else { return }
        guard document.editor.string.utf16.elementsEqual(captured.utf16) else {
          let alert = NSAlert()
          alert.messageText = "The document changed while JSON was formatting"
          alert.informativeText = "Run Format JSON again to format the current text."
          alert.runModal()
          return
        }
        guard !formatted.utf16.elementsEqual(captured.utf16) else { return }
        let range = NSRange(location: 0, length: (captured as NSString).length)
        let editor = document.editor
        guard editor.shouldChangeText(in: range, replacementString: formatted) else { return }
        editor.breakUndoCoalescing()
        editor.documentUndo.beginUndoGrouping()
        editor.textStorage?.replaceCharacters(in: range, with: formatted)
        editor.didChangeText()
        editor.documentUndo.endUndoGrouping()
        editor.documentUndo.setActionName("Format JSON")
        self.refresh()
      } catch { self?.present(error) }
    }
  }

  func applySettings(_ value: EditorSettings) {
    guard !preparingToQuit else { return }
    do { settings = try value.validated() } catch {
      present(error)
      return
    }
    documents.forEach(configureSettings)
    refresh()
  }

  private func configureSettings(_ document: EditorDocument) {
    let font =
      settings.fontName == EditorSettings.systemMonospacedFontName
      ? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
      : (NSFont(name: settings.fontName, size: settings.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular))
    document.editor.font = font
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(settings.tabWidth)
    document.editor.defaultParagraphStyle = paragraph
    document.editor.typingAttributes[.paragraphStyle] = paragraph
    document.editor.textStorage?.addAttribute(
      .paragraphStyle, value: paragraph,
      range: NSRange(location: 0, length: (document.editor.string as NSString).length))
    configureWrap(document, enabled: settings.wrap)
    document.settingsApplied = true
  }

  private func configureWrap(_ document: EditorDocument, enabled wrap: Bool) {
    let editor = document.editor
    editor.isHorizontallyResizable = !wrap
    document.scroll.hasHorizontalScroller = !wrap
    editor.textContainer?.widthTracksTextView = wrap
    editor.textContainer?.containerSize = NSSize(
      width: wrap ? max(100, document.scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    if wrap {
      editor.setFrameSize(
        NSSize(width: max(100, document.scroll.contentSize.width), height: editor.frame.height))
    }
  }

  private func toggleWrap() {
    guard let document = current else { return }
    configureWrap(document, enabled: document.editor.isHorizontallyResizable)
    refresh()
  }

  @objc private func selectTab() {
    guard documents.indices.contains(tabs.indexOfSelectedItem) else { return }
    display(documents[tabs.indexOfSelectedItem])
  }

  private func display(_ document: EditorDocument) {
    selectedID = document.id
    for subview in host.subviews { subview.removeFromSuperview() }
    host.addSubview(document.scroll)
    document.scroll.frame = host.bounds
    document.scroll.autoresizingMask = [.width, .height]
    if !document.settingsApplied { configureSettings(document) }
    window?.makeFirstResponder(document.editor)
    updateLanguage(document)
    refresh()
  }

  private func closeDocument() {
    guard let document = current else { return }
    closeDocuments(ids: [document.id])
  }

  private func closeDocuments(ids: Set<UUID>) {
    guard !preparingToQuit else { return }
    let closing = documents.filter { ids.contains($0.id) }
    guard !closing.isEmpty, !closing.contains(where: { $0.saving }), confirmDiscard(closing) else {
      return
    }
    for document in closing {
      if !document.dirty { closedDocuments.append(document) }
      discardRecovery(document.id)
    }
    closedDocuments = Array(closedDocuments.suffix(10))
    documents.removeAll { ids.contains($0.id) }
    if documents.isEmpty {
      newDocument()
    } else if let selected = current {
      display(selected)
    } else {
      display(documents[0])
    }
  }

  private func reopenClosed() {
    guard let old = closedDocuments.popLast() else { return }
    let document = EditorDocument()
    document.url = old.url
    document.originalBytes = old.originalBytes
    document.savedText = old.savedText
    document.encoding = old.encoding
    document.hasBOM = old.hasBOM
    document.savedEncoding = old.savedEncoding
    document.savedHasBOM = old.savedHasBOM
    document.editor.string = old.editor.string
    document.language = old.language
    document.manualLanguage = old.manualLanguage
    document.editor.delegate = self
    documents.append(document)
    display(document)
    scheduleRecovery()
  }

  private func switchTab(delta: Int) {
    guard let index = documents.firstIndex(where: { $0.id == selectedID }), !documents.isEmpty
    else { return }
    display(documents[(index + delta + documents.count) % documents.count])
  }

  private func configureTabBar() {
    tabBar.onSelect = { [weak self] id in
      guard let self, let document = self.documents.first(where: { $0.id == id }) else { return }
      self.display(document)
    }
    tabBar.onClose = { [weak self] id in self?.closeDocuments(ids: [id]) }
    tabBar.onPin = { [weak self] id in
      guard let self, let document = self.documents.first(where: { $0.id == id }) else { return }
      document.pinned.toggle()
      self.documents = self.documents.filter(\.pinned) + self.documents.filter { !$0.pinned }
      self.refresh()
    }
    tabBar.onMove = { [weak self] id, index in
      guard let self else { return }
      do {
        let ids = try TabOrder.reordered(items: self.documents.map(\.id), moving: id, to: index)
        let lookup = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
        let ordered = ids.compactMap { lookup[$0] }
        self.documents = ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
        self.refresh()
      } catch { self.present(error) }
    }
    tabBar.onCloseOthers = { [weak self] id in
      guard let self else { return }
      self.closeDocuments(ids: Set(self.documents.filter { $0.id != id && !$0.pinned }.map(\.id)))
    }
    tabBar.onCloseRight = { [weak self] id in
      guard let self, let index = self.documents.firstIndex(where: { $0.id == id }) else { return }
      self.closeDocuments(
        ids: Set(self.documents.dropFirst(index + 1).filter { !$0.pinned }.map(\.id)))
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }

  func canClose() -> Bool {
    guard !preparingToQuit else { return false }
    guard allowLeavingUnsavedRecording() else { return false }
    guard loadingCount == 0, !macroSaving, !documents.contains(where: { $0.saving }) else {
      let alert = NSAlert()
      alert.messageText = "A file operation is still running"
      alert.informativeText = "Wait for loading or saving to finish before closing this window."
      alert.runModal()
      return false
    }
    return confirmDiscard(documents)
  }

  func windowWillClose(_ notification: Notification) {
    searchPanel?.close()
    textUtilities?.close()
    folderSearch?.close()
    if !preparingToQuit { for document in documents { discardRecovery(document.id) } }
    recoveryDebounce?.cancel()
    recoveryPeriodic?.cancel()
    onClose?()
  }

  private func confirmDiscard(_ items: [EditorDocument]) -> Bool {
    let dirty = items.filter { $0.dirty }
    guard !dirty.isEmpty else { return true }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Discard unsaved changes?"
    alert.informativeText =
      dirty.map(\.name).joined(separator: ", ")
      + " has unsaved changes. Cancel to save your work first."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard Changes")
    return alert.runModal() == .alertSecondButtonReturn
  }

  func textDidChange(_ notification: Notification) {
    if let editor = notification.object as? NSTextView,
      let document = documents.first(where: { $0.editor === editor })
    {
      updateLanguage(document)
    }
    refresh()
    scheduleRecovery()
  }

  func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    guard let id = recordingDocumentID,
      documents.first(where: { $0.id == id })?.editor === textView,
      let replacementString
    else { return true }
    let count = replacementString.utf16.count
    guard recordedCommands.count < 10_000, count <= 10_000_000 - recordedUnits else {
      recordingDocumentID = nil
      let alert = NSAlert()
      alert.messageText = "Macro recording limit reached"
      alert.informativeText =
        "Editing will continue. Use Stop Recording to save the commands captured so far."
      alert.runModal()
      return true
    }
    recordedCommands.append(
      .replace(
        location: affectedCharRange.location, length: affectedCharRange.length,
        text: replacementString))
    recordedUnits += count
    return true
  }

  private func allowLeavingUnsavedRecording() -> Bool {
    guard !recordedCommands.isEmpty else { return true }
    let alert = NSAlert()
    alert.messageText = "The macro recording has not been saved"
    alert.informativeText =
      "Use Macro → Stop and Save Recording to keep these commands, or Macro → Discard Recording to remove them, before starting another recording, closing this window, or quitting."
    alert.runModal()
    return false
  }

  private func stopRecording() {
    guard !macroSaving else { return }
    recordingDocumentID = nil
    refresh()
    guard !recordedCommands.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Save recorded macro"
    alert.informativeText =
      "This macro records exact text replacement commands. Replay requires compatible document offsets."
    let name = NSTextField(string: "Recorded Macro")
    name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    name.setAccessibilityLabel("Macro name")
    alert.accessoryView = name
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let macro = recordingSnapshot(named: name.stringValue) else { return }
    macroSaving = true
    Task { [weak self] in
      do {
        try await Task.detached {
          try MacroLibrary(directory: MacroLibrary.defaultDirectory).save(macro)
        }.value
        self?.recordedCommands = []
        self?.recordedUnits = 0
        self?.macroSaving = false
      } catch {
        self?.macroSaving = false
        self?.present(error)
      }
    }
  }

  func recordingSnapshot(named name: String) -> EditorMacro? {
    guard !recordedCommands.isEmpty else { return nil }
    return EditorMacro(name: name, commands: recordedCommands)
  }

  func externalCommandContext() throws -> CommandContext {
    guard let document = current else { return CommandContext(path: nil, selection: "") }
    let text = document.editor.string as NSString
    let selection = document.editor.selectedRange()
    guard selection.length <= 1_000_000 else {
      throw NSError(
        domain: "TheOnlyPad", code: 9,
        userInfo: [
          NSLocalizedDescriptionKey:
            "External commands accept selections up to 1 million UTF-16 units. Reduce the selection and try again."
        ])
    }
    let selected = text.substring(with: selection)
    return CommandContext(
      path: document.url?.path, selection: selected,
      text: text.length <= 1_000_000 ? document.editor.string : nil)
  }

  func cancelMacroReplay() { replayCancellation?.cancel() }
  var selectedDocumentID: UUID? { current?.id }

  func replay(_ macro: EditorMacro, repeatCount: Int) {
    guard let document = current, !document.saving, !preparingToQuit, !isRecordingMacro,
      replayCancellation == nil
    else { return }
    let snapshot = document.editor.string
    let cancellation = MacroCancellation()
    replayCancellation = cancellation
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      do {
        let replacement = try await Task.detached(priority: .userInitiated) {
          try MacroPlayer.replay(
            macro, on: snapshot, repeatCount: repeatCount, isCancelled: { cancellation.isCancelled }
          )
        }.value
        guard let self else { return }
        self.replayCancellation = nil
        document.saving = false
        document.editor.isEditable = true
        guard !cancellation.isCancelled, document.editor.string.utf16.elementsEqual(snapshot.utf16)
        else {
          self.refresh()
          return
        }
        let range = NSRange(location: 0, length: snapshot.utf16.count)
        if document.editor.shouldChangeText(in: range, replacementString: replacement) {
          document.editor.breakUndoCoalescing()
          document.editor.documentUndo.beginUndoGrouping()
          document.editor.textStorage?.replaceCharacters(in: range, with: replacement)
          document.editor.didChangeText()
          document.editor.documentUndo.endUndoGrouping()
          document.editor.documentUndo.setActionName(macro.name)
        }
        self.refresh()
      } catch {
        self?.replayCancellation = nil
        document.saving = false
        document.editor.isEditable = true
        self?.refresh()
        if !cancellation.isCancelled { self?.present(error) }
      }
    }
  }
  func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

  private func refresh() {
    tabBar.update(
      items: documents.map {
        TabItem(id: $0.id, title: $0.name, dirty: $0.dirty, pinned: $0.pinned)
      }, selectedID: selectedID)
    for document in documents {
      document.scroll.rulersVisible = document.editor.string.utf16.count <= 2_000_000
    }
    tabs.removeAllItems()
    for document in documents {
      let title =
        (document.dirty ? "● " : "") + document.name + (document.saving ? " — Working…" : "")
      tabs.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }
    if let index = documents.firstIndex(where: { $0.id == selectedID }) {
      tabs.selectItem(at: index)
    }
    window?.title = (current?.name ?? "Untitled") + " — " + AppIdentity.name
    window?.isDocumentEdited = current?.dirty ?? false
    window?.representedURL = current?.url
    if let current { languagePicker.selectItem(withTitle: current.language.rawValue) }
    updateStatus()
  }

  private func updateStatus() {
    guard let document = current else { return }
    let text = document.editor.string as NSString
    let caret = min(document.editor.selectedRange().location, text.length)
    // Status on very large text avoids a full-buffer scan for every caret movement.
    let location: String
    if text.length <= 1_000_000 {
      let prefix = text.substring(to: caret)
      var line = 1
      var column = 1
      for character in prefix {
        if character == "\n" || character == "\r" || character == "\r\n" {
          line += 1
          column = 1
        } else {
          column += 1
        }
      }
      location = "Ln \(line), Col \(column)"
    } else {
      location = "UTF-16 offset \(caret)"
    }
    let selection = document.editor.selectedRange().length
    status.stringValue =
      "\(document.language.rawValue)  |  \(location)  |  Selected \(selection) UTF-16 units  |  \(document.encoding.rawValue)\(document.hasBOM ? " BOM" : "")  |  \(document.editor.isHorizontallyResizable ? "No Wrap" : "Wrap")"
      + (text.length > 2_000_000 ? "  |  Highlighting disabled: large document" : "")
      + (loadingCount > 0 ? "  |  Loading…" : "")
      + (recordingDocumentID != nil ? "  |  Recording macro" : "")
  }

  private func restoreRecovery() {
    loadingCount += 1
    Task { [weak self, recovery] in
      do {
        let startup = try await recovery.claimStartup()
        guard let self else { return }
        self.loadingCount -= 1
        for snapshot in startup.snapshots {
          let document = EditorDocument(id: snapshot.id)
          document.editor.string = snapshot.text
          document.encoding = snapshot.encoding
          document.hasBOM = snapshot.hasBOM
          document.recoveredName =
            "Recovered "
            + (snapshot.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent }
              ?? "Untitled")
          // Never restore the original URL: Save must ask for a destination.
          document.editor.delegate = self
          self.documents.append(document)
          self.display(document)
        }
        self.refresh()
        if startup.quarantinedCount > 0 {
          let alert = NSAlert()
          alert.messageText = "Some recovery files could not be restored"
          alert.informativeText =
            "\(startup.quarantinedCount) corrupt recovery file(s) were preserved with a .corrupt extension in the recovery directory. Valid recovered documents are available as scratch buffers."
          alert.runModal()
        }
      } catch {
        guard let self else { return }
        self.loadingCount -= 1
        self.refresh()
        self.reportRecoveryFailure(error)
      }
    }
  }

  private func scheduleRecovery() {
    guard !preparingToQuit else { return }
    recoveryDebounce?.cancel()
    recoveryDebounce = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.enqueueRecovery()
    }
  }

  private func recoveryBatch() -> [(UUID, UInt64, RecoverySnapshot?)] {
    documents.map { document in
      document.recoveryRevision += 1
      let snapshot =
        document.url == nil || document.dirty
        ? RecoverySnapshot(
          id: document.id, text: document.editor.string,
          encoding: document.encoding, hasBOM: document.hasBOM,
          originalPath: document.url?.path) : nil
      return (document.id, document.recoveryRevision, snapshot)
    }
  }

  private func enqueueRecovery() {
    let batch = recoveryBatch()
    let previous = recoveryWork
    recoveryWork = Task { [weak self, recovery] in
      await previous?.value
      do {
        for (id, revision, snapshot) in batch {
          if let snapshot {
            try await recovery.persist(snapshot, revision: revision)
          } else {
            try await recovery.clear(id: id, revision: revision)
          }
        }
      } catch { self?.reportRecoveryFailure(error) }
    }
  }

  private func discardRecovery(_ id: UUID) {
    let previous = recoveryWork
    let cleanup = Task<Error?, Never> { [recovery] in
      await previous?.value
      do {
        try await recovery.close(id: id)
        return nil
      } catch { return error }
    }
    Self.pendingCloses[id] = (recovery, cleanup)
    recoveryWork = Task { [weak self] in
      if let error = await cleanup.value { self?.reportRecoveryFailure(error) }
    }
  }

  static func finishPendingCloses() async -> Bool {
    while let (id, entry) = pendingCloses.first {
      if await entry.1.value != nil {
        do { try await entry.0.close(id: id) } catch {
          let alert = NSAlert()
          alert.messageText = "Discarded recovery data could not be removed"
          alert.informativeText =
            "Quit was cancelled so cleanup can be retried. " + error.localizedDescription
          alert.runModal()
          return false
        }
      }
      pendingCloses.removeValue(forKey: id)
    }
    return true
  }

  func prepareToQuit() async -> Bool {
    guard allowLeavingUnsavedRecording() else { return false }
    guard loadingCount == 0, !macroSaving, !documents.contains(where: { $0.saving }) else {
      let alert = NSAlert()
      alert.messageText = "A file operation is still running"
      alert.informativeText = "Wait for loading or saving to finish, then quit again."
      alert.runModal()
      return false
    }
    preparingToQuit = true
    for document in documents { document.editor.isEditable = false }
    recoveryDebounce?.cancel()
    await recoveryWork?.value
    do {
      for (id, revision, snapshot) in recoveryBatch() {
        if let snapshot {
          try await recovery.persist(snapshot, revision: revision)
        } else {
          try await recovery.clear(id: id, revision: revision)
        }
      }
      return true
    } catch {
      cancelPreparedQuit()
      reportRecoveryFailure(error, always: true)
      return false
    }
  }

  func cancelPreparedQuit() {
    preparingToQuit = false
    for document in documents { document.editor.isEditable = !document.saving }
  }

  private func reportRecoveryFailure(_ error: Error, always: Bool = false) {
    guard always || !recoveryFailureShown else { return }
    recoveryFailureShown = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Recovery could not be saved or restored"
    alert.informativeText =
      "Save your documents to files before closing. " + error.localizedDescription
    alert.runModal()
  }

  private func present(_ error: Error) { NSAlert(error: error).runModal() }
}
