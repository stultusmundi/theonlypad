import AppKit
import PadCore

struct SessionWindowCheckpointCapture: Sendable {
  let window: SessionWindow
  let liveTabIDs: Set<UUID>
  let recovery: [RecoveryCheckpointItem]
}

struct PaneCommandContext: Equatable {
  let documentID: UUID
  let paneID: UUID
  let editRevision: UInt64
  let selection: NSRange
}
enum PaneRoutingError: LocalizedError {
  case stale, composition
  var errorDescription: String? {
    switch self {
    case .stale: return "The source pane, document, or selection changed. Run the command again."
    case .composition: return "Finish text composition before changing panes."
    }
  }
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

private enum EditorSaveFailure: Error {
  case uncertain(PendingDocumentPublication)
}

/// Refuse known-denied editor focus before AppKit resigns the current responder.
@MainActor private final class EditorAdmissionWindow: NSWindow {
  private var checkingFocusAdmission = false
  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    guard !checkingFocusAdmission else { return false }
    if let editor = responder as? DocumentTextView, let canFocus = editor.canFocus {
      checkingFocusAdmission = true
      let admitted = canFocus()
      checkingFocusAdmission = false
      guard admitted else { return false }
    }
    // AppKit still performs becomeFirstResponder and its final admission check.
    return super.makeFirstResponder(responder)
  }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  let sessionID: UUID
  private let applicationRouting: EditorApplicationRouting?
  private var projectionToken: UUID?
  private var projectionFocus: (token: UUID, paneID: UUID)?
  private var projectionValid = false
  private var applicationPreparation: UUID?
  private var pendingEndpointAttachments = Set<UUID>()
  private var emptyWindowClosePermit: (id: UUID, revision: UUID)?
  private var recoveryWorkGeneration = UUID()
  private var recoveryWorkError: Error?
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
  private let host = EditorPaneHost(frame: .zero)
  private let workspaceSplit = NSSplitView()
  private lazy var workspace = WorkspaceSidebar { [weak self] url in self?.open(url) }
  private let status = NSTextField(labelWithString: "")
  private let panePresentationStatus = NSTextField(wrappingLabelWithString: "")
  private let panePresentationRow = NSStackView()
  private let restorePanePresentationButton = NSButton(
    title: "Restore Saved Split", target: nil, action: nil)
  private let discardPanePresentationButton = NSButton(
    title: "Use One Pane", target: nil, action: nil)
  private let checkpointStatus = NSTextField(wrappingLabelWithString: "")
  private let checkpointRetry = NSButton(title: "Retry", target: nil, action: nil)
  private let checkpointStatusRow = NSStackView()
  private var checkpointRetryAction: (() -> Void)?
  private let onSessionChange: (() -> Void)?
  private var current: EditorDocument? { documents.first { $0.id == selectedID } }
  var focusedPane: EditorPane? { current.map { preferredPane(in: $0) } }
  var visiblePanes: [EditorPane] { current?.panePool.filter(\.isAttached) ?? [] }
  private func preferredPane(in document: EditorDocument) -> EditorPane {
    document.panePool.first { $0.id == document.preferredPaneID && $0.isAttached }
      ?? document.panePool.first(where: \.isAttached) ?? document.panePool[0]
  }
  private func pane(for editor: NSTextView) -> EditorPane? {
    documents.lazy.flatMap(\.panePool).first { $0.editor === editor }
  }
  func paneContext() -> PaneCommandContext? {
    guard let pane = focusedPane else { return nil }
    return context(for: pane)
  }
  private func context(for pane: EditorPane) -> PaneCommandContext {
    PaneCommandContext(
      documentID: pane.document.id, paneID: pane.id,
      editRevision: pane.document.editRevision, selection: pane.editor.selectedRange())
  }
  func accepts(_ context: PaneCommandContext, requireFocus: Bool = true) -> Bool {
    guard !windowClosed, !preparingToQuit,
      let document = documents.first(where: { $0.id == context.documentID }),
      !document.saving, document.composingPaneID == nil,
      applicationAllows(.select, document: document),
      document.editRevision == context.editRevision,
      let pane = document.panePool.first(where: { $0.id == context.paneID && $0.isAttached })
    else { return false }
    return !requireFocus
      || (current === document && focusedPane === pane
        && pane.editor.selectedRange() == context.selection)
  }
  private func mayMutate(_ pane: EditorPane) -> Bool {
    let document = pane.document
    return applicationAllows(.edit, document: document)
      && !windowClosed && !preparingToQuit && !document.saving && pane.isAttached
      && document.panePresentation.installing == nil
      && documents.contains(where: { $0 === document })
      && (document.composingPaneID == nil || document.composingPaneID == pane.id)
  }
  private func refreshInteractivity(_ document: EditorDocument) {
    for pane in document.panePool {
      pane.editor.isEditable = mayMutate(pane)
      pane.editor.isSelectable =
        applicationAllows(.select, document: document) && !preparingToQuit && !windowClosed
    }
    renderDiskStatus()
  }
  func focusPane(id: UUID) throws {
    guard !windowClosed, !preparingToQuit,
      let document = current, document.panePresentation.installing == nil,
      applicationAllows(.select, document: document),
      let pane = document.panePool.first(where: { $0.id == id && $0.isAttached })
    else { throw PaneRoutingError.stale }
    guard document.composingPaneID == nil || document.composingPaneID == id
    else { throw PaneRoutingError.composition }
    let previous = focusedPane
    if previous !== pane {
      previous?.editor.breakUndoCoalescing()
      pane.editor.breakUndoCoalescing()
    }
    guard window?.makeFirstResponder(pane.editor) == true else { throw PaneRoutingError.stale }
    document.preferredPaneID = pane.id
    presentationInteraction(document)
    updateStatus()
  }
  private func admitPaneChange() throws -> (EditorDocument, EditorPane) {
    guard !windowClosed, !preparingToQuit, let document = current, let pane = focusedPane,
      !document.saving, document.panePresentation.installing == nil, pane.isAttached,
      applicationAllows(.paneInstall, document: document)
    else { throw PaneRoutingError.stale }
    guard document.composingPaneID == nil else { throw PaneRoutingError.composition }
    return (document, pane)
  }

