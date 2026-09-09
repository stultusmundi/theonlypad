import AppKit
import PadCore

struct SessionWindowCheckpointCapture: Sendable {
  let window: SessionWindow
  let liveTabIDs: Set<UUID>
  let recovery: [RecoveryCheckpointItem]
}

/// Injectable I/O boundary; production work runs in the detached save task.
struct EditorSaveServices: Sendable {
  var write: @Sendable (Data, URL, Data?) throws -> Void = {
    try AtomicFileStore().save($0, to: $1, expected: $2)
  }
  var backup: @Sendable (Data, URL, DocumentEncoding) throws -> Void = {
    _ = try BackupStore(directory: BackupStore.defaultDirectory).capture(
      data: $0, originalURL: $1, encoding: $2)
  }
  var validate: @Sendable (FilePublicationEvidence, Data) throws -> Void = {
    try AtomicFileStore().validatePublication($0, expected: $1)
  }
}

private struct PendingDocumentPublication: Sendable {
  let evidence: FilePublicationEvidence
  let bytes: Data
}
private enum EditorSaveFailure: Error {
  case uncertain(PendingDocumentPublication)
}

@MainActor
private final class DocumentTextView: NSTextView {
  let documentUndo = UndoManager()
  override var undoManager: UndoManager? { documentUndo }
  var onMarkedTextUpdated: (() -> Void)?
  var onTypingRunEnded: (() -> Void)?
  private(set) var isOrdinaryTextInsertion = false
  var onCompositionBegan: (() -> Void)?
  var onCompositionEnded: (() -> Void)?
  private(set) var isComposingText = false
  // AppKit may call setMarkedText again inside unmarkText; finalize only at the outer boundary.
  private var compositionOperationDepth = 0
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if !isComposingText {
      isComposingText = true
      onCompositionBegan?()
    }
    compositionOperationDepth += 1
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    onMarkedTextUpdated?()
    compositionOperationDepth -= 1
    if compositionOperationDepth == 0, !hasMarkedText() { finishComposition() }
  }
  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let previousInsertion = isOrdinaryTextInsertion
    isOrdinaryTextInsertion = !isComposingText && replacementRange.location == NSNotFound
    compositionOperationDepth += 1
    super.insertText(insertString, replacementRange: replacementRange)
    compositionOperationDepth -= 1
    isOrdinaryTextInsertion = previousInsertion
    if compositionOperationDepth == 0, !hasMarkedText() { finishComposition() }
  }
  override func unmarkText() {
    compositionOperationDepth += 1
    super.unmarkText()
    compositionOperationDepth -= 1
    if compositionOperationDepth == 0 { finishComposition() }
  }
  override func breakUndoCoalescing() {
    onTypingRunEnded?()
    super.breakUndoCoalescing()
  }
  override func setSelectedRange(_ charRange: NSRange) {
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    super.setSelectedRange(charRange)
  }
  override func setSelectedRange(
    _ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
  }
  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
  }
  private func finishComposition() {
    guard isComposingText else { return }
    isComposingText = false
    onCompositionEnded?()
  }

}