  func splitCurrent(_ axis: PaneAxis) throws {
    let (document, source) = try admitPaneChange()
    let attached = document.panePool.filter(\.isAttached)
    guard attached.count == 2 || document.storage.length <= 2_000_000 else {
      throw NSError(
        domain: "TheOnlyPad", code: 24,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Split views currently support documents up to 2 million UTF-16 units. Use one pane or copy a smaller excerpt to a new tab."
        ])
    }
    guard document.panePresentation.pending == nil else {
      throw NSError(
        domain: "TheOnlyPad", code: 25,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Restore Saved Split or choose Use One Pane before changing this saved layout."
        ])
    }
    presentationInteraction(document)
    let selection = source.editor.selectedRange()
    let wrap = !source.editor.isHorizontallyResizable
    // Constructing another NSTextView can change attributes in its already-shared storage.
    let font = source.editor.font
    let paragraph = source.editor.defaultParagraphStyle
    let typingAttributes = source.editor.typingAttributes
    source.editor.breakUndoCoalescing()
    if attached.count == 1 {
      let additional = try document.makePane()
      additional.attach()
      installCallbacks(for: additional)
      additional.editor.font = font
      additional.editor.defaultParagraphStyle = paragraph
      additional.editor.typingAttributes = typingAttributes
      additional.editor.setSelectedRange(selection)
      document.highlighter.applyCachedTokens(to: additional.layoutManager)
    }
    document.splitAxis = axis
    document.preferredPaneID = source.id
    try presentPanes(document, wrap: wrap)
    try focusPane(id: source.id)
    source.editor.setSelectedRange(selection)
    document.panePresentation.warning = nil
    refresh()
  }

  func collapseToFocusedPane() throws {
    let (document, source) = try admitPaneChange()
    guard document.panePool.filter(\.isAttached).count == 2 else { throw PaneRoutingError.stale }
    presentationInteraction(document)
    document.panePresentation.pending = nil
    let selection = source.editor.selectedRange()
    let wrap = !source.editor.isHorizontallyResizable
    for pane in document.panePool where pane !== source && pane.isAttached {
      pane.editor.breakUndoCoalescing()
      pane.detach()
    }
    document.preferredPaneID = source.id
    try presentPanes(document, wrap: wrap)
    try focusPane(id: source.id)
    source.editor.setSelectedRange(selection)
    document.panePresentation.warning = nil
    refresh()
  }

  private func focusOtherPane() throws {
    let (document, source) = try admitPaneChange()
    guard let other = document.panePool.first(where: { $0.isAttached && $0 !== source })
    else { throw PaneRoutingError.stale }
    try focusPane(id: other.id)
  }

  private func presentPanes(_ document: EditorDocument, wrap: Bool) throws {
    let panes = document.panePool.filter(\.isAttached)
    try host.present(panes: panes, axis: document.splitAxis)
    window?.contentView?.layoutSubtreeIfNeeded()
    if let window {
      var minimum = NSSize(width: 540, height: 360)
      if panes.count == 2 {
        if document.splitAxis == .sideBySide {
          minimum.width = max(minimum.width, ceil(window.frame.width - host.bounds.width + 321))
        } else {
          minimum.height = max(minimum.height, ceil(window.frame.height - host.bounds.height + 321))
        }
      }
      window.minSize = minimum
      var frame = window.frame
      frame.size.width = max(frame.width, minimum.width)
      frame.size.height = max(frame.height, minimum.height)
      if frame != window.frame { window.setFrame(frame, display: false) }
      window.contentView?.layoutSubtreeIfNeeded()
    }
    configureWrap(document, enabled: wrap)
    refreshInteractivity(document)
  }

  private func activateSource(_ pane: EditorPane, snapshot: String, range: NSRange) throws {
    guard !windowClosed, !preparingToQuit,
      documents.contains(where: { $0 === pane.document }), pane.isAttached,
      !pane.document.saving, pane.document.composingPaneID == nil,
      current?.composingPaneID == nil,
      pane.document.storage.string.utf16.elementsEqual(snapshot.utf16),
      range.location >= 0, range.length >= 0, range.location <= (snapshot as NSString).length,
      range.length <= (snapshot as NSString).length - range.location,
      Range(range, in: snapshot) != nil
    else { throw PaneRoutingError.stale }
    pane.document.preferredPaneID = pane.id
    display(pane.document)
    try focusPane(id: pane.id)
    pane.editor.setSelectedRange(range)
    pane.editor.scrollRangeToVisible(range)
  }
  private var settings = EditorSettings.defaults
  private var loadingCount = 0
  private var preparingToQuit = false
  private var windowClosed = false
  private var fileMonitoring: ApplicationFileMonitoring?
  private var diskActions: DocumentDiskActionCoordinator?
  private var locateActions: DocumentLocateCoordinator?
  var confirmDiskReload: ((EditorDocument) -> Bool)?
  var chooseDiskLocation: ((URL?) -> URL?)?
  private var pendingFileStateAdoptions: Set<UUID> = []
  private var onDiskStateChange: (() -> Void)?
  private var diskConflict: DocumentDiskConflictController?
  private var diskConflictDocumentID: UUID?
  private lazy var diskStatusRow = DocumentDiskStatusView { [weak self] action in
    self?.performDiskStatusAction(action)
  }
  func configureFileMonitoring(_ owner: ApplicationFileMonitoring) {
    guard fileMonitoring == nil, !windowClosed else { return }
    fileMonitoring = owner
    diskActions = DocumentDiskActionCoordinator(application: owner)
    locateActions = DocumentLocateCoordinator(application: owner)
    onDiskStateChange = { [weak self] in self?.renderDiskStatus() }
    for document in documents {
      if applicationRouting != nil {
        do {
          try attachDocumentEndpoint(document)
          pendingEndpointAttachments.remove(document.id)
        } catch {
          pendingEndpointAttachments.insert(document.id)
          errorHandler?(error)
        }
      } else {
        adoptFileState(document)
      }
    }
    renderDiskStatus()
  }
  func reconcileFileMonitoring() {
    if fileMonitoring?.isSuspended == true || preparingToQuit {
      diskConflict?.close()
      diskConflict = nil
      diskConflictDocumentID = nil
    }
    for document in documents {
      if pendingFileStateAdoptions.contains(document.id) { adoptFileState(document) }
      document.fileState?.reconcileEligibility()
    }
    onDiskStateChange?()
  }
  private func fileStateContext(_ document: EditorDocument) -> FileStateLiveContext? {
    guard let owner = fileMonitoring else { return nil }
    return FileStateLiveContext(
      documentID: document.id, ownershipGeneration: document.ownershipGeneration,
      bindingID: document.fileBindingID,
      baselineRevision: document.baselineRevision, url: document.url,
      editRevision: document.editRevision, encoding: document.encoding, hasBOM: document.hasBOM,
      dirty: document.dirty, pendingPublicationID: document.pendingPublication?.id,
      operationID: document.operationID, composing: document.composingPaneID != nil,
      recording: isRecordingMacro,
      closed: windowClosed || !documents.contains(where: { $0 === document }),
      quitting: preparingToQuit || owner.isSuspended,
      deliveryGeneration: owner.deliveryGeneration)
  }
  private func attachDocumentEndpoint(_ document: EditorDocument) throws {
    guard let routing = applicationRouting, document.fileState != nil else {
      adoptFileState(document)
      return
    }
    try routing.reattachDocumentEndpoint(
      document,
      { [weak self, weak document] in
        guard let self, let document else { return nil }
        return self.fileStateContext(document)
      }, { [weak self] in self?.onDiskStateChange?() })
  }
  private func adoptFileState(
    _ document: EditorDocument, validatedIdentity: FileTargetIdentity? = nil
  ) {
    guard let owner = fileMonitoring, !windowClosed,
      documents.contains(where: { $0 === document }), document.url != nil,
      let bytes = document.originalBytes
    else { return }
    guard !owner.isSuspended, !preparingToQuit else {
      pendingFileStateAdoptions.insert(document.id)
      return
    }
    if document.fileState == nil {
      document.fileState = DocumentFileStateController(
        documentID: document.id, client: owner.client,
        liveContext: { [weak self, weak document] in
          guard let self, let document else { return nil }
          return self.fileStateContext(document)
        }, onChange: { [weak self] in self?.onDiskStateChange?() })
    }
    document.fileState?.adoptBaseline(bytes: bytes, validatedIdentity: validatedIdentity)
    pendingFileStateAdoptions.remove(document.id)
  }
  private func invalidateFileState(_ document: EditorDocument) {
    if diskConflictDocumentID == document.id {
      diskConflict?.close()
      diskConflict = nil
      diskConflictDocumentID = nil
    }
    pendingFileStateAdoptions.remove(document.id)
    document.fileState?.invalidate()
    fileMonitoring?.cancelAction(documentID: document.id)
  }
  private func renderDiskStatus() {
    let document = current
    let bridge = document?.fileState
    diskStatusRow.render(
      state: bridge?.state ?? ObservedFileState(), manualNotice: bridge?.manualNotice,
      failure: bridge?.lastFailure,
      hasSource: fileMonitoring != nil && document?.url != nil,
      enabled: !windowClosed && !preparingToQuit && fileMonitoring?.isSuspended != true
        && document?.saving == false && document?.composingPaneID == nil
        && document.map({ applicationAllows(.fileOperation, document: $0) }) == true)
  }
  private func performDiskStatusAction(_ action: DocumentDiskStatusView.Action) {
    guard !windowClosed, !preparingToQuit, fileMonitoring?.isSuspended == false,
      let document = current, !document.saving, document.composingPaneID == nil,
      applicationAllows(.fileOperation, document: document),
      let bridge = document.fileState
    else { return }
    switch action {
    case .checkAgain: bridge.checkAgain()
    case .retryMonitoring: bridge.retryRegistration()
    case .resolve:
      guard let panel = makeDiskConflict(document) else { return }
      diskConflict?.close()
      diskConflict = panel
      diskConflictDocumentID = document.id
      panel.showWindow(nil)
    }
  }
  private func makeDiskConflict(_ document: EditorDocument) -> DocumentDiskConflictController? {
    guard !windowClosed, !preparingToQuit, fileMonitoring?.isSuspended == false,
      documents.contains(where: { $0 === document }),
      applicationAllows(.fileOperation, document: document), let bridge = document.fileState,
      bridge.state.observation != nil
    else { return nil }
    var actions: [DocumentDiskConflictController.Action] = []
    if let context = bridge.captureAction(.keepBuffer) {
      actions.append(
        .init(title: "Keep Buffer", accessibilityID: "document.keepBuffer") {
          [weak self, weak document] in
          guard let self, let document, self.documents.contains(where: { $0 === document }),
            self.applicationAllows(.fileOperation, document: document)
          else {
            return
          }
          guard bridge.keepBuffer(context) else {
            self.reportStaleDiskAction()
            return
          }
        })
    }
    if let context = bridge.captureAction(.saveAs) {
      actions.append(
        .init(title: "Save As…", accessibilityID: "document.diskSaveAs") {
          [weak self, weak document] in
          guard let self, let document, self.documents.contains(where: { $0 === document }),
            self.applicationAllows(.fileOperation, document: document)
          else {
            return
          }
          guard bridge.isCurrent(context) else {
            self.reportStaleDiskAction()
            return
          }
          self.save(document, saveAs: true)
        })
    }
    for (action, title, identifier) in [
      (FileConflictAction.reload, "Reload from Disk…", "document.diskReload"),
      (.openDiskCopy, "Open Disk Copy", "document.diskCopy"),
    ] {
      if let context = bridge.captureAction(action) {
        actions.append(
          .init(title: title, accessibilityID: identifier) { [weak self, weak document] in
            guard let self, let document else { return }
            self.performCheckedDiskAction(document, context: context)
          })
      }
    }
    if !isRecordingMacro, let context = bridge.captureAction(.locate) {
      actions.append(
        .init(title: "Locate File…", accessibilityID: "document.locateFile") {
          [weak self, weak document] in
          guard let self, let document else { return }
          self.locateFile(document, context: context)
        })
    }
    actions.append(
      .init(title: "Check Again", accessibilityID: "document.checkDisk") {
        [weak self, weak document] in
        guard let self, let document, !self.windowClosed, !self.preparingToQuit,
          self.fileMonitoring?.isSuspended == false,
          self.applicationAllows(.fileOperation, document: document),
          self.documents.contains(where: { $0 === document })
        else { return }
        bridge.checkAgain()
      })
    actions.append(
      .init(title: "Retry Monitoring", accessibilityID: "document.retryMonitoring") {
        [weak self, weak document] in
        guard let self, let document, !self.windowClosed, !self.preparingToQuit,
          self.fileMonitoring?.isSuspended == false,
          self.applicationAllows(.fileOperation, document: document),
          self.documents.contains(where: { $0 === document })
        else { return }
        bridge.retryRegistration()
      })
    actions.append(
      .init(title: "Use Manual Checks", accessibilityID: "document.manualChecks") {
        [weak self, weak document] in
        guard let self, let document, !self.windowClosed, !self.preparingToQuit,
          self.fileMonitoring?.isSuspended == false,
          self.applicationAllows(.fileOperation, document: document),
          self.documents.contains(where: { $0 === document })
        else { return }
        bridge.useManualFallback()
      })
    return DocumentDiskConflictController(
      documentName: document.name,
      explanation:
        "The buffer is preserved. Keeping it does not authorize overwriting a changed file. Save As writes to a new filename."
        + (bridge.state.observation?.movedCandidate.map { " Suggested location: " + $0.path } ?? ""),
      actions: actions)
  }
  private func locateFile(_ document: EditorDocument, context: FileStateActionContext) {
    guard applicationUserAllows(.fileOperation, document: document), context.action == .locate,
      let bridge = document.fileState,
      bridge.isCurrent(context), !isRecordingMacro, document.pendingPublication == nil,
      let originalURL = document.url, let bytes = document.originalBytes,
      let coordinator = locateActions
    else {
      reportStaleDiskAction()
      return
    }
    let suggested = bridge.state.observation?.movedCandidate ?? originalURL
    let candidate: URL?
    if let chooseDiskLocation {
      candidate = chooseDiskLocation(suggested)
    } else {
      let panel = NSOpenPanel()
      panel.title = "Locate File"
      panel.message =
        "Choose the file containing the last saved bytes. Your buffer edits will be kept."
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.directoryURL = suggested.deletingLastPathComponent()
      panel.nameFieldStringValue = suggested.lastPathComponent
      candidate = panel.runModal() == .OK ? panel.url : nil
    }
    guard let candidate else { return }
    guard bridge.isCurrent(context), !isRecordingMacro, document.pendingPublication == nil else {
      reportStaleDiskAction()
      return
    }
    let input = DocumentLocateInput(
      documentID: document.id, originalURL: originalURL, candidateURL: candidate,
      baselineRevision: document.baselineRevision, originalBytes: bytes)
    let admitted = coordinator.start(
      input,
      callbacks: DocumentLocateCallbacks(
        beginOperation: { [weak self, weak document] in
          guard let self, let document, !self.isRecordingMacro, bridge.isCurrent(context),
            !document.saving, document.pendingPublication == nil,
            self.applicationAllows(.fileOperation, document: document)
          else { return nil }
          let operation = document.beginFileOperation()
          document.saving = true
          self.refreshInteractivity(document)
          return operation
        },
        isCurrent: { [weak self, weak document] operation in
          guard let self, let document else { return false }
          return !self.isRecordingMacro && document.pendingPublication == nil
            && bridge.isCurrent(context, owningOperation: operation)
        },
        apply: { [weak self, weak document] url, identity, operation in
          guard let self, let document, document.operationID == operation else {
            throw CancellationError()
          }
          self.applyLocatedFile(document, url: url, identity: identity)
        },
        finish: { [weak self, weak document] operation in
          Self.completeFileOperation(document, id: operation, controller: self)
        },
        reportError: { [weak self] error in self?.reportLocateError(error) }))
    if !admitted, bridge.isCurrent(context) { reportDiskActionError(FileActionError.capacity) }
  }
  private func applyLocatedFile(
    _ document: EditorDocument, url: URL, identity: FileTargetIdentity
  ) {
    let changedURL = document.url != url
    document.url = url
    document.acknowledgeFileBaseline()
    adoptFileState(document, validatedIdentity: identity)
    if !document.manualLanguage {
      document.language = LanguageService.detect(
        filename: document.name, text: document.storage.string)
    }
    document.highlighter.update(language: document.language)
    refresh()
    // refresh records the single controller session change; standalone windows need recovery too.
    if onSessionChange == nil { scheduleRecovery() }
    if changedURL { onOpenedURL?(url) }
  }
  private func reportLocateError(_ error: Error) {
    guard !windowClosed, !preparingToQuit, fileMonitoring?.isSuspended == false,
      !(error is CancellationError), (error as? MonitorFailure) != .cancelled
    else { return }
    let message: String
    switch error as? DocumentLocateError {
    case .differentBytes:
      message =
        "That file has different bytes from the last saved version. Your buffer and original location are preserved. Choose another file, or open this file separately."
    case .changedCandidate:
      message =
        "The selected file changed while it was being checked. Your buffer and original location are preserved. Locate it again."
    case .unavailable(.notDownloaded):
      message =
        "Download the selected file explicitly before locating it again. Your buffer and original location are preserved."
    default:
      message =
        "The selected file could not be verified. Choose an accessible local regular file containing the last saved bytes. Your buffer and original location are preserved."
    }
    present(NSError(domain: "TheOnlyPad", code: 26, userInfo: [NSLocalizedDescriptionKey: message]))
  }
  private func performCheckedDiskAction(
    _ document: EditorDocument, context: FileStateActionContext
  ) {
    guard applicationUserAllows(.fileOperation, document: document),
      let bridge = document.fileState, bridge.isCurrent(context),
      let url = document.url, let observation = bridge.state.observation,
      let coordinator = diskActions,
      context.action == .reload || context.action == .openDiskCopy
    else {
      reportStaleDiskAction()
      return
    }
    let reload = context.action == .reload
    let panes = document.panePool
    let ranges = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.editor.selectedRange()) })
    let attached = panes.map(\.isAttached)
    let axis = document.splitAxis
    let input = DocumentDiskActionInput(
      documentID: document.id, url: url, observation: observation,
      savedEncoding: document.savedEncoding, action: reload ? .reload : .copy,
      requiresDiscard: document.dirty || document.pendingPublication != nil,
      selections: reload ? ranges : [:], copySourceName: reload ? nil : document.name)
    let admitted = coordinator.start(
      input,
      callbacks: DocumentDiskActionCallbacks(
        beginOperation: { [weak self, weak document] in
          guard let self, let document, bridge.isCurrent(context), !document.saving,
            self.applicationAllows(.fileOperation, document: document)
          else {
            return nil
          }
          let operation = document.beginFileOperation()
          document.saving = true
          self.refreshInteractivity(document)
          return operation
        },
        isCurrent: { [weak document] operation in
          guard let document, bridge.isCurrent(context, owningOperation: operation) else {
            return false
          }
          guard reload else { return true }
          return document.panePool.map(\.id) == panes.map(\.id)
            && document.panePool.map(\.isAttached) == attached && document.splitAxis == axis
            && panes.allSatisfy { $0.editor.selectedRange() == ranges[$0.id] }
        },
        confirmDiscard: { [weak self, weak document] _ in
          guard let self, let document else { return false }
          return self.confirmDiskReload?(document) ?? self.confirmCheckedDiskReload(document)
        },
        apply: { [weak self, weak document] prepared, operation in
          guard let self, let document, !self.windowClosed, !self.preparingToQuit,
            self.documents.contains(where: { $0 === document }), document.operationID == operation,
            bridge.isCurrent(context, owningOperation: operation)
          else { throw CancellationError() }
          switch prepared {
          case .reload(let snapshot, let selections):
            guard reload else { throw CancellationError() }
            self.applyCheckedDiskReload(document, snapshot: snapshot, selections: selections)
          case .copy(_, let seed):
            guard !reload, seed.kind == .diskCopy else { throw CancellationError() }
            if self.applicationRouting != nil {
              // Source authority is consumed now. Intake owns the immutable seed before the
              // disk coordinator finishes this operation; later destination checks exclude it.
              let id = try self.submitApplicationSeed(
                seed, provenance: .fresh,
                selection: .selectIfStillSelected(
                  documentID: document.id, ownershipGeneration: document.ownershipGeneration))
              self.observeApplicationIntake(id)
            } else {
              try self.openCheckedDiskCopy(document, seed: seed)
            }
          }
        },
        finish: { [weak self, weak document] operation in
          Self.completeFileOperation(document, id: operation, controller: self)
          guard let self, !self.windowClosed, !self.preparingToQuit else { return }
          self.renderDiskStatus()
        },
        reportError: { [weak self] error in self?.reportDiskActionError(error) }))
    if !admitted, bridge.isCurrent(context) {
      reportDiskActionError(FileActionError.capacity)
    }
  }
  /// All validation/preparation precedes this nonthrowing, coherent owner adoption.
  private func applyCheckedDiskReload(
    _ document: EditorDocument, snapshot: ExternalFileActionSnapshot, selections: [UUID: NSRange]
  ) {
    document.storage.mutableString.setString(snapshot.document.text)
    document.bookmarks.removeAll()
    document.pendingBookmarks = nil
    document.compositionBookmarks = nil
    document.compositionOriginalText = nil
    document.compositionUndoRegistered = false
    document.typingBookmarkNextLocation = nil
    document.pendingBookmarksHaveUndo = false
    for pane in document.panePool {
      (pane.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = []
      if let range = selections[pane.id] { pane.editor.setSelectedRange(range) }
    }
    document.savedText = snapshot.document.text
    document.originalBytes = snapshot.bytes
    document.pendingPublication = nil
    document.encoding = snapshot.document.encoding
    document.hasBOM = snapshot.document.hasBOM
    document.savedEncoding = snapshot.document.encoding
    document.savedHasBOM = snapshot.document.hasBOM
    document.undoManager.removeAllActions()
    document.acknowledgeFileBaseline()
    adoptFileState(document)
    updateLanguage(document)
    refresh()
    scheduleRecovery()
  }
  private func openCheckedDiskCopy(_ source: EditorDocument, seed: NativeDocumentSeed) throws {
    let copy = try EditorDocumentFactory.make(seed)
    copy.onCharactersChanged = { [weak self] in self?.notifySessionChange() }
    for pane in copy.panePool { installCallbacks(for: pane) }
    documents.append(copy)
    if current === source {
      display(copy)
    } else {
      refresh()
    }
    scheduleRecovery()
  }
  static func diskReloadConfirmationText(_ document: EditorDocument) -> String {
    if document.pendingPublication != nil {
      return document.name
        + " has an unconfirmed save that may already have written the file on disk. Reload discards your buffer changes and the retained save retry state. Cancel to keep your edits and verify or retry the save first."
    }
    return document.name
      + " has unsaved changes. Reload discards them. Cancel to save your work first."
  }
  private func confirmCheckedDiskReload(_ document: EditorDocument) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Reload from disk and discard retained changes?"
    alert.informativeText = Self.diskReloadConfirmationText(document)
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Reload from Disk")
    return alert.runModal() == .alertSecondButtonReturn
  }
  private func reportDiskActionError(_ error: Error) {
    guard !windowClosed, !preparingToQuit, fileMonitoring?.isSuspended == false,
      !(error is CancellationError), (error as? FileActionError) != .cancelled
    else { return }
    let message: String
    switch error as? FileActionError {
    case .capacity:
      message = "Another disk action is still finishing. Try this action again shortly."
    case .observationChanged:
      message =
        "The file changed again. Your buffer is preserved. Check the file again before reloading."
    case .decoding:
      message =
        "The disk copy cannot be decoded safely with this encoding. Your buffer is preserved. Use Open or Reopen with Encoding to choose an interpretation."
    case .notDownloaded:
      message = "Download the file explicitly, then check it again. Your buffer is preserved."
    case .policy:
      message =
        "The system could not safely check this file without downloading it. Your buffer is preserved."
    default:
      message =
        "The disk action could not finish. Your buffer is preserved. Check the file and its permissions, then try again."
    }
    present(NSError(domain: "TheOnlyPad", code: 25, userInfo: [NSLocalizedDescriptionKey: message]))
  }
  private func reportStaleDiskAction() {
    guard !windowClosed, !preparingToQuit, fileMonitoring?.isSuspended == false else { return }
    present(
      NSError(
        domain: "TheOnlyPad", code: 24,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The document or file status changed. Check the file again before choosing an action."
        ]))
  }
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

  convenience init(
    id: UUID = UUID(), restoreStartup: Bool = true,
    saveServices: EditorSaveServices = EditorSaveServices(),
    chooseSaveDestination: ((URL?, String) -> URL?)? = nil,
    onError: ((Error) -> Void)? = nil,
    onSessionChange: (() -> Void)? = nil
  ) {
    self.init(
      id: id, restoreStartup: restoreStartup, saveServices: saveServices,
      chooseSaveDestination: chooseSaveDestination, onError: onError,
      onSessionChange: onSessionChange, applicationRouting: nil)
  }

  convenience init(
    id: UUID, application: EditorApplicationRouting,
    saveServices: EditorSaveServices = EditorSaveServices(),
    chooseSaveDestination: ((URL?, String) -> URL?)? = nil,
    onError: ((Error) -> Void)? = nil
  ) throws {
    try application.requireEndpointCurrent()
    guard id == application.assignment.windowID,
      let window = application.registry.window(id: id), window.groups.count == 1,
      window.groups[0].id == application.assignment.groupID
    else { throw EditorApplicationRoutingError.staleEndpoint }
    self.init(
      id: id, restoreStartup: false, saveServices: saveServices,
      chooseSaveDestination: chooseSaveDestination, onError: onError,
      onSessionChange: nil, applicationRouting: application)
  }

  private init(
    id: UUID, restoreStartup: Bool, saveServices: EditorSaveServices,
    chooseSaveDestination: ((URL?, String) -> URL?)?, onError: ((Error) -> Void)?,
    onSessionChange: (() -> Void)?, applicationRouting: EditorApplicationRouting?
  ) {
    self.applicationRouting = applicationRouting
    self.onSessionChange = onSessionChange
    self.saveServices = saveServices
    self.chooseSaveDestination = chooseSaveDestination
    self.errorHandler = onError
    sessionID = id
    let window = EditorAdmissionWindow(
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
    panePresentationStatus.setAccessibilityIdentifier("session.panes.status")
    restorePanePresentationButton.setAccessibilityIdentifier("session.panes.restore")
    discardPanePresentationButton.setAccessibilityIdentifier("session.panes.discard")
    restorePanePresentationButton.target = self
    restorePanePresentationButton.action = #selector(restoreSavedPanePresentation)
    discardPanePresentationButton.target = self
    discardPanePresentationButton.action = #selector(discardSavedPanePresentation)
    panePresentationRow.orientation = .vertical
    panePresentationRow.alignment = .leading
    panePresentationRow.addArrangedSubview(panePresentationStatus)
    panePresentationStatus.widthAnchor.constraint(equalTo: panePresentationRow.widthAnchor)
      .isActive = true
    panePresentationRow.addArrangedSubview(
      NSStackView(views: [restorePanePresentationButton, discardPanePresentationButton]))
    panePresentationRow.isHidden = true
    let stack = NSStackView(views: [
      tabBar, tabs, languagePicker, diskStatusRow, workspaceSplit, status, checkpointStatusRow,
      panePresentationRow,
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
    if applicationRouting == nil && onSessionChange == nil {
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

  private func capturePresentation(_ document: EditorDocument) -> SessionPresentation {
    document.panePresentation.capture(
      panes: document.panePool.filter(\.isAttached),
      preferred: preferredPane(in: document), axis: document.splitAxis)
  }

  private func presentationInteraction(_ document: EditorDocument) {
    guard !windowClosed, !preparingToQuit else { return }
    document.panePresentation.invalidate()
  }

  private func renderPanePresentationStatus() {
    guard let document = current else {
      panePresentationRow.isHidden = true
      return
    }
    let state = document.panePresentation
    let deferred = state.pending?.presentation.panes.count == 2
    panePresentationRow.isHidden = !deferred && state.warning == nil
    let deferredMessage =
      deferred
      ? "Saved split is deferred. Restore it when this document is at most 2 million UTF-16 units, or keep one pane."
      : nil
    panePresentationStatus.stringValue = [deferredMessage, state.warning].compactMap { $0 }.joined(
      separator: "\n")
    restorePanePresentationButton.isHidden = !deferred
    discardPanePresentationButton.isHidden = !deferred
    let eligible =
      !windowClosed && !preparingToQuit && !document.saving
      && applicationAllows(.paneInstall, document: document)
      && document.composingPaneID == nil && document.operationID == nil && state.installing == nil
      && !document.panePool.contains(where: { $0.isAttached && $0.editor.hasMarkedText() })
    restorePanePresentationButton.isEnabled = eligible && document.storage.length <= 2_000_000
    discardPanePresentationButton.isEnabled = eligible
  }

  @objc private func discardSavedPanePresentation() {
    guard let document = current, !windowClosed, !preparingToQuit, !document.saving,
      applicationAllows(.paneInstall, document: document),
      document.composingPaneID == nil, document.operationID == nil,
      document.panePresentation.installing == nil,
      !document.panePool.contains(where: { $0.isAttached && $0.editor.hasMarkedText() })
    else { return }
    document.panePresentation.invalidate(force: true)
    document.panePresentation.pending = nil
    document.panePresentation.warning = nil
    renderPanePresentationStatus()
    notifySessionChange()
  }

  @objc private func restoreSavedPanePresentation() {
    guard let document = current, applicationAllows(.select, document: document) else { return }
    restorePendingPresentation(document)
  }

  private func restorePendingPresentation(_ document: EditorDocument) {
    guard projectionAllows(.paneInstall, document: document) else { return }
    let state = document.panePresentation
    guard canInstallPresentation(document), state.installing == nil, state.pending != nil,
      state.pending?.presentation.panes.count == 1 || document.storage.length <= 2_000_000
    else { return }
    do {
      let value = capturePresentation(document)
      try value.validate()
      // Two endpoint ranges only. No text copy, bookmark scan, worker or delayed replay.
      let source = document.storage.mutableString
      let panes = try value.panes.map {
        SessionPaneState(
          selection: try RestoredSelection.resolve($0.selection, inUTF16: source),
          scrollOrigin: $0.scrollOrigin)
      }
      let resolved = SessionPresentation(
        axis: value.axis, panes: panes,
        focusedPaneIndex: value.focusedPaneIndex)
      try installResolvedPanes(resolved, on: document)
      if panes.map(\.selection) != value.panes.map(\.selection) {
        state.warning = "Saved pane selections were adjusted to the current document."
      }
    } catch {
      if !windowClosed, !preparingToQuit, documents.contains(where: { $0 === document }) {
        state.warning =
          state.pending?.presentation.panes.count == 2
          ? "The document or view changed. Its saved layout was retained; use Restore Saved Split again."
          : "The document or view changed. The current single-pane view was preserved."
      }
    }
    if !windowClosed { renderPanePresentationStatus() }
    notifySessionChange()
  }

  private func canInstallPresentation(_ document: EditorDocument) -> Bool {
    !windowClosed && !preparingToQuit && current === document
      && projectionAllows(.paneInstall, document: document)
      && documents.contains(where: { $0 === document })
      && !document.saving && document.operationID == nil && document.composingPaneID == nil
      && !document.panePool.contains(where: { $0.isAttached && $0.editor.hasMarkedText() })
  }

  /// No suspension. AppKit callbacks can still reenter, so every native mutation is fenced.
  private func installResolvedPanes(
    _ presentation: SessionPresentation, on document: EditorDocument
  ) throws {
    try presentation.validate()
    let state = document.panePresentation
    guard canInstallPresentation(document), state.installing == nil else {
      throw PaneRoutingError.stale
    }
    let token = UUID()
    let interaction = state.interaction
    let revision = document.editRevision
    let original = document.panePool.filter(\.isAttached)
    guard original.count == 1 else { throw PaneRoutingError.stale }
    let live = preferredPane(in: document)
    let oldAxis = document.splitAxis
    let oldPreferred = document.preferredPaneID
    let oldSelection = live.editor.selectedRange()
    var expectedSelection = oldSelection
    var expectedPanes = original
    var expectedRanges = [live.id: oldSelection]
    var expectedPreferred = oldPreferred
    var expectedAxis = oldAxis
    var additional: EditorPane?
    var committed = false
    state.installing = token
    state.suppression += 1
    let wrap = !live.editor.isHorizontallyResizable
    defer {
      if !committed {
        // The pool retains native undo targets, but a refused transaction must not leave a
        // newly attached layout. Do not overwrite selection changed by a reentrant owner.
        additional?.detach()
        if document.preferredPaneID == expectedPreferred { document.preferredPaneID = oldPreferred }
        if document.splitAxis == expectedAxis { document.splitAxis = oldAxis }
        if original.allSatisfy(\.isAttached),
          document.panePool.filter(\.isAttached).count == original.count
        {
          document.orderAttachedPanes(original)
        }
        if !windowClosed, current === document, documents.contains(where: { $0 === document }) {
          if document.editRevision == revision, document.composingPaneID == nil,
            !live.editor.hasMarkedText(), live.editor.selectedRange() == expectedSelection,
            let restored = try? RestoredSelection.resolve(
              oldSelection, inUTF16: document.storage.mutableString)
          {
            live.editor.setSelectedRange(restored)
          }
          if !windowClosed, !preparingToQuit, current === document,
            documents.contains(where: { $0 === document })
          {
            do { try presentPanes(document, wrap: wrap) } catch {
              state.warning =
                "The saved layout was retained, but its current view could not be restored. Try restoring the saved layout again."
            }
          }
        }
      }
      state.suppression -= 1
      if state.installing == token { state.installing = nil }
      if !windowClosed, documents.contains(where: { $0 === document }) {
        refreshInteractivity(document)
      }
    }
    func validateAuthority() throws {
      guard state.installing == token, canInstallPresentation(document),
        document.editRevision == revision, state.interaction == interaction,
        document.preferredPaneID == expectedPreferred, document.splitAxis == expectedAxis,
        document.panePool.filter(\.isAttached).map(\.id) == expectedPanes.map(\.id),
        expectedPanes.allSatisfy({ $0.editor.selectedRange() == expectedRanges[$0.id] }),
        live.isAttached, live.editor.selectedRange() == expectedSelection
      else { throw PaneRoutingError.stale }
    }
    let slot = state.pending?.liveSlot ?? 0
    let font = live.editor.font
    let paragraph = live.editor.defaultParagraphStyle
    let attributes = live.editor.typingAttributes
    var panes = [live]
    if presentation.panes.count == 2 {
      guard document.storage.length <= 2_000_000 else { throw EditorPaneError.limit }
      let second = try document.makePane()
      additional = second
      expectedPanes = document.panePool.filter { $0.isAttached || $0 === second }
      expectedRanges[second.id] = second.editor.selectedRange()
      // A reused pane is detached until attach(), while a newly created pane starts attached.
      guard canInstallPresentation(document), state.interaction == interaction,
        document.editRevision == revision
      else { throw PaneRoutingError.stale }
      second.attach()
      try validateAuthority()
      installCallbacks(for: second)
      second.editor.font = font
      try validateAuthority()
      second.editor.defaultParagraphStyle = paragraph
      second.editor.typingAttributes = attributes
      document.highlighter.applyCachedTokens(to: second.layoutManager)
      try validateAuthority()
      panes = slot == 0 ? [live, second] : [second, live]
    }
    document.orderAttachedPanes(panes)
    expectedPanes = panes
    for (index, pane) in panes.enumerated() {
      if pane === live { expectedSelection = presentation.panes[index].selection }
      expectedRanges[pane.id] = presentation.panes[index].selection
      try pane.editor.withSelectionInstallation(
        authorizedBy: { [weak self, weak document] in
          guard let self, let document else { return false }
          return state.installing == token && self.canInstallPresentation(document)
        },
        {
          pane.editor.setSelectedRange(presentation.panes[index].selection)
        })
      try validateAuthority()
      guard pane.editor.selectedRange() == presentation.panes[index].selection else {
        throw PaneRoutingError.stale
      }
    }
    expectedAxis = presentation.axis == .stacked ? .stacked : .sideBySide
    document.splitAxis = expectedAxis
    expectedPreferred = panes[presentation.focusedPaneIndex].id
    document.preferredPaneID = expectedPreferred
    try presentPanes(document, wrap: wrap)
    try validateAuthority()
    window?.makeFirstResponder(panes[presentation.focusedPaneIndex].editor)
    try validateAuthority()
    state.warning = nil
    for (index, pane) in panes.enumerated() {
      if !DocumentPanePresentation.applyOrigin(presentation.panes[index].scrollOrigin, to: pane) {
        state.warning = "Saved scroll position could not be restored with the available layout."
      }
      try validateAuthority()
    }
    state.pending = nil
    committed = true
  }

  private func installPendingPresentationIfPossible(_ document: EditorDocument) {
    let state = document.panePresentation
    guard var pending = state.pending else { return }
    if pending.presented { return }
    let mayInstall = pending.presentation.panes.count == 1 || document.storage.length <= 2_000_000
    if mayInstall && pending.resolvedAtRevision == document.editRevision {
      // The live slot is now visible even when split installation is refused.
      // Retain dormant metadata, but never freeze subsequent live caret/scroll capture.
      pending.presented = true
      state.pending = pending
      do { try installResolvedPanes(pending.presentation, on: document) } catch {
        state.warning = error.localizedDescription
      }
      renderPanePresentationStatus()
      return
    }
    // A deferred live pane consumes its own scroll attempt now, with no later replay.
    state.suppression += 1
    let live = preferredPane(in: document)
    if !DocumentPanePresentation.applyOrigin(
      pending.presentation.panes[pending.liveSlot].scrollOrigin, to: live)
    {
      state.warning = "Saved scroll position could not be restored with the available layout."
    }
    pending.presented = true
    state.pending = pending
    state.suppression -= 1
    guard mayInstall else {
      renderPanePresentationStatus()
      return
    }
    guard pending.resolvedAtRevision == document.editRevision else {
      restorePendingPresentation(document)
      return
    }
    do { try installResolvedPanes(pending.presentation, on: document) } catch {
      state.warning = error.localizedDescription
    }
    renderPanePresentationStatus()
  }

  private func notifySessionChange() {
    guard !preparingToQuit, !windowClosed, projectionToken == nil,
      !documents.contains(where: { $0.panePresentation.suppression > 0 })
    else { return }
    if let applicationRouting { applicationRouting.requestCheckpoint() } else { onSessionChange?() }
  }

  func captureSessionCheckpoint() throws -> SessionWindowCheckpointCapture {
    guard applicationRouting == nil, documents.allSatisfy({ $0.recoveryAuthority == nil }) else {
      throw EditorApplicationRoutingError.applicationOwned
    }
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
          selection: preferredPane(in: document).editor.selectedRange(),
          bookmarks: document.bookmarks.offsets, presentation: capturePresentation(document))
      }, selectedTabID: selectedID)
  }

  /// Scalar budget preflight; no recovery snapshot or String copy is constructed here.
  var checkpointRecoveryUTF16Count: Int {
    documents.reduce(0) { count, document in
      count + (document.url == nil || document.dirty ? document.storage.length : 0)
    }
  }

  var sessionResourceUsage: (utf16Count: Int, originalByteCount: Int) {
    documents.reduce(into: (utf16Count: 0, originalByteCount: 0)) { usage, document in
      usage.utf16Count += document.storage.length
      usage.originalByteCount += document.originalBytes?.count ?? 0
    }
  }

  /// The caller performs decoding and position validation off-main before importing.
  /// Recovery content passes nil URL/bytes and remains scratch regardless of historical metadata.
  func restoreSessionTab(
    _ metadata: SessionTab, decoded: DecodedDocument, originalBytes: Data?, url: URL?,
    viewState: RestoredViewState, insertionIndex: Int? = nil,
    resolvedPresentation: RestoredPresentationState? = nil, activate: Bool = true
  ) throws {
    guard applicationRouting == nil else {
      throw EditorApplicationRoutingError.preparedSeedRequired
    }
    guard !windowClosed, !preparingToQuit else { throw CancellationError() }
    guard
      metadata.presentation == .single(selection: metadata.selection) || resolvedPresentation != nil
    else {
      throw SessionStoreError.invalidMetadata
    }
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
    document.storage.mutableString.setString(decoded.text)
    document.encoding = decoded.encoding
    document.hasBOM = decoded.hasBOM
    document.pinned = metadata.pinned
    document.bookmarks = resolvedPresentation?.bookmarks ?? viewState.bookmarks
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
      document.acknowledgeFileBaseline()
    } else {
      document.recoveredName =
        "Recovered "
        + (metadata.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled")
    }
    for pane in document.panePool { self.installCallbacks(for: pane) }
    document.onCharactersChanged = { [weak self, weak document] in
      if let document { self?.presentationInteraction(document) }
      self?.notifySessionChange()
    }
    if let resolvedPresentation {
      try resolvedPresentation.presentation.validate()
      let value = resolvedPresentation.presentation
      let live = document.panePool[0]
      live.editor.setSelectedRange(value.panes[value.focusedPaneIndex].selection)
      document.preferredPaneID = live.id
      document.panePresentation.pending = .init(
        presentation: value, livePaneID: live.id,
        liveSlot: value.focusedPaneIndex, resolvedAtRevision: document.editRevision)
    } else {
      document.panePool[0].editor.setSelectedRange(viewState.selection)
    }
    documents.insert(document, at: index)
    adoptFileState(document)
    if activate { display(document) }
    refresh()
  }

  func selectSessionTab(_ id: UUID?) {
    guard !windowClosed, let document = documents.first(where: { $0.id == id }) else { return }
    display(document)
  }

  func newDocument() {
    guard !preparingToQuit else { return }
    if applicationRouting != nil {
      do {
        let id = try submitApplicationSeed(.scratch(), provenance: .fresh, selection: .select)
        observeApplicationIntake(id)
      } catch { present(error) }
      return
    }
    let document = EditorDocument()
    for pane in document.panePool { self.installCallbacks(for: pane) }
    documents.append(document)
    display(document)
  }

  func restoreBackup(_ record: BackupRecord, data: Data) async throws {
    guard !preparingToQuit, !windowClosed else { throw CancellationError() }
    if let routing = applicationRouting {
      let request = try beginApplicationPreparation()
      defer { if applicationPreparation == request { applicationPreparation = nil } }
      let seed = try await Task.detached {
        try NativeDocumentSeed.backup(
          originalPath: record.originalPath, data: data, encoding: record.encoding)
      }.value
      try requireApplicationPreparation(request)
      let id = try submitApplicationSeed(seed, provenance: .fresh, selection: .select)
      let result = try await routing.wait(id)
      try validateApplicationResult(result)
      return
    }
    let decoded = try await Task.detached {
      try DocumentCodec.decode(data, encoding: record.encoding)
    }.value
    guard !preparingToQuit, !windowClosed else { throw CancellationError() }
    let document = EditorDocument()
    document.storage.mutableString.setString(decoded.text)
    document.encoding = decoded.encoding
    document.hasBOM = decoded.hasBOM
    document.recoveredName =
      "Backup — " + URL(fileURLWithPath: record.originalPath).lastPathComponent
    for pane in document.panePool { self.installCallbacks(for: pane) }
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
      guard applicationRouting == nil || current === existing else {
        finish(EditorApplicationRoutingError.invalidProjection, false)
        return
      }
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
    if applicationRouting != nil {
      openApplicationDocument(
        url, encoding: encoding, shouldAccept: shouldAccept, allowLargeViewer: onFailure == nil,
        hasPositionCompletion: onOpened != nil, finish: finish)
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
        document.storage.mutableString.setString(loaded.1.text)
        document.acknowledgeFileBaseline()
        document.bookmarks.removeAll()
        document.pendingBookmarks = nil
        for pane in document.panePool {
          (pane.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = []
        }
        document.language = LanguageService.detect(
          filename: url.lastPathComponent, text: loaded.1.text)
        for pane in document.panePool { self.installCallbacks(for: pane) }
        self.documents.append(document)
        self.adoptFileState(document)
        self.display(document)
        finish(nil, false)
      }
    }
  }

  nonisolated private static func read(_ url: URL, encoding: DocumentEncoding? = nil) throws -> (
    Data, DecodedDocument
  ) {
    let bytes = try readBytes(url)
    return (bytes, try DocumentCodec.decode(bytes, encoding: encoding))
  }
  nonisolated private static func readBytes(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw FileStoreError.unsafeTarget }
    let maximum = 100_000_000
    guard (values.fileSize ?? maximum + 1) <= maximum else { throw largeFileError() }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
    guard bytes.count <= maximum else { throw largeFileError() }
    return bytes
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
    guard applicationCommandAllowed(id) else { return }
    guard !preparingToQuit, !windowClosed,
      !documents.contains(where: { $0.panePresentation.installing != nil })
    else { return }
    guard current?.composingPaneID == nil else {
      present(PaneRoutingError.composition)
      return
    }
    switch id {
    case "file.checkDisk": performDiskStatusAction(.checkAgain)
    case "file.resolveDiskChange": performDiskStatusAction(.resolve)
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
      guard let document = current, applicationAllows(.select, document: document) else { return }
      guard document.storage.string.utf16.count <= 2_000_000 else {
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
        text: document.storage.string,
        font: preferredPane(in: document).editor.font
          ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
        name: document.name)
    case "file.saveAs": if let current { save(current, saveAs: true) }
    case "file.saveAll":
      for document in documents where document.dirty { save(document, saveAs: false) }
    case "file.close": closeDocument()
    case "file.reload", "file.revert": reload()
    case "file.duplicate":
      if let source = current {
        if applicationRouting != nil {
          duplicateApplicationDocument(source)
          return
        }
        let document = EditorDocument()
        document.storage.mutableString.setString(source.storage.string)
        document.encoding = source.encoding
        document.language = source.language
        document.manualLanguage = source.manualLanguage
        document.hasBOM = source.hasBOM
        for pane in document.panePool { self.installCallbacks(for: pane) }
        documents.append(document)
        display(document)
      }
    case "tool.formatJSON": formatJSON()
    case "edit.commentLine", "edit.commentBlock":
      guard let document = current, applicationAllows(.select, document: document) else { return }
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
      guard let document = current, applicationAllows(.select, document: document) else { return }
      let source = preferredPane(in: document)
      outline?.close()
      let panel = OutlineController(text: document.storage.string, language: document.language) {
        [weak self, weak document] range, snapshot in
        guard let self else { return }
        guard !self.preparingToQuit, !self.windowClosed else { return }
        guard let document, self.documents.contains(where: { $0 === document }),
          document.storage.string.utf16.elementsEqual(snapshot.utf16)
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
        do { try self.activateSource(source, snapshot: snapshot, range: range) } catch {
          self.present(error)
        }
      }
      outline = panel
      panel.onClose = { [weak self, weak panel] in
        if self?.outline === panel { self?.outline = nil }
      }
      panel.showWindow(nil)
    case "tool.previewMarkdown":
      guard let document = current, applicationAllows(.select, document: document) else { return }
      markdownPreview?.close()
      let preview = MarkdownPreviewController(text: document.storage.string)
      preview.window?.title = "Markdown Preview — " + document.name
      markdownPreview = preview
      preview.onClose = { [weak self, weak preview] in
        if self?.markdownPreview === preview { self?.markdownPreview = nil }
      }
      preview.showWindow(nil)
    case "tool.compare":
      guard let document = current, applicationAllows(.select, document: document) else { return }
      guard document.storage.string.utf8.count <= 2_000_000 else {
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
        leftText: document.storage.string, leftName: document.name)
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
    case "view.splitVertical":
      do { try splitCurrent(.sideBySide) } catch { present(error) }
    case "view.splitHorizontal":
      do { try splitCurrent(.stacked) } catch { present(error) }
    case "view.closeSplit":
      do { try collapseToFocusedPane() } catch { present(error) }
    case "view.focusOtherPane":
      do { try focusOtherPane() } catch { present(error) }
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
    guard applicationCommandAllowed(id) else { return false }
    guard !preparingToQuit, !windowClosed, current?.composingPaneID == nil else { return false }
    if id.hasPrefix("bookmark.") { return current != nil && current?.saving == false }
    switch id {
    case "file.checkDisk", "file.resolveDiskChange":
      guard fileMonitoring?.isSuspended == false, current?.saving == false,
        let bridge = current?.fileState
      else { return false }
      return id == "file.checkDisk" || bridge.state.noticeIsProminent
    case "view.splitVertical", "view.splitHorizontal":
      guard let document = current, !document.saving else { return false }
      return visiblePanes.count == 2 || document.storage.length <= 2_000_000
    case "view.closeSplit", "view.focusOtherPane":
      return current?.saving == false && visiblePanes.count == 2
    case "macro.start":
      return current != nil && current?.saving == false && recordingDocumentID == nil
        && !macroSaving && recordedCommands.isEmpty
    case "macro.stop":
      return !macroSaving && (recordingDocumentID != nil || !recordedCommands.isEmpty)
        && current?.saving == false
    case "macro.discard":
      return !macroSaving && (recordingDocumentID != nil || !recordedCommands.isEmpty)
    case "macro.cancel": return replayCancellation != nil
    case "file.reopenClosed":
      if let routing = applicationRouting {
        return routing.registry.closedHistoryCount(windowID: sessionID) > 0
      }
      return !closedDocuments.isEmpty
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

  /// Finalize only this operation; keep its identity until all synchronous mutations finish.
  private static func completeFileOperation(
    _ document: EditorDocument?, id: UUID, controller: EditorWindowController?
  ) {
    guard let document, document.finishFileOperation(id) else { return }
    document.saving = false
    controller?.refreshInteractivity(document)
    document.fileState?.reconcileEligibility()
  }

  private func save(_ document: EditorDocument, saveAs: Bool) {
    guard applicationAllows(.fileOperation, document: document) else { return }
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
      applicationAllows(.fileOperation, document: document),
      documents.contains(where: { $0 === document })
    else { return }
    let sameDestination = destination.standardizedFileURL == document.url?.standardizedFileURL
    let original = document.originalBytes
    let originalEncoding = document.savedEncoding
    let services = saveServices
    let snapshot = DecodedDocument(
      text: document.storage.string, encoding: document.encoding, hasBOM: document.hasBOM)
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self] in
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
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
        guard document.operationID == operationID else { return }
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
        document.acknowledgeFileBaseline()
        self.adoptFileState(document)
        Self.completeFileOperation(document, id: operationID, controller: self)
        self.refreshInteractivity(document)
        self.refresh()
        self.updateLanguage(document)
        self.scheduleRecovery()
      } catch {
        guard document.operationID == operationID else { return }
        document.saving = false
        if case EditorSaveFailure.uncertain(let pending) = error {
          document.pendingPublication = pending
        }
        guard let self, !self.windowClosed,
          self.documents.contains(where: { $0 === document })
        else {
          for pane in document.panePool { pane.editor.isEditable = false }
          return
        }
        Self.completeFileOperation(document, id: operationID, controller: self)
        self.refreshInteractivity(document)
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
    guard let document = current, let url = document.url, !document.saving,
      applicationAllows(.fileOperation, document: document),
      document.composingPaneID == nil
    else {
      fail(CancellationError())
      return
    }
    guard confirmDiscard([document]), !windowClosed, !preparingToQuit, !isRecordingMacro,
      applicationAllows(.fileOperation, document: document),
      document.composingPaneID == nil, !document.saving,
      documents.contains(where: { $0 === document }), shouldAccept?() != false
    else {
      fail(CancellationError())
      return
    }
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self] in
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
      let result = await Task.detached(priority: .userInitiated) {
        Result { try Self.read(url, encoding: encoding) }
      }.value
      guard document.operationID == operationID else {
        fail(CancellationError())
        return
      }
      document.saving = false
      guard let self else {
        for pane in document.panePool { pane.editor.isEditable = false }
        Self.completeFileOperation(document, id: operationID, controller: self)
        fail(CancellationError())
        return
      }
      guard !self.windowClosed, !self.preparingToQuit, !self.isRecordingMacro,
        document.composingPaneID == nil,
        self.documents.contains(where: { $0 === document }), shouldAccept?() != false
      else {
        self.refreshInteractivity(document)
        if !self.windowClosed { self.refresh() }
        Self.completeFileOperation(document, id: operationID, controller: self)
        fail(CancellationError())
        return
      }
      refreshInteractivity(document)
      switch result {
      case .failure(let error):
        Self.completeFileOperation(document, id: operationID, controller: self)
        self.refresh()
        fail(error)
      case .success(let loaded):
        document.storage.mutableString.setString(loaded.1.text)
        document.bookmarks.removeAll()
        document.pendingBookmarks = nil
        for pane in document.panePool {
          (pane.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = []
        }
        document.savedText = loaded.1.text
        document.pendingPublication = nil
        document.originalBytes = loaded.0
        document.encoding = loaded.1.encoding
        document.hasBOM = loaded.1.hasBOM
        document.savedEncoding = loaded.1.encoding
        document.savedHasBOM = loaded.1.hasBOM
        document.undoManager.removeAllActions()
        document.acknowledgeFileBaseline()
        self.adoptFileState(document)
        Self.completeFileOperation(document, id: operationID, controller: self)
        self.refresh()
        self.updateLanguage(document)
        self.scheduleRecovery()
        onReload?()
      }
    }
  }

  private func showEncoding() {
    guard let document = current, !document.saving, let window else { return }
    let source = preferredPane(in: document)
    let panel = EncodingPanelController(
      current: DecodedDocument(
        text: document.storage.string, encoding: document.encoding, hasBOM: document.hasBOM),
      onConvert: { [weak self, weak document] encoding, bom in
        guard let self, let document, !self.windowClosed, !self.preparingToQuit,
          self.documents.contains(where: { $0 === document })
        else { return }
        self.convertEncoding(document, encoding: encoding, bom: bom)
      },
      onReopen: { [weak self, weak document] encoding in
        guard let self, let document, !self.windowClosed, !self.preparingToQuit,
          self.documents.contains(where: { $0 === document })
        else { return }
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
        guard let self, let document, !document.saving, !self.windowClosed, !self.preparingToQuit,
          document.composingPaneID == nil, source.isAttached,
          self.documents.contains(where: { $0 === document })
        else { return }
        self.convertLineEndings(document, source: source, to: ending)
      })
    encodingPanel = panel
    panel.present(for: window)
  }

  private func convertLineEndings(
    _ document: EditorDocument, source: EditorPane, to ending: LineEnding
  ) {
    guard !document.saving, !windowClosed, !preparingToQuit,
      applicationAllows(.fileOperation, document: document),
      document.composingPaneID == nil, source.isAttached,
      documents.contains(where: { $0 === document })
    else { return }
    let snapshot = document.storage.string
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task {
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
      let replacement = await Task.detached { LineEndings.convert(snapshot, to: ending) }.value
      guard document.operationID == operationID else { return }
      document.saving = false
      refreshInteractivity(document)
      replaceDocumentText(
        document, source: source, expected: snapshot, replacement: replacement,
        action: "Convert Line Endings")
    }
  }

  private func convertEncoding(
    _ document: EditorDocument, encoding: DocumentEncoding, bom: Bool,
    validate: @escaping @Sendable (DecodedDocument) throws -> Void = {
      _ = try DocumentCodec.encode($0)
    },
    onFinish: (() -> Void)? = nil
  ) {
    guard !document.saving, !preparingToQuit, !windowClosed, document.composingPaneID == nil,
      applicationAllows(.fileOperation, document: document),
      documents.contains(where: { $0 === document })
    else { return }
    let snapshot = DecodedDocument(text: document.storage.string, encoding: encoding, hasBOM: bom)
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self] in
      defer {
        Self.completeFileOperation(document, id: operationID, controller: self)
        onFinish?()
      }
      do {
        try await Task.detached { try validate(snapshot) }.value
        guard document.operationID == operationID else { return }
        document.saving = false
        self?.refreshInteractivity(document)
        guard let self, !self.windowClosed, !self.preparingToQuit,
          self.documents.contains(where: { $0 === document })
        else { return }
        self.setEncoding(document, encoding: encoding, bom: bom)
      } catch {
        guard document.operationID == operationID else { return }
        document.saving = false
        self?.refreshInteractivity(document)
        self?.refresh()
        Self.completeFileOperation(document, id: operationID, controller: self)
        self?.present(error)
      }
    }
  }

  private func setEncoding(_ document: EditorDocument, encoding: DocumentEncoding, bom: Bool) {
    guard applicationAllows(.edit, document: document) else { return }
    guard document.encoding != encoding || document.hasBOM != bom else {
      refresh()
      return
    }
    let previous = document.encoding
    let previousBOM = document.hasBOM
    document.undoManager.registerUndo(withTarget: self) { [weak document] controller in
      guard let document else { return }
      controller.setEncoding(document, encoding: previous, bom: previousBOM)
    }
    document.encoding = encoding
    document.hasBOM = bom
    document.undoManager.setActionName("Convert Encoding")
    refresh()
    scheduleRecovery()
  }

  @discardableResult private func replaceDocumentText(
    _ document: EditorDocument, source: EditorPane, expected: String, replacement: String,
    action: String,
    edit: TextEdit? = nil
  ) -> Bool {
    guard !preparingToQuit, !windowClosed, !document.saving, source.isAttached,
      applicationAllows(.edit, document: document),
      source.document === document, document.composingPaneID == nil,
      documents.contains(where: { $0 === document }),
      document.storage.string.utf16.elementsEqual(expected.utf16),
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
    guard source.editor.shouldChangeText(in: change.range, replacementString: change.replacement)
    else {
      return false
    }
    source.editor.breakUndoCoalescing()
    document.undoManager.beginUndoGrouping()
    source.editor.textStorage?.replaceCharacters(in: change.range, with: change.replacement)
    source.editor.didChangeText()
    document.undoManager.endUndoGrouping()
    document.undoManager.setActionName(action)
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
    focusedPane?.document.undoManager
  }

  private func setBookmarks(_ document: EditorDocument, value: DocumentBookmarks) {
    guard applicationAllows(.edit, document: document) else { return }
    let previous = document.bookmarks
    guard previous != value else { return }
    document.typingBookmarkNextLocation = nil
    document.undoManager.registerUndo(withTarget: self) { [weak document] controller in
      guard let document else { return }
      controller.setBookmarks(document, value: previous)
    }
    document.bookmarks = value
    for pane in document.panePool {
      (pane.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(value.offsets)
    }
    notifySessionChange()
  }

  private func performBookmarkCommand(_ id: String) {
    guard let document = current, !document.saving, !preparingToQuit,
      applicationAllows(.edit, document: document)
    else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    guard accepts(sourceContext) else { return }

    let snapshot = document.storage.string
    let selection = source.editor.selectedRange()
    let original = document.bookmarks
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self, weak document] in
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
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
        guard document.operationID == operationID else { return }
        document.saving = false
        self.refreshInteractivity(document)
        self.refresh()
        guard self.accepts(sourceContext),
          source.editor.selectedRange() == selection,
          document.bookmarks == original,
          document.storage.string.utf16.elementsEqual(snapshot.utf16)
        else {
          throw NSError(
            domain: "TheOnlyPad", code: 18,
            userInfo: [
              NSLocalizedDescriptionKey: "The bookmark target changed. Run the command again."
            ])
        }
        if result.0 != original {
          source.editor.breakUndoCoalescing()
          document.undoManager.beginUndoGrouping()
          self.setBookmarks(document, value: result.0)
          document.undoManager.endUndoGrouping()
          document.undoManager.setActionName("Bookmarks")
        }
        if let offset = result.1 {
          source.editor.setSelectedRange(NSRange(location: offset, length: 0))
          source.editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
        }
        if let text = result.2 {
          self.newDocument()
          self.focusedPane?.editor.insertText(
            text, replacementRange: NSRange(location: 0, length: 0))
        }
      } catch {
        guard document?.operationID == operationID else { return }
        document?.saving = false
        if let document { self?.refreshInteractivity(document) }
        self?.refresh()
        Self.completeFileOperation(document, id: operationID, controller: self)
        self?.present(error)
      }
    }
  }

  private func performDocumentCommand(
    _ action: String, operation: @escaping @Sendable (String, NSRange) throws -> LineCommandResult
  ) {
    guard let document = current, !document.saving, applicationAllows(.edit, document: document)
    else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    guard accepts(sourceContext) else { return }

    let snapshot = document.storage.string
    let selection = source.editor.selectedRange()
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self, weak document] in
      defer { Self.completeFileOperation(document, id: operationID, controller: self) }
      do {
        let (result, edit) = try await Task.detached(priority: .userInitiated) {
          let result = try operation(snapshot, selection)
          return (result, try TextDifference.singleEdit(from: snapshot, to: result.text))
        }.value
        guard let self, let document else { return }
        guard document.operationID == operationID else { return }
        document.saving = false
        self.refreshInteractivity(document)
        self.refresh()
        guard self.accepts(sourceContext),
          source.editor.selectedRange() == selection,
          document.storage.string.utf16.elementsEqual(snapshot.utf16)
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
            document, source: source, expected: snapshot, replacement: result.text, action: action,
            edit: edit)
        {
          source.editor.setSelectedRange(result.selection)
          source.editor.scrollRangeToVisible(result.selection)
        }
      } catch {
        guard document?.operationID == operationID else { return }
        document?.saving = false
        if let document { self?.refreshInteractivity(document) }
        self?.refresh()
        Self.completeFileOperation(document, id: operationID, controller: self)
        self?.present(error)
      }
    }
  }

  func navigate(line: Int, column: Int, requireFocus: Bool = true) {
    guard let document = current, applicationAllows(.select, document: document) else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    let snapshot = document.storage.string
    Task { [weak self, weak document] in
      do {
        let offset = try await Task.detached(priority: .userInitiated) {
          try TextNavigation.utf16Offset(in: snapshot, line: line, column: column)
        }.value
        guard let self, let document, !self.preparingToQuit,
          self.documents.contains(where: { $0 === document })
        else { return }
        guard self.accepts(sourceContext, requireFocus: requireFocus),
          document.storage.string.utf16.elementsEqual(snapshot.utf16)
        else {
          throw NSError(
            domain: "TheOnlyPad", code: 14,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The document changed during navigation. Try Go to Line again."
            ])
        }
        let range = NSRange(location: offset, length: 0)
        source.editor.setSelectedRange(range)
        source.editor.scrollRangeToVisible(range)
        if requireFocus, self.current === document {
          self.window?.makeFirstResponder(source.editor)
        }
      } catch { self?.present(error) }
    }
  }

  func selectSearchResult(_ range: NSRange, snapshot: String) {
    guard let source = focusedPane else { return }
    do { try activateSource(source, snapshot: snapshot, range: range) } catch { present(error) }
  }

  private func showStatistics() {
    guard let document = current, applicationAllows(.select, document: document) else { return }
    let snapshot = document.storage.string
    let selection = preferredPane(in: document).editor.selectedRange()
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
    guard let document = current, !document.saving, applicationAllows(.edit, document: document)
    else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    guard accepts(sourceContext) else { return }

    let snapshot = document.storage.string
    let selected = source.editor.selectedRange()
    let range = selected.length == 0 ? NSRange(location: 0, length: snapshot.utf16.count) : selected
    let input = (snapshot as NSString).substring(with: range)
    textUtilities?.close()
    let panel = TextUtilitiesController(text: input) { [weak self, weak document] replacement in
      guard let self, let document else { return }
      guard self.accepts(sourceContext), !document.saving,
        document.storage.string.utf16.elementsEqual(snapshot.utf16)
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
      let editor = source.editor
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
    guard let document = current, applicationAllows(.select, document: document) else { return }
    let source = preferredPane(in: document)
    let panel = SearchPanelController(
      snapshot: { [weak self, weak document] in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          !document.saving, !self.preparingToQuit, !self.windowClosed, source.isAttached,
          document.composingPaneID == nil
        else { return nil }
        return document.storage.string
      },
      select: { [weak self, weak document] range, expected in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          document.storage.string.utf16.elementsEqual(expected.utf16)
        else { return false }
        do {
          try self.activateSource(source, snapshot: expected, range: range)
          return true
        } catch {
          self.present(error)
          return false
        }
      },
      replace: { [weak self, weak document] expected, replacement in
        guard let self, let document, self.documents.contains(where: { $0 === document }),
          !document.saving, !self.preparingToQuit, !self.windowClosed, source.isAttached,
          document.composingPaneID == nil,
          document.storage.string.utf16.elementsEqual(expected.utf16)
        else { return false }
        let editor = source.editor
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
        document.preferredPaneID = source.id
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
        filename: document.name, text: document.storage.string)
    }
    document.highlighter.update(language: document.language)
    if document.id == selectedID {
      languagePicker.selectItem(withTitle: document.language.rawValue)
    }
    updateStatus()
  }

  @objc private func selectLanguage() {
    guard !preparingToQuit, !windowClosed, let document = current,
      applicationAllows(.edit, document: document),
      let title = languagePicker.titleOfSelectedItem,
      let language = DocumentLanguage(rawValue: title)
    else { return }
    document.manualLanguage = true
    document.language = language
    document.highlighter.update(language: language)
    updateStatus()
  }

  private func formatJSON(
    operation: @escaping @Sendable (String) throws -> String = {
      try LanguageService.formatJSON($0)
    },
    onFinish: (() -> Void)? = nil
  ) {
    guard let document = current, !document.saving, applicationAllows(.edit, document: document)
    else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    guard accepts(sourceContext, requireFocus: false) else { return }
    let captured = document.storage.string
    Task { [weak self] in
      defer { onFinish?() }
      do {
        let formatted = try await Task.detached(priority: .userInitiated) {
          try operation(captured)
        }.value
        guard let self, !self.windowClosed, !self.preparingToQuit, !document.saving,
          self.documents.contains(where: { $0.id == document.id })
        else { return }
        guard self.accepts(sourceContext, requireFocus: false),
          document.storage.string.utf16.elementsEqual(captured.utf16)
        else {
          self.present(
            NSError(
              domain: "TheOnlyPad", code: 15,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The document changed while JSON was formatting. Run Format JSON again to format the current text."
              ]))
          return
        }
        guard !formatted.utf16.elementsEqual(captured.utf16) else { return }
        let range = NSRange(location: 0, length: (captured as NSString).length)
        let editor = source.editor
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
    guard !preparingToQuit,
      documents.allSatisfy({ applicationUserAllows(.paneInstall, document: $0) })
    else { return }
    do { settings = try value.validated() } catch {
      present(error)
      return
    }
    documents.forEach(configureSettings)
    refresh()
  }

  private func configureSettings(_ document: EditorDocument) {
    guard projectionAllows(.paneInstall, document: document) else { return }
    let font =
      settings.fontName == EditorSettings.systemMonospacedFontName
      ? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
      : NSFont(name: settings.fontName, size: settings.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(settings.tabWidth)
    for pane in document.panePool {
      pane.editor.font = font
      pane.editor.defaultParagraphStyle = paragraph
      pane.editor.typingAttributes[.paragraphStyle] = paragraph
    }
    document.storage.addAttribute(
      .paragraphStyle, value: paragraph,
      range: NSRange(location: 0, length: document.storage.length))
    configureWrap(document, enabled: settings.wrap)
    document.settingsApplied = true
  }
  private func configureWrap(_ document: EditorDocument, enabled wrap: Bool) {
    guard projectionAllows(.paneInstall, document: document) else { return }
    for pane in document.panePool {
      let editor = pane.editor
      editor.isHorizontallyResizable = !wrap
      pane.scroll.hasHorizontalScroller = !wrap
      editor.textContainer?.widthTracksTextView = wrap
      editor.textContainer?.containerSize = NSSize(
        width: wrap ? max(100, pane.scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)
      if wrap {
        editor.setFrameSize(
          NSSize(width: max(100, pane.scroll.contentSize.width), height: editor.frame.height))
      }
    }
  }

  private func toggleWrap() {
    guard let document = current, applicationAllows(.select, document: document) else { return }
    configureWrap(document, enabled: preferredPane(in: document).editor.isHorizontallyResizable)
    refresh()
  }

  @objc private func selectTab() {
    guard !preparingToQuit, !windowClosed, documents.indices.contains(tabs.indexOfSelectedItem)
    else { return }
    display(documents[tabs.indexOfSelectedItem])
  }

  private func installCallbacks(for pane: EditorPane) {
    let document = pane.document
    let editor = pane.editor
    editor.delegate = self
    editor.canChangeSelection = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane else { return false }
      return !self.preparingToQuit && !self.windowClosed && pane.isAttached
        && self.applicationUserAllows(.select, document: document)
    }
    document.canUndoRedo = { [weak self, weak document] in
      guard let self, let document else { return false }
      return !self.preparingToQuit && !self.windowClosed && !document.saving
        && document.composingPaneID == nil
        && self.applicationUserAllows(.undoRedo, document: document)
    }
    editor.canFocus = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane else { return false }
      return self.mayFocus(pane)
        && !self.windowClosed && !self.preparingToQuit && pane.isAttached
        && (document.composingPaneID == nil || document.composingPaneID == pane.id)
        && (self.current?.composingPaneID == nil || self.current === document)
    }
    editor.canMutate = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane else { return false }
      return withExtendedLifetime(document) { self.mayMutate(pane) }
    }
    pane.onBoundsChanged = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane, pane.isAttached,
        self.documents.contains(where: { $0 === document }),
        document.panePresentation.suppression == 0,
        self.applicationAllows(.select, document: document)
      else { return }
      self.presentationInteraction(document)
      self.notifySessionChange()
    }
    editor.onFocus = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane, self.current === document,
        self.applicationAllows(.select, document: document)
      else { return }
      if self.focusedPane !== pane {
        self.focusedPane?.editor.breakUndoCoalescing()
        pane.editor.breakUndoCoalescing()
      }
      document.preferredPaneID = pane.id
      self.presentationInteraction(document)
      self.updateStatus()
    }
    editor.onTypingRunEnded = { [weak document] in document?.typingBookmarkNextLocation = nil }
    editor.onCompositionBegan = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane else { return }
      self.presentationInteraction(document)
      document.composingPaneID = pane.id
      pane.editor.breakUndoCoalescing()
      document.compositionBookmarks = document.bookmarks
      document.compositionOriginalText =
        document.bookmarks.offsets.isEmpty ? nil : document.storage.string
      document.compositionUndoRegistered = false
      self.refreshInteractivity(document)
    }
    editor.onCompositionEnded = { [weak self, weak document, weak pane] in
      guard let self, let document, let pane, document.composingPaneID == pane.id else { return }
      if let before = document.compositionBookmarks,
        let original = document.compositionOriginalText,
        document.storage.string.utf16.elementsEqual(original.utf16)
      {
        document.bookmarks = before
        for presentation in document.panePool {
          (presentation.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(
            before.offsets)
        }
      }
      self.presentationInteraction(document)
      document.composingPaneID = nil
      document.compositionBookmarks = nil
      document.compositionOriginalText = nil
      document.compositionUndoRegistered = false
      self.refreshInteractivity(document)
      document.fileState?.reconcileEligibility()
      self.refresh()
    }
    editor.onMarkedTextUpdated = { [weak document, weak pane] in
      guard let document, let pane, document.pendingBookmarks != nil else { return }
      pane.editor.didChangeText()
    }
    if let ruler = pane.scroll.verticalRulerView as? LineNumberRuler {
      ruler.bookmarkOffsets = Set(document.bookmarks.offsets)
      ruler.onToggleBookmark = { [weak self, weak document, weak pane] offset in
        guard let self, let document, let pane, self.current === document, self.mayMutate(pane),
          pane.document.composingPaneID == nil
        else { return }
        do { try self.focusPane(id: pane.id) } catch {
          self.present(error)
          return
        }
        pane.editor.setSelectedRange(NSRange(location: offset, length: 0))
        self.performBookmarkCommand("bookmark.toggle")
      }
    }
  }

  private func display(_ document: EditorDocument) {
    guard !windowClosed, !preparingToQuit else { return }
    if let routing = applicationRouting {
      do {
        try routing.requireEndpointCurrent()
        guard projectionToken == nil, routing.registry.handle(id: document.id) === document,
          routing.registry.assignment(of: document.id) == routing.assignment,
          routing.registry.allows(.select, documentID: document.id),
          current?.composingPaneID == nil || current === document
        else { throw EditorApplicationRoutingError.invalidProjection }
        try routing.registry.selectDocument(
          document.id, in: routing.assignment, expectedRevision: routing.registry.workspaceRevision)
        try projectCurrentRegistry()
      } catch { present(error) }
      return
    }
    guard current?.composingPaneID == nil || current === document else {
      present(PaneRoutingError.composition)
      return
    }
    document.onCharactersChanged = { [weak self, weak document] in
      if let document { self?.presentationInteraction(document) }
      self?.notifySessionChange()
    }
    if let previous = current, previous !== document { presentationInteraction(previous) }
    selectedID = document.id
    for pane in document.panePool where pane.isAttached { installCallbacks(for: pane) }
    if !document.settingsApplied { configureSettings(document) }
    let wrap = !preferredPane(in: document).editor.isHorizontallyResizable
    do { try presentPanes(document, wrap: wrap) } catch {
      present(error)
      return
    }
    window?.makeFirstResponder(preferredPane(in: document).editor)
    installPendingPresentationIfPossible(document)
    updateLanguage(document)
    refresh()
    renderDiskStatus()
  }

  private func closeDocument() {
    guard let document = current, applicationAllows(.select, document: document) else { return }
    closeDocuments(ids: [document.id])
  }

  private func closeDocuments(ids: Set<UUID>) {
    if let routing = applicationRouting {
      do {
        _ = try requireApplicationEndpoint()
        _ = try routing.requestClose(ids)
      } catch { present(error) }
      return
    }
    guard !preparingToQuit, !windowClosed,
      !documents.contains(where: { $0.panePresentation.installing != nil })
    else { return }
    let closing = documents.filter { ids.contains($0.id) }
    guard current?.composingPaneID == nil, !closing.contains(where: { $0.composingPaneID != nil })
    else {
      present(PaneRoutingError.composition)
      return
    }
    guard !closing.isEmpty, !closing.contains(where: { $0.saving }), confirmDiscard(closing) else {
      return
    }
    for document in closing {
      invalidateFileState(document)
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
    if let routing = applicationRouting {
      Task { [weak self] in
        do {
          guard (try self?.requireApplicationEndpoint()) != nil else { throw CancellationError() }
          let id = try await routing.requestReopen()
          guard let self, !self.windowClosed else { return }
          self.observeApplicationIntake(id)
        } catch { self?.present(error) }
      }
      return
    }
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
    document.storage.mutableString.setString(old.storage.string)
    document.language = old.language
    document.manualLanguage = old.manualLanguage
    if document.url != nil && document.originalBytes != nil { document.acknowledgeFileBaseline() }
    for pane in document.panePool { self.installCallbacks(for: pane) }
    documents.append(document)
    adoptFileState(document)
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
      if let routing = self.applicationRouting {
        do {
          try routing.requireEndpointCurrent()
          try routing.registry.setPinned(
            !document.pinned, documentID: id, expectedRevision: routing.registry.workspaceRevision)
          try self.projectCurrentRegistry()
        } catch { self.present(error) }
        return
      }
      document.pinned.toggle()
      self.documents = self.documents.filter(\.pinned) + self.documents.filter { !$0.pinned }
      self.refresh()
    }
    tabBar.onMove = { [weak self] id, index in
      guard let self, !self.preparingToQuit, !self.windowClosed else { return }
      do {
        if let routing = self.applicationRouting {
          try routing.requireEndpointCurrent()
          try routing.registry.reorderDocument(
            id, to: index, expectedRevision: routing.registry.workspaceRevision)
          try self.projectCurrentRegistry()
          return
        }
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

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let routing = applicationRouting {
      if let permit = emptyWindowClosePermit {
        emptyWindowClosePermit = nil
        guard sender === window, !windowClosed, documents.isEmpty,
          (try? requireApplicationEndpoint(userInitiated: false)) != nil,
          !windowClosed, documents.isEmpty, routing.registry.workspaceRevision == permit.revision,
          routing.registry.window(id: sessionID)?.groups.allSatisfy({ $0.documentIDs.isEmpty })
            == true
        else { return false }
        return true
      }
      do {
        _ = try requireApplicationEndpoint()
        if documents.isEmpty {
          let revision = routing.registry.workspaceRevision
          guard sender === window, let expected = routing.registry.window(id: sessionID),
            expected.groups.allSatisfy({ $0.documentIDs.isEmpty })
          else { throw NativeManagedCloseError.opening }
          try validateRegistryProjection(
            expected, revision: revision, endpointID: routing.endpointID)
          _ = try requireApplicationEndpoint()
          guard !windowClosed, documents.isEmpty, routing.registry.workspaceRevision == revision
          else { throw NativeManagedCloseError.stale }
          return true
        }
        _ = try routing.requestClose(Set(documents.map(\.id)))
      } catch { present(error) }
      return false
    }
    return canClose()
  }

  func canClose() -> Bool {
    guard !documents.contains(where: { $0.panePresentation.installing != nil }) else {
      return false
    }
    guard !preparingToQuit, !windowClosed, current?.composingPaneID == nil else { return false }
    guard allowLeavingUnsavedRecording() else { return false }
    guard !documents.contains(where: { $0.composingPaneID != nil }) else {
      present(PaneRoutingError.composition)
      return false
    }
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
    diskActions?.cancel()
    locateActions?.cancel()
    diskConflict?.close()
    diskConflict = nil
    for document in documents {
      if let routing = applicationRouting {
        do { try routing.detachDocumentEndpoint(document) } catch { errorHandler?(error) }
      } else {
        document.panePresentation.invalidate(force: true)
        invalidateFileState(document)
      }
    }
    markdownPreview?.close()
    backupManager?.close()
    outline?.close()
    comparison?.close()
    statisticsTask?.cancel()
    statisticsGeneration += 1
    searchPanel?.close()
    encodingPanel?.close()
    encodingPanel = nil
    textUtilities?.close()
    folderSearch?.close()
    if applicationRouting == nil, !preparingToQuit {
      for document in documents { discardRecovery(document.id) }
    }
    applicationRouting?.endpointClosed(applicationRouting!.endpointID)
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
      let source = pane(for: editor), source.isAttached,
      let document = Optional(source.document)
    {
      if let updated = document.pendingBookmarks {
        document.pendingBookmarks = nil
        if source.editor.isComposingText || document.pendingBookmarksHaveUndo {
          document.bookmarks = updated
          for pane in document.panePool {
            (pane.scroll.verticalRulerView as? LineNumberRuler)?.bookmarkOffsets = Set(
              updated.offsets)
          }
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
    guard let source = pane(for: textView), mayMutate(source) else { return false }
    let document = source.document
    do {
      document.pendingBookmarks = nil
      document.pendingBookmarksHaveUndo = false
      if document.undoManager.isUndoing || document.undoManager.isRedoing {
        document.typingBookmarkNextLocation = nil
      }
      if !document.bookmarks.offsets.isEmpty, let replacementString,
        !document.undoManager.isUndoing, !document.undoManager.isRedoing
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
          } else if source.editor.isComposingText {
            // Register before AppKit's first text undo, then let provisional text edits coalesce.
            if !document.compositionUndoRegistered, let before = document.compositionBookmarks {
              document.undoManager.registerUndo(withTarget: self) {
                [weak document] controller in
                guard let document else { return }
                controller.setBookmarks(document, value: before)
              }
              document.compositionUndoRegistered = true
            }
          } else if source.editor.isOrdinaryTextInsertion, affectedCharRange.length == 0,
            !replacementString.utf16.contains(where: { $0 == 10 || $0 == 13 })
          {
            if document.typingBookmarkNextLocation != affectedCharRange.location
              || !document.undoManager.canUndo
            {
              source.editor.breakUndoCoalescing()
              let before = document.bookmarks
              if before != updated {
                document.undoManager.registerUndo(withTarget: self) {
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
            if document.typingBookmarkNextLocation != nil { source.editor.breakUndoCoalescing() }
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
      source.document.id == id,
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
    let text = document.storage.string as NSString
    let selection = preferredPane(in: document).editor.selectedRange()
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
      text: text.length <= 1_000_000 ? document.storage.string : nil)
  }

  func cancelMacroReplay() { replayCancellation?.cancel() }
  var selectedDocumentID: UUID? { current?.id }

  func replay(_ macro: EditorMacro, repeatCount: Int) {
    guard let document = current, !document.saving, !preparingToQuit, !isRecordingMacro,
      applicationAllows(.fileOperation, document: document),
      replayCancellation == nil
    else { return }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    guard accepts(sourceContext, requireFocus: false) else { return }
    let snapshot = document.storage.string
    let cancellation = MacroCancellation()
    replayCancellation = cancellation
    let operationID = document.beginFileOperation()
    document.saving = true
    refreshInteractivity(document)
    refresh()
    Task { [weak self] in
      defer {
        if document.operationID == operationID, self?.replayCancellation === cancellation {
          self?.replayCancellation = nil
        }
        Self.completeFileOperation(document, id: operationID, controller: self)
      }
      do {
        let replacement = try await Task.detached(priority: .userInitiated) {
          try MacroPlayer.replay(
            macro, on: snapshot, repeatCount: repeatCount, isCancelled: { cancellation.isCancelled }
          )
        }.value
        guard let self, document.operationID == operationID,
          self.replayCancellation === cancellation
        else { return }
        self.replayCancellation = nil
        document.saving = false
        self.refreshInteractivity(document)
        guard self.accepts(sourceContext, requireFocus: false), !cancellation.isCancelled,
          document.storage.string.utf16.elementsEqual(snapshot.utf16)
        else {
          self.refresh()
          return
        }
        let range = NSRange(location: 0, length: snapshot.utf16.count)
        if source.editor.shouldChangeText(in: range, replacementString: replacement) {
          source.editor.breakUndoCoalescing()
          document.undoManager.beginUndoGrouping()
          source.editor.textStorage?.replaceCharacters(in: range, with: replacement)
          source.editor.didChangeText()
          document.undoManager.endUndoGrouping()
          document.undoManager.setActionName(macro.name)
        }
        self.refresh()
      } catch {
        guard document.operationID == operationID, self?.replayCancellation === cancellation else {
          return
        }
        self?.replayCancellation = nil
        document.saving = false
        self?.refreshInteractivity(document)
        self?.refresh()
        Self.completeFileOperation(document, id: operationID, controller: self)
        if !cancellation.isCancelled { self?.present(error) }
      }
    }
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    guard let editor = notification.object as? NSTextView, let pane = pane(for: editor),
      pane.isAttached, current === pane.document
    else { return }
    presentationInteraction(pane.document)
    if window?.firstResponder === editor { pane.document.preferredPaneID = pane.id }
    updateStatus()
  }

  private func refresh() {
    renderPanePresentationStatus()
    tabBar.update(
      items: documents.map {
        TabItem(id: $0.id, title: $0.name, dirty: $0.dirty, pinned: $0.pinned)
      }, selectedID: selectedID)
    for document in documents {
      for pane in document.panePool {
        pane.scroll.rulersVisible = document.storage.length <= 2_000_000
      }
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
    guard let document = current, applicationAllows(.select, document: document) else { return }
    let text = document.storage.string as NSString
    let caret = min(preferredPane(in: document).editor.selectedRange().location, text.length)
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
    let selection = preferredPane(in: document).editor.selectedRange().length
    let splitNotice =
      text.length > 2_000_000 && document.panePool.filter(\.isAttached).count == 1
      ? "Split unavailable: over 2 million UTF-16 units  |  " : ""
    status.stringValue =
      splitNotice
      + "\(document.language.rawValue)  |  \(location)  |  Selected \(selection) UTF-16 units  |  \(document.encoding.rawValue)\(document.hasBOM ? " BOM" : "")  |  \(preferredPane(in: document).editor.isHorizontallyResizable ? "No Wrap" : "Wrap")"
      + (text.length > 2_000_000 ? "  |  Highlighting disabled: large document" : "")
      + (loadingCount > 0 ? "  |  Loading…" : "")
      + (document.saving ? "  |  Working…" : "")
      + (document.pendingPublication != nil
        ? "  |  Save not confirmed — retry Save or Save As" : "")
      + (recordingDocumentID != nil ? "  |  Recording macro" : "")
  }

  private func restoreRecovery() {
    guard applicationRouting == nil else {
      present(EditorApplicationRoutingError.applicationOwned)
      return
    }
    loadingCount += 1
    Task { [weak self, recovery] in
      do {
        let startup = try await recovery.claimStartup()
        guard let self else { return }
        self.loadingCount -= 1
        guard !self.windowClosed, !self.preparingToQuit else { return }
        for snapshot in startup.snapshots {
          let document = EditorDocument(id: snapshot.id)
          document.storage.mutableString.setString(snapshot.text)
          document.encoding = snapshot.encoding
          document.hasBOM = snapshot.hasBOM
          document.recoveredName =
            "Recovered "
            + (snapshot.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent }
              ?? "Untitled")
          // Never restore the original URL: Save must ask for a destination.
          for pane in document.panePool { self.installCallbacks(for: pane) }
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
        guard !self.windowClosed, !self.preparingToQuit else { return }
        self.refresh()
        self.reportRecoveryFailure(error)
      }
    }
  }

  private func scheduleRecovery() {
    if applicationRouting != nil {
      notifySessionChange()
      return
    }
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
          id: document.id, text: document.storage.string,
          encoding: document.encoding, hasBOM: document.hasBOM,
          originalPath: document.url?.path) : nil
      return (document.id, document.recoveryRevision, snapshot)
    }
  }

  private func enqueueRecovery() {
    if applicationRouting != nil {
      notifySessionChange()
      return
    }
    guard documents.allSatisfy({ $0.recoveryAuthority == nil }) else {
      present(EditorApplicationRoutingError.applicationOwned)
      return
    }
    guard !preparingToQuit, !windowClosed else { return }
    if onSessionChange != nil {
      notifySessionChange()
      return
    }
    let batch = recoveryBatch()
    let previous = recoveryWork
    recoveryWorkGeneration = UUID()
    recoveryWork = Task { [weak self, recovery] in
      await previous?.value
      do {
        try await recovery.persistBatch(batch)
      } catch {
        self?.recoveryWorkError = error
        self?.reportRecoveryFailure(error)
      }
    }
  }

  private func discardRecovery(_ id: UUID) {
    guard applicationRouting == nil,
      documents.first(where: { $0.id == id })?.recoveryAuthority == nil
    else {
      present(EditorApplicationRoutingError.applicationOwned)
      return
    }
    let previous = recoveryWork
    let cleanup = Task<Error?, Never> { [recovery] in
      await previous?.value
      do {
        try await recovery.close(id: id)
        return nil
      } catch { return error }
    }
    Self.pendingCloses[id] = (recovery, cleanup)
    recoveryWorkGeneration = UUID()
    recoveryWork = Task { [weak self] in
      let error = await cleanup.value
      if let error { self?.recoveryWorkError = error }
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
    guard
      editors.allSatisfy({
        $0.applicationRouting == nil && $0.documents.allSatisfy({ $0.recoveryAuthority == nil })
      })
    else {
      throw EditorApplicationRoutingError.applicationOwned
    }
    try await RecoveryCoordinator.shared.persistBatch(editors.flatMap { $0.recoveryBatch() })
  }

  func prepareToQuit(persistRecovery: Bool = true) async -> Bool {
    if persistRecovery,
      applicationRouting != nil || documents.contains(where: { $0.recoveryAuthority != nil })
    {
      present(EditorApplicationRoutingError.applicationOwned)
      return false
    }
    guard !documents.contains(where: { $0.panePresentation.installing != nil }) else {
      return false
    }
    guard allowLeavingUnsavedRecording() else { return false }
    guard !documents.contains(where: { $0.composingPaneID != nil }) else {
      present(PaneRoutingError.composition)
      return false
    }
    guard loadingCount == 0, !macroSaving, !documents.contains(where: { $0.saving }) else {
      let alert = NSAlert()
      alert.messageText = "A file operation is still running"
      alert.informativeText = "Wait for loading or saving to finish, then quit again."
      alert.runModal()
      return false
    }
    for document in documents {
      document.panePresentation.frozenCapture = capturePresentation(document)
      document.panePresentation.invalidate(force: true)
    }
    preparingToQuit = true
    for document in documents {
      for pane in document.panePool {
        if pane.selectableBeforeQuit == nil { pane.selectableBeforeQuit = pane.editor.isSelectable }
        pane.editor.isEditable = false
        pane.editor.isSelectable = false
      }
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
      document.panePresentation.frozenCapture = nil
      document.panePresentation.invalidate(force: true)
      for pane in document.panePool {
        let selectable = pane.selectableBeforeQuit ?? pane.editor.isSelectable
        pane.editor.isEditable = mayMutate(pane)
        pane.editor.isSelectable = selectable
        pane.selectableBeforeQuit = nil
      }
    }
    reconcileFileMonitoring()
  }

  private func reportRecoveryFailure(_ error: Error, always: Bool = false) {
    guard !windowClosed else { return }
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
    guard !windowClosed, !preparingToQuit else { return }
    if let errorHandler { errorHandler(error) } else { NSAlert(error: error).runModal() }
  }
}

// Application mode: one process owns models; this window only projects their registry placement.
extension EditorWindowController {
  private func requireApplicationEndpoint(userInitiated: Bool = true) throws
    -> EditorApplicationRouting
  {
    guard let routing = applicationRouting, !windowClosed, !userInitiated || !preparingToQuit else {
      throw EditorApplicationRoutingError.staleEndpoint
    }
    try routing.requireEndpointCurrent()
    if userInitiated { try routing.requireUserAdmission() }
    guard !windowClosed, !userInitiated || !preparingToQuit,
      routing.assignment.windowID == sessionID
    else {
      throw EditorApplicationRoutingError.staleEndpoint
    }
    return routing
  }
  private func applicationAllows(_ action: DocumentAdmission, document: EditorDocument) -> Bool {
    guard let routing = applicationRouting else { return true }
    guard (try? requireApplicationEndpoint()) != nil,
      routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment
    else { return false }
    return routing.registry.allows(action, documentID: document.id)
  }
  private func mayFocus(_ pane: EditorPane) -> Bool {
    if applicationUserAllows(.select, document: pane.document) { return true }
    guard let scope = projectionFocus, projectionToken == scope.token, scope.paneID == pane.id,
      current === pane.document, pane.isAttached,
      pane.document.panePool.contains(where: { $0 === pane })
    else { return false }
    return projectionAllows(.select, document: pane.document)
  }
  private func focusProjectedPane(_ pane: EditorPane) {
    guard let token = projectionToken, projectionFocus == nil else { return }
    projectionFocus = (token, pane.id)
    defer { projectionFocus = nil }
    _ = window?.makeFirstResponder(pane.editor)
  }
  /// Used only by synchronous owner layout/focus installation, never by user mutation sinks.
  private func projectionAllows(_ action: DocumentAdmission, document: EditorDocument) -> Bool {
    guard projectionToken != nil, let routing = applicationRouting else {
      return applicationAllows(action, document: document)
    }
    guard action == .paneInstall || action == .select,
      (try? requireApplicationEndpoint(userInitiated: false)) != nil,
      routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment
    else { return false }
    return routing.registry.allows(action, documentID: document.id)
  }
  private func applicationUserAllows(_ action: DocumentAdmission, document: EditorDocument) -> Bool
  {
    guard applicationRouting != nil else { return true }
    guard (try? requireApplicationEndpoint()) != nil else { return false }
    return applicationAllows(action, document: document)
  }
  private func applicationCommandAllowed(_ id: String) -> Bool {
    guard applicationRouting != nil else { return true }
    guard (try? requireApplicationEndpoint()) != nil else { return false }
    guard let document = current else { return true }
    let action: DocumentAdmission
    switch id {
    case "file.save", "file.saveAs", "file.revert", "file.checkDisk", "file.resolveDiskChange",
      "document.encoding":
      action = .fileOperation
    case "view.splitVertical", "view.splitHorizontal", "view.closeSplit", "view.wrap":
      action = .paneInstall
    case "file.nextTab", "file.previousTab", "view.focusOtherPane": action = .select
    case "edit.undo", "edit.redo": action = .undoRedo
    case "file.close", "file.closeAll", "file.closeOthers": action = .close
    default: action = .edit
    }
    return applicationAllows(action, document: document)
  }
  private func beginApplicationPreparation() throws -> UUID {
    _ = try requireApplicationEndpoint()
    guard applicationPreparation == nil else { throw DocumentIntakeError.busy }
    let id = UUID()
    applicationPreparation = id
    return id
  }
  private func requireApplicationPreparation(_ id: UUID) throws {
    _ = try requireApplicationEndpoint()
    guard applicationPreparation == id else { throw EditorApplicationRoutingError.staleEndpoint }
  }
  private func submitApplicationSeed(
    _ seed: NativeDocumentSeed, provenance: DocumentIntakeProvenance,
    selection: EditorIntakeSelection, additionalAdmission: (() -> Bool)? = nil,
    insertionIndex: Int? = nil
  ) throws -> DocumentIntakeID {
    let userInitiated: Bool
    switch provenance {
    case .fresh, .history: userInitiated = true
    case .session, .recovery: userInitiated = false
    }
    let routing = try requireApplicationEndpoint(userInitiated: userInitiated)
    guard projectionToken == nil, additionalAdmission?() != false else { throw CancellationError() }
    let endpoint = routing.endpointID
    return try routing.submit(
      .init(
        endpointID: endpoint, assignment: routing.assignment,
        seed: seed, provenance: provenance, selection: selection,
        requireDestinationCurrent: { [weak self] in
          guard let self else { throw CancellationError() }
          let current = try self.requireApplicationEndpoint(userInitiated: userInitiated)
          guard current.endpointID == endpoint, additionalAdmission?() != false else {
            throw EditorApplicationRoutingError.staleEndpoint
          }
        }, insertionIndex: insertionIndex))
  }
  func acceptPreparedSessionSeed(
    _ seed: NativeDocumentSeed, provenance: DocumentIntakeProvenance,
    selection: EditorIntakeSelection, insertionIndex: Int? = nil
  ) throws -> DocumentIntakeID {
    guard seed.kind == .restored else { throw EditorApplicationRoutingError.unsupportedSeed }
    switch provenance {
    case .session(let claim):
      guard claim.documentID == seed.id else { throw EditorApplicationRoutingError.unsupportedSeed }
    case .recovery(let claim):
      guard claim.documentID == seed.id, seed.url == nil, seed.originalBytes == nil else {
        throw EditorApplicationRoutingError.unsupportedSeed
      }
    case .fresh, .history: throw EditorApplicationRoutingError.unsupportedSeed
    }
    return try submitApplicationSeed(
      seed, provenance: provenance, selection: selection, insertionIndex: insertionIndex)
  }
  private func validateApplicationResult(_ result: DocumentIntakeResult) throws {
    let routing = try requireApplicationEndpoint(userInitiated: false)
    switch result {
    case .imported(let id):
      guard let model = routing.registry.handle(id: id) as? EditorDocument,
        documents.contains(where: { $0 === model }),
        let expected = routing.registry.window(id: sessionID)
      else { throw EditorApplicationRoutingError.invalidProjection }
      try validateRegistryProjection(
        expected, revision: routing.registry.workspaceRevision, endpointID: routing.endpointID)
    case .refused(let error), .retained(_, let error): throw error
    }
  }
  private func observeApplicationIntake(_ id: DocumentIntakeID) {
    guard let routing = applicationRouting else { return }
    Task { [weak self] in
      do {
        let result = try await routing.wait(id)
        guard let self else { return }
        try self.validateApplicationResult(result)
      } catch {
        guard let self, !self.windowClosed, !self.preparingToQuit else { return }
        self.present(error)
      }
    }
  }
  private func openApplicationDocument(
    _ url: URL, encoding: DocumentEncoding?, shouldAccept: (() -> Bool)?,
    allowLargeViewer: Bool, hasPositionCompletion: Bool,
    finish: @escaping (Error?, Bool) -> Void
  ) {
    let request: UUID
    do { request = try beginApplicationPreparation() } catch {
      finish(error, true)
      return
    }
    loadingCount += 1
    refresh()
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result<NativeDocumentSeed?, Error> {
          let values = try url.resourceValues(forKeys: [.fileSizeKey])
          if (values.fileSize ?? 0) > 100_000_000 { return nil }
          return try NativeDocumentSeed.opened(
            url: url, bytes: Self.readBytes(url), encoding: encoding)
        }
      }.value
      guard let self else {
        finish(CancellationError(), false)
        return
      }
      self.loadingCount -= 1
      defer {
        if self.applicationPreparation == request { self.applicationPreparation = nil }
        if !self.windowClosed { self.refresh() }
      }
      do {
        try self.requireApplicationPreparation(request)
        guard shouldAccept?() != false else { throw CancellationError() }
        guard let seed = try result.get() else {
          if allowLargeViewer, let viewer = self.onOpenLargeFile {
            viewer(url)
            finish(Self.largeFileError(), hasPositionCompletion)
          } else {
            finish(Self.largeFileError(), true)
          }
          return
        }
        if let existing = self.documents.first(where: {
          $0.url?.standardizedFileURL == url.standardizedFileURL
        }) {
          self.display(existing)
          guard self.current === existing else {
            throw EditorApplicationRoutingError.invalidProjection
          }
          if let encoding {
            self.reload(
              encoding: encoding, shouldAccept: shouldAccept,
              onFailure: { finish($0, true) }, onReload: { finish(nil, false) })
          } else {
            finish(nil, false)
          }
          return
        }
        let id = try self.submitApplicationSeed(
          seed, provenance: .fresh, selection: .select, additionalAdmission: shouldAccept)
        let outcome = try await self.applicationRouting!.wait(id)
        try self.requireApplicationPreparation(request)
        guard shouldAccept?() != false else { throw CancellationError() }
        try self.validateApplicationResult(outcome)
        finish(nil, false)
      } catch { finish(error, !self.windowClosed && !self.preparingToQuit) }
    }
  }
  private func duplicateApplicationDocument(_ source: EditorDocument) {
    let request: UUID
    do {
      guard applicationAllows(.select, document: source), source.storage.length <= 100_000_000
      else {
        throw EditorApplicationRoutingError.applicationOwned
      }
      request = try beginApplicationPreparation()
    } catch {
      present(error)
      return
    }
    let text = source.storage.string
    let revision = source.editRevision
    let ownership = source.ownershipGeneration
    let encoding = source.encoding
    let bom = source.hasBOM
    let language = source.language
    let manual = source.manualLanguage
    Task { [weak self, weak source] in
      let result = await Task.detached {
        Result {
          try NativeDocumentSeed.duplicate(
            text: text, encoding: encoding, hasBOM: bom, language: language, manualLanguage: manual)
        }
      }.value
      guard let self else { return }
      defer { if self.applicationPreparation == request { self.applicationPreparation = nil } }
      do {
        try self.requireApplicationPreparation(request)
        guard let source, self.documents.contains(where: { $0 === source }),
          source.editRevision == revision, source.ownershipGeneration == ownership,
          self.applicationAllows(.select, document: source)
        else { throw PaneRoutingError.stale }
        let id = try self.submitApplicationSeed(
          result.get(), provenance: .fresh, selection: .select)
        self.observeApplicationIntake(id)
      } catch { if !self.windowClosed { self.present(error) } }
    }
  }

  private func registryModels(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws -> [EditorDocument] {
    guard let routing = applicationRouting, !windowClosed,
      endpointID == routing.endpointID, expected.id == sessionID,
      routing.assignment.windowID == sessionID
    else { throw EditorApplicationRoutingError.staleEndpoint }
    try routing.requireEndpointCurrent()
    guard !windowClosed, routing.registry.workspaceRevision == revision,
      routing.registry.window(id: sessionID) == expected,
      expected.groups.count == 1, expected.groups[0].id == routing.assignment.groupID,
      expected.focusedGroupID == expected.groups[0].id
    else { throw EditorApplicationRoutingError.invalidProjection }
    let group = expected.groups[0]
    guard Set(group.documentIDs).count == group.documentIDs.count,
      group.selectedDocumentID.map({ group.documentIDs.contains($0) }) ?? group.documentIDs.isEmpty
    else { throw EditorApplicationRoutingError.invalidProjection }
    return try group.documentIDs.map { id in
      guard let model = routing.registry.handle(id: id) as? EditorDocument,
        model.id == id, routing.registry.assignment(of: id) == routing.assignment,
        routing.registry.adoptionStatus(documentID: id) == .active,
        routing.registry.metadata(id: id) != nil
      else { throw EditorApplicationRoutingError.invalidProjection }
      return model
    }
  }
  private func projectCurrentRegistry() throws {
    let routing = try requireApplicationEndpoint()
    guard let expected = routing.registry.window(id: sessionID) else {
      throw EditorApplicationRoutingError.invalidProjection
    }
    try applyRegistryProjection(
      expected, revision: routing.registry.workspaceRevision, endpointID: routing.endpointID)
  }
  func applyRegistryProjection(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws {
    guard projectionToken == nil, !preparingToQuit else {
      throw EditorApplicationRoutingError.invalidProjection
    }
    let token = UUID()
    projectionToken = token
    defer { if projectionToken == token { projectionToken = nil } }
    let next = try registryModels(expected, revision: revision, endpointID: endpointID)
    let oldCurrent = current
    let selection = expected.groups[0].selectedDocumentID
    let selected = next.first { $0.id == selection }
    guard oldCurrent?.composingPaneID == nil || oldCurrent === selected else {
      throw PaneRoutingError.composition
    }
    let old = documents
    projectionValid = false
    for removed in old where !next.contains(where: { $0 === removed }) {
      try applicationRouting!.detachDocumentEndpoint(removed)
      _ = try registryModels(expected, revision: revision, endpointID: endpointID)
      pendingEndpointAttachments.remove(removed.id)
    }
    documents = next
    selectedID = selection
    for document in next {
      if let pin = applicationRouting?.registry.metadata(id: document.id)?.pinned,
        document.pinned != pin
      {
        document.pinned = pin
      }
      if !old.contains(where: { $0 === document }) {
        for pane in document.panePool { installCallbacks(for: pane) }
        pendingEndpointAttachments.insert(document.id)
      }
      if pendingEndpointAttachments.contains(document.id) {
        try attachDocumentEndpoint(document)
        // Successful reattachment consumed its receipt; later projection refusal must not repeat it.
        pendingEndpointAttachments.remove(document.id)
        _ = try registryModels(expected, revision: revision, endpointID: endpointID)
      }
    }
    if let selected {
      if oldCurrent !== selected
        || host.displayedIDs != selected.panePool.filter(\.isAttached).map(\.id)
      {
        if let oldCurrent, oldCurrent !== selected, next.contains(where: { $0 === oldCurrent }) {
          presentationInteraction(oldCurrent)
        }
        for pane in selected.panePool where pane.isAttached { installCallbacks(for: pane) }
        if !selected.settingsApplied { configureSettings(selected) }
        let wrap = !preferredPane(in: selected).editor.isHorizontallyResizable
        try presentPanes(selected, wrap: wrap)
        focusProjectedPane(preferredPane(in: selected))
        installPendingPresentationIfPossible(selected)
        selected.highlighter.update(language: selected.language)
      }
    } else {
      try host.present(panes: [], axis: .sideBySide)
    }
    let verified = try registryModels(expected, revision: revision, endpointID: endpointID)
    guard projectionToken == token, verified.count == documents.count,
      zip(verified, documents).allSatisfy({ $0 === $1 }), selectedID == selection
    else { throw EditorApplicationRoutingError.invalidProjection }
    refresh()
    renderDiskStatus()
    // AppKit notifications may reenter registry operations during rendering.
    try validateRegistryProjection(
      expected, revision: revision, endpointID: endpointID, allowing: token)
    projectionValid = true
  }
  func validateRegistryProjection(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws {
    try validateRegistryProjection(
      expected, revision: revision, endpointID: endpointID, allowing: nil)
  }
  private func validateRegistryProjection(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID, allowing token: UUID?
  ) throws {
    guard projectionToken == token, token != nil || projectionValid else {
      throw EditorApplicationRoutingError.invalidProjection
    }
    let models = try registryModels(expected, revision: revision, endpointID: endpointID)
    guard models.count == documents.count, zip(models, documents).allSatisfy({ $0 === $1 }),
      selectedID == expected.groups[0].selectedDocumentID,
      host.displayedIDs == (current?.panePool.filter(\.isAttached).map(\.id) ?? []),
      models.allSatisfy({ applicationRouting?.registry.metadata(id: $0.id)?.pinned == $0.pinned })
    else { throw EditorApplicationRoutingError.invalidProjection }
  }
  func captureManagedSessionCheckpoint(expected: DocumentWindowSnapshot) throws
    -> ManagedWindowCheckpointCapture
  {
    guard let routing = applicationRouting else {
      throw EditorApplicationRoutingError.applicationOwned
    }
    let revision = routing.registry.workspaceRevision
    try validateRegistryProjection(expected, revision: revision, endpointID: routing.endpointID)
    let items = try documents.map { document -> RecoveryCheckpointItem in
      let item = try document.captureAuthorizedRecovery()
      return .init(
        id: document.id, revision: item.revision, snapshot: item.snapshot, authority: item.authority
      )
    }
    let metadata = sessionMetadata
    try validateRegistryProjection(expected, revision: revision, endpointID: routing.endpointID)
    return .init(window: metadata, liveTabIDs: Set(documents.map(\.id)), recovery: items)
  }
}

// Native adapters for the process-owned close transaction. No filesystem authority is created here.
enum NativeManagedCloseError: LocalizedError {
  case stale, busy, pendingPublication, drainFailed, opening
  var errorDescription: String? {
    switch self {
    case .stale: return "Document ownership changed. Keep it open and retry closing."
    case .opening: return "Finish opening or recovering this window’s documents before closing it."
    case .busy: return "Finish composition, file operations, and macro recording before closing."
    case .pendingPublication:
      return
        "A file save is unconfirmed. Use Save to verify and retry, or Save As before closing. The destination may already contain the attempted bytes."
    case .drainFailed:
      return "Earlier recovery work failed. Resolve recovery before changing document ownership."
    }
  }
}
extension EditorWindowController {
  func requireEndpointIdentity(endpointID: UUID, assignment: DocumentAssignment) throws {
    let routing = try requireApplicationEndpoint(userInitiated: false)
    guard routing.endpointID == endpointID, routing.assignment == assignment else {
      throw NativeManagedCloseError.stale
    }
  }
  private func closeModel(_ request: DocumentCloseRequest, endpointID: UUID) throws
    -> EditorDocument
  {
    guard let routing = applicationRouting else { throw NativeManagedCloseError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: request.assignment)
    guard let model = routing.registry.handle(id: request.documentID) as? EditorDocument,
      documents.contains(where: { $0 === model }),
      routing.registry.assignment(of: model.id) == request.assignment,
      routing.registry.allows(.close, documentID: model.id),
      try model.captureCloseState() == request.state,
      !model.undoManager.isUndoing, !model.undoManager.isRedoing,
      !macroSaving, !isRecordingMacro, recordedCommands.isEmpty, replayCancellation == nil,
      loadingCount == 0, applicationPreparation == nil
    else { throw NativeManagedCloseError.busy }
    if model.pendingPublication != nil { throw NativeManagedCloseError.pendingPublication }
    let fresh = try routing.registry.requestClose(documentID: model.id)
    guard fresh.admissionGeneration == request.admissionGeneration,
      fresh.assignment == request.assignment, fresh.metadata == request.metadata,
      fresh.state == request.state
    else { throw NativeManagedCloseError.stale }
    return model
  }
  func confirmManagedClose(
    _ request: DocumentCloseRequest, endpointID: UUID,
    decide: ((NSAlert) async -> NSApplication.ModalResponse)? = nil
  ) async throws -> DocumentCloseDisposition? {
    let model = try closeModel(request, endpointID: endpointID)
    if !request.state.isDirty, !request.state.hasPendingPublication,
      request.state.canRetainCleanHistory
    {
      return .retainCleanHistory
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Discard unsaved changes?"
    alert.informativeText = "\(model.name) has unsaved changes. Cancel to save your work first."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Discard Changes")
    let response: NSApplication.ModalResponse
    if let decide { response = await decide(alert) } else { response = alert.runModal() }
    _ = try closeModel(request, endpointID: endpointID)
    return response == .alertSecondButtonReturn ? .discardWithoutHistory : nil
  }
  func applyManagedAdmission(to document: EditorDocument, endpointID: UUID) throws {
    guard let routing = applicationRouting else { throw NativeManagedCloseError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
    guard routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment,
      documents.contains(where: { $0 === document })
    else { throw NativeManagedCloseError.stale }
    let before = try document.captureCloseState()
    let geometry = document.captureCloseGeometry()
    refreshInteractivity(document)
    renderPanePresentationStatus()
    guard try document.captureCloseState() == before, document.captureCloseGeometry() == geometry
    else { throw NativeManagedCloseError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
  }
  func drainLegacyRecoveryWrites(endpointID: UUID) async throws {
    guard let routing = applicationRouting else { throw NativeManagedCloseError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
    // Application-created endpoints never start legacy timers. A nonempty queue is drained conservatively.
    recoveryDebounce?.cancel()
    recoveryPeriodic?.cancel()
    while true {
      let generation = recoveryWorkGeneration
      await recoveryWork?.value
      try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
      if generation == recoveryWorkGeneration { break }
    }
    if let error = recoveryWorkError { throw error }
    try Self.assertNoPendingCloses()
  }
  func validateManagedResources(expected: DocumentWindowSnapshot) throws {
    guard let routing = applicationRouting else { throw NativeManagedCloseError.stale }
    try validateRegistryProjection(
      expected, revision: routing.registry.workspaceRevision, endpointID: routing.endpointID)
    var budget = SessionStartupBudget()
    for document in documents {
      try budget.admit(
        utf16Count: document.storage.length, originalByteCount: document.originalBytes?.count ?? 0)
    }
  }
  func closeEmptyManagedWindow(endpointID: UUID) throws {
    guard let routing = applicationRouting, let window else { throw NativeManagedCloseError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
    guard let expected = routing.registry.window(id: sessionID) else {
      throw NativeManagedCloseError.stale
    }
    try validateRegistryProjection(
      expected, revision: routing.registry.workspaceRevision, endpointID: endpointID)
    guard documents.isEmpty, expected.groups.allSatisfy({ $0.documentIDs.isEmpty }),
      emptyWindowClosePermit == nil
    else { throw NativeManagedCloseError.busy }
    emptyWindowClosePermit = (UUID(), routing.registry.workspaceRevision)
    defer { emptyWindowClosePermit = nil }
    window.performClose(nil)
  }
}