@MainActor
private final class EditorDocument {
  let id: UUID
  let editor: DocumentTextView
  let scroll: NSScrollView
  var url: URL?
  var originalBytes: Data?
  var pendingPublication: PendingDocumentPublication?
  var savedText = "" {
    didSet {
      savedUTF16Length = (savedText as NSString).length
      cachedTextDirty = nil
    }
  }
  private var savedUTF16Length = 0
  var selectableBeforeQuit: Bool?
  var onCharactersChanged: (() -> Void)?
  private var cachedTextDirty: Bool?
  private var storageObserver: NSObjectProtocol?
  var encoding: DocumentEncoding = .utf8
  var hasBOM = false
  var savedEncoding: DocumentEncoding = .utf8
  var savedHasBOM = false
  var pinned = false
  var saving = false
  var bookmarks = DocumentBookmarks()
  var pendingBookmarks: DocumentBookmarks?
  var compositionBookmarks: DocumentBookmarks?
  var compositionOriginalText: String?
  var compositionUndoRegistered = false
  var typingBookmarkNextLocation: Int?
  var pendingBookmarksHaveUndo = false
  var dirty: Bool {
    if pendingPublication != nil { return true }
    guard encoding == savedEncoding, hasBOM == savedHasBOM else { return true }
    let storage = editor.textStorage!
    // Queries inside an unfinished editing batch must not reuse the previous result.
    if storage.editedMask.contains(.editedCharacters) { cachedTextDirty = nil }
    if let cachedTextDirty { return cachedTextDirty }
    let changed =
      storage.length != savedUTF16Length
      || !storage.mutableString.isEqual(to: savedText)
    cachedTextDirty = changed
    return changed
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
    editor.minSize = NSSize(width: 0, height: 0)
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
    storageObserver = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        if let storage = notification.object as? NSTextStorage,
          storage.editedMask.contains(.editedCharacters)
        {
          self?.cachedTextDirty = nil
          self?.onCharactersChanged?()
        }
      }
    }
  }

  deinit {
    if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
  }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  let sessionID: UUID
  var onClose: (() -> Void)?
  var onOpenLargeFile: ((URL) -> Void)?
  var onOpenedURL: ((URL) -> Void)?
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
  private let checkpointStatus = NSTextField(wrappingLabelWithString: "")
  private let checkpointRetry = NSButton(title: "Retry", target: nil, action: nil)
  private let checkpointStatusRow = NSStackView()
  private var checkpointRetryAction: (() -> Void)?
  private let onSessionChange: (() -> Void)?
  private var current: EditorDocument? { documents.first { $0.id == selectedID } }
  private var settings = EditorSettings.defaults
  private var loadingCount = 0
  private var preparingToQuit = false
  private var windowClosed = false
  private var recoveryDebounce: Task<Void, Never>?
  private var recoveryWork: Task<Void, Never>?
  private var recoveryPeriodic: Task<Void, Never>?
  private let recovery = RecoveryCoordinator.shared
  private var recoveryFailureShown = false
  private var searchPanel: SearchPanelController?
  private var encodingPanel: EncodingPanelController?
  private var textUtilities: TextUtilitiesController?
  private var folderSearch: FolderSearchController?
  private var statisticsTask: Task<DocumentStatistics, Error>?
  private var statisticsGeneration = 0
  private var markdownPreview: MarkdownPreviewController?
  private var backupManager: BackupManagerController?
  private var outline: OutlineController?
  private var comparison: ComparisonController?
  private var recordingDocumentID: UUID?
  private var recordedCommands: [MacroCommand] = []
  private var recordedUnits = 0
  private var macroSaving = false
  private var replayCancellation: MacroCancellation?
  var isRecordingMacro: Bool { recordingDocumentID != nil }
  var currentDocumentIsDirty: Bool { current?.dirty ?? false }
  var currentSaveIsUncertain: Bool { current?.pendingPublication != nil }
  private let saveServices: EditorSaveServices
  private let chooseSaveDestination: ((URL?, String) -> URL?)?
  private let errorHandler: ((Error) -> Void)?

  init(
    id: UUID = UUID(), restoreStartup: Bool = true,
    saveServices: EditorSaveServices = EditorSaveServices(),
    chooseSaveDestination: ((URL?, String) -> URL?)? = nil,
    onError: ((Error) -> Void)? = nil,
    onSessionChange: (() -> Void)? = nil
  ) {
    self.onSessionChange = onSessionChange
    self.saveServices = saveServices
    self.chooseSaveDestination = chooseSaveDestination
    self.errorHandler = onError
    sessionID = id
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
    checkpointStatus.setAccessibilityIdentifier("session.checkpoint.status")
    checkpointStatus.identifier = .init("session.checkpoint.status")
    checkpointStatus.setAccessibilityLabel("Session checkpoint status")
    checkpointRetry.setAccessibilityIdentifier("session.checkpoint.retry")
    checkpointRetry.identifier = .init("session.checkpoint.retry")
    checkpointRetry.setAccessibilityLabel("Retry session checkpoint")
    checkpointRetry.target = self
    checkpointRetry.action = #selector(retrySessionCheckpoint)
    checkpointRetry.isHidden = true
    checkpointStatusRow.addArrangedSubview(checkpointStatus)
    checkpointStatusRow.addArrangedSubview(checkpointRetry)
    checkpointStatusRow.spacing = 8
    checkpointStatusRow.isHidden = true
    let stack = NSStackView(views: [
      tabBar, tabs, languagePicker, workspaceSplit, status, checkpointStatusRow,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    window.contentView = stack
    for view in [tabBar, tabs, languagePicker, workspaceSplit, status, checkpointStatusRow] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
    }
    workspaceSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    tabBar.heightAnchor.constraint(equalToConstant: 34).isActive = true
    tabs.setContentHuggingPriority(.required, for: .vertical)
    languagePicker.setContentHuggingPriority(.required, for: .vertical)
    status.setContentHuggingPriority(.required, for: .vertical)
    if restoreStartup {
      newDocument()
      restoreRecovery()
    }
    if onSessionChange == nil {
      recoveryPeriodic = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
          guard let self else { return }
          if !self.preparingToQuit { self.enqueueRecovery() }
        }
      }
    }

  }

  required init?(coder: NSCoder) { fatalError("Use init()") }

  /// Rendering this status must never schedule another checkpoint.
  func updateSessionCheckpointStatus(message: String, retry: (() -> Void)? = nil) {
    checkpointStatus.stringValue = message
    checkpointRetryAction = retry
    checkpointRetry.isHidden = retry == nil
    checkpointStatusRow.isHidden = message.isEmpty && retry == nil
  }
  @objc private func retrySessionCheckpoint() { checkpointRetryAction?() }

  private func notifySessionChange() {
    guard !preparingToQuit, !windowClosed else { return }
    onSessionChange?()
  }

  func captureSessionCheckpoint() throws -> SessionWindowCheckpointCapture {
    try Self.assertNoPendingCloses()
    guard !windowClosed else { throw CancellationError() }
    // No suspension between recovery text/disposition and the paired metadata/view state.
    let recovery = recoveryBatch().map {
      RecoveryCheckpointItem(id: $0.0, revision: $0.1, snapshot: $0.2)
    }
    return SessionWindowCheckpointCapture(
      window: sessionMetadata, liveTabIDs: Set(documents.map(\.id)), recovery: recovery)
  }

  var sessionMetadata: SessionWindow {
    SessionWindow(
      id: sessionID,
      tabs: documents.map { document in
        SessionTab(
          id: document.id, originalPath: document.url?.path, pinned: document.pinned,
          encoding: document.savedEncoding,
          manualLanguage: document.manualLanguage ? document.language : nil,
          selection: document.editor.selectedRange(), bookmarks: document.bookmarks.offsets)
      }, selectedTabID: selectedID)
  }

  /// Scalar budget preflight; no recovery snapshot or String copy is constructed here.
  var checkpointRecoveryUTF16Count: Int {
    documents.reduce(0) { count, document in
      count + (document.url == nil || document.dirty ? document.editor.textStorage?.length ?? 0 : 0)
    }
  }

  var sessionResourceUsage: (utf16Count: Int, originalByteCount: Int) {
    documents.reduce(into: (utf16Count: 0, originalByteCount: 0)) { usage, document in
      usage.utf16Count += document.editor.textStorage?.length ?? 0
      usage.originalByteCount += document.originalBytes?.count ?? 0
    }
  }

  /// The caller performs decoding and position validation off-main before importing.
  /// Recovery content passes nil URL/bytes and remains scratch regardless of historical metadata.
  func restoreSessionTab(
    _ metadata: SessionTab, decoded: DecodedDocument, originalBytes: Data?, url: URL?,
    viewState: RestoredViewState, insertionIndex: Int? = nil
  ) throws {
    guard !windowClosed, !preparingToQuit else { throw CancellationError() }
    guard !documents.contains(where: { $0.id == metadata.id }) else {
      throw SessionRestorationError.duplicateID
    }
    guard documents.count < 128 else { throw SessionStoreError.limit }
    let index = insertionIndex ?? documents.count
    guard (0...documents.count).contains(index) else { throw SessionStoreError.invalidMetadata }
    guard (url == nil) == (originalBytes == nil), url == nil || url?.isFileURL == true else {
      throw SessionStoreError.invalidMetadata
    }
    let document = EditorDocument(id: metadata.id)
    document.editor.string = decoded.text
    document.encoding = decoded.encoding
    document.hasBOM = decoded.hasBOM
    document.pinned = metadata.pinned
    document.bookmarks = viewState.bookmarks
    document.language =
      metadata.manualLanguage
      ?? LanguageService.detect(filename: url?.lastPathComponent ?? "", text: decoded.text)
    document.manualLanguage = metadata.manualLanguage != nil
    if let url, let originalBytes {
      document.url = url
      document.originalBytes = originalBytes
      document.savedText = decoded.text
      document.savedEncoding = decoded.encoding
      document.savedHasBOM = decoded.hasBOM
    } else {
      document.recoveredName =
        "Recovered "
        + (metadata.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled")
    }
    document.editor.delegate = self
    documents.insert(document, at: index)
    display(document)
    document.editor.setSelectedRange(viewState.selection)
    refresh()
  }

  func selectSessionTab(_ id: UUID?) {
    guard !windowClosed, let document = documents.first(where: { $0.id == id }) else { return }
    display(document)
  }

  func newDocument() {
    guard !preparingToQuit else { return }
    let document = EditorDocument()
    document.editor.delegate = self
    documents.append(document)
    display(document)
  }

  func restoreBackup(_ record: BackupRecord, data: Data) async throws {
    guard !preparingToQuit, !windowClosed else { throw CancellationError() }
    let decoded = try await Task.detached {
      try DocumentCodec.decode(data, encoding: record.encoding)
    }.value
    guard !preparingToQuit, !windowClosed else { throw CancellationError() }
    let document = EditorDocument()
    document.editor.string = decoded.text
    document.encoding = decoded.encoding
    document.hasBOM = decoded.hasBOM
    document.recoveredName =
      "Backup — " + URL(fileURLWithPath: record.originalPath).lastPathComponent
    document.editor.delegate = self
    documents.append(document)
    display(document)
    scheduleRecovery()
  }

  func open(
    _ url: URL, encoding: DocumentEncoding? = nil, shouldAccept: (() -> Bool)? = nil,
    onFailure: ((Error) -> Void)? = nil, onOpened: (() -> Void)? = nil
  ) {
    // Completion owns exactly one outcome, even when a window disappears during its read.
    var completed = false
    let finish: (Error?, Bool) -> Void = { [weak self] error, showDefaultError in
      guard !completed else { return }
      completed = true
      if let error {
        if let onFailure {
          onFailure(error)
        } else if showDefaultError, !(error is CancellationError) {
          self?.present(error)
        }
      } else {
        self?.onOpenedURL?(url)
        onOpened?()
      }
    }
    guard !preparingToQuit, !windowClosed, shouldAccept?() != false else {
      finish(CancellationError(), false)
      return
    }
    if let existing = documents.first(where: {
      $0.url?.standardizedFileURL == url.standardizedFileURL
    }) {
      display(existing)
      if let encoding {
        reload(
          encoding: encoding, shouldAccept: shouldAccept,
          onFailure: { finish($0, true) },
          onReload: {
            self.display(existing)
            finish(nil, false)
          })
      } else {
        finish(nil, false)
      }
      return
    }
    loadingCount += 1
    refresh()
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result<(Data, DecodedDocument)?, Error> {
          let values = try url.resourceValues(forKeys: [.fileSizeKey])
          if (values.fileSize ?? 0) > 100_000_000 { return nil }
          return try Self.read(url, encoding: encoding)
        }
      }.value
      guard let self else {
        finish(CancellationError(), false)
        return
      }
      self.loadingCount -= 1
      guard !self.windowClosed, !self.preparingToQuit, shouldAccept?() != false else {
        if !self.windowClosed { self.refresh() }
        finish(CancellationError(), false)
        return
      }
      switch result {
      case .failure(let error):
        self.refresh()
        finish(error, true)
      case .success(let loaded):
        guard let loaded else {
          self.refresh()
          // The byte viewer has no successful-load completion yet. Never report a text open
          // or update recent history merely because its window was constructed.
          if onFailure != nil {
            finish(Self.largeFileError(), true)
            return
          }
          if let viewer = self.onOpenLargeFile {
            viewer(url)
            if onOpened != nil {
              finish(
                NSError(
                  domain: "TheOnlyPad", code: 13,
                  userInfo: [
                    NSLocalizedDescriptionKey:
                      "Opened the read-only byte viewer. Text-position navigation is unavailable above 100 MB."
                  ]), true)
            } else {
              finish(Self.largeFileError(), false)
            }
          } else {
            finish(Self.largeFileError(), true)
          }
          return
        }
        // An overlapping open may have finished first. Select it without replacing dirty text.
        if let existing = self.documents.first(where: {
          $0.url?.standardizedFileURL == url.standardizedFileURL
        }) {
          self.display(existing)
          if let encoding {
            self.reload(
              encoding: encoding, shouldAccept: shouldAccept,
              onFailure: { finish($0, true) },
              onReload: {
                self.display(existing)
                finish(nil, false)
              })
          } else {
            finish(nil, false)
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
        document.bookmarks.removeAll()
        document.pendingBookmarks = nil
        (document.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = []
        document.language = LanguageService.detect(
          filename: url.lastPathComponent, text: loaded.1.text)
        document.editor.delegate = self
        self.documents.append(document)
        self.display(document)
        finish(nil, false)
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
          "This action supports editable text up to 100 MB. Use File > Open for the read-only byte viewer, or open a smaller excerpt."
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
    case "file.backups":
      backupManager?.close()
      let manager = BackupManagerController { [weak self] record, data in
        guard let self else { throw CancellationError() }
        try await self.restoreBackup(record, data: data)
      }
      backupManager = manager
      manager.onClose = { [weak self, weak manager] in
        if self?.backupManager === manager { self?.backupManager = nil }
      }
      manager.showWindow(nil)
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
    case "edit.commentLine", "edit.commentBlock":
      guard let document = current else { return }
      let language = document.language
      performDocumentCommand(id == "edit.commentLine" ? "Line Comment" : "Block Comment") {
        text, selection in
        if id == "edit.commentLine" {
          return try LanguageEditing.toggleLineComment(
            text: text, selection: selection, language: language)
        }
        return try LanguageEditing.toggleBlockComment(
          text: text, selection: selection, language: language)
      }
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
    case "tool.statistics": showStatistics()
    case "tool.outline":
      guard let document = current else { return }
      outline?.close()
      let panel = OutlineController(text: document.editor.string, language: document.language) {
        [weak self, weak document] range, snapshot in
        guard let self else { return }
        guard !self.preparingToQuit, !self.windowClosed else { return }
        guard let document, self.documents.contains(where: { $0 === document }),
          document.editor.string.utf16.elementsEqual(snapshot.utf16)
        else {
          self.present(
            NSError(
              domain: "TheOnlyPad", code: 19,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The outline document changed or closed. Open a fresh outline to navigate."
              ]))
          return
        }
        self.display(document)
        self.selectSearchResult(range, snapshot: snapshot)
      }
      outline = panel
      panel.onClose = { [weak self, weak panel] in
        if self?.outline === panel { self?.outline = nil }
      }
      panel.showWindow(nil)
    case "tool.previewMarkdown":
      guard let document = current else { return }
      markdownPreview?.close()
      let preview = MarkdownPreviewController(text: document.editor.string)
      preview.window?.title = "Markdown Preview — " + document.name
      markdownPreview = preview
      preview.onClose = { [weak self, weak preview] in
        if self?.markdownPreview === preview { self?.markdownPreview = nil }
      }
      preview.showWindow(nil)
    case "tool.compare":
      guard let document = current else { return }
      guard document.editor.string.utf8.count <= 2_000_000 else {
        present(
          NSError(
            domain: "TheOnlyPad", code: 16,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Comparison is limited to 2 MB of UTF-8 text per side. Copy a smaller excerpt to a new tab."
            ]))
        return
      }
      comparison?.close()
      let controller = ComparisonController(
        leftText: document.editor.string, leftName: document.name)
      comparison = controller
      controller.showWindow(nil)
    case "edit.findFolder":
      folderSearch?.close()
      let panel = FolderSearchController(root: workspace.rootURL) {
        [weak self] url, range, snapshot in
        self?.open(
          url, onOpened: { [weak self] in self?.selectSearchResult(range, snapshot: snapshot) })
      }
      folderSearch = panel
      panel.showWindow(nil)
    case "view.wrap": toggleWrap()
    case "edit.find":
      showSearch()
    default:
      if id.hasPrefix("bookmark.") {
        performBookmarkCommand(id)
      } else if id.hasPrefix("edit.line."),
        let command = LineCommand(rawValue: String(id.dropFirst(10)))
      {
        applyLineCommand(command)
      } else if id.hasPrefix("edit."),
        let transform = LineTransform(rawValue: String(id.dropFirst(5)))
      {
        apply(transform)
      }
    }
  }

  func isCommandAvailable(_ id: String) -> Bool {
    guard !preparingToQuit else { return false }
    if id.hasPrefix("bookmark.") { return current != nil && current?.saving == false }
    switch id {
    case "macro.start":
      return current != nil && current?.saving == false && recordingDocumentID == nil
        && !macroSaving && recordedCommands.isEmpty
    case "macro.stop":
      return !macroSaving && (recordingDocumentID != nil || !recordedCommands.isEmpty)
        && current?.saving == false
    case "macro.discard":
      return !macroSaving && (recordingDocumentID != nil || !recordedCommands.isEmpty)
    case "macro.cancel": return replayCancellation != nil
    case "file.reopenClosed": return !closedDocuments.isEmpty
    case "file.nextTab", "file.previousTab": return documents.count > 1
    case "file.save", "file.saveAs", "file.revert", "document.encoding", "tool.formatJSON",
      "tool.textUtilities", "edit.commentLine", "edit.commentBlock":
      return current != nil && current?.saving == false
    default:
      if id.hasPrefix("edit.line.")
        || (id.hasPrefix("edit.") && LineTransform(rawValue: String(id.dropFirst(5))) != nil)
      {
        return current != nil && current?.saving == false
      }
      return true
    }
  }

  private func save(_ document: EditorDocument, saveAs: Bool) {
    guard !document.saving, !windowClosed, !preparingToQuit else { return }
    let retry = saveAs ? nil : document.pendingPublication
    var destination = retry?.evidence.destination ?? document.url
    if saveAs || destination == nil {
      let suggestedName = document.name == "Untitled" ? "Untitled.txt" : document.name
      if let chooseSaveDestination {
        destination = chooseSaveDestination(
          document.url?.deletingLastPathComponent(), suggestedName)
      } else {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = document.url?.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        destination = panel.url
      }
    }
    // Native dialogs run a nested event loop; the target may have closed or frozen meanwhile.
    guard let destination, !windowClosed, !preparingToQuit, !document.saving,
      documents.contains(where: { $0 === document })
    else { return }
    let sameDestination = destination.standardizedFileURL == document.url?.standardizedFileURL
    let original = document.originalBytes
    let originalEncoding = document.savedEncoding
    let services = saveServices
    let snapshot = DecodedDocument(
      text: document.editor.string, encoding: document.encoding, hasBOM: document.hasBOM)
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      do {
        let bytes = try await Task.detached(priority: .userInitiated) {
          let bytes = try DocumentCodec.encode(snapshot)
          let expected: Data?
          if let retry {
            // Only this exact previously attempted publication can authorize a retry.
            // Readback is not a durability receipt; a fresh save must still succeed.
            try services.validate(retry.evidence, retry.bytes)
            expected = retry.bytes
          } else {
            // Save As remains create-only, never implicit overwrite permission.
            expected = sameDestination ? original : nil
            if let expected, expected != bytes {
              try services.backup(expected, destination, originalEncoding)
            }
          }
          do {
            try services.write(bytes, destination, expected)
          } catch FileStoreError.publicationUncertain(let evidence) {
            throw EditorSaveFailure.uncertain(
              PendingDocumentPublication(evidence: evidence, bytes: bytes))
          } catch FileStoreError.externalChange where !sameDestination && retry == nil {
            throw NSError(
              domain: "TheOnlyPad", code: 2,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Save As requires a new filename in this build. Choose an unused destination; an existing or newly created file will not be overwritten."
              ])
          }
          return bytes
        }.value
        document.saving = false
        guard let self, !self.windowClosed,
          self.documents.contains(where: { $0 === document })
        else { return }
        document.url = destination
        document.originalBytes = bytes
        document.savedText = snapshot.text
        document.savedEncoding = snapshot.encoding
        document.savedHasBOM = snapshot.hasBOM
        document.pendingPublication = nil
        document.editor.isEditable = true
        self.refresh()
        self.updateLanguage(document)
        self.scheduleRecovery()
      } catch {
        document.saving = false
        if case EditorSaveFailure.uncertain(let pending) = error {
          document.pendingPublication = pending
        }
        guard let self, !self.windowClosed,
          self.documents.contains(where: { $0 === document })
        else {
          document.editor.isEditable = false
          return
        }
        document.editor.isEditable = true
        if case EditorSaveFailure.uncertain = error { self.scheduleRecovery() }
        self.refresh()
        if case EditorSaveFailure.uncertain = error {
          self.present(
            NSError(
              domain: "TheOnlyPad", code: 21,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The new file may already exist, but its save could not be confirmed. Your edits remain in the buffer. Use Save to verify and retry that destination, or Save As to choose a new path."
              ]))
        } else {
          self.present(error)
        }
      }
    }
  }

  private func reload(
    encoding: DocumentEncoding? = nil, shouldAccept: (() -> Bool)? = nil,
    onFailure: ((Error) -> Void)? = nil, onReload: (() -> Void)? = nil
  ) {
    let fail: (Error) -> Void = { [weak self] error in
      if let onFailure {
        onFailure(error)
      } else if !(error is CancellationError) {
        self?.present(error)
      }
    }
    guard !windowClosed, !preparingToQuit, shouldAccept?() != false else {
      fail(CancellationError())
      return
    }
    guard !isRecordingMacro else {
      fail(
        NSError(
          domain: "TheOnlyPad", code: 14,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Stop macro recording before reloading. Reload replaces file bytes outside the recorded text-edit sequence."
          ]))
      return
    }
    guard let document = current, let url = document.url, !document.saving else {
      fail(CancellationError())
      return
    }
    guard confirmDiscard([document]), !windowClosed, !preparingToQuit,
      documents.contains(where: { $0 === document }), shouldAccept?() != false
    else {
      fail(CancellationError())
      return
    }
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result { try Self.read(url, encoding: encoding) }
      }.value
      document.saving = false
      guard let self else {
        document.editor.isEditable = true
        fail(CancellationError())
        return
      }
      guard !self.windowClosed, !self.preparingToQuit,
        self.documents.contains(where: { $0 === document }), shouldAccept?() != false
      else {
        document.editor.isEditable = !self.windowClosed && !self.preparingToQuit
        if !self.windowClosed { self.refresh() }
        fail(CancellationError())
        return
      }
      document.editor.isEditable = true
      switch result {
      case .failure(let error):
        self.refresh()
        fail(error)
      case .success(let loaded):
        document.editor.string = loaded.1.text
        document.bookmarks.removeAll()
        document.pendingBookmarks = nil
        (document.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = []
        document.savedText = loaded.1.text
        document.pendingPublication = nil
        document.originalBytes = loaded.0
        document.encoding = loaded.1.encoding
        document.hasBOM = loaded.1.hasBOM
        document.savedEncoding = loaded.1.encoding
        document.savedHasBOM = loaded.1.hasBOM
        document.editor.documentUndo.removeAllActions()
        self.refresh()
        self.updateLanguage(document)
        self.scheduleRecovery()
        onReload?()
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
    document.editor.documentUndo.registerUndo(withTarget: self) { [weak document] controller in
      guard let document else { return }
      controller.setEncoding(document, encoding: previous, bom: previousBOM)
    }
    document.encoding = encoding
    document.hasBOM = bom
    document.editor.documentUndo.setActionName("Convert Encoding")
    refresh()
    scheduleRecovery()
  }

  @discardableResult private func replaceDocumentText(
    _ document: EditorDocument, expected: String, replacement: String, action: String,
    edit: TextEdit? = nil
  ) -> Bool {
    guard !preparingToQuit, !document.saving,
      documents.contains(where: { $0 === document }),
      document.editor.string.utf16.elementsEqual(expected.utf16),
      !expected.utf16.elementsEqual(replacement.utf16)
    else { return false }
    let change: TextEdit
    do {
      guard let calculated = try edit ?? TextDifference.singleEdit(from: expected, to: replacement)
      else { return false }
      change = calculated
    } catch {
      present(error)
      return false
    }
    guard document.editor.shouldChangeText(in: change.range, replacementString: change.replacement)
    else {
      return false
    }
    document.editor.breakUndoCoalescing()
    document.editor.documentUndo.beginUndoGrouping()
    document.editor.textStorage?.replaceCharacters(in: change.range, with: change.replacement)
    document.editor.didChangeText()
    document.editor.documentUndo.endUndoGrouping()
    document.editor.documentUndo.setActionName(action)
    refresh()
    return true
  }

  private func applyLineCommand(_ command: LineCommand) {
    let tabWidth = settings.tabWidth
    performDocumentCommand(command.rawValue) { text, selection in
      try command.apply(to: text, selection: selection, tabWidth: tabWidth)
    }
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
    current?.editor.documentUndo
  }

  private func setBookmarks(_ document: EditorDocument, value: DocumentBookmarks) {
    let previous = document.bookmarks
    guard previous != value else { return }
    document.typingBookmarkNextLocation = nil
    document.editor.documentUndo.registerUndo(withTarget: self) { [weak document] controller in
      guard let document else { return }
      controller.setBookmarks(document, value: previous)
    }
    document.bookmarks = value
    (document.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(value.offsets)
    notifySessionChange()
  }

  private func performBookmarkCommand(_ id: String) {
    guard let document = current, !document.saving, !preparingToQuit else { return }
    let snapshot = document.editor.string
    let selection = document.editor.selectedRange()
    let original = document.bookmarks
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self, weak document] in
      do {
        let result = try await Task.detached { () throws -> (DocumentBookmarks, Int?, String?) in
          var marks = original
          switch id {
          case "bookmark.toggle": try marks.toggle(atUTF16Offset: selection.location, in: snapshot)
          case "bookmark.clear": marks.removeAll()
          case "bookmark.next", "bookmark.previous":
            return (
              marks,
              try marks.destination(
                from: selection.location, direction: id == "bookmark.next" ? .next : .previous,
                in: snapshot), nil
            )
          case "bookmark.export": return (marks, nil, try marks.export(from: snapshot))
          default: break
          }
          return (marks, nil, nil)
        }.value
        guard let self, let document else { return }
        document.saving = false
        document.editor.isEditable = true
        self.refresh()
        guard !self.preparingToQuit, !self.windowClosed, self.current === document,
          document.editor.selectedRange() == selection,
          document.bookmarks == original,
          document.editor.string.utf16.elementsEqual(snapshot.utf16)
        else {
          throw NSError(
            domain: "TheOnlyPad", code: 18,
            userInfo: [
              NSLocalizedDescriptionKey: "The bookmark target changed. Run the command again."
            ])
        }
        if result.0 != original {
          document.editor.breakUndoCoalescing()
          document.editor.documentUndo.beginUndoGrouping()
          self.setBookmarks(document, value: result.0)
          document.editor.documentUndo.endUndoGrouping()
          document.editor.documentUndo.setActionName("Bookmarks")
        }
        if let offset = result.1 {
          document.editor.setSelectedRange(NSRange(location: offset, length: 0))
          document.editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
        }
        if let text = result.2 {
          self.newDocument()
          self.current?.editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }
      } catch {
        document?.saving = false
        document?.editor.isEditable = true
        self?.refresh()
        self?.present(error)
      }
    }
  }

  private func performDocumentCommand(
    _ action: String, operation: @escaping @Sendable (String, NSRange) throws -> LineCommandResult
  ) {
    guard let document = current, !document.saving else { return }
    let snapshot = document.editor.string
    let selection = document.editor.selectedRange()
    document.saving = true
    document.editor.isEditable = false
    refresh()
    Task { [weak self, weak document] in
      do {
        let (result, edit) = try await Task.detached(priority: .userInitiated) {
          let result = try operation(snapshot, selection)
          return (result, try TextDifference.singleEdit(from: snapshot, to: result.text))
        }.value
        guard let self, let document else { return }
        document.saving = false
        document.editor.isEditable = true
        self.refresh()
        guard !self.preparingToQuit, !self.windowClosed, self.current === document,
          document.editor.selectedRange() == selection,
          document.editor.string.utf16.elementsEqual(snapshot.utf16)
        else {
          throw NSError(
            domain: "TheOnlyPad", code: 15,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The target document or selection changed. Run the editing command again."
            ])
        }
        if result.text.utf16.elementsEqual(snapshot.utf16)
          || self.replaceDocumentText(
            document, expected: snapshot, replacement: result.text, action: action, edit: edit)
        {
          document.editor.setSelectedRange(result.selection)
          document.editor.scrollRangeToVisible(result.selection)
        }
      } catch {
        document?.saving = false
        document?.editor.isEditable = true
        self?.refresh()
        self?.present(error)
      }
    }
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

  private func showStatistics() {
    guard let document = current else { return }
    let snapshot = document.editor.string
    let selection = document.editor.selectedRange()
    let name = document.name
    let savedBytes = document.originalBytes.map { String($0.count) } ?? "Not saved"
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let work = Task.detached(priority: .userInitiated) {
      try DocumentStatistics.measure(
        snapshot, selection: selection, isCancelled: { Task.isCancelled })
    }
    statisticsTask = work
    Task { [weak self] in
      do {
        let stats = try await work.value
        guard let self, !self.preparingToQuit, self.statisticsGeneration == generation else {
          return
        }
        self.statisticsTask = nil
        let alert = NSAlert()
        alert.messageText = "Statistics — " + name
        alert.informativeText =
          "Snapshot at command invocation\n\nCharacters (graphemes): \(stats.characters)\nUTF-16 units: \(stats.utf16Units)\nUnicode scalars: \(stats.unicodeScalars)\nUTF-8 bytes without BOM: \(stats.utf8Bytes)\nLast loaded/saved file bytes: \(savedBytes)\nLogical lines: \(stats.lines)\nEndings — LF: \(stats.lfEndings), CRLF: \(stats.crlfEndings), CR: \(stats.crEndings)\nSelection: \(stats.selectedCharacters) characters / \(stats.selectedUTF16Units) UTF-16 units"
        alert.runModal()
      } catch is CancellationError {} catch { self?.present(error) }
    }
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
      guard !self.preparingToQuit, !self.windowClosed, self.current === document, !document.saving,
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
    performDocumentCommand(transform.rawValue) { text, selection in
      guard text.utf8.count <= 100_000_000 else {
        throw NSError(
          domain: "TheOnlyPad", code: 17,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Text transformations are limited to 100 MB of UTF-8 text. Copy a smaller excerpt to another tab."
          ])
      }
      let range = selection.length == 0 ? NSRange(location: 0, length: text.utf16.count) : selection
      guard let selected = Range(range, in: text) else { throw TextEditError.invalidRange }
      let replacement = transform.apply(to: String(text[selected]))
      guard replacement.utf8.count <= 100_000_000 else {
        throw NSError(
          domain: "TheOnlyPad", code: 17,
          userInfo: [
            NSLocalizedDescriptionKey: "The transformed text exceeds the 100 MB output limit."
          ])
      }
      let result = try TextEdits.apply([TextEdit(range: range, replacement: replacement)], to: text)
      guard result.utf8.count <= 100_000_000 else {
        throw NSError(
          domain: "TheOnlyPad", code: 17,
          userInfo: [
            NSLocalizedDescriptionKey: "The transformed document exceeds the 100 MB output limit."
          ])
      }
      return LineCommandResult(
        text: result, selection: NSRange(location: range.location, length: replacement.utf16.count))
    }
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
    guard !preparingToQuit, !windowClosed, let document = current,
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
    guard !preparingToQuit, !windowClosed, documents.indices.contains(tabs.indexOfSelectedItem)
    else { return }
    display(documents[tabs.indexOfSelectedItem])
  }

  private func display(_ document: EditorDocument) {
    document.onCharactersChanged = { [weak self] in self?.notifySessionChange() }
    selectedID = document.id
    for subview in host.subviews { subview.removeFromSuperview() }
    host.addSubview(document.scroll)
    document.scroll.frame = host.bounds
    document.scroll.autoresizingMask = [.width, .height]
    if !document.settingsApplied { configureSettings(document) }
    if let ruler = document.scroll.verticalRulerView as? LineNumberRuler {
      document.editor.onTypingRunEnded = { [weak document] in
        document?.typingBookmarkNextLocation = nil
      }
      document.editor.onCompositionBegan = { [weak document] in
        guard let document else { return }
        document.editor.breakUndoCoalescing()
        document.compositionBookmarks = document.bookmarks
        // Keep one snapshot per composition so restoring canceled replacement text can restore lost anchors.
        document.compositionOriginalText =
          document.bookmarks.offsets.isEmpty ? nil : document.editor.string
        document.compositionUndoRegistered = false
      }
      document.editor.onCompositionEnded = { [weak self, weak document] in
        guard let self, let document, let before = document.compositionBookmarks else { return }
        if let originalText = document.compositionOriginalText,
          document.editor.string.utf16.elementsEqual(originalText.utf16)
        {
          document.bookmarks = before
          (document.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(
            before.offsets)
        }
        document.compositionBookmarks = nil
        document.compositionOriginalText = nil
        document.compositionUndoRegistered = false
        self.refresh()
      }
      document.editor.onMarkedTextUpdated = { [weak document] in
        guard let document, document.pendingBookmarks != nil else { return }
        document.editor.didChangeText()
      }
      ruler.bookmarkOffsets = Set(document.bookmarks.offsets)
      ruler.onToggleBookmark = { [weak self, weak document] offset in
        guard let self, let document, !self.preparingToQuit, !self.windowClosed,
          self.current === document, !document.saving
        else { return }
        document.editor.setSelectedRange(NSRange(location: offset, length: 0))
        self.performBookmarkCommand("bookmark.toggle")
      }
    }
    window?.makeFirstResponder(document.editor)
    updateLanguage(document)
    refresh()
  }

  private func closeDocument() {
    guard let document = current else { return }
    closeDocuments(ids: [document.id])
  }

  private func closeDocuments(ids: Set<UUID>) {
    guard !preparingToQuit, !windowClosed else { return }
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
    document.pendingPublication = old.pendingPublication
    document.savedText = old.savedText
    document.encoding = old.encoding
    document.hasBOM = old.hasBOM
    document.savedEncoding = old.savedEncoding
    document.savedHasBOM = old.savedHasBOM
    document.bookmarks = old.bookmarks
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
      guard let self, !self.preparingToQuit, !self.windowClosed,
        let document = self.documents.first(where: { $0.id == id })
      else { return }
      self.display(document)
    }
    tabBar.onClose = { [weak self] id in self?.closeDocuments(ids: [id]) }
    tabBar.onPin = { [weak self] id in
      guard let self, !self.preparingToQuit, !self.windowClosed,
        let document = self.documents.first(where: { $0.id == id })
      else { return }
      document.pinned.toggle()
      self.documents = self.documents.filter(\.pinned) + self.documents.filter { !$0.pinned }
      self.refresh()
    }
    tabBar.onMove = { [weak self] id, index in
      guard let self, !self.preparingToQuit, !self.windowClosed else { return }
      do {
        let ids = try TabOrder.reordered(items: self.documents.map(\.id), moving: id, to: index)
        let lookup = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
        let ordered = ids.compactMap { lookup[$0] }
        self.documents = ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
        self.refresh()
      } catch { self.present(error) }
    }
    tabBar.onCloseOthers = { [weak self] id in
      guard let self, !self.preparingToQuit, !self.windowClosed else { return }
      self.closeDocuments(ids: Set(self.documents.filter { $0.id != id && !$0.pinned }.map(\.id)))
    }
    tabBar.onCloseRight = { [weak self] id in
      guard let self, !self.preparingToQuit, !self.windowClosed,
        let index = self.documents.firstIndex(where: { $0.id == id })
      else { return }
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
    windowClosed = true
    markdownPreview?.close()
    backupManager?.close()
    outline?.close()
    comparison?.close()
    statisticsTask?.cancel()
    statisticsGeneration += 1
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
      if let updated = document.pendingBookmarks {
        document.pendingBookmarks = nil
        if document.editor.isComposingText || document.pendingBookmarksHaveUndo {
          document.bookmarks = updated
          (document.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(
            updated.offsets)
        } else {
          setBookmarks(document, value: updated)
        }
        document.pendingBookmarksHaveUndo = false
      }
      updateLanguage(document)
    }
    refresh()
    scheduleRecovery()
  }

  func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    if let document = documents.first(where: { $0.editor === textView }) {
      document.pendingBookmarks = nil
      document.pendingBookmarksHaveUndo = false
      if document.editor.documentUndo.isUndoing || document.editor.documentUndo.isRedoing {
        document.typingBookmarkNextLocation = nil
      }
      if !document.bookmarks.offsets.isEmpty, let replacementString,
        !document.editor.documentUndo.isUndoing, !document.editor.documentUndo.isRedoing
      {
        do {
          var updated = document.bookmarks
          try updated.remap(
            through: TextEdit(range: affectedCharRange, replacement: replacementString),
            inUTF16: textView.textStorage!.mutableString)
          let replacement = replacementString as NSString
          let nativeText = textView.textStorage!.mutableString
          let isNoOp =
            affectedCharRange.length == replacement.length
            && (0..<replacement.length).allSatisfy {
              nativeText.character(at: affectedCharRange.location + $0)
                == replacement.character(at: $0)
            }
          if isNoOp {
            document.pendingBookmarksHaveUndo = true
          } else if document.editor.isComposingText {
            // Register before AppKit's first text undo, then let provisional text edits coalesce.
            if !document.compositionUndoRegistered, let before = document.compositionBookmarks {
              document.editor.documentUndo.registerUndo(withTarget: self) {
                [weak document] controller in
                guard let document else { return }
                controller.setBookmarks(document, value: before)
              }
              document.compositionUndoRegistered = true
            }
          } else if document.editor.isOrdinaryTextInsertion, affectedCharRange.length == 0,
            !replacementString.utf16.contains(where: { $0 == 10 || $0 == 13 })
          {
            if document.typingBookmarkNextLocation != affectedCharRange.location
              || !document.editor.documentUndo.canUndo
            {
              document.editor.breakUndoCoalescing()
              let before = document.bookmarks
              if before != updated {
                document.editor.documentUndo.registerUndo(withTarget: self) {
                  [weak document] controller in
                  guard let document else { return }
                  controller.setBookmarks(document, value: before)
                }
              }
            }
            // Later caret inserts update anchors without inserting actions into native typing coalescence.
            document.typingBookmarkNextLocation = affectedCharRange.location + replacement.length
            document.pendingBookmarksHaveUndo = true
          } else {
            if document.typingBookmarkNextLocation != nil { document.editor.breakUndoCoalescing() }
            document.typingBookmarkNextLocation = nil
          }
          document.pendingBookmarks = updated
        } catch {
          present(error)
          return false
        }
      }
    }
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
    if let recordingDocumentID,
      documents.first(where: { $0.id == recordingDocumentID })?.saving == true
    {
      let alert = NSAlert()
      alert.messageText = "An editing command is still running"
      alert.informativeText = "Wait for it to finish before saving this macro recording."
      alert.runModal()
      return
    }
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
    notifySessionChange()
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
      + (document.saving ? "  |  Working…" : "")
      + (document.pendingPublication != nil
        ? "  |  Save not confirmed — retry Save or Save As" : "")
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
    guard !preparingToQuit, !windowClosed else { return }
    if onSessionChange != nil {
      notifySessionChange()
      return
    }
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
    guard !preparingToQuit, !windowClosed else { return }
    if onSessionChange != nil {
      notifySessionChange()
      return
    }
    let batch = recoveryBatch()
    let previous = recoveryWork
    recoveryWork = Task { [weak self, recovery] in
      await previous?.value
      do {
        try await recovery.persistBatch(batch)
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
      let error = await cleanup.value
      if let self, self.onSessionChange != nil {
        self.onSessionChange?()
      } else if let error {
        self?.reportRecoveryFailure(error)
      }
    }
  }

  /// Synchronous guard for the final no-await capture boundary, including zero-window captures.
  static func assertNoPendingCloses() throws {
    guard pendingCloses.isEmpty else {
      throw NSError(
        domain: "TheOnlyPad.Recovery", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Recovery cleanup is pending. Retry the checkpoint after cleanup completes."
        ])
    }
  }

  static func drainPendingCloses() async throws {
    while let (id, entry) = pendingCloses.first {
      if await entry.1.value != nil { try await entry.0.close(id: id) }
      pendingCloses.removeValue(forKey: id)
    }
  }

  static func finishPendingCloses() async -> Bool {
    do {
      try await drainPendingCloses()
      return true
    } catch {
      let alert = NSAlert()
      alert.messageText = "Discarded recovery data could not be removed"
      alert.informativeText =
        "Quit was cancelled so cleanup can be retried. " + error.localizedDescription
      alert.runModal()
      return false
    }
  }

  static func persistPreparedRecovery(_ editors: [EditorWindowController]) async throws {
    try await RecoveryCoordinator.shared.persistBatch(editors.flatMap { $0.recoveryBatch() })
  }

  func prepareToQuit(persistRecovery: Bool = true) async -> Bool {
    guard allowLeavingUnsavedRecording() else { return false }
    guard loadingCount == 0, !macroSaving, !documents.contains(where: { $0.saving }) else {
      let alert = NSAlert()
      alert.messageText = "A file operation is still running"
      alert.informativeText = "Wait for loading or saving to finish, then quit again."
      alert.runModal()
      return false
    }
    preparingToQuit = true
    for document in documents {
      if document.selectableBeforeQuit == nil {
        document.selectableBeforeQuit = document.editor.isSelectable
      }
      document.editor.isEditable = false
      document.editor.isSelectable = false
    }
    recoveryDebounce?.cancel()
    await recoveryWork?.value
    guard persistRecovery else { return true }
    do {
      try await recovery.persistBatch(recoveryBatch())
      return true
    } catch {
      cancelPreparedQuit()
      reportRecoveryFailure(error, always: true)
      return false
    }
  }

  func cancelPreparedQuit() {
    preparingToQuit = false
    for document in documents {
      let selectable = document.selectableBeforeQuit ?? document.editor.isSelectable
      document.editor.isEditable = !document.saving
      document.editor.isSelectable = selectable
      document.selectableBeforeQuit = nil
    }
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

  private func present(_ error: Error) {
    if let errorHandler { errorHandler(error) } else { NSAlert(error: error).runModal() }
  }
}
