import AppKit
import PadCore
import SearchExecution

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
/// Captured before completion callbacks can move, edit, or replace the opened target.
@MainActor struct EditorOpenedDocument {
  fileprivate let document: EditorDocument
  fileprivate let pane: EditorPane
  fileprivate let context: PaneCommandContext
  fileprivate let ownership: UUID
  fileprivate let closeMutation: UUID
  fileprivate let operationID: UUID?
  fileprivate let endpointID: UUID?
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

@MainActor private struct DocumentSearchNativeBinding {
  let windowID: UUID
  let endpointID: UUID
  let documentID: UUID
  let paneID: UUID
  let ownershipGeneration: UUID
  let assignment: DocumentAssignment
  let registryIdentity: ObjectIdentifier
  let windowIdentity: ObjectIdentifier

}

@MainActor private enum NativeEditMode {
  case interactive
  case searchBorrow(binding: DocumentSearchNativeBinding, credential: DocumentSearchCredential)
}

/// One synchronous native edit admission owns this proposal. The actual delegate claims
/// it before calling application code; nested native edits keep their normal bookkeeping.
@MainActor private final class NativeEditPreparation {
  let editor: NSTextView
  let range: NSRange
  let replacement: String
  let mode: NativeEditMode
  let validate: @MainActor () -> Bool
  var delegateClaimed = false
  var controlledStringInsertion = false
  var controlledFactsValid: (@MainActor () -> Bool)?
  var macroFactsValid: (@MainActor () -> Bool)?
  var commit: (@MainActor () -> Bool)?

  init(
    editor: NSTextView, range: NSRange, replacement: String, mode: NativeEditMode,
    validate: @escaping @MainActor () -> Bool
  ) {
    self.editor = editor
    self.range = range
    self.replacement = replacement
    self.mode = mode
    self.validate = validate
  }
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
  private var settledTransferProjection: EditorTransferEndpointReceipt?
  private var transferLayoutDepth = 0
  private var projectionToken: UUID?
  private var transferProjection:
    (snapshot: DocumentTransferSnapshot, receipt: EditorTransferEndpointReceipt)?
  private var projectionFocus: (token: UUID, paneID: UUID)?
  private var projectionValid = false
  private var applicationPreparation: UUID?
  private var pendingEndpointAttachments = Set<UUID>()
  private var transferAttachmentOwner: (lease: DocumentTransferLease, ids: Set<UUID>)?
  private var emptyWindowClosePermit: (id: UUID, revision: UUID)?
  private var recoveryWorkGeneration = UUID()
  private var recoveryWorkError: Error?
  var onClose: (() -> Void)?
  var onOpenLargeFile: ((URL) -> Void)?
  var onOpenedURL: ((URL) -> Void)?
  private static var pendingCloses: [UUID: (RecoveryCoordinator, Task<Error?, Never>)] = [:]
  private var documents: [EditorDocument] = [] { didSet { reconcileMacroMembership(oldValue) } }
  private var selectedID: UUID?
  private let tabs = NSPopUpButton(frame: .zero, pullsDown: false)
  private let tabBar = DocumentTabBar()
  private var closedDocuments: [EditorDocument] = []
  private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
  private let host = EditorPaneHost(frame: .zero)
  private let workspaceSplit = NSSplitView()
  private lazy var workspace = WorkspaceSidebar { [weak self] url in self?.open(url) }
  private let status = NSTextField(labelWithString: "")
  private let macroRecordingIncompleteStatus = NSTextField(
    wrappingLabelWithString:
      "Macro recording is incomplete. Some text changes were outside the supported recording boundary. The captured commands are retained, but this recording cannot be saved as a complete sequence. Use Macro → Discard Recording to start again."
  )
  private var macroNoticeRendering = false
  private var macroNoticeRenderPending = false
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
    source.editor.breakUndoCoalescing()
    if attached.count == 1 {
      let additional = try makeConfiguredPane(document)
      additional.attach()
      installCallbacks(for: additional)
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

  private func makeConfiguredPane(_ document: EditorDocument) throws -> EditorPane {
    let endpoint = applicationRouting?.endpointID
    let policy = settingsPolicyRevision
    return try document.makePane { [self] in
      guard !windowClosed, !preparingToQuit, applicationRouting?.endpointID == endpoint,
        settingsPolicyRevision == policy, documents.contains(where: { $0 === document })
      else { return false }
      return projectionAllows(
        .paneInstall, document: document,
        configurationToken: document.nativeConfigurationToken)
        && settingsPolicyRevision == policy && applicationRouting?.endpointID == endpoint
    }
  }

  private func presentPanes(_ document: EditorDocument, wrap: Bool) throws {
    let panes = document.panePool.filter(\.isAttached)
    try withTransferNativeLayout {
      try host.present(panes: panes, axis: document.splitAxis)
      window?.contentView?.layoutSubtreeIfNeeded()
      if let window {
        var minimum = NSSize(width: 540, height: 360)
        if panes.count == 2 {
          if document.splitAxis == .sideBySide {
            minimum.width = max(minimum.width, ceil(window.frame.width - host.bounds.width + 321))
          } else {
            minimum.height = max(
              minimum.height, ceil(window.frame.height - host.bounds.height + 321))
          }
        }
        window.minSize = minimum
        var frame = window.frame
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
        window.contentView?.layoutSubtreeIfNeeded()
      }
    }
    configureWrap(document, enabled: wrap)
    refreshInteractivity(document)
    installApprovedViewRouting(document)
  }

  private func openedTarget(_ document: EditorDocument, pane source: EditorPane? = nil)
    -> EditorOpenedDocument
  {
    let pane = source ?? preferredPane(in: document)
    return EditorOpenedDocument(
      document: document, pane: pane, context: context(for: pane),
      ownership: document.ownershipGeneration, closeMutation: document.closeMutationGeneration,
      operationID: document.operationID, endpointID: applicationRouting?.endpointID)
  }

  /// Reads only native identity/state; owner callbacks run before this final fence.
  private func openedTargetStillValid(_ target: EditorOpenedDocument) -> Bool {
    let document = target.document
    return nativeEditContextStillValid(
      document, source: target.pane, context: target.context, requireFocus: false,
      operationID: target.operationID)
      && document.operationID == target.operationID
      && document.ownershipGeneration == target.ownership
      && document.closeMutationGeneration == target.closeMutation
      && applicationRouting?.endpointID == target.endpointID
      && !target.pane.editor.hasMarkedText()
      && current?.composingPaneID == nil
  }

  private func activateSource(
    _ pane: EditorPane, snapshot: String, range: NSRange,
    opened: EditorOpenedDocument? = nil, request: FolderSearchNavigationRequest? = nil
  ) throws {
    let target = opened ?? openedTarget(pane.document, pane: pane)
    let document = pane.document
    let native = snapshot as NSString
    guard range.location >= 0, range.length >= 0, range.location <= native.length,
      range.length <= native.length - range.location
    else { throw PaneRoutingError.stale }
    func scalarBoundary(_ offset: Int) -> Bool {
      offset == 0 || offset == native.length
        || !(0xDC00...0xDFFF).contains(native.character(at: offset))
    }
    guard scalarBoundary(range.location), scalarBoundary(NSMaxRange(range)) else {
      throw PaneRoutingError.stale
    }
    func valid() -> Bool {
      target.document === document && (opened == nil || target.pane === pane)
        && openedTargetStillValid(target)
        && pane.isAttached && document.panePool.contains(where: { $0 === pane })
        && pane.editor.textStorage === document.storage && !pane.editor.hasMarkedText()
        && document.storage.string.utf16.elementsEqual(snapshot.utf16)
        && (request == nil || (request!.isCurrent && request!.belongs(to: folderSearch)))
    }
    func admitted() -> Bool { applicationAllows(.select, document: document) && valid() }
    guard admitted() else { throw PaneRoutingError.stale }
    document.preferredPaneID = pane.id
    display(document)
    guard admitted(), current === document else { throw PaneRoutingError.stale }
    try focusPane(id: pane.id)
    guard admitted(), current === document, focusedPane === pane else {
      throw PaneRoutingError.stale
    }
    pane.editor.setSelectedRange(range)
    // Selection notifications can reenter too; never scroll a now-invalid target.
    guard admitted(), current === document, focusedPane === pane else {
      throw PaneRoutingError.stale
    }
    pane.editor.scrollRangeToVisible(range)
  }
  private var settings = EditorSettings.defaults
  private var settingsPolicyRevision = UUID()
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
    let transferReceipt = transferProjection?.receipt
    let transferLease = transferReceipt?.lease
    try routing.reattachDocumentEndpoint(
      document,
      { [weak self, weak document, weak transferReceipt] in
        guard let self, let document else { return nil }
        if let transferLease,
          self.applicationRouting?.registry.hasActiveTransferLease(transferLease) == true
        {
          guard let transferReceipt else { return nil }
          return self.transferFileStateContext(document, receipt: transferReceipt)
        }
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
    case .notText:
      message =
        "The disk copy contains NUL characters or an unsupported Unicode prefix and was refused as editable text. Your buffer is preserved. Inspect the file with a suitable read-only viewer or convert a copy to a supported text format."
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
  private var nativeEditPreparation: NativeEditPreparation?
  private var encodingPanel: EncodingPanelController?
  private var textUtilities: TextUtilitiesController?
  private var folderSearch: FolderSearchController?
  private var statisticsTask: Task<DocumentStatistics, Error>?
  private var statisticsGeneration = 0
  private var markdownPreview: MarkdownPreviewController?
  private var backupManager: BackupManagerController?
  private var outline: OutlineController?
  private var comparison: ComparisonController?
  private var recordingDocumentID: UUID? { didSet { recorderIdentityWritten() } }
  private var recordedCommands: [MacroCommand] = [] { didSet { recorderCommandsWritten() } }
  private var recordedUnits = 0 { didSet { recorderUnitsWritten() } }
  private var macroSaving = false
  private var replayCancellation: MacroCancellation?
  var isRecordingMacro: Bool { recordingDocumentID != nil }
  var currentDocumentIsDirty: Bool { current?.dirty ?? false }
  var currentSaveIsUncertain: Bool { current?.pendingPublication != nil }
  private let saveServices: EditorSaveServices
  private let chooseSaveDestination: ((URL?, String) -> URL?)?
  private let errorHandler: ((Error) -> Void)?

  // APPROVED-VIEW-BROKER-BEGIN
  private static let approvedViewBroker = ApprovedViewCommitBroker()
  private final class ApprovedRouteAssociation {
    let value: ApprovedViewRoute
    weak var document: EditorDocument?
    weak var pane: EditorPane?
    weak var storage: DocumentCommitTextStorage?
    weak var window: NSWindow?
    weak var manager: GuardedDocumentUndoManager?
    init(
      value: ApprovedViewRoute, document: EditorDocument, pane: EditorPane,
      storage: DocumentCommitTextStorage, window: NSWindow,
      manager: GuardedDocumentUndoManager
    ) {
      self.value = value
      self.document = document
      self.pane = pane
      self.storage = storage
      self.window = window
      self.manager = manager
    }
  }
  private var approvedRoutes: [ObjectIdentifier: ApprovedRouteAssociation] = [:]
  private var approvedRouteSerial: UInt64 = 0
  private var approvedRouteSerialExhausted = false

  // A native lifecycle retirement may find no association. Still fence a
  // callback-bearing installation, including same-window/view ABA.
  private var approvedRouteRetirementSerial: UInt64 = 0
  private var approvedRouteRetirementExhausted = false
  private func noteApprovedRouteRetirement() {
    guard !approvedRouteRetirementExhausted else { return }
    let (next, overflow) = approvedRouteRetirementSerial.addingReportingOverflow(1)
    if overflow {
      approvedRouteRetirementExhausted = true
    } else {
      approvedRouteRetirementSerial = next
    }
  }

  struct ApprovedRouteRecorderFence: Equatable {
    let epoch: UUID?
    let documentID: UUID?
    let active: Bool?
    let reason: MacroRecordingGap?
    let noticePending: Bool?
    let recordingID: UUID?
    let serial: UInt64
    let exhausted: Bool
    let compatibilityPhase: UInt8
    let commands: [MacroCommand]
    let units: Int
    let saving: Bool
    let saveAttemptID: UUID?
    static func == (lhs: Self, rhs: Self) -> Bool {
      guard lhs.epoch == rhs.epoch, lhs.documentID == rhs.documentID,
        lhs.active == rhs.active, lhs.reason == rhs.reason,
        lhs.noticePending == rhs.noticePending, lhs.recordingID == rhs.recordingID,
        lhs.serial == rhs.serial, lhs.exhausted == rhs.exhausted,
        lhs.compatibilityPhase == rhs.compatibilityPhase, lhs.units == rhs.units,
        lhs.saving == rhs.saving, lhs.saveAttemptID == rhs.saveAttemptID,
        lhs.commands.count == rhs.commands.count
      else { return false }
      return zip(lhs.commands, rhs.commands).allSatisfy { pair in
        switch pair {
        case (.transform(let a), .transform(let b)): return a == b
        case (.replace(let al, let an, let a), .replace(let bl, let bn, let b)):
          return al == bl && an == bn && a.utf16.elementsEqual(b.utf16)
        default: return false
        }
      }
    }
  }

  // Pure value snapshot. This is route-install fencing, not recording authority.
  func nativeMacroApprovedRouteRecorderFence() -> ApprovedRouteRecorderFence {
    let phase: UInt8
    switch compatibilitySetterPhase {
    case .none: phase = 0
    case .identityNil: phase = 1
    case .identityNonNil: phase = 2
    case .commandsAfterNil: phase = 3
    case .commandsAfterNonNil: phase = 4
    }
    return ApprovedRouteRecorderFence(
      epoch: recordingIntegrity?.epoch,
      documentID: recordingIntegrity?.documentID, active: recordingIntegrity?.active,
      reason: recordingIntegrity?.firstReason, noticePending: recordingIntegrity?.noticePending,
      recordingID: recordingDocumentID, serial: recordingStateSerial,
      exhausted: recordingStateSerialExhausted, compatibilityPhase: phase,
      commands: recordedCommands, units: recordedUnits, saving: macroSaving,
      saveAttemptID: recordingSaveAttempt?.id)
  }

  private static var approvedContextCount: Int { macroCommitContext?.entryCount ?? 64 }
  private static var approvedContextAvailable: Bool {
    guard let context = macroCommitContext else { return false }
    return !context.overflowBarrierIsActive && !context.frameIssuerIsExhausted
  }

  // A replacement is retirement, never a permission-time association refresh.
  override var window: NSWindow? {
    willSet { retireAllApprovedRoutes() }
  }

  private func retireAllApprovedRoutes() {
    noteApprovedRouteRetirement()
    Self.approvedViewBroker.retire(owner: ObjectIdentifier(self))
    let old = approvedRoutes
    approvedRoutes.removeAll()
    for association in old.values {
      association.pane?.editor.retireApprovedViewOwner(self)
      if let storage = association.storage {
        association.manager?.retireApprovedHistoryOwner(self, storageID: ObjectIdentifier(storage))
      }
    }
  }

  func nativeApprovedViewRetire(storageID: ObjectIdentifier) {
    noteApprovedRouteRetirement()
    Self.approvedViewBroker.retire(owner: ObjectIdentifier(self), storage: storageID)
    let keys = approvedRoutes.filter { $0.value.value.lease.storageID == storageID }.map(\.key)
    for key in keys {
      guard let association = approvedRoutes.removeValue(forKey: key) else { continue }
      association.pane?.editor.retireApprovedViewOwner(self)
      association.manager?.retireApprovedHistoryOwner(self, storageID: storageID)
    }
  }

  func nativeApprovedViewRetire(_ view: DocumentTextView) {
    noteApprovedRouteRetirement()
    guard let association = approvedRoutes[ObjectIdentifier(view)] else { return }
    nativeApprovedViewRetire(storageID: association.value.lease.storageID)
  }

  private func approvedStoredRoute(_ association: ApprovedRouteAssociation) -> Bool {
    let value = association.value
    guard !windowClosed, !preparingToQuit, projectionToken == nil,
      transferProjection == nil, settledTransferProjection == nil,
      approvedRoutes[value.viewID] === association,
      macroBindings[value.lease.storageID] == value.lease,
      let document = association.document, let pane = association.pane,
      let storage = association.storage, let manager = association.manager,
      association.window != nil,
      ObjectIdentifier(document) == value.lease.documentObjectID,
      document.id == value.lease.documentID,
      document.ownershipGeneration == value.lease.ownershipGeneration,
      documents.contains(where: { $0 === document }),
      document.panePool.contains(where: { $0 === pane }), pane.isAttached,
      pane.document === document, pane.id == value.paneID,
      ObjectIdentifier(pane.editor) == value.viewID,
      ObjectIdentifier(storage) == value.lease.storageID,
      document.storage === storage, document.undoManager === manager,
      ObjectIdentifier(manager) == value.managerID,
      value.lease.endpointID == applicationRouting?.endpointID,
      value.lease.assignment == applicationRouting?.assignment,
      storage.nativeMacroHasBinding(self, lease: value.lease)
    else { return false }
    return true
  }

  private func approvedNativeRoute(_ association: ApprovedRouteAssociation) -> Bool {
    guard let pane = association.pane, let storage = association.storage,
      let boundWindow = association.window, let manager = association.manager
    else { return false }
    return window === boundWindow && pane.editor.window === boundWindow
      && ObjectIdentifier(boundWindow) == association.value.windowID
      && pane.editor.textStorage === storage && pane.editor.documentUndo === manager
      && pane.editor.approvedViewOwner === self
      && pane.editor.approvedViewStorage === storage
      && pane.editor.approvedViewWindow === boundWindow
      && pane.editor.approvedViewRoute == association.value
  }

  // Stored state only: never invoke native admission/getters from this predicate.
  // Managed installation requires the current exact registry projection and open
  // active membership. Unmanaged controllers retain their lawful local route.
  private func approvedInstallMemberCurrent(
    _ document: EditorDocument, pane: EditorPane, storage: DocumentCommitTextStorage,
    lease: MacroBindingLease
  ) -> Bool {
    guard !windowClosed, !preparingToQuit, projectionToken == nil,
      transferProjection == nil, settledTransferProjection == nil,
      documents.contains(where: { $0 === document }),
      document.panePool.contains(where: { $0 === pane }), pane.document === document,
      pane.isAttached, lease.paneIDs.contains(pane.id),
      document.storage === storage, !storage.nativeMacroBindingIsSuspended,
      lease.controllerID == ObjectIdentifier(self),
      lease.documentObjectID == ObjectIdentifier(document), lease.documentID == document.id,
      lease.storageID == ObjectIdentifier(storage),
      lease.ownershipGeneration == document.ownershipGeneration,
      macroBindings[ObjectIdentifier(storage)] == lease,
      storage.nativeMacroHasBinding(self, lease: lease),
      lease.endpointID == applicationRouting?.endpointID,
      lease.assignment == applicationRouting?.assignment
    else { return false }
    if let routing = applicationRouting {
      guard projectionValid, routing.assignment.windowID == sessionID,
        routing.registry.handle(id: document.id) === document,
        routing.registry.assignment(of: document.id) == routing.assignment,
        routing.registry.closeStatus(documentID: document.id) == .open,
        routing.registry.adoptionStatus(documentID: document.id) == .active,
        let expected = routing.registry.window(id: sessionID)
      else { return false }
      return nativeMacroTerminalProjectionMatches(
        expected,
        revision: routing.registry.workspaceRevision, endpointID: routing.endpointID)
    }
    return true
  }

  private func installApprovedViewRouting(_ document: EditorDocument) {
    guard let storage = document.storage as? DocumentCommitTextStorage,
      let lease = macroBindings[ObjectIdentifier(storage)], !approvedRouteSerialExhausted,
      !approvedRouteRetirementExhausted,
      storage.nativeMacroHasBinding(self, lease: lease)
    else { return }
    let ownership = document.ownershipGeneration
    let manager = document.undoManager
    for pane in document.panePool where pane.isAttached {
      guard approvedInstallMemberCurrent(document, pane: pane, storage: storage, lease: lease)
      else { continue }
      let view = pane.editor
      let recorder = nativeMacroApprovedRouteRecorderFence()
      let retirement = approvedRouteRetirementSerial
      let generation = approvedRouteSerial
      let prior = approvedRoutes[ObjectIdentifier(view)]
      let revision = document.editRevision
      let mutation = document.closeMutationGeneration
      let panes = document.panePool.filter(\.isAttached).map(\.id)
      var actualWindow: NSWindow?
      let native = withMacroCallbackBarrier {
        actualWindow = window
        return actualWindow != nil && view.window === actualWindow
          && view.textStorage === storage && view.documentUndo === manager
      }
      guard native, let actualWindow,
        approvedInstallMemberCurrent(document, pane: pane, storage: storage, lease: lease),
        !windowClosed, !preparingToQuit,
        !approvedRouteRetirementExhausted, approvedRouteRetirementSerial == retirement,
        !approvedRouteSerialExhausted, approvedRouteSerial == generation,
        nativeMacroApprovedRouteRecorderFence() == recorder,
        approvedRoutes[ObjectIdentifier(view)] === prior,
        document.editRevision == revision, document.closeMutationGeneration == mutation,
        document.ownershipGeneration == ownership,
        document.storage === storage, document.undoManager === manager,
        document.panePool.filter(\.isAttached).map(\.id) == panes,
        macroBindings[ObjectIdentifier(storage)] == lease,
        storage.nativeMacroHasBinding(self, lease: lease),
        documents.contains(where: { $0 === document }), pane.document === document,
        pane.isAttached, lease.paneIDs.contains(pane.id),
        projectionToken == nil, transferProjection == nil, settledTransferProjection == nil
      else { continue }
      if let old = prior, old.value.lease == lease, old.window === actualWindow,
        old.pane === pane, old.storage === storage, old.manager === manager
      {
        // Equality alone does not prove that both native weak owners remain installed.
        // Reassign the same authenticated association using pure stored-field setters.
        guard approvedInstallMemberCurrent(document, pane: pane, storage: storage, lease: lease),
          !approvedRouteRetirementExhausted,
          approvedRouteRetirementSerial == retirement,
          !approvedRouteSerialExhausted, approvedRouteSerial == generation,
          nativeMacroApprovedRouteRecorderFence() == recorder,
          approvedRoutes[ObjectIdentifier(view)] === old,
          macroBindings[ObjectIdentifier(storage)] == lease,
          storage.nativeMacroHasBinding(self, lease: lease)
        else { continue }
        view.installApprovedViewOwner(
          self, storage: storage, window: actualWindow, route: old.value)
        manager.installApprovedHistoryOwner(self, association: old.value)
        continue
      }
      let (next, overflow) = approvedRouteSerial.addingReportingOverflow(1)
      guard !overflow else {
        approvedRouteSerialExhausted = true
        retireAllApprovedRoutes()
        return
      }
      approvedRouteSerial = next
      let value = ApprovedViewRoute(
        lease: lease, viewID: ObjectIdentifier(view),
        paneID: pane.id, windowID: ObjectIdentifier(actualWindow),
        managerID: ObjectIdentifier(manager), generation: next)
      // Deliberate removal by this attempt is pure. Capture the owned baseline
      // afterwards, so it cannot invalidate its own final retirement fence.
      if approvedRoutes[value.viewID] != nil { nativeApprovedViewRetire(view) }
      let ownedRetirement = approvedRouteRetirementSerial
      let association = ApprovedRouteAssociation(
        value: value, document: document,
        pane: pane, storage: storage, window: actualWindow, manager: manager)
      guard approvedInstallMemberCurrent(document, pane: pane, storage: storage, lease: lease),
        approvedRoutes.count < 64, approvedRoutes[value.viewID] == nil,
        !approvedRouteRetirementExhausted, approvedRouteRetirementSerial == ownedRetirement,
        nativeMacroApprovedRouteRecorderFence() == recorder,
        macroBindings[ObjectIdentifier(storage)] == lease,
        storage.nativeMacroHasBinding(self, lease: lease),
        document.ownershipGeneration == ownership, document.editRevision == revision,
        document.closeMutationGeneration == mutation,
        !windowClosed, !preparingToQuit, projectionToken == nil,
        transferProjection == nil, settledTransferProjection == nil
      else { continue }
      approvedRoutes[value.viewID] = association
      view.installApprovedViewOwner(self, storage: storage, window: actualWindow, route: value)
      manager.installApprovedHistoryOwner(self, association: value)
    }
  }

  // Callback-bearing terminal route phase. The consumed suspension commit has
  // already returned and the process has recorded its finished flag.
  func nativeMacroCompleteTerminalApprovedRoutes(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws {
    let recorder = nativeMacroApprovedRouteRecorderFence()
    guard nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID)
    else { throw ApplicationDocumentTransferError.pendingLayout }
    for document in documents {
      guard nativeMacroApprovedRouteRecorderFence() == recorder,
        nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID),
        let lease = refreshMacroBinding(document)
      else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      guard nativeMacroApprovedRouteRecorderFence() == recorder,
        nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID),
        macroBindings[ObjectIdentifier(document.storage)] == lease
      else {
        throw ApplicationDocumentTransferError.pendingLayout
      }
      // Layout attachment survives tab changes; only the current document is displayed.
      guard document === current else { continue }
      for pane in document.panePool where pane.isAttached {
        guard let association = approvedRoutes[ObjectIdentifier(pane.editor)],
          association.value.lease == lease, association.pane === pane,
          approvedStoredRoute(association)
        else {
          throw ApplicationDocumentTransferError.pendingLayout
        }
        let retirement = approvedRouteRetirementSerial
        let generation = approvedRouteSerial
        let native = withMacroCallbackBarrier { approvedNativeRoute(association) }
        guard native, !approvedRouteRetirementExhausted,
          approvedRouteRetirementSerial == retirement,
          !approvedRouteSerialExhausted, approvedRouteSerial == generation,
          nativeMacroApprovedRouteRecorderFence() == recorder,
          nativeMacroTerminalProjectionMatches(
            expected, revision: revision, endpointID: endpointID),
          approvedRoutes[ObjectIdentifier(pane.editor)] === association,
          approvedStoredRoute(association)
        else {
          throw ApplicationDocumentTransferError.pendingLayout
        }
      }
    }
    guard nativeMacroApprovedRouteRecorderFence() == recorder,
      nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID)
    else { throw ApplicationDocumentTransferError.pendingLayout }
  }

  private func approvedRecorder(_ route: ApprovedViewRoute) -> ApprovedRecorderState? {
    guard let identity = macroIdentity(route.lease, paneID: route.paneID),
      let integrity = recordingIntegrity
    else { return nil }
    let phase: UInt8
    switch compatibilitySetterPhase {
    case .none: phase = 0
    case .identityNil: phase = 1
    case .identityNonNil: phase = 2
    case .commandsAfterNil: phase = 3
    case .commandsAfterNonNil: phase = 4
    }
    return ApprovedRecorderState(
      identity: identity, active: integrity.active,
      firstReason: integrity.firstReason, compatibilityPhase: phase, saving: macroSaving,
      saveAttempt: recordingSaveAttempt?.id, commands: recordedCommands, units: recordedUnits)
  }

  private func approvedSnapshot(_ association: ApprovedRouteAssociation) -> ApprovedViewSnapshot? {
    guard approvedStoredRoute(association), let document = association.document,
      let storage = association.storage, let recorder = approvedRecorder(association.value)
    else { return nil }
    return ApprovedViewSnapshot(
      route: association.value, recorder: recorder,
      primitive: storage.nativeMacroPrimitiveState, revision: document.editRevision,
      closeMutation: document.closeMutationGeneration, bookmarks: document.bookmarks,
      pending: document.pendingBookmarks, pendingUndo: document.pendingBookmarksHaveUndo)
  }

  func nativeApprovedHistoryBegin(
    _ manager: GuardedDocumentUndoManager,
    association expected: ApprovedViewRoute, action: ApprovedHistoryAction
  ) -> ApprovedHistoryInvocation? {
    guard let association = approvedRoutes[expected.viewID],
      association.value == expected, association.manager === manager,
      approvedStoredRoute(association)
    else { return nil }
    let native = withMacroCallbackBarrier { approvedNativeRoute(association) }
    guard native, approvedStoredRoute(association) else { return nil }
    return Self.approvedViewBroker.beginHistory(
      owner: ObjectIdentifier(self),
      manager: ObjectIdentifier(manager), association: expected, action: action,
      contextCount: Self.approvedContextCount, contextAvailable: Self.approvedContextAvailable)
  }

  func nativeApprovedHistoryFinish(_ invocation: ApprovedHistoryInvocation?) {
    if let invocation { Self.approvedViewBroker.finishHistory(invocation) }
  }

  func nativeApprovedDecisionBegin(
    _ view: DocumentTextView, range: NSRange?,
    replacement: String?, singular: Bool
  ) -> ApprovedDecisionCapture? {
    guard nativeEditPreparation == nil, Self.macroCommitContext?.hasActiveExplicitFrame == false,
      let association = approvedRoutes[ObjectIdentifier(view)],
      approvedStoredRoute(association),
      Self.approvedViewBroker.historyMatches(association.value)
    else { return nil }
    var prepared: MacroPreparedReplacement?
    let before = approvedSnapshot(association)
    let native = withMacroCallbackBarrier {
      guard approvedNativeRoute(association), let storage = association.storage else {
        return false
      }
      if singular, let range, let replacement, range.length <= 4096,
        replacement.utf16.count <= 4096
      {
        prepared = storage.prepareApprovedCharacters(in: range, with: replacement)
      }
      return true
    }
    let after = approvedSnapshot(association)
    guard native, let before, after == before,
      !before.primitive.exhausted, !before.primitive.backingReentry
    else { return nil }
    return Self.approvedViewBroker.beginDecision(
      view: ObjectIdentifier(view),
      snapshot: before, range: range, replacement: replacement,
      before: prepared?.beforeUTF16Count,
      replacementCount: prepared?.replacementUTF16Count, singular: singular,
      contextCount: Self.approvedContextCount, contextAvailable: Self.approvedContextAvailable)
  }

  static func withApprovedViewDecisionBarrier<Value>(
    _ decision: ApprovedDecisionCapture?,
    _ body: () throws -> Value
  ) rethrows -> Value {
    let barrier = approvedViewBroker.beginBarrier(
      decision: decision,
      contextCount: approvedContextCount, contextAvailable: approvedContextAvailable)
    defer { approvedViewBroker.finishBarrier(barrier) }
    if let context = macroCommitContext {
      if barrier == nil { return try context.withRejectedCallbackBarrier(body) }
      return try context.withCallbackBarrier(body)
    }
    return try body()
  }

  func nativeApprovedDecisionFinish(
    _ view: DocumentTextView,
    decision: ApprovedDecisionCapture?, result: Bool
  ) {
    guard let decision else { return }
    guard let association = approvedRoutes[ObjectIdentifier(view)] else {
      Self.approvedViewBroker.cancelDecision(decision)
      return
    }
    let native = withMacroCallbackBarrier { approvedNativeRoute(association) }
    Self.approvedViewBroker.finishDecision(
      decision, result: result,
      actual: native ? approvedSnapshot(association) : nil,
      contextCount: Self.approvedContextCount, contextAvailable: Self.approvedContextAvailable)
  }

  static func nativeApprovedDecisionCancel(_ decision: ApprovedDecisionCapture?) {
    if let decision { approvedViewBroker.cancelDecision(decision) }
  }

  private func approvedBookkeepingBefore(
    _ view: NSTextView, range: NSRange,
    replacement: String?, edge: ApprovedBookkeepingEdge
  )
    -> (ApprovedDecisionCapture?, ApprovedViewSnapshot?)
  {
    guard let replacement, let association = approvedRoutes[ObjectIdentifier(view)],
      let snapshot = approvedSnapshot(association)
    else { return (nil, nil) }
    return (
      Self.approvedViewBroker.beginBookkeeping(
        view: ObjectIdentifier(view),
        range: range, replacement: replacement, edge: edge, actual: snapshot), snapshot
    )
  }

  private func approvedBookkeepingAfter(
    _ view: NSTextView,
    edge: ApprovedBookkeepingEdge,
    before: (ApprovedDecisionCapture?, ApprovedViewSnapshot?)
  ) {
    let after = approvedRoutes[ObjectIdentifier(view)].flatMap { approvedSnapshot($0) }
    Self.approvedViewBroker.finishBookkeeping(before.0, edge: edge, before: before.1, after: after)
  }

  func nativeApprovedReserve(
    storageID: ObjectIdentifier, range: NSRange,
    replacement: String, before: Int, changed: Bool
  ) -> ApprovedViewReservation? {
    let route = Self.approvedViewBroker.pendingRoute(storage: storageID)
    let snapshot = route.flatMap { value in
      approvedRoutes[value.viewID].flatMap { approvedSnapshot($0) }
    }
    return Self.approvedViewBroker.reserve(
      range: range, replacement: replacement,
      before: before, changed: changed, actual: snapshot,
      contextCount: Self.approvedContextCount, contextAvailable: Self.approvedContextAvailable)
  }

  func nativeApprovedAttributes(storageID: ObjectIdentifier) {
    Self.approvedViewBroker.burnPending(owner: ObjectIdentifier(self), storage: storageID)
  }

  private func consumeApprovedView(
    _ reservation: ApprovedViewReservation,
    observation: PrimitiveCommitObservation
  ) -> Bool {
    // Post-backing sink reads C's stored values only. No native/model callout.
    defer { Self.approvedViewBroker.discardReservation(reservation) }
    let route = Self.approvedViewBroker.reservationRoute(reservation)
    guard !windowClosed, !preparingToQuit, projectionToken == nil,
      transferProjection == nil, settledTransferProjection == nil,
      let state = approvedRecorder(route),
      state.firstReason == nil, !state.saving, state.saveAttempt == nil,
      state.compatibilityPhase == 0, !state.identity.recorderStateSerialExhausted,
      recordingStateSerial <= UInt64.max - 2,
      recordedCommands.count < 10_000, recordedUnits >= 0, recordedUnits <= 10_000_000,
      reservation.unitCost <= 10_000_000 - recordedUnits,
      let command = Self.approvedViewBroker.consume(
        reservation, recorder: state,
        currentLease: macroBindings[reservation.lease.storageID], observation: observation,
        contextCount: Self.approvedContextCount, contextAvailable: Self.approvedContextAvailable)
    else {
      markRecordingGap(reservation.epoch, reason: .unsupportedCharacterMutation, activeOnly: true)
      return false
    }
    withOwnedRecorderMutation {
      recordedCommands.append(command)
      recordedUnits += reservation.unitCost
    }
    return true
  }
  // APPROVED-VIEW-BROKER-END

  // TASK2A-SCALAR-ADAPTER-BEGIN
  private static let macroCommitContext = NativeMacroCommitContext()
  private static var macroBindingSerial: UInt64 = 0
  private var macroBindings: [ObjectIdentifier: MacroBindingLease] = [:]
  private var recordingIntegrity: MacroRecordingIntegrity?
  private var recordingStateSerial: UInt64 = 0
  private var recordingStateSerialExhausted = false
  private var recordingSaveAttempt: MacroRecordingSaveAttempt?
  private var recorderOwnedMutationDepth = 0
  private var compatibilitySetterPhase: MacroCompatibilityPhase = .none

  // Shared lexical processing barrier also covers unbound storage dispatch.
  // No callback is retained; missing context still executes the native body once.
  static func withNativeMacroProcessingBarrier<Value>(
    _ body: () throws -> Value
  ) rethrows -> Value {
    let barrier = approvedViewBroker.beginBarrier(
      contextCount: approvedContextCount,
      contextAvailable: approvedContextAvailable)
    defer { approvedViewBroker.finishBarrier(barrier) }
    if let context = macroCommitContext {
      if barrier == nil { return try context.withRejectedCallbackBarrier(body) }
      return try context.withCallbackBarrier(body)
    }
    return try body()
  }

  private func withMacroCallbackBarrier<Value>(_ body: () throws -> Value) rethrows -> Value {
    let barrier = Self.approvedViewBroker.beginBarrier(
      contextCount: Self.approvedContextCount,
      contextAvailable: Self.approvedContextAvailable)
    defer { Self.approvedViewBroker.finishBarrier(barrier) }
    if let context = Self.macroCommitContext {
      if barrier == nil { return try context.withRejectedCallbackBarrier(body) }
      return try context.withCallbackBarrier(body)
    }
    return try body()
  }

  private func withOwnedRecorderMutation(_ body: () -> Void) {
    let incoming = recorderOwnedMutationDepth
    recorderOwnedMutationDepth = incoming < 64 ? incoming + 1 : 64
    defer { recorderOwnedMutationDepth = incoming }
    body()
  }

  private func markRecordingGap(_ epoch: UUID?, reason: MacroRecordingGap, activeOnly: Bool = false)
  {
    guard let epoch, var value = recordingIntegrity, value.epoch == epoch,
      !activeOnly || value.active
    else { return }
    if value.firstReason == nil { value.firstReason = reason }
    value.noticePending = true
    recordingIntegrity = value
  }

  private func advanceRecordingSerial() {
    let (next, overflow) = recordingStateSerial.addingReportingOverflow(1)
    if overflow {
      recordingStateSerialExhausted = true
      markRecordingGap(recordingIntegrity?.epoch, reason: .recorderStateSerialExhausted)
    } else {
      recordingStateSerial = next
    }
  }

  private func beginRecordingIntegrity(_ id: UUID) {
    recordingSaveAttempt = nil
    macroSaving = false
    compatibilitySetterPhase = .none
    recordingStateSerial = 0
    recordingStateSerialExhausted = false
    recordingIntegrity = MacroRecordingIntegrity(epoch: UUID(), documentID: id, active: true)
    if Self.macroCommitContext == nil {
      markRecordingGap(recordingIntegrity?.epoch, reason: .contextUnavailable, activeOnly: true)
    }
  }

  private func recorderIdentityWritten() {
    if recorderOwnedMutationDepth == 0 {
      recordingSaveAttempt = nil
      macroSaving = false
      if let id = recordingDocumentID {
        beginRecordingIntegrity(id)
        compatibilitySetterPhase = .identityNonNil
      } else {
        if var value = recordingIntegrity {
          value.active = false
          recordingIntegrity = value
        }
        compatibilitySetterPhase = .identityNil
      }
    }
    advanceRecordingSerial()
  }

  private func recorderCommandsWritten() {
    if recorderOwnedMutationDepth == 0 {
      switch compatibilitySetterPhase {
      case .identityNil: compatibilitySetterPhase = .commandsAfterNil
      case .identityNonNil: compatibilitySetterPhase = .commandsAfterNonNil
      default:
        compatibilitySetterPhase = .none
        markRecordingGap(recordingIntegrity?.epoch, reason: .externalRecorderWrite)
      }
    }
    advanceRecordingSerial()
  }

  private func recorderUnitsWritten() {
    if recorderOwnedMutationDepth == 0 {
      let phase = compatibilitySetterPhase
      compatibilitySetterPhase = .none
      switch phase {
      case .commandsAfterNil:
        if recordingDocumentID == nil && recordedCommands.isEmpty && recordedUnits == 0 {
          recordingIntegrity = nil
          recordingSaveAttempt = nil
          macroSaving = false
        }
      case .commandsAfterNonNil: break
      default: markRecordingGap(recordingIntegrity?.epoch, reason: .externalRecorderWrite)
      }
    }
    advanceRecordingSerial()
  }

  private func stopRecordingIntegrity() {
    compatibilitySetterPhase = .none
    if var value = recordingIntegrity {
      value.active = false
      recordingIntegrity = value
    }
    withOwnedRecorderMutation { recordingDocumentID = nil }
  }

  private var unresolvedRecording: Bool { recordingIntegrity?.firstReason != nil }

  private func retireMacroBinding(_ document: EditorDocument) {
    retireControlledStringRouting(document)
    let key = ObjectIdentifier(document.storage)
    guard let lease = macroBindings.removeValue(forKey: key) else { return }
    if recordingIntegrity?.documentID == lease.documentID {
      markRecordingGap(recordingIntegrity?.epoch, reason: .explicitCommitRefused, activeOnly: true)
    }
    (document.storage as? DocumentCommitTextStorage)?.unbindMacroOwner(self, lease: lease)
  }

  func nativeMacroRetireBinding(_ lease: MacroBindingLease) {
    guard macroBindings[lease.storageID] == lease else { return }
    for document in documents where ObjectIdentifier(document.storage) == lease.storageID {
      retireControlledStringRouting(document)
    }
    macroBindings.removeValue(forKey: lease.storageID)
    if recordingIntegrity?.documentID == lease.documentID {
      markRecordingGap(recordingIntegrity?.epoch, reason: .explicitCommitRefused, activeOnly: true)
    }
  }

  private func reconcileMacroMembership(_ old: [EditorDocument]) {
    for document in old where !documents.contains(where: { $0 === document }) {
      retireMacroBinding(document)
    }
    for document in documents { _ = refreshMacroBinding(document) }
  }

  private func refreshMacroBinding(_ document: EditorDocument) -> MacroBindingLease? {
    guard !windowClosed, !preparingToQuit, projectionToken == nil,
      transferProjection == nil, settledTransferProjection == nil,
      documents.contains(where: { $0 === document }),
      let storage = document.storage as? DocumentCommitTextStorage
    else {
      retireMacroBinding(document)
      return nil
    }
    if let routing = applicationRouting {
      guard projectionValid, routing.registry.handle(id: document.id) === document,
        routing.registry.assignment(of: document.id) == routing.assignment,
        routing.registry.closeStatus(documentID: document.id) == .open,
        routing.registry.adoptionStatus(documentID: document.id)?.blocksAdmission == false
      else {
        retireMacroBinding(document)
        return nil
      }
    }
    guard !storage.nativeMacroBindingIsSuspended else { return nil }
    let key = ObjectIdentifier(storage)
    let panes = document.panePool.filter(\.isAttached).map(\.id)
    if var existing = macroBindings[key],
      existing.documentObjectID == ObjectIdentifier(document),
      existing.ownershipGeneration == document.ownershipGeneration,
      existing.endpointID == applicationRouting?.endpointID,
      existing.assignment == applicationRouting?.assignment
    {
      existing.paneIDs = panes
      guard storage.bindMacroOwner(self, lease: existing) else { return nil }
      macroBindings[key] = existing
      installControlledStringRouting(document)
      installApprovedViewRouting(document)
      return existing
    }
    retireMacroBinding(document)
    let (serial, overflow) = Self.macroBindingSerial.addingReportingOverflow(1)
    guard !overflow else { return nil }
    Self.macroBindingSerial = serial
    let lease = MacroBindingLease(
      controllerID: ObjectIdentifier(self),
      documentObjectID: ObjectIdentifier(document), documentID: document.id,
      storageID: key, ownershipGeneration: document.ownershipGeneration,
      endpointID: applicationRouting?.endpointID, assignment: applicationRouting?.assignment,
      serial: serial, paneIDs: panes)
    guard storage.bindMacroOwner(self, lease: lease) else { return nil }
    macroBindings[key] = lease
    installControlledStringRouting(document)
    installApprovedViewRouting(document)
    return lease
  }

  // TASK2B-TERMINAL-BINDING-BEGIN
  // Callback-free final projection predicate; native endpoint/admission callbacks
  // must finish before both peer predicates and the final release are evaluated.
  func nativeMacroTerminalProjectionMatches(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) -> Bool {
    guard let routing = applicationRouting, !windowClosed, !preparingToQuit,
      projectionToken == nil, transferProjection == nil, settledTransferProjection == nil,
      projectionValid, routing.endpointID == endpointID,
      routing.assignment.windowID == sessionID, expected.id == sessionID,
      routing.registry.workspaceRevision == revision,
      routing.registry.window(id: sessionID) == expected, expected.groups.count == 1,
      expected.groups[0].id == routing.assignment.groupID,
      expected.focusedGroupID == expected.groups[0].id,
      expected.groups[0].documentIDs == documents.map(\.id),
      selectedID == expected.groups[0].selectedDocumentID,
      host.displayedIDs == (current?.panePool.filter(\.isAttached).map(\.id) ?? [])
    else { return false }
    return documents.allSatisfy { document in
      routing.registry.handle(id: document.id) === document
        && routing.registry.assignment(of: document.id) == routing.assignment
        && routing.registry.closeStatus(documentID: document.id) == .open
        && routing.registry.adoptionStatus(documentID: document.id) == .active
        && routing.registry.metadata(id: document.id)?.pinned == document.pinned
    }
  }

  func nativeMacroRepairTerminalBindings(excluding token: MacroTransferSuspension) -> Bool {
    for document in documents where ObjectIdentifier(document.storage) != token.storageID {
      guard refreshMacroBinding(document) != nil else { return false }
    }
    return true
  }

  func nativeMacroFinishTransferBinding(
    _ token: MacroTransferSuspension, document: EditorDocument,
    expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws {
    guard
      nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID),
      document.id == token.documentID, ObjectIdentifier(document) == token.documentObjectID,
      documents.contains(where: { $0 === document }),
      let storage = document.storage as? DocumentCommitTextStorage,
      ObjectIdentifier(storage) == token.storageID, storage.canFinishMacroBinding(token),
      macroBindings[token.storageID] == nil, let routing = applicationRouting
    else { throw ApplicationDocumentTransferError.pendingLayout }
    let (serial, overflow) = Self.macroBindingSerial.addingReportingOverflow(1)
    guard !overflow else { throw ApplicationDocumentTransferError.pendingLayout }
    let lease = MacroBindingLease(
      controllerID: ObjectIdentifier(self),
      documentObjectID: token.documentObjectID, documentID: document.id,
      storageID: token.storageID, ownershipGeneration: document.ownershipGeneration,
      endpointID: endpointID, assignment: routing.assignment, serial: serial,
      paneIDs: document.panePool.filter(\.isAttached).map(\.id))
    guard storage.finishMacroBinding(token, owner: self, lease: lease) else {
      throw ApplicationDocumentTransferError.pendingLayout
    }
    // No callback, await or throwing operation follows the storage commit.
    macroBindings[token.storageID] = lease
    Self.macroBindingSerial = serial
    installControlledStringRouting(document)
  }

  private func nativeMacroStartBindingAvailable(_ document: EditorDocument) -> Bool {
    guard Self.macroCommitContext != nil, !windowClosed, !preparingToQuit,
      projectionToken == nil, transferProjection == nil, settledTransferProjection == nil,
      documents.contains(where: { $0 === document }),
      let storage = document.storage as? DocumentCommitTextStorage,
      !storage.nativeMacroBindingIsSuspended,
      let lease = macroBindings[ObjectIdentifier(storage)],
      lease.controllerID == ObjectIdentifier(self),
      lease.documentObjectID == ObjectIdentifier(document), lease.documentID == document.id,
      lease.storageID == ObjectIdentifier(storage),
      lease.ownershipGeneration == document.ownershipGeneration,
      lease.endpointID == applicationRouting?.endpointID,
      lease.assignment == applicationRouting?.assignment,
      lease.paneIDs == document.panePool.filter(\.isAttached).map(\.id),
      storage.nativeMacroHasBinding(self, lease: lease)
    else { return false }
    if let routing = applicationRouting {
      guard let expected = routing.registry.window(id: sessionID) else { return false }
      return nativeMacroTerminalProjectionMatches(
        expected,
        revision: routing.registry.workspaceRevision, endpointID: routing.endpointID)
    }
    return true
  }
  // TASK2B-TERMINAL-BINDING-END

  func nativeMacroCapture(_ lease: MacroBindingLease) -> MacroPrimitiveCapture? {
    guard !windowClosed, macroBindings[lease.storageID] == lease else { return nil }
    let epoch = recordingIntegrity.flatMap {
      $0.active && $0.documentID == lease.documentID && recordingDocumentID == lease.documentID
        ? $0.epoch : nil
    }
    return MacroPrimitiveCapture(lease: lease, epoch: epoch)
  }

  private func macroIdentity(_ lease: MacroBindingLease, paneID: UUID) -> MacroContextIdentity? {
    guard let value = recordingIntegrity, value.active,
      value.documentID == lease.documentID, recordingDocumentID == lease.documentID,
      lease.paneIDs.contains(paneID)
    else { return nil }
    return MacroContextIdentity(
      documentID: lease.documentID, paneID: paneID,
      storageID: lease.storageID, ownershipGeneration: lease.ownershipGeneration,
      recordingEpoch: value.epoch, recorderStateSerial: recordingStateSerial,
      recorderStateSerialExhausted: recordingStateSerialExhausted)
  }

  private func explicitMacroSeed(
    _ document: EditorDocument, pane: EditorPane,
    expected: NSString, range: NSRange, replacement: String
  ) -> MacroExplicitSeed? {
    guard let lease = refreshMacroBinding(document),
      let identity = macroIdentity(lease, paneID: pane.id),
      let storage = document.storage as? DocumentCommitTextStorage
    else { return nil }
    let count = replacement.utf16.count
    let replacementUnits = replacement as NSString
    let noOp =
      range.length == count
      && (0..<count).allSatisfy {
        expected.character(at: range.location + $0) == replacementUnits.character(at: $0)
      }
    let preparedReplacement = storage.prepareExplicitCharacters(in: range, with: replacement)
    guard preparedReplacement.beforeUTF16Count == expected.length,
      preparedReplacement.replacementUTF16Count == count,
      preparedReplacement.changedCharacters == !noOp
    else { return nil }
    let contract = MacroContextPrimitiveContract(
      kind: noOp ? .explicitAcceptedNoOp : .changedCharacters, range: range,
      beforeUTF16Count: expected.length, replacementUTF16Count: count)
    return MacroExplicitSeed(
      lease: lease, identity: identity,
      primitive: preparedReplacement.primitive, contract: contract,
      commands: recordedCommands, units: recordedUnits,
      command: .replace(location: range.location, length: range.length, text: replacement),
      preparedReplacement: preparedReplacement)
  }

  private func explicitMacroFactsValid(
    _ seed: MacroExplicitSeed,
    storage: DocumentCommitTextStorage
  ) -> Bool {
    !windowClosed && macroBindings[seed.lease.storageID] == seed.lease
      && macroIdentity(seed.lease, paneID: seed.identity.paneID) == seed.identity
      && recordedCommands == seed.commands && recordedUnits == seed.units
      && !storage.nativeMacroBindingIsSuspended
      && storage.nativeMacroHasBinding(self, lease: seed.lease)
      && storage.nativeMacroPrimitiveState == seed.primitive
      && !recordingStateSerialExhausted && recordingStateSerial <= UInt64.max - 2
      && recordedUnits >= 0 && recordedUnits <= 10_000_000
      && seed.contract.replacementUTF16Count <= 10_000_000 - recordedUnits
      && recordedCommands.count < 10_000
  }

  func nativeMacroPublish(
    _ capture: MacroPrimitiveCapture?, delivery: MacroExplicitDelivery?,
    observation: PrimitiveCommitObservation, approved: ApprovedViewReservation? = nil
  ) {
    // Pure local/value sink: no model/storage/registry/undo/UI/callback access.
    if let delivery {
      let seed = delivery.seed
      guard let context = Self.macroCommitContext,
        !windowClosed, macroBindings[seed.lease.storageID] == seed.lease,
        macroIdentity(seed.lease, paneID: seed.identity.paneID) == seed.identity,
        recordedCommands == seed.commands, recordedUnits == seed.units,
        !recordingStateSerialExhausted, recordingStateSerial <= UInt64.max - 2,
        recordedCommands.count < 10_000, recordedUnits >= 0, recordedUnits <= 10_000_000,
        seed.contract.replacementUTF16Count <= 10_000_000 - recordedUnits
      else {
        markRecordingGap(
          seed.identity.recordingEpoch, reason: .explicitCommitRefused, activeOnly: true)
        return
      }
      let completion = MacroContextPrimitiveCompletion(
        kind: observation.kind == .characters ? .characters : .attributes,
        range: observation.range, beforeUTF16Count: observation.beforeUTF16Count,
        afterUTF16Count: observation.afterUTF16Count,
        replacementUTF16Count: observation.replacementUTF16Count,
        changedCharacters: observation.changedCharacters,
        state: MacroContextPrimitiveState(
          sequence: observation.sequence,
          exhausted: observation.sequenceExhausted, backingReentry: observation.backingReentry))
      guard
        context.consumeExplicitPermit(
          delivery.permit, identity: seed.identity,
          completion: completion)
      else {
        markRecordingGap(
          seed.identity.recordingEpoch, reason: .explicitCommitRefused, activeOnly: true)
        return
      }
      withOwnedRecorderMutation {
        recordedCommands.append(seed.command)
        recordedUnits += seed.contract.replacementUTF16Count
      }
    } else if let approved, consumeApprovedView(approved, observation: observation) {
      // Exact approved character replacement was appended by the pure sink once.
    } else if let capture {
      if observation.sequenceExhausted {
        markRecordingGap(capture.epoch, reason: .primitiveSequenceExhausted, activeOnly: true)
      } else if observation.kind == .characters && observation.changedCharacters {
        markRecordingGap(capture.epoch, reason: .unsupportedCharacterMutation, activeOnly: true)
      }
    }
  }

  private func recordingSaveStillCurrent(_ attempt: MacroRecordingSaveAttempt) -> Bool {
    guard let value = recordingIntegrity else { return false }
    return macroSaving && recordingSaveAttempt?.id == attempt.id && value.epoch == attempt.epoch
      && value.documentID == attempt.documentID && !value.active && value.firstReason == nil
      && recordingDocumentID == nil && !recordingStateSerialExhausted
      && recordingStateSerial == attempt.serial && recordedCommands == attempt.commands
      && recordedUnits == attempt.units
  }
  // TASK2A-SCALAR-ADAPTER-END

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
    macroRecordingIncompleteStatus.setAccessibilityIdentifier("macro.recording.incomplete")
    macroRecordingIncompleteStatus.identifier = .init("macro.recording.incomplete")
    macroRecordingIncompleteStatus.setAccessibilityLabel("Incomplete macro recording")
    macroRecordingIncompleteStatus.setAccessibilityValue(macroRecordingIncompleteStatus.stringValue)
    macroRecordingIncompleteStatus.isHidden = true
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
      tabBar, tabs, languagePicker, diskStatusRow, workspaceSplit, status,
      macroRecordingIncompleteStatus, checkpointStatusRow, panePresentationRow,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    window.contentView = stack
    for view in [
      tabBar, tabs, languagePicker, workspaceSplit, status, checkpointStatusRow,
      macroRecordingIncompleteStatus,
    ] {
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
    var panes = [live]
    if presentation.panes.count == 2 {
      guard document.storage.length <= 2_000_000 else { throw EditorPaneError.limit }
      let second = try makeConfiguredPane(document)
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
    let focusTarget = panes[presentation.focusedPaneIndex]
    let focusAccepted =
      projectionToken != nil
      ? focusProjectedPane(focusTarget)
      : (window?.makeFirstResponder(focusTarget.editor) ?? false)
    try validateAuthority()
    guard focusAccepted, window?.firstResponder === focusTarget.editor else {
      throw PaneRoutingError.stale
    }
    state.warning = nil
    for (index, pane) in panes.enumerated() {
      if !DocumentPanePresentation.applyOrigin(presentation.panes[index].scrollOrigin, to: pane) {
        state.warning = "Saved scroll position could not be restored with the available layout."
      }
      try validateAuthority()
    }
    guard window?.firstResponder === focusTarget.editor else { throw PaneRoutingError.stale }
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
    onFailure: ((Error) -> Void)? = nil, onOpened: (() -> Void)? = nil,
    onOpenedDocument: ((EditorOpenedDocument) -> Void)? = nil
  ) {
    // Completion owns exactly one outcome, even when a window disappears during its read.
    var openedDocument: EditorDocument?
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
        let target = openedDocument.flatMap { self?.openedTarget($0) }
        self?.onOpenedURL?(url)
        onOpened?()
        if let target { onOpenedDocument?(target) }
      }
    }
    let succeed: (EditorDocument) -> Void = { document in
      openedDocument = document
      finish(nil, false)
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
          document: existing, encoding: encoding, shouldAccept: shouldAccept,
          onFailure: { finish($0, true) },
          onReload: {
            self.display(existing)
            succeed(existing)
          })
      } else {
        succeed(existing)
      }
      return
    }
    if applicationRouting != nil {
      openApplicationDocument(
        url, encoding: encoding, shouldAccept: shouldAccept, allowLargeViewer: onFailure == nil,
        hasPositionCompletion: onOpened != nil || onOpenedDocument != nil,
        finish: finish, succeed: succeed)
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
            if onOpened != nil || onOpenedDocument != nil {
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
              document: existing, encoding: encoding, shouldAccept: shouldAccept,
              onFailure: { finish($0, true) },
              onReload: {
                self.display(existing)
                succeed(existing)
              })
          } else {
            succeed(existing)
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
        succeed(document)
      }
    }
  }

  nonisolated private static func read(_ url: URL, encoding: DocumentEncoding? = nil) throws -> (
    Data, DecodedDocument
  ) {
    let bytes = try readBytes(url)
    return (bytes, try EditableDocumentDecoder.decode(bytes, encoding: encoding))
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
      guard let current, !current.saving, recordingDocumentID == nil, !macroSaving,
        recordingSaveAttempt == nil
      else { return }
      let integrity = recordingIntegrity
      let serial = recordingStateSerial
      let exhausted = recordingStateSerialExhausted
      let commands = recordedCommands
      let units = recordedUnits
      func factsStillCurrent() -> Bool {
        self.current === current && !current.saving && recordingDocumentID == nil
          && !macroSaving && recordingSaveAttempt == nil
          && recordingIntegrity?.epoch == integrity?.epoch
          && recordingIntegrity?.documentID == integrity?.documentID
          && recordingIntegrity?.active == integrity?.active
          && recordingIntegrity?.firstReason == integrity?.firstReason
          && recordingStateSerial == serial && recordingStateSerialExhausted == exhausted
          && recordedCommands == commands && recordedUnits == units
      }
      guard allowLeavingUnsavedRecording() else { return }
      if applicationRouting != nil {
        guard (try? requireApplicationEndpoint()) != nil else { return }
      }
      guard factsStillCurrent(), refreshMacroBinding(current) != nil,
        nativeMacroStartBindingAvailable(current), factsStillCurrent()
      else { return }
      beginRecordingIntegrity(current.id)
      withOwnedRecorderMutation {
        recordedCommands = []
        recordedUnits = 0
        recordingDocumentID = current.id
      }
      refresh()
    case "macro.stop": stopRecording()
    case "macro.discard":
      guard !macroSaving else { return }
      recordingIntegrity = nil
      recordingSaveAttempt = nil
      compatibilitySetterPhase = .none
      withOwnedRecorderMutation {
        recordingDocumentID = nil
        recordedCommands = []
        recordedUnits = 0
      }
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
      let panel = FolderSearchController(root: workspace.rootURL) { [weak self] request in
        guard let self, request.isCurrent, request.belongs(to: self.folderSearch) else { return }
        self.open(
          request.url,
          shouldAccept: { [weak self] in
            request.isCurrent && request.belongs(to: self?.folderSearch)
          },
          onOpenedDocument: { [weak self] target in
            guard let self, request.isCurrent, request.belongs(to: self.folderSearch) else {
              return
            }
            do {
              try self.activateSource(
                target.pane, snapshot: request.snapshot, range: request.range,
                opened: target, request: request)
            } catch { self.present(error) }
          })
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
        && !macroSaving && recordingSaveAttempt == nil && recordedCommands.isEmpty
        && !unresolvedRecording && current.map(nativeMacroStartBindingAvailable) == true
    case "macro.stop":
      return !macroSaving
        && (recordingDocumentID != nil || !recordedCommands.isEmpty || unresolvedRecording)
        && current?.saving == false
    case "macro.discard":
      return !macroSaving
        && (recordingDocumentID != nil || !recordedCommands.isEmpty || unresolvedRecording)
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
    document requestedDocument: EditorDocument? = nil, encoding: DocumentEncoding? = nil,
    shouldAccept: (() -> Bool)? = nil,
    onFailure: ((Error) -> Void)? = nil, onReload: (() -> Void)? = nil
  ) {
    let target = requestedDocument ?? current
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
    guard let document = target, let url = document.url, !document.saving,
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
    let sourceContext = context(for: source)
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
        action: "Convert Line Endings", context: sourceContext, requireFocus: false,
        operationID: operationID)
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

  // Tiny source-owned String insertion prototype; ordinary/native provenance stays separate.
  private func installControlledStringRouting(_ document: EditorDocument) {
    for pane in document.panePool {
      if pane.isAttached {
        pane.editor.installControlledStringOwner(self)
      } else {
        pane.editor.retireControlledStringOwner(self)
      }
    }
  }

  private func retireControlledStringRouting(_ document: EditorDocument) {
    nativeApprovedViewRetire(storageID: ObjectIdentifier(document.storage))
    for pane in document.panePool { pane.editor.retireControlledStringOwner(self) }
  }

  func controlledStringInsertion(
    _ editor: DocumentTextView, replacement: String
  ) -> ControlledStringInsertionResult {
    guard editor.controlledStringOwner === self,
      let source = pane(for: editor), source.isAttached, current === source.document,
      focusedPane === source, recordingDocumentID == source.document.id,
      recordingIntegrity?.active == true,
      recordingIntegrity?.documentID == source.document.id,
      !editor.isComposingText, !editor.hasMarkedText(),
      !source.document.undoManager.isUndoing, !source.document.undoManager.isRedoing,
      editor.selectedRanges.count == 1,
      editor.selectedRange().length == 0,
      !replacement.isEmpty, !replacement.utf16.contains(where: { $0 == 10 || $0 == 13 }),
      source.document.storage.length <= 4096, replacement.utf16.count <= 4096,
      let storage = source.document.storage as? DocumentCommitTextStorage
    else { return .unhandled }
    // A nested same-C invocation cannot escape an occupied explicit preparation.
    guard nativeEditPreparation == nil else { return .handledRefused }
    let document = source.document
    let selection = editor.selectedRange()
    let expected = storage.string
    let native = expected as NSString
    guard selection.location >= 0, selection.location <= native.length,
      selection.location == 0 || selection.location == native.length
        || !(0xDC00...0xDFFF).contains(native.character(at: selection.location))
    else { return .handledRefused }
    let seed = explicitMacroSeed(
      document, pane: source, expected: native,
      range: selection, replacement: replacement)
    let revision = document.editRevision
    let ownership = document.ownershipGeneration
    let mutation = document.closeMutationGeneration
    let initialLease = macroBindings[ObjectIdentifier(storage)]
    let hadBinding = initialLease.map { storage.nativeMacroHasBinding(self, lease: $0) } ?? false
    let endpoint = applicationRouting?.endpointID
    let assignment = applicationRouting?.assignment
    let panes = document.panePool.filter(\.isAttached).map(\.id)
    let primitive = storage.nativeMacroPrimitiveState
    @MainActor func editingStillValid() -> Bool {
      guard editor.controlledStringOwner === self, current === document, focusedPane === source,
        source.editor === editor, source.document === document, source.isAttached,
        editor.textStorage === storage, document.storage === storage,
        editor.selectedRange() == selection, editor.selectedRanges.count == 1,
        document.editRevision == revision, document.ownershipGeneration == ownership,
        document.closeMutationGeneration == mutation,
        applicationRouting?.endpointID == endpoint, applicationRouting?.assignment == assignment,
        document.panePool.filter(\.isAttached).map(\.id) == panes,
        macroBindings[ObjectIdentifier(storage)] == initialLease,
        nativeEditContextStillValid(
          document, source: source, context: nil,
          requireFocus: true, operationID: nil),
        storage.string.utf16.elementsEqual(expected.utf16)
      else { return false }
      if hadBinding, let initialLease {
        return storage.nativeMacroHasBinding(self, lease: initialLease)
      }
      return true
    }
    @MainActor func stillAdmitted() -> Bool {
      withMacroCallbackBarrier {
        applicationAllows(.select, document: document)
          && applicationAllows(.edit, document: document) && editingStillValid()
      }
    }
    let scope: MacroContextScope?
    if let seed, let context = Self.macroCommitContext,
      recordedCommands.count < 10_000, recordedUnits >= 0, recordedUnits <= 10_000_000,
      seed.contract.replacementUTF16Count <= 10_000_000 - recordedUnits
    {
      scope = Self.approvedViewBroker.beginExplicitScope(
        in: context, identity: seed.identity,
        primitive: seed.primitive, contract: seed.contract)
    } else {
      scope = nil
    }
    var scopeFinished = false
    @MainActor func finishScope() {
      guard !scopeFinished, let scope else { return }
      scopeFinished = true
      _ = Self.macroCommitContext?.finish(scope)
    }
    defer { finishScope() }
    guard stillAdmitted() else { return .handledRefused }
    // Own a lawful native group even when this entry had no caller-supplied group.
    withMacroCallbackBarrier { editor.documentUndo.beginUndoGrouping() }
    defer {
      finishScope()
      withMacroCallbackBarrier { editor.documentUndo.endUndoGrouping() }
    }
    guard stillAdmitted() else { return .handledRefused }
    withMacroCallbackBarrier { editor.breakUndoCoalescing() }
    guard stillAdmitted() else { return .handledRefused }
    let preparation = NativeEditPreparation(
      editor: editor, range: selection,
      replacement: replacement, mode: .interactive, validate: editingStillValid)
    preparation.controlledStringInsertion = true
    nativeEditPreparation = preparation
    defer { nativeEditPreparation = nil }
    guard
      withMacroCallbackBarrier({
        editor.shouldChangeText(in: selection, replacementString: replacement)
      }), stillAdmitted(), preparation.controlledFactsValid?() == true
    else { return .handledRefused }
    // Derive representation and authentic current capture before any issue/bookkeeping.
    let prepared = storage.prepareControlledCharacters(in: selection, with: replacement)
    guard editingStillValid(),
      prepared.replacement.beforeUTF16Count == native.length,
      preparation.controlledFactsValid?() == true
    else { return .handledRefused }
    let delivery: MacroExplicitDelivery?
    if let seed, let scope, let context = Self.macroCommitContext,
      explicitMacroFactsValid(seed, storage: storage),
      let capture = prepared.capture, capture.lease == seed.lease,
      capture.epoch == seed.identity.recordingEpoch,
      context.admitFinalDecision(
        scope, decision: .admitted(UUID()),
        identity: seed.identity, primitive: primitive),
      let permit = context.issueExplicitPermit(scope, identity: seed.identity, primitive: primitive)
    {
      delivery = MacroExplicitDelivery(seed: seed, permit: permit, capture: capture)
    } else {
      finishScope()
      delivery = nil
      // Missing owner/binding must not depend on a nonexistent storage sink.
      // Only the authentic current active interval of this exact editing document is marked.
      if let value = recordingIntegrity, value.active, value.documentID == document.id,
        recordingDocumentID == document.id
      {
        markRecordingGap(value.epoch, reason: .explicitCommitRefused, activeOnly: true)
      }
    }
    // Pure stored-value guard/metadata, then the sole shared actual backing entry.
    guard preparation.commit?() == true else { return .handledRefused }
    guard storage.replaceControlledCharacters(prepared, delivery: delivery) else {
      if let seed {
        markRecordingGap(
          seed.identity.recordingEpoch,
          reason: .explicitCommitRefused, activeOnly: true)
      }
      return .handledRefused
    }
    withMacroCallbackBarrier { editor.didChangeText() }
    withMacroCallbackBarrier { editor.documentUndo.setActionName("Typing") }
    // No later UI/recording refusal can repeat or roll back this committed native edit.
    return .handledCommitted
  }

  private func prepareControlledStringEdit(_ preparation: NativeEditPreparation) -> Bool {
    guard let source = pane(for: preparation.editor), mayMutate(source), preparation.validate()
    else { return false }
    let document = source.document
    var updated: DocumentBookmarks?
    if !document.bookmarks.offsets.isEmpty {
      do {
        var bookmarks = document.bookmarks
        try bookmarks.remap(
          through: TextEdit(
            range: preparation.range,
            replacement: preparation.replacement), inUTF16: document.storage.mutableString)
        updated = bookmarks
      } catch { return false }
    }
    let beforeBookmarks = document.bookmarks
    let beforePending = document.pendingBookmarks
    let beforePendingUndo = document.pendingBookmarksHaveUndo
    let beforeTyping = document.typingBookmarkNextLocation
    let beforeRevision = document.editRevision
    let beforeOwnership = document.ownershipGeneration
    let beforeMutation = document.closeMutationGeneration
    // Unlike strict explicit/search preparation, recorder identity/serial refusal does
    // not deny an otherwise admitted controlled ordinary edit.
    preparation.controlledFactsValid = { [weak document] in
      guard let document else { return false }
      return document.bookmarks == beforeBookmarks && document.pendingBookmarks == beforePending
        && document.pendingBookmarksHaveUndo == beforePendingUndo
        && document.typingBookmarkNextLocation == beforeTyping
        && document.editRevision == beforeRevision
        && document.ownershipGeneration == beforeOwnership
        && document.closeMutationGeneration == beforeMutation
    }
    preparation.commit = { [weak self, weak document, weak preparation] in
      guard let self, let document, let preparation,
        self.nativeEditPreparation === preparation,
        preparation.controlledFactsValid?() == true
      else { return false }
      document.pendingBookmarks = updated
      document.pendingBookmarksHaveUndo = false
      document.typingBookmarkNextLocation = nil
      return true
    }
    return true
  }

  /// Primitive checks only: callers run owner admission before this final fence.
  private func nativeEditContextStillValid(
    _ document: EditorDocument, source: EditorPane, context: PaneCommandContext?,
    requireFocus: Bool, operationID: UUID?, cancellation: MacroCancellation? = nil
  ) -> Bool {
    guard !document.saving, !preparingToQuit, !windowClosed,
      source.isAttached, source.document === document,
      document.panePresentation.installing == nil, document.composingPaneID == nil,
      documents.contains(where: { $0 === document }),
      document.panePool.contains(where: { $0 === source }),
      source.editor.textStorage === document.storage,
      !document.storage.editedMask.contains(.editedCharacters)
    else { return false }
    if let operationID, document.operationID != operationID { return false }
    if cancellation?.isCancelled == true { return false }
    if let context {
      guard context.documentID == document.id, context.paneID == source.id,
        context.editRevision == document.editRevision
      else { return false }
      if requireFocus {
        guard current === document, focusedPane === source,
          source.editor.selectedRange() == context.selection
        else { return false }
      }
    }
    return true
  }

  @discardableResult private func applyNativeTextEdit(
    _ document: EditorDocument, source: EditorPane, expected: String, edit: TextEdit,
    action: String, context: PaneCommandContext? = nil, requireFocus: Bool = true,
    operationID: UUID? = nil, cancellation: MacroCancellation? = nil
  ) -> Bool {
    applyNativeTextEdit(
      document, source: source, expected: expected, edit: edit, action: action,
      context: context, requireFocus: requireFocus, operationID: operationID,
      cancellation: cancellation, mode: .interactive)
  }

  @discardableResult private func applyNativeTextEdit(
    _ document: EditorDocument, source: EditorPane, expected: String, edit: TextEdit,
    action: String, context: PaneCommandContext?, requireFocus: Bool,
    operationID: UUID?, cancellation: MacroCancellation?, mode: NativeEditMode
  ) -> Bool {
    guard nativeEditPreparation == nil,
      documents.contains(where: { $0 === document }),
      !document.saving, !preparingToQuit, !windowClosed, source.isAttached,
      document.composingPaneID == nil,
      document.storage.string.utf16.elementsEqual(expected.utf16)
    else { return false }
    let range = edit.range
    let replacement = edit.replacement
    let native = expected as NSString
    guard range.location >= 0, range.length >= 0, range.location <= native.length,
      range.length <= native.length - range.location
    else { return false }
    func scalarBoundary(_ offset: Int) -> Bool {
      offset == 0 || offset == native.length
        || !(0xDC00...0xDFFF).contains(native.character(at: offset))
    }
    guard scalarBoundary(range.location), scalarBoundary(NSMaxRange(range)) else { return false }
    let editor = source.editor
    let revision = document.editRevision
    let ownership = document.ownershipGeneration
    let mutation = document.closeMutationGeneration
    @MainActor func snapshotStillValid() -> Bool {
      @MainActor func nativeSnapshot() -> Bool {
        self.nativeEditContextStillValid(
          document, source: source, context: context, requireFocus: requireFocus,
          operationID: operationID, cancellation: cancellation)
          && document.editRevision == revision && document.ownershipGeneration == ownership
          && document.closeMutationGeneration == mutation
          && document.storage.string.utf16.elementsEqual(expected.utf16)
      }
      guard nativeSnapshot() else { return false }
      switch mode {
      case .interactive:
        return true
      case .searchBorrow(let binding, let credential):
        guard let window = self.window, ObjectIdentifier(window) == binding.windowIdentity,
          (try? self.inspectDocumentSearchSource(
            document: document, pane: source, window: window, binding: binding)) == credential
        else { return false }
        // Inspection runs real owner callbacks; reread transaction-only facts afterward too.
        return nativeSnapshot()
      }
    }
    @MainActor func stillAdmitted() -> Bool {
      withMacroCallbackBarrier {
        (context == nil || self.applicationAllows(.select, document: document))
          && self.applicationAllows(.edit, document: document) && snapshotStillValid()
      }
    }
    let customStorage = document.storage as? DocumentCommitTextStorage
    let macroSeed: MacroExplicitSeed?
    let macroScope: MacroContextScope?
    if recordingDocumentID == document.id {
      guard recordedUnits >= 0, recordedUnits <= 10_000_000 else { return false }
      let fits =
        recordedCommands.count < 10_000
        && replacement.utf16.count <= 10_000_000 - recordedUnits
      if !fits {
        if case .searchBorrow = mode { return false }
        // Interactive capacity stop stays in the original delegate preflight.
        macroSeed = nil
        macroScope = nil
      } else {
        guard
          let seed = explicitMacroSeed(
            document, pane: source, expected: native,
            range: range, replacement: replacement), let context = Self.macroCommitContext,
          let scope = Self.approvedViewBroker.beginExplicitScope(
            in: context, identity: seed.identity,
            primitive: seed.primitive, contract: seed.contract)
        else {
          markRecordingGap(recordingIntegrity?.epoch, reason: .contextUnavailable, activeOnly: true)
          return false
        }
        macroSeed = seed
        macroScope = scope
      }
    } else {
      macroSeed = nil
      macroScope = nil
    }
    var macroScopeFinished = false
    @MainActor func finishMacroScope() {
      guard !macroScopeFinished, let scope = macroScope else { return }
      macroScopeFinished = true
      _ = Self.macroCommitContext?.finish(scope)
    }
    defer { finishMacroScope() }
    guard stillAdmitted() else { return false }
    withMacroCallbackBarrier { editor.breakUndoCoalescing() }
    guard stillAdmitted() else { return false }
    let preparation = NativeEditPreparation(
      editor: editor, range: range, replacement: replacement, mode: mode,
      validate: snapshotStillValid)
    self.nativeEditPreparation = preparation
    defer { self.nativeEditPreparation = nil }
    guard
      withMacroCallbackBarrier({
        editor.shouldChangeText(in: range, replacementString: replacement)
      }), stillAdmitted()
    else { return false }
    withMacroCallbackBarrier { editor.documentUndo.beginUndoGrouping() }
    guard stillAdmitted(), preparation.macroFactsValid?() ?? !preparation.delegateClaimed else {
      finishMacroScope()
      withMacroCallbackBarrier { editor.documentUndo.endUndoGrouping() }
      return false
    }
    let delivery: MacroExplicitDelivery?
    if let seed = macroSeed, let scope = macroScope {
      guard let storage = customStorage, explicitMacroFactsValid(seed, storage: storage),
        let capture = nativeMacroCapture(seed.lease), capture.epoch == seed.identity.recordingEpoch,
        let context = Self.macroCommitContext,
        context.admitFinalDecision(
          scope, decision: .admitted(UUID()),
          identity: seed.identity, primitive: storage.nativeMacroPrimitiveState),
        let permit = context.issueExplicitPermit(
          scope, identity: seed.identity,
          primitive: storage.nativeMacroPrimitiveState)
      else {
        finishMacroScope()
        withMacroCallbackBarrier { editor.documentUndo.endUndoGrouping() }
        return false
      }
      delivery = MacroExplicitDelivery(seed: seed, permit: permit, capture: capture)
    } else {
      delivery = nil
    }
    // After issuance: pure guarded prederived bookkeeping, then direct backing.
    guard preparation.commit?() ?? !preparation.delegateClaimed else {
      finishMacroScope()
      withMacroCallbackBarrier { editor.documentUndo.endUndoGrouping() }
      return false
    }
    if let storage = customStorage, let delivery {
      storage.replaceExplicitCharacters(delivery: delivery)
    } else {
      editor.textStorage?.replaceCharacters(in: range, with: replacement)
    }
    withMacroCallbackBarrier { editor.didChangeText() }
    withMacroCallbackBarrier { editor.documentUndo.endUndoGrouping() }
    withMacroCallbackBarrier { editor.documentUndo.setActionName(action) }
    return true
  }

  @discardableResult private func replaceDocumentText(
    _ document: EditorDocument, source: EditorPane, expected: String, replacement: String,
    action: String,
    edit: TextEdit? = nil, context: PaneCommandContext? = nil, requireFocus: Bool = true,
    operationID: UUID? = nil
  ) -> Bool {
    guard !preparingToQuit, !windowClosed, !document.saving, source.isAttached,
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
    guard
      applyNativeTextEdit(
        document, source: source, expected: expected, edit: change, action: action,
        context: context, requireFocus: requireFocus, operationID: operationID)
    else { return false }
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
          document.undoManager.setActionName("Bookmarks")
          document.undoManager.endUndoGrouping()
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
        let unchanged = result.text.utf16.elementsEqual(snapshot.utf16)
        if unchanged {
          guard
            self.nativeEditContextStillValid(
              document, source: source, context: sourceContext, requireFocus: true,
              operationID: operationID)
          else { return }
        }
        if unchanged
          || self.replaceDocumentText(
            document, source: source, expected: snapshot, replacement: result.text, action: action,
            edit: edit, context: sourceContext, operationID: operationID)
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

  func navigateManaged(
    documentID: UUID, endpointID: UUID, line: Int, column: Int,
    resolveOffset: @Sendable (String, Int, Int) async throws -> Int = { text, line, column in
      try await Task.detached(priority: .userInitiated) {
        try TextNavigation.utf16Offset(in: text, line: line, column: column)
      }.value
    }
  ) async throws {
    guard let routing = applicationRouting else { throw PaneRoutingError.stale }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
    guard let document = routing.registry.handle(id: documentID) as? EditorDocument,
      documents.contains(where: { $0 === document })
    else { throw PaneRoutingError.stale }
    let source = preferredPane(in: document)
    let sourceContext = context(for: source)
    let ownership = document.ownershipGeneration
    let preferredID = document.preferredPaneID
    let operationID = document.operationID
    let snapshot = document.storage.string
    // Endpoint validation may invoke an application callback. Check every captured value afterward.
    func validateTarget() throws {
      try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
      guard !preparingToQuit, !document.saving, document.composingPaneID == nil,
        document.operationID == operationID,
        routing.registry.handle(id: documentID) === document,
        routing.registry.assignment(of: documentID) == routing.assignment,
        routing.registry.allows(.select, documentID: documentID),
        documents.contains(where: { $0 === document }),
        document.ownershipGeneration == ownership,
        document.editRevision == sourceContext.editRevision,
        !document.storage.editedMask.contains(.editedCharacters),
        document.preferredPaneID == preferredID,
        document.panePool.contains(where: { $0 === source }), source.isAttached,
        !source.editor.hasMarkedText()
      else { throw PaneRoutingError.stale }
    }
    try validateTarget()
    guard source.editor.selectedRange() == sourceContext.selection else {
      throw PaneRoutingError.stale
    }
    let offset = try await resolveOffset(snapshot, line, column)
    try Task.checkCancellation()
    try validateTarget()
    guard source.editor.selectedRange() == sourceContext.selection,
      offset >= 0, offset <= document.storage.length
    else { throw PaneRoutingError.stale }
    let range = NSRange(location: offset, length: 0)
    try source.editor.withSelectionInstallation(
      authorizedBy: {
        (try? validateTarget()) != nil
          && source.editor.selectedRange() == sourceContext.selection
      },
      { source.editor.setSelectedRange(range) })
    try validateTarget()
    guard source.editor.selectedRange() == range else { throw PaneRoutingError.stale }
    source.editor.scrollRangeToVisible(range)
    try validateTarget()
    guard source.editor.selectedRange() == range else { throw PaneRoutingError.stale }
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
      guard
        self.applyNativeTextEdit(
          document, source: source, expected: snapshot,
          edit: TextEdit(range: range, replacement: replacement), action: "Text Conversion",
          context: sourceContext)
      else { return }
      let editor = source.editor
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
        guard let self, let document,
          self.applyNativeTextEdit(
            document, source: source, expected: expected,
            edit: TextEdit(
              range: NSRange(location: 0, length: expected.utf16.count),
              replacement: replacement), action: "Replace All")
        else { return false }
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
        guard
          self.applyNativeTextEdit(
            document, source: source, expected: captured,
            edit: TextEdit(range: range, replacement: formatted), action: "Format JSON",
            context: sourceContext, requireFocus: false)
        else { return }
        self.refresh()
      } catch { self?.present(error) }
    }
  }

  func applySettings(_ value: EditorSettings) {
    guard !preparingToQuit, !windowClosed,
      documents.allSatisfy({
        $0.nativeConfigurationToken == nil && applicationUserAllows(.paneInstall, document: $0)
      })
    else { return }
    let validated: EditorSettings
    do { validated = try value.validated() } catch {
      present(error)
      return
    }
    if WindowPresentationPolicy(settings) != WindowPresentationPolicy(validated) {
      settingsPolicyRevision = UUID()
    }
    settings = validated
    let policyRevision = settingsPolicyRevision
    for document in documents {
      guard settingsPolicyRevision == policyRevision else { return }
      configureSettings(document)
    }
    refresh()
  }

  private func configureSettings(_ document: EditorDocument) {
    guard transferProjection == nil, settledTransferProjection == nil,
      projectionAllows(.paneInstall, document: document), document.nativeConfigurationToken == nil
    else { return }
    let plan = ResolvedDocumentTypography(settings)
    let typographyChanged = document.appliedTypography != plan.signature
    let wrapChanged = document.appliedWrap != settings.wrap
    guard typographyChanged || wrapChanged else { return }
    let desiredWrap = settings.wrap
    do {
      try withDocumentConfiguration(
        document, invalidateTypography: typographyChanged,
        invalidateWrap: wrapChanged,
        publish: {
          if typographyChanged { document.appliedTypography = plan.signature }
          if wrapChanged { document.appliedWrap = desiredWrap }
        },
        write: { validate in
          if typographyChanged {
            for pane in document.panePool {
              try validate()
              pane.editor.font = plan.font
              try validate()
              pane.editor.defaultParagraphStyle = plan.paragraph
              try validate()
              pane.editor.typingAttributes[.paragraphStyle] = plan.paragraph
              try validate()
            }
            document.storage.addAttribute(
              .paragraphStyle, value: plan.paragraph,
              range: NSRange(location: 0, length: document.storage.length))
            try validate()
          }
          if wrapChanged {
            try writeWrap(document, enabled: desiredWrap, validate: validate)
          }
        })
    } catch {
      document.panePresentation.warning =
        "Document settings changed during native configuration. Apply settings again to retry."
    }
  }

  /// Native callbacks may reenter without suspension. The token fences user sinks while
  /// the captured endpoint, policy, revision and exact pane attachments fence publication.
  private func withDocumentConfiguration(
    _ document: EditorDocument, invalidateTypography: Bool = false, invalidateWrap: Bool = false,
    publish: () -> Void, write body: (_ validate: () throws -> Void) throws -> Void
  ) throws {
    guard projectionAllows(.paneInstall, document: document),
      documents.contains(where: { $0 === document })
    else { throw NativeConfigurationError.changed }
    let endpoint = applicationRouting?.endpointID
    let ownership = document.ownershipGeneration
    let revision = document.editRevision
    let policy = settingsPolicyRevision
    let panes = document.panePool
    let attached = panes.map(\.isAttached)
    let token = try document.beginNativeConfiguration()
    defer { document.endNativeConfiguration(token) }
    if invalidateTypography { document.appliedTypography = nil }
    if invalidateWrap { document.appliedWrap = nil }
    let mutation = document.closeMutationGeneration
    func validate() throws {
      guard document.nativeConfigurationToken == token,
        document.closeMutationGeneration == mutation,
        !windowClosed, !preparingToQuit,
        applicationRouting?.endpointID == endpoint, settingsPolicyRevision == policy,
        document.ownershipGeneration == ownership, document.editRevision == revision,
        documents.contains(where: { $0 === document }), document.panePool.count == panes.count,
        zip(document.panePool, panes).allSatisfy({ $0 === $1 }),
        zip(panes, attached).allSatisfy({ $0.isAttached == $1 }),
        panes.allSatisfy({
          $0.document === document
            && ($0.isAttached
              ? $0.layoutManager.textStorage === document.storage
              : $0.layoutManager.textStorage == nil)
        }),
        projectionAllows(.paneInstall, document: document, configurationToken: token)
      else { throw NativeConfigurationError.changed }
      // Endpoint admission callbacks above may themselves change the exact captured facts.
      guard document.nativeConfigurationToken == token,
        document.closeMutationGeneration == mutation,
        document.editRevision == revision, document.ownershipGeneration == ownership,
        settingsPolicyRevision == policy, applicationRouting?.endpointID == endpoint,
        document.panePool.count == panes.count,
        zip(document.panePool, panes).allSatisfy({ $0 === $1 }),
        zip(panes, attached).allSatisfy({ $0.isAttached == $1 })
      else { throw NativeConfigurationError.changed }
    }
    do {
      try validate()
      try body(validate)
      try validate()
      // This private closure only publishes scalar proof; it performs no native calls.
      publish()
    } catch {
      // Never invalidate proof belonging to a later operation that replaced this token.
      if document.nativeConfigurationToken == token {
        document.appliedTypography = nil
        document.appliedWrap = nil
      }
      throw error
    }
  }
  private func writeWrap(
    _ document: EditorDocument, enabled wrap: Bool,
    validate: () throws -> Void
  ) throws {
    try withTransferNativeLayout {
      for pane in document.panePool {
        try validate()
        try pane.configureWrapGeometry(enabled: wrap, validate: validate)
        try validate()
      }
    }
  }
  private func configureWrap(_ document: EditorDocument, enabled wrap: Bool) {
    // Layout refresh still updates host-size geometry even if the semantic proof matches.
    do {
      // Transfer preserves even unknown original proof. Presenting an inactive neighbor
      // may refresh geometry, but must not manufacture a new semantic receipt.
      let changed =
        transferProjection == nil && settledTransferProjection == nil
        && document.appliedWrap != wrap
      try withDocumentConfiguration(
        document, invalidateWrap: changed,
        publish: { if changed { document.appliedWrap = wrap } },
        write: { validate in
          try writeWrap(document, enabled: wrap, validate: validate)
        })
    } catch {
      // The transfer owner already validates/refuses its projection. A transient endpoint
      // refusal must not rewrite the captured warning and poison an otherwise valid retry.
      if transferProjection == nil, settledTransferProjection == nil {
        document.panePresentation.warning =
          "Document wrap could not be configured. Apply settings again to retry."
      }
    }
  }
  private func toggleWrap() {
    guard let document = current, document.nativeConfigurationToken == nil,
      applicationAllows(.select, document: document)
    else { return }
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
    _ = refreshMacroBinding(document)
    let editor = pane.editor
    if pane.isAttached { editor.installControlledStringOwner(self) }
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
        document.panePresentation.suppression == 0
      else { return }
      if self.transferProjection != nil || self.settledTransferProjection != nil {
        if self.transferLayoutDepth == 0 { document.panePresentation.invalidate(force: true) }
        return
      }
      guard self.applicationAllows(.select, document: document) else { return }
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
      retireMacroBinding(document)
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
    for document in documents { retireMacroBinding(document) }
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
    if let preparation = nativeEditPreparation,
      !preparation.delegateClaimed, preparation.editor === textView
    {
      // Claim before any owner/delegate callback. Identical nested edits cannot
      // consume this proposal or publish the outer command on its behalf.
      preparation.delegateClaimed = true
      guard affectedCharRange == preparation.range,
        replacementString == preparation.replacement
      else { return false }
      return prepareNativeEdit(preparation)
    }
    guard let source = pane(for: textView), mayMutate(source) else { return false }
    let document = source.document
    do {
      let approvedPending = approvedBookkeepingBefore(
        textView, range: affectedCharRange,
        replacement: replacementString, edge: .clearPending)
      document.pendingBookmarks = nil
      approvedBookkeepingAfter(textView, edge: .clearPending, before: approvedPending)
      let approvedUndoFlag = approvedBookkeepingBefore(
        textView, range: affectedCharRange,
        replacement: replacementString, edge: .clearUndoFlag)
      document.pendingBookmarksHaveUndo = false
      approvedBookkeepingAfter(textView, edge: .clearUndoFlag, before: approvedUndoFlag)
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
    guard recordedUnits >= 0, recordedUnits <= 10_000_000,
      recordedCommands.count < 10_000, count <= 10_000_000 - recordedUnits
    else {
      stopRecordingIntegrity()
      let alert = NSAlert()
      alert.messageText = "Macro recording limit reached"
      alert.informativeText =
        "Editing will continue. Use Stop Recording to save the commands captured so far."
      alert.runModal()
      return true
    }
    // Delegate permission is not a primitive commit. Successful unsupported
    // native character writes remain disclosed by the storage observation sink.
    return true
  }

  private func prepareNativeEdit(_ preparation: NativeEditPreparation) -> Bool {
    if preparation.controlledStringInsertion { return prepareControlledStringEdit(preparation) }
    guard let source = pane(for: preparation.editor), mayMutate(source), preparation.validate()
    else { return false }
    let document = source.document
    let count = preparation.replacement.utf16.count
    if recordingDocumentID == document.id,
      recordedUnits < 0 || recordedUnits > 10_000_000
        || recordedCommands.count >= 10_000 || count > 10_000_000 - recordedUnits
    {
      if case .searchBorrow = preparation.mode { return false }
      stopRecordingIntegrity()
      let alert = NSAlert()
      alert.messageText = "Macro recording limit reached"
      alert.informativeText =
        "Editing will continue. Use Stop Recording to save the commands captured so far."
      alert.runModal()
      guard preparation.validate() else { return false }
    }
    var bookmarks: DocumentBookmarks?
    if !document.bookmarks.offsets.isEmpty {
      do {
        var updated = document.bookmarks
        try updated.remap(
          through: TextEdit(range: preparation.range, replacement: preparation.replacement),
          inUTF16: document.storage.mutableString)
        bookmarks = updated
      } catch {
        if case .interactive = preparation.mode { present(error) }
        return false
      }
    }
    let native = document.storage.mutableString
    let replacementUnits = preparation.replacement.utf16
    let noOp =
      preparation.range.length == replacementUnits.count
      && zip(preparation.range.location..<NSMaxRange(preparation.range), replacementUnits)
        .allSatisfy { native.character(at: $0.0) == $0.1 }
    let recordingID = recordingDocumentID
    let commands = recordedCommands
    let units = recordedUnits
    let recordingEpoch = recordingIntegrity?.epoch
    let recordingSerial = recordingStateSerial
    let primitive = (document.storage as? DocumentCommitTextStorage)?.nativeMacroPrimitiveState
    preparation.macroFactsValid = { [weak self, weak document] in
      guard let self, let document else { return false }
      return self.recordingDocumentID == recordingID && self.recordedCommands == commands
        && self.recordedUnits == units && self.recordingIntegrity?.epoch == recordingEpoch
        && self.recordingStateSerial == recordingSerial
        && (recordingID == nil || !self.recordingStateSerialExhausted)
        && (document.storage as? DocumentCommitTextStorage)?.nativeMacroPrimitiveState == primitive
    }
    preparation.commit = { [weak document, weak preparation] in
      guard let document, let preparation, preparation.macroFactsValid?() == true
      else { return false }
      document.pendingBookmarks = bookmarks
      document.pendingBookmarksHaveUndo = bookmarks != nil && noOp
      document.typingBookmarkNextLocation = nil
      return true
    }
    return true
  }

  private func allowLeavingUnsavedRecording() -> Bool {
    if unresolvedRecording {
      renderMacroRecordingIncompleteStatus()
      return false
    }
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
    stopRecordingIntegrity()
    // Capture this stopped interval before refresh invokes owner/session callbacks.
    let stopped: MacroRecordingSaveAttempt?
    if let value = recordingIntegrity, !value.active, value.firstReason == nil,
      recordingDocumentID == nil, !recordingStateSerialExhausted,
      !recordedCommands.isEmpty, !macroSaving, recordingSaveAttempt == nil
    {
      stopped = MacroRecordingSaveAttempt(
        id: UUID(), epoch: value.epoch,
        documentID: value.documentID, serial: recordingStateSerial,
        commands: recordedCommands, units: recordedUnits)
    } else {
      stopped = nil
    }
    withMacroCallbackBarrier { refresh() }
    guard let stopped, !windowClosed, !preparingToQuit, !macroSaving,
      recordingSaveAttempt == nil, let currentStopped = recordingIntegrity,
      currentStopped.epoch == stopped.epoch, currentStopped.documentID == stopped.documentID,
      !currentStopped.active, currentStopped.firstReason == nil,
      recordingDocumentID == nil, !recordingStateSerialExhausted,
      recordingStateSerial == stopped.serial, recordedCommands == stopped.commands,
      recordedUnits == stopped.units
    else { return }
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
    guard withMacroCallbackBarrier({ alert.runModal() }) == .alertFirstButtonReturn,
      !macroSaving, recordingSaveAttempt == nil,
      let current = recordingIntegrity, current.epoch == stopped.epoch,
      current.documentID == stopped.documentID, !current.active, current.firstReason == nil,
      recordingDocumentID == nil, recordingStateSerial == stopped.serial,
      !recordingStateSerialExhausted, recordedCommands == stopped.commands,
      recordedUnits == stopped.units,
      let macro = recordingSnapshot(named: name.stringValue)
    else { return }
    recordingSaveAttempt = stopped
    macroSaving = true
    Task { [weak self] in
      do {
        try await Task.detached {
          try MacroLibrary(directory: MacroLibrary.defaultDirectory).save(macro)
        }.value
        guard let self, self.recordingSaveStillCurrent(stopped) else { return }
        self.withOwnedRecorderMutation {
          self.recordedCommands = []
          self.recordedUnits = 0
          self.recordingIntegrity = nil
          self.recordingSaveAttempt = nil
          self.macroSaving = false
        }
      } catch {
        guard let self, self.recordingSaveStillCurrent(stopped) else { return }
        self.recordingSaveAttempt = nil
        self.macroSaving = false
        self.withMacroCallbackBarrier { self.present(error) }
      }
    }
  }

  func recordingSnapshot(named name: String) -> EditorMacro? {
    guard !recordedCommands.isEmpty, let value = recordingIntegrity,
      value.firstReason == nil, !recordingStateSerialExhausted
    else { return nil }
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
        self.applyNativeTextEdit(
          document, source: source, expected: snapshot,
          edit: TextEdit(range: range, replacement: replacement), action: macro.name,
          context: sourceContext, requireFocus: false, operationID: operationID,
          cancellation: cancellation)
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

  private func renderMacroRecordingIncompleteStatus() {
    withMacroCallbackBarrier {
      macroNoticeRenderPending = true
      guard !macroNoticeRendering else { return }
      macroNoticeRendering = true
      defer { macroNoticeRendering = false }
      // Bound only our synchronous attempts; no scheduled drain or recorder ack.
      for _ in 0..<2 {
        guard macroNoticeRenderPending else { return }
        macroNoticeRenderPending = false
        guard let currentWindow = window else {
          macroNoticeRenderPending = true
          return
        }
        let closed = windowClosed
        let quitting = preparingToQuit
        let epoch = recordingIntegrity?.epoch
        let documentID = recordingIntegrity?.documentID
        let active = recordingIntegrity?.active
        let reason = recordingIntegrity?.firstReason
        let recordingID = recordingDocumentID
        let serial = recordingStateSerial
        let serialExhausted = recordingStateSerialExhausted
        let saving = macroSaving
        let saveAttemptID = recordingSaveAttempt?.id
        // Every native read precedes the final pure scalar/identity guards.
        let beforeHidden = macroRecordingIncompleteStatus.isHidden
        let beforeWindow = window
        let beforeRowWindow = macroRecordingIncompleteStatus.window
        guard !closed, !quitting, !windowClosed, !preparingToQuit,
          beforeWindow === currentWindow, beforeRowWindow === currentWindow
        else {
          macroNoticeRenderPending = true
          return
        }
        guard windowClosed == closed, preparingToQuit == quitting,
          recordingIntegrity?.epoch == epoch, recordingIntegrity?.documentID == documentID,
          recordingIntegrity?.active == active, recordingIntegrity?.firstReason == reason,
          recordingDocumentID == recordingID, recordingStateSerial == serial,
          recordingStateSerialExhausted == serialExhausted,
          macroSaving == saving, recordingSaveAttempt?.id == saveAttemptID
        else {
          macroNoticeRenderPending = true
          continue
        }
        let desiredHidden = reason == nil
        if beforeHidden != desiredHidden {
          macroRecordingIncompleteStatus.isHidden = desiredHidden
        }
        // Revalidate after setter return; callbacks may have created a successor.
        let afterHidden = macroRecordingIncompleteStatus.isHidden
        let afterWindow = window
        let afterRowWindow = macroRecordingIncompleteStatus.window
        guard !windowClosed, !preparingToQuit,
          afterWindow === currentWindow, afterRowWindow === currentWindow
        else {
          macroNoticeRenderPending = true
          return
        }
        guard windowClosed == closed, preparingToQuit == quitting,
          recordingIntegrity?.epoch == epoch, recordingIntegrity?.documentID == documentID,
          recordingIntegrity?.active == active, recordingIntegrity?.firstReason == reason,
          recordingDocumentID == recordingID, recordingStateSerial == serial,
          recordingStateSerialExhausted == serialExhausted,
          macroSaving == saving, recordingSaveAttempt?.id == saveAttemptID,
          afterHidden == desiredHidden
        else {
          macroNoticeRenderPending = true
          continue
        }
        // This acknowledges current visibility only, never recording metadata.
        macroNoticeRenderPending = false
        return
      }
      // Two invalidations retain pending for a later real status boundary.
    }
  }

  private func updateStatus() {
    defer { renderMacroRecordingIncompleteStatus() }
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
    for document in documents { retireControlledStringRouting(document) }
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
    for document in documents { _ = refreshMacroBinding(document) }
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

// Explicit native source installation; no owner, consumer or panel is activated here.
extension EditorWindowController {
  private func makeDocumentSearchSource(document: EditorDocument, pane: EditorPane) throws
    -> EditorDocumentSearchSource
  {
    guard let window = self.window, let routing = applicationRouting else {
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
    let binding = DocumentSearchNativeBinding(
      windowID: sessionID, endpointID: routing.endpointID, documentID: document.id,
      paneID: pane.id, ownershipGeneration: document.ownershipGeneration,
      assignment: routing.assignment, registryIdentity: ObjectIdentifier(routing.registry),
      windowIdentity: ObjectIdentifier(window))
    _ = try inspectDocumentSearchSource(
      document: document, pane: pane, window: window, binding: binding)
    return EditorDocumentSearchSource(
      inspect: { [weak self, weak document, weak pane, weak window] in
        guard let self, let document, let pane, let window else {
          throw ApplicationDocumentSearchFailure.sourceUnavailable
        }
        // Retain the document before any helper reads the pane's unowned document.
        return try withExtendedLifetime((document, pane, window)) {
          try self.inspectDocumentSearchSource(
            document: document, pane: pane, window: window, binding: binding)
        }
      },
      capture: { [weak self, weak document, weak pane, weak window] expected in
        guard let self, let document, let pane, let window else {
          throw ApplicationDocumentSearchFailure.sourceUnavailable
        }
        return try withExtendedLifetime((document, pane, window)) {
          let inspected = try self.inspectDocumentSearchSource(
            document: document, pane: pane, window: window, binding: binding)
          guard inspected == expected else { throw ApplicationDocumentSearchFailure.staleSource }
          let text = document.storage.string
          guard text.utf16.count == expected.inputUTF16,
            try self.inspectDocumentSearchSource(
              document: document, pane: pane, window: window, binding: binding) == expected
          else { throw ApplicationDocumentSearchFailure.staleSource }
          return SearchAdmissionCapture(
            text: text, inputUTF16: expected.inputUTF16, context: expected)
        }
      },
      isCurrent: { [weak self, weak document, weak pane, weak window] expected in
        guard let self, let document, let pane, let window else { return false }
        return withExtendedLifetime((document, pane, window)) {
          (try? self.inspectDocumentSearchSource(
            document: document, pane: pane, window: window, binding: binding)) == expected
        }
      },
      select: { [weak self, weak document, weak pane, weak window] expected, source, range in
        guard let self, let document, let pane, let window else { return false }
        return withExtendedLifetime((document, pane, window)) {
          self.selectDocumentSearchSource(
            document: document, pane: pane, window: window, binding: binding,
            expected: expected, source: source, range: range)
        }
      },
      replace: { [weak self, weak document, weak pane, weak window] expected, source, replacement in
        guard let self, let document, let pane, let window else { return false }
        return withExtendedLifetime((document, pane, window)) {
          self.replaceDocumentSearchSource(
            document: document, pane: pane, window: window, binding: binding,
            expected: expected, source: source, replacement: replacement)
        }
      })
  }

  private func inspectDocumentSearchSource(
    document: EditorDocument, pane: EditorPane, window: NSWindow,
    binding: DocumentSearchNativeBinding
  ) throws -> DocumentSearchCredential {
    func primitiveAvailable() -> Bool {
      guard sessionID == binding.windowID, self.window === window,
        ObjectIdentifier(window) == binding.windowIdentity, !windowClosed, !preparingToQuit,
        let routing = applicationRouting, routing.endpointID == binding.endpointID,
        routing.assignment == binding.assignment, routing.assignment.windowID == sessionID,
        ObjectIdentifier(routing.registry) == binding.registryIdentity,
        document.id == binding.documentID, pane.id == binding.paneID,
        document.ownershipGeneration == binding.ownershipGeneration,
        documents.contains(where: { $0 === document }),
        routing.registry.handle(id: binding.documentID) === document,
        routing.registry.assignment(of: binding.documentID) == binding.assignment,
        document.panePool.contains(where: { $0 === pane }), pane.isAttached,
        pane.document === document, pane.editor.textStorage === document.storage,
        pane.layoutManager.textStorage === document.storage,
        !document.saving, document.operationID == nil, document.composingPaneID == nil,
        document.nativeConfigurationToken == nil, document.panePresentation.installing == nil,
        !document.storage.editedMask.contains(.editedCharacters),
        !pane.editor.isComposingText, !pane.editor.hasMarkedText(),
        !document.searchRevisionExhausted, transferProjection == nil,
        projectionToken == nil, projectionValid,
        routing.registry.allows(.select, documentID: binding.documentID)
      else { return false }
      return true
    }
    guard primitiveAvailable() else { throw ApplicationDocumentSearchFailure.sourceUnavailable }
    let revision = document.editRevision
    let length = document.storage.length
    do {
      let routing = try requireApplicationEndpoint()
      guard routing.registry.allows(.select, documentID: binding.documentID) else {
        throw ApplicationDocumentSearchFailure.sourceUnavailable
      }
      // User admission can invalidate its own endpoint; recheck that actual authority.
      try routing.requireEndpointCurrent()
      guard primitiveAvailable(), document.editRevision == revision,
        document.storage.length == length
      else { throw ApplicationDocumentSearchFailure.sourceUnavailable }
      return try DocumentSearchCredential(
        windowID: binding.windowID, endpointID: binding.endpointID,
        documentID: binding.documentID, paneID: binding.paneID,
        ownershipGeneration: binding.ownershipGeneration,
        editRevision: document.editRevision, inputUTF16: document.storage.length)
    } catch {
      throw ApplicationDocumentSearchFailure.sourceUnavailable
    }
  }

  private func displayDocumentSearchSource(
    document: EditorDocument, pane: EditorPane, window: NSWindow,
    binding: DocumentSearchNativeBinding, expected: DocumentSearchCredential, source: String
  ) -> Bool {
    func valid() -> Bool {
      (try? inspectDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding)) == expected
        && source.utf16.count == expected.inputUTF16
        && document.storage.string.utf16.elementsEqual(source.utf16)
    }
    guard valid(), !pendingEndpointAttachments.contains(document.id),
      current?.composingPaneID == nil || current === document,
      let routing = applicationRouting
    else { return false }
    do {
      try routing.registry.selectDocument(
        document.id, in: routing.assignment, expectedRevision: routing.registry.workspaceRevision)
      guard valid() else { return false }
      try projectCurrentRegistry()
      return valid() && current === document
    } catch {
      return false
    }
  }

  private func focusDocumentSearchSource(
    document: EditorDocument, pane: EditorPane, window: NSWindow,
    binding: DocumentSearchNativeBinding, expected: DocumentSearchCredential, source: String
  ) -> Bool {
    func valid() -> Bool {
      (try? inspectDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding)) == expected
        && current === document && source.utf16.count == expected.inputUTF16
        && document.storage.string.utf16.elementsEqual(source.utf16)
    }
    guard valid() else { return false }
    let previous = focusedPane
    if previous !== pane {
      guard valid() else { return false }
      previous?.editor.breakUndoCoalescing()
      guard valid() else { return false }
      pane.editor.breakUndoCoalescing()
      guard valid() else { return false }
    }
    guard valid(), window.makeFirstResponder(pane.editor), valid(),
      window.firstResponder === pane.editor
    else { return false }
    guard valid() else { return false }
    document.preferredPaneID = pane.id
    guard valid() else { return false }
    presentationInteraction(document)
    guard valid() else { return false }
    updateStatus()
    return valid() && window.firstResponder === pane.editor
  }

  private func selectDocumentSearchSource(
    document: EditorDocument, pane: EditorPane, window: NSWindow,
    binding: DocumentSearchNativeBinding, expected: DocumentSearchCredential,
    source: String, range: NSRange
  ) -> Bool {
    func valid() -> Bool {
      (try? inspectDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding)) == expected
        && source.utf16.count == expected.inputUTF16
        && document.storage.string.utf16.elementsEqual(source.utf16)
    }
    guard valid(), range.location >= 0, range.length >= 0,
      range.location <= expected.inputUTF16,
      range.length <= expected.inputUTF16 - range.location
    else { return false }
    let native = source as NSString
    func scalarBoundary(_ offset: Int) -> Bool {
      offset == 0 || offset == expected.inputUTF16
        || !(0xDC00...0xDFFF).contains(native.character(at: offset))
    }
    guard scalarBoundary(range.location), scalarBoundary(range.location + range.length),
      displayDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding,
        expected: expected, source: source),
      focusDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding,
        expected: expected, source: source)
    else { return false }
    func selectedAndCurrent() -> Bool {
      valid() && current === document && window.firstResponder === pane.editor
        && pane.editor.selectedRange() == range
    }
    do {
      try pane.editor.withSelectionInstallation(
        authorizedBy: {
          valid() && self.current === document && window.firstResponder === pane.editor
        },
        { pane.editor.setSelectedRange(range) })
    } catch {
      return false
    }
    guard selectedAndCurrent() else { return false }
    pane.editor.scrollRangeToVisible(range)
    return selectedAndCurrent()
  }

  private func replaceDocumentSearchSource(
    document: EditorDocument, pane: EditorPane, window: NSWindow,
    binding: DocumentSearchNativeBinding, expected: DocumentSearchCredential,
    source: String, replacement: String
  ) -> Bool {
    guard
      (try? inspectDocumentSearchSource(
        document: document, pane: pane, window: window, binding: binding)) == expected,
      source.utf16.count == expected.inputUTF16,
      document.storage.string.utf16.elementsEqual(source.utf16)
    else { return false }
    let context = PaneCommandContext(
      documentID: expected.documentID, paneID: expected.paneID,
      editRevision: expected.editRevision, selection: pane.editor.selectedRange())
    return withExtendedLifetime((document, pane, window)) {
      applyNativeTextEdit(
        document, source: pane, expected: source,
        edit: TextEdit(
          range: NSRange(location: 0, length: expected.inputUTF16), replacement: replacement),
        action: "Replace All", context: context, requireFocus: false,
        operationID: nil, cancellation: nil,
        mode: .searchBorrow(binding: binding, credential: expected))
    }
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
    guard document.nativeConfigurationToken == nil else { return false }
    if transferProjection != nil { return false }
    guard let routing = applicationRouting else { return true }
    guard (try? requireApplicationEndpoint()) != nil,
      routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment
    else { return false }
    let allowed = routing.registry.allows(action, documentID: document.id)
    return allowed && document.nativeConfigurationToken == nil
  }
  private func mayFocus(_ pane: EditorPane) -> Bool {
    guard pane.document.nativeConfigurationToken == nil else { return false }
    if applicationUserAllows(.select, document: pane.document) { return true }
    guard let scope = projectionFocus, projectionToken == scope.token, scope.paneID == pane.id,
      current === pane.document, pane.isAttached,
      pane.document.panePool.contains(where: { $0 === pane })
    else { return false }
    return projectionAllows(.select, document: pane.document)
  }
  @discardableResult
  private func focusProjectedPane(_ pane: EditorPane) -> Bool {
    guard let token = projectionToken, projectionFocus == nil else { return false }
    projectionFocus = (token, pane.id)
    defer { projectionFocus = nil }
    return window?.makeFirstResponder(pane.editor) ?? false
  }
  /// Used only by synchronous owner layout/focus installation, never by user mutation sinks.
  private func projectionAllows(
    _ action: DocumentAdmission, document: EditorDocument,
    configurationToken: UUID? = nil
  ) -> Bool {
    guard
      document.nativeConfigurationToken == nil
        || (configurationToken != nil && document.nativeConfigurationToken == configurationToken)
    else { return false }
    guard let routing = applicationRouting else { return !windowClosed && !preparingToQuit }
    if projectionToken == nil {
      guard transferProjection == nil, (try? requireApplicationEndpoint()) != nil,
        routing.registry.handle(id: document.id) === document,
        routing.registry.assignment(of: document.id) == routing.assignment
      else { return false }
      return routing.registry.allows(action, documentID: document.id)
    }
    guard action == .paneInstall || action == .select,
      (try? requireApplicationEndpoint(userInitiated: false)) != nil,
      routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment
    else { return false }
    if let scope = transferProjection {
      // An identity-only registry snapshot is insufficient authority. During configuration
      // compare the complete live native state below, excluding only this exact token's
      // busy bit; ordinary validation/capture remains busy until the operation ends.
      let liveSnapshot =
        configurationToken == nil
        ? try? routing.registry.validateTransferSnapshot(scope.snapshot.lease)
        : try? routing.registry.transferSnapshot(scope.snapshot.lease)
      guard let live = liveSnapshot, !live.requiresReconciliation,
        live.phase == scope.snapshot.phase, live.expectedState == scope.snapshot.expectedState,
        scope.receipt.endpointID == routing.endpointID,
        current === document, documents.contains(where: { $0 === document })
      else { return false }
      if let configurationToken {
        guard live.handle === scope.snapshot.handle, live.source == scope.snapshot.source,
          live.target == scope.snapshot.target,
          scope.receipt.presentationPolicy == WindowPresentationPolicy(settings)
        else { return false }
        for model in scope.receipt.models {
          guard routing.registry.handle(id: model.id) === model,
            let expected = model.id == live.request.documentID
              ? live.expectedState : scope.receipt.states[model.id],
            let actual = try? model.captureTransferState(
              preparation: transferPreparation,
              configurationToken: model === document ? configurationToken : nil),
            actual == expected
          else { return false }
        }
      }
      return true
    }
    return routing.registry.allows(action, documentID: document.id)
  }
  private func applicationUserAllows(_ action: DocumentAdmission, document: EditorDocument) -> Bool
  {
    guard document.nativeConfigurationToken == nil else { return false }
    if transferProjection != nil { return false }
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
    finish: @escaping (Error?, Bool) -> Void, succeed: @escaping (EditorDocument) -> Void
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
              document: existing, encoding: encoding, shouldAccept: shouldAccept,
              onFailure: { finish($0, true) }, onReload: { succeed(existing) })
          } else {
            succeed(existing)
          }
          return
        }
        let id = try self.submitApplicationSeed(
          seed, provenance: .fresh, selection: .select, additionalAdmission: shouldAccept)
        let outcome = try await self.applicationRouting!.wait(id)
        try self.requireApplicationPreparation(request)
        guard shouldAccept?() != false else { throw CancellationError() }
        try self.validateApplicationResult(outcome)
        guard case .imported(let documentID) = outcome,
          let document = self.applicationRouting?.registry.handle(id: documentID) as? EditorDocument
        else { throw EditorApplicationRoutingError.invalidProjection }
        succeed(document)
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
    if let scope = transferProjection {
      let live = try routing.registry.validateTransferSnapshot(scope.snapshot.lease)
      guard live.phase == scope.snapshot.phase, live.expectedState == scope.snapshot.expectedState,
        (sessionID == live.source.id ? live.source : live.target) == expected
      else { throw NativeDocumentTransferError.changed }
    }
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
  // An already-current unrelated projection has no native work to apply.
  // Keep exact live bindings; a real changed/stale projection takes the original path.
  private func preserveUnchangedMacroProjection(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws -> Bool {
    guard projectionValid, projectionToken == nil, !windowClosed, !preparingToQuit,
      transferProjection == nil, settledTransferProjection == nil,
      pendingEndpointAttachments.isEmpty, transferAttachmentOwner == nil,
      !approvedRouteSerialExhausted, !approvedRouteRetirementExhausted,
      nativeMacroTerminalProjectionMatches(expected, revision: revision, endpointID: endpointID),
      documents.allSatisfy({ nativeMacroStartBindingAvailable($0) })
    else { return false }
    let models = documents
    let ownership = models.map(\.ownershipGeneration)
    let mutations = models.map(\.closeMutationGeneration)
    let revisions = models.map(\.editRevision)
    let bindings = macroBindings
    let routeSerial = approvedRouteSerial
    let retirementSerial = approvedRouteRetirementSerial
    let recorder = nativeMacroApprovedRouteRecorderFence()
    let selected = current
    let panes = selected?.panePool.filter(\.isAttached) ?? []
    var associations: [ApprovedRouteAssociation] = []
    for pane in panes {
      guard let association = approvedRoutes[ObjectIdentifier(pane.editor)],
        association.pane === pane, approvedStoredRoute(association),
        pane.editor.controlledStringOwner === self
      else { return false }
      associations.append(association)
    }
    @MainActor func storedProofStillCurrent() -> Bool {
      projectionValid && projectionToken == nil && !windowClosed && !preparingToQuit
        && transferProjection == nil && settledTransferProjection == nil
        && pendingEndpointAttachments.isEmpty && transferAttachmentOwner == nil
        && !approvedRouteSerialExhausted && !approvedRouteRetirementExhausted
        && approvedRouteSerial == routeSerial
        && approvedRouteRetirementSerial == retirementSerial
        && macroBindings == bindings
        && documents.count == models.count
        && zip(documents, models).allSatisfy({ $0 === $1 })
        && models.map(\.ownershipGeneration) == ownership
        && models.map(\.closeMutationGeneration) == mutations
        && models.map(\.editRevision) == revisions
        && current === selected
        && (current?.panePool.filter(\.isAttached).map(\.id) ?? []) == panes.map(\.id)
        && nativeMacroApprovedRouteRecorderFence() == recorder
        && nativeMacroTerminalProjectionMatches(
          expected, revision: revision, endpointID: endpointID)
        && documents.allSatisfy({ nativeMacroStartBindingAvailable($0) })
        && associations.allSatisfy({ approvedStoredRoute($0) })
        && panes.allSatisfy({ $0.editor.controlledStringOwner === self })
    }
    return try withMacroCallbackBarrier {
      try validateRegistryProjection(expected, revision: revision, endpointID: endpointID)
      guard storedProofStillCurrent() else {
        throw EditorApplicationRoutingError.invalidProjection
      }
      for association in associations {
        guard approvedNativeRoute(association), storedProofStillCurrent() else {
          throw EditorApplicationRoutingError.invalidProjection
        }
      }
      guard storedProofStillCurrent() else {
        throw EditorApplicationRoutingError.invalidProjection
      }
      return true
    }
  }

  func applyRegistryProjection(
    _ expected: DocumentWindowSnapshot, revision: UUID, endpointID: UUID
  ) throws {
    guard projectionToken == nil, !preparingToQuit else {
      throw EditorApplicationRoutingError.invalidProjection
    }
    if transferProjection == nil { _ = try applicationRouting?.registry.captureWindows() }
    if try preserveUnchangedMacroProjection(expected, revision: revision, endpointID: endpointID) {
      return
    }
    let token = UUID()
    projectionToken = token
    for document in documents { retireMacroBinding(document) }
    projectionValid = false
    defer {
      if projectionToken == token { projectionToken = nil }
      if projectionValid { for document in documents { _ = refreshMacroBinding(document) } }
    }
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
      if transferProjection?.snapshot.request.documentID != removed.id {
        try applicationRouting!.detachDocumentEndpoint(removed)
      }
      _ = try registryModels(expected, revision: revision, endpointID: endpointID)
      pendingEndpointAttachments.remove(removed.id)
    }
    documents = next
    selectedID = selection
    if let scope = transferProjection { scope.receipt.projected = expected }
    for document in next {
      if let pin = applicationRouting?.registry.metadata(id: document.id)?.pinned,
        document.pinned != pin
      {
        guard transferProjection == nil else { throw NativeDocumentTransferError.changed }
        document.pinned = pin
      }
      if !old.contains(where: { $0 === document }) {
        for pane in document.panePool { installCallbacks(for: pane) }
        if transferProjection?.snapshot.request.documentID != document.id {
          pendingEndpointAttachments.insert(document.id)
          if let scope = transferProjection {
            if transferAttachmentOwner?.lease != scope.snapshot.lease {
              transferAttachmentOwner = (scope.snapshot.lease, [])
            }
            transferAttachmentOwner?.ids.insert(document.id)
          }
        }
      }
      if pendingEndpointAttachments.contains(document.id) {
        try attachDocumentEndpoint(document)
        // Successful reattachment consumed its receipt; later projection refusal must not repeat it.
        pendingEndpointAttachments.remove(document.id)
        transferAttachmentOwner?.ids.remove(document.id)
        if transferAttachmentOwner?.ids.isEmpty == true { transferAttachmentOwner = nil }
        _ = try registryModels(expected, revision: revision, endpointID: endpointID)
      }
    }
    if let selected {
      if transferProjection != nil || oldCurrent !== selected
        || host.displayedIDs != selected.panePool.filter(\.isAttached).map(\.id)
      {
        if transferProjection == nil, settledTransferProjection == nil, let oldCurrent,
          oldCurrent !== selected,
          next.contains(where: { $0 === oldCurrent })
        {
          presentationInteraction(oldCurrent)
        }
        for pane in selected.panePool where pane.isAttached { installCallbacks(for: pane) }
        if transferProjection == nil, settledTransferProjection == nil, !selected.settingsApplied {
          configureSettings(selected)
        }
        let wrap = !preferredPane(in: selected).editor.isHorizontallyResizable
        try presentPanes(selected, wrap: wrap)
        if transferProjection == nil, settledTransferProjection == nil {
          focusProjectedPane(preferredPane(in: selected))
          installPendingPresentationIfPossible(selected)
          selected.highlighter.update(language: selected.language)
        }
      }
    } else {
      try host.present(panes: [], axis: .sideBySide)
    }
    let verified = try registryModels(expected, revision: revision, endpointID: endpointID)
    guard projectionToken == token, verified.count == documents.count,
      zip(verified, documents).allSatisfy({ $0 === $1 }), selectedID == selection
    else { throw EditorApplicationRoutingError.invalidProjection }
    if transferProjection == nil {
      refresh()
      renderDiskStatus()
    }
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
      !macroSaving, !isRecordingMacro, recordedCommands.isEmpty, !unresolvedRecording,
      replayCancellation == nil,
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
    retireMacroBinding(document)
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

/// Immutable capture retained by one transfer; it never becomes registry authority.
@MainActor final class EditorTransferEndpointReceipt {
  let endpointID: UUID
  let windowID: UUID
  let lease: DocumentTransferLease
  let original: DocumentWindowSnapshot
  let models: [EditorDocument]
  let views: [UUID: NativeDocumentTransferViewReceipt]
  let states: [UUID: DocumentTransferState]
  let presentationPolicy: WindowPresentationPolicy
  fileprivate var projected: DocumentWindowSnapshot
  fileprivate var projectionPending = false
  fileprivate var acceptedState: DocumentTransferState?
  fileprivate init(
    endpointID: UUID, lease: DocumentTransferLease, original: DocumentWindowSnapshot,
    models: [EditorDocument], views: [UUID: NativeDocumentTransferViewReceipt],
    states: [UUID: DocumentTransferState], presentationPolicy: WindowPresentationPolicy
  ) {
    self.endpointID = endpointID
    self.windowID = original.id
    self.lease = lease
    self.original = original
    self.models = models
    self.views = views
    self.states = states
    self.presentationPolicy = presentationPolicy
    self.projected = original
  }
}
extension EditorWindowController {
  /// Conservative observation while transfer owns admission; never authorizes actions or baseline adoption.
  func transferFileStateContext(_ document: EditorDocument, receipt: EditorTransferEndpointReceipt)
    -> FileStateLiveContext?
  {
    guard let owner = fileMonitoring, let routing = applicationRouting,
      receipt.endpointID == routing.endpointID, receipt.windowID == sessionID,
      receipt.models.contains(where: { $0 === document }),
      routing.registry.handle(id: document.id) === document,
      (try? routing.requireEndpointCurrent()) != nil
    else { return nil }
    return FileStateLiveContext(
      documentID: document.id, ownershipGeneration: document.ownershipGeneration,
      bindingID: document.fileBindingID, baselineRevision: document.baselineRevision,
      url: document.url,
      editRevision: document.editRevision, encoding: document.encoding, hasBOM: document.hasBOM,
      dirty: true, pendingPublicationID: document.pendingPublication?.id,
      operationID: document.operationID,
      composing: document.composingPaneID != nil, recording: isRecordingMacro,
      closed: windowClosed || !documents.contains(where: { $0 === document })
        || routing.registry.assignment(of: document.id) != routing.assignment,
      quitting: preparingToQuit || owner.isSuspended, deliveryGeneration: owner.deliveryGeneration)
  }
  func ordinaryFileStateContext(_ document: EditorDocument) -> FileStateLiveContext? {
    guard let routing = applicationRouting,
      (try? routing.registry.captureWindows()) != nil,
      routing.registry.handle(id: document.id) === document,
      routing.registry.assignment(of: document.id) == routing.assignment,
      documents.contains(where: { $0 === document }),
      (try? routing.requireEndpointCurrent()) != nil
    else { return nil }
    return fileStateContext(document)
  }
  private func withTransferNativeLayout<T>(_ body: () throws -> T) rethrows -> T {
    guard transferProjection != nil || settledTransferProjection != nil else { return try body() }
    transferLayoutDepth += 1
    defer { transferLayoutDepth -= 1 }
    return try body()
  }
  func notifyTransferDiskStateChange() { onDiskStateChange?() }
  func captureTransferPreparation() throws -> NativeDocumentTransferPreparation {
    guard let routing = applicationRouting, !windowClosed else {
      throw NativeDocumentTransferError.changed
    }
    try routing.requireEndpointCurrent()
    guard !windowClosed else { throw NativeDocumentTransferError.changed }
    return transferPreparation
  }
  private var transferPreparation: NativeDocumentTransferPreparation {
    let owned: Set<UUID>
    if let owner = transferAttachmentOwner,
      applicationRouting?.registry.hasActiveTransferLease(owner.lease) == true
    {
      owned = owner.ids
    } else {
      owned = []
    }
    return .init(
      loading: loadingCount > 0,
      macroWork: recordingDocumentID != nil || macroSaving || replayCancellation != nil
        || !recordedCommands.isEmpty || unresolvedRecording,
      applicationPreparation: applicationPreparation != nil
        || !pendingEndpointAttachments.subtracting(owned).isEmpty
        || (projectionToken != nil && transferProjection == nil), preparingQuit: preparingToQuit)
  }
  private func transferWindow(_ snapshot: DocumentTransferSnapshot) throws -> DocumentWindowSnapshot
  {
    guard let routing = applicationRouting, !windowClosed,
      routing.assignment == snapshot.request.source || routing.assignment == snapshot.request.target
    else { throw NativeDocumentTransferError.changed }
    try routing.requireEndpointCurrent()
    let live = try routing.registry.validateTransferSnapshot(snapshot.lease)
    guard live.phase == snapshot.phase, live.expectedState == snapshot.expectedState,
      live.source == snapshot.source, live.target == snapshot.target,
      live.handle === snapshot.handle, !windowClosed
    else { throw NativeDocumentTransferError.changed }
    return sessionID == live.source.id ? live.source : live.target
  }
  func captureTransferEndpoint(_ snapshot: DocumentTransferSnapshot, endpointID: UUID) throws
    -> EditorTransferEndpointReceipt
  {
    guard projectionToken == nil, transferProjection == nil, !transferPreparation.isBusy,
      applicationRouting?.endpointID == endpointID, snapshot.phase == .reserved
    else { throw NativeDocumentTransferError.busy }
    let capturedPolicy = WindowPresentationPolicy(settings)
    let expected = try transferWindow(snapshot)
    try validateRegistryProjection(
      expected, revision: applicationRouting!.registry.workspaceRevision,
      endpointID: endpointID)
    guard let moved = snapshot.handle as? EditorDocument else {
      throw NativeDocumentTransferError.unmanaged
    }
    var models = documents
    if !models.contains(where: { $0 === moved }) { models.append(moved) }
    var viewIDs = Set<UUID>()
    if let selectedID { viewIDs.insert(selectedID) }
    if sessionID == snapshot.source.id {
      let ids = expected.groups[0].documentIDs
      if let index = ids.firstIndex(of: moved.id) {
        let remaining = ids.filter { $0 != moved.id }
        if !remaining.isEmpty { viewIDs.insert(remaining[min(index, remaining.count - 1)]) }
      }
    } else {
      viewIDs.insert(moved.id)
    }
    guard viewIDs.count <= 2 else { throw NativeDocumentTransferError.invalidGeometry }
    var states: [UUID: DocumentTransferState] = [:]
    var views: [UUID: NativeDocumentTransferViewReceipt] = [:]
    for model in models {
      let state = try model.captureTransferState(preparation: transferPreparation)
      guard !state.isBusy, !state.isComposing, !state.hasPendingTextEdits,
        state.operationID == nil, state.pendingPublicationID == nil, state.recoveryAuthority != nil
      else { throw NativeDocumentTransferError.busy }
      states[model.id] = state
      if viewIDs.contains(model.id) {
        views[model.id] = try model.captureTransferView(preparation: transferPreparation)
      }
    }
    let receipt = EditorTransferEndpointReceipt(
      endpointID: endpointID, lease: snapshot.lease,
      original: expected, models: models, views: views, states: states,
      presentationPolicy: capturedPolicy)
    try validateTransferEndpoint(snapshot, receipt: receipt)
    return receipt
  }
  func validateTransferEndpoint(
    _ snapshot: DocumentTransferSnapshot,
    receipt: EditorTransferEndpointReceipt
  ) throws {
    try validateTransferEndpoint(snapshot, receipt: receipt, allowLayoutOrigins: false)
  }
  private func validateTransferEndpoint(
    _ snapshot: DocumentTransferSnapshot,
    receipt: EditorTransferEndpointReceipt, allowLayoutOrigins: Bool
  ) throws {
    guard !allowLayoutOrigins || transferProjection?.receipt === receipt else {
      throw NativeDocumentTransferError.changed
    }
    guard receipt.lease == snapshot.lease, receipt.endpointID == applicationRouting?.endpointID,
      receipt.windowID == sessionID,
      receipt.presentationPolicy == WindowPresentationPolicy(settings),
      !transferPreparation.isBusy
    else { throw NativeDocumentTransferError.changed }
    _ = try transferWindow(snapshot)
    let ids = receipt.projected.groups[0].documentIDs
    guard documents.map(\.id) == ids, selectedID == receipt.projected.groups[0].selectedDocumentID,
      receipt.projectionPending
        || host.displayedIDs == (current?.panePool.filter(\.isAttached).map(\.id) ?? [])
    else { throw NativeDocumentTransferError.changed }
    for model in receipt.models {
      guard applicationRouting?.registry.handle(id: model.id) === model,
        let captured = receipt.states[model.id]
      else { throw NativeDocumentTransferError.changed }
      let expected = model.id == snapshot.request.documentID ? snapshot.expectedState : captured
      guard try model.captureTransferState(preparation: transferPreparation) == expected else {
        throw NativeDocumentTransferError.changed
      }
      if let view = receipt.views[model.id] {
        let projected = receipt.projected != receipt.original
        let geometry =
          allowLayoutOrigins
          ? transferViewWithLiveOrigins(view, model: model)
          : (projected ? constrainedTransferView(view, model: model) : view)
        if receipt.projectionPending,
          (try? model.validateTransferView(
            view, expectedState: expected, preparation: transferPreparation)) != nil
        {
          continue
        }
        try model.validateTransferView(
          geometry, expectedState: expected, preparation: transferPreparation)
      }
    }
  }
  private func transferViewWithLiveOrigins(
    _ view: NativeDocumentTransferViewReceipt,
    model: EditorDocument
  ) -> NativeDocumentTransferViewReceipt {
    let panes = view.panes.map { value -> NativeTransferPaneReceipt in
      let origin =
        model.panePool.first(where: { $0.id == value.id })?.scroll.contentView.bounds.origin
        ?? value.origin
      return .init(
        id: value.id, object: value.object, attached: value.attached, selection: value.selection,
        origin: origin)
    }
    return .init(
      model: view.model, state: view.state, panes: panes, preferredPaneID: view.preferredPaneID,
      axis: view.axis, pending: view.pending, interaction: view.interaction, warning: view.warning,
      appliedTypography: view.appliedTypography, appliedWrap: view.appliedWrap)
  }
  private func constrainedTransferView(
    _ view: NativeDocumentTransferViewReceipt,
    model: EditorDocument
  ) -> NativeDocumentTransferViewReceipt {
    let panes = view.panes.map { value -> NativeTransferPaneReceipt in
      // Storage attachment survives a move's temporary removal from its native host. Such
      // unhosted panes retain the original origin until an endpoint actually lays them out.
      guard let pane = model.panePool.first(where: { $0.id == value.id }), pane.isAttached,
        pane.scroll.superview != nil
      else {
        return value
      }
      var proposed = pane.scroll.contentView.bounds
      proposed.origin = value.origin
      let clip = pane.scroll.contentView
      let constrained = clip.constrainBoundsRect(proposed)
      // NSClipView's setter aligns to backing pixels, including fractional split-view frames.
      // Derive that exact framework postcondition from the original receipt, never live origins.
      let origin = clip.backingAlignedRect(
        constrained,
        options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
      ).origin
      return .init(
        id: value.id, object: value.object, attached: value.attached, selection: value.selection,
        origin: origin)
    }
    return .init(
      model: view.model, state: view.state, panes: panes, preferredPaneID: view.preferredPaneID,
      axis: view.axis, pending: view.pending, interaction: view.interaction, warning: view.warning,
      appliedTypography: view.appliedTypography, appliedWrap: view.appliedWrap)
  }
  func applyTransferProjection(
    _ snapshot: DocumentTransferSnapshot,
    receipt: EditorTransferEndpointReceipt
  ) throws {
    guard transferProjection == nil, projectionToken == nil else {
      throw NativeDocumentTransferError.busy
    }
    try validateTransferEndpoint(snapshot, receipt: receipt)
    let expected = try transferWindow(snapshot)
    receipt.acceptedState = snapshot.expectedState
    transferProjection = (snapshot, receipt)
    defer { transferProjection = nil }
    // A refused native layout can be retried without recapturing or approving unrelated geometry.
    receipt.projectionPending = true
    try applyRegistryProjection(
      expected, revision: applicationRouting!.registry.workspaceRevision,
      endpointID: receipt.endpointID)
    try validateTransferEndpoint(snapshot, receipt: receipt, allowLayoutOrigins: true)
    if let selected = current, let view = receipt.views[selected.id] {
      let expectedState =
        selected.id == snapshot.request.documentID ? snapshot.expectedState : view.state
      guard try selected.captureTransferState(preparation: transferPreparation) == expectedState
      else {
        throw NativeDocumentTransferError.changed
      }
      let constrained = constrainedTransferView(view, model: selected)
      for value in constrained.panes where value.attached {
        guard let pane = selected.panePool.first(where: { $0.id == value.id }),
          pane.editor.selectedRange() == value.selection
        else { throw NativeDocumentTransferError.changed }
        let clip = pane.scroll.contentView
        let actual = clip.bounds.origin
        if actual != value.origin {
          // Active-lease layout owns origin restoration; original receipts remain immutable.
          withTransferNativeLayout { clip.setBoundsOrigin(value.origin) }
        }
      }
    }
    try validateTransferEndpoint(snapshot, receipt: receipt)
    receipt.projectionPending = false
    try validateTransferEndpoint(snapshot, receipt: receipt)
  }
}

extension EditorWindowController {
  private func replacementTransferReceipt(
    _ receipt: EditorTransferEndpointReceipt, endpointID: UUID
  )
    -> EditorTransferEndpointReceipt
  {
    let result = EditorTransferEndpointReceipt(
      endpointID: endpointID, lease: receipt.lease,
      original: receipt.original, models: receipt.models, views: receipt.views,
      states: receipt.states, presentationPolicy: receipt.presentationPolicy)
    result.acceptedState = receipt.acceptedState
    return result
  }
  private func requireReplacementEndpoint(
    _ receipt: EditorTransferEndpointReceipt,
    endpointID: UUID, expected: DocumentWindowSnapshot
  ) throws {
    guard projectionToken == nil, transferProjection == nil, settledTransferProjection == nil,
      !transferPreparation.isBusy, let routing = applicationRouting,
      endpointID == routing.endpointID, receipt.windowID == sessionID, expected.id == sessionID,
      receipt.presentationPolicy == WindowPresentationPolicy(settings),
      expected.groups.count == 1, expected.groups[0].id == routing.assignment.groupID
    else { throw NativeDocumentTransferError.changed }
    try requireEndpointIdentity(endpointID: endpointID, assignment: routing.assignment)
    guard
      documents.isEmpty && selectedID == nil && host.displayedIDs.isEmpty
        || documents.map(\.id) == expected.groups[0].documentIDs
          && selectedID == expected.groups[0].selectedDocumentID
          && documents.allSatisfy({ model in receipt.models.contains(where: { $0 === model }) })
    else { throw NativeDocumentTransferError.changed }
  }
  func reconcileTransferEndpoint(
    _ snapshot: DocumentTransferSnapshot,
    receipt: EditorTransferEndpointReceipt, endpointID: UUID
  ) throws -> EditorTransferEndpointReceipt {
    let expected = try transferWindow(snapshot)
    try requireReplacementEndpoint(receipt, endpointID: endpointID, expected: expected)
    guard receipt.lease == snapshot.lease else { throw NativeDocumentTransferError.changed }
    let result = replacementTransferReceipt(receipt, endpointID: endpointID)
    result.acceptedState = snapshot.expectedState
    if documents.isEmpty {
      result.projected = .init(
        id: expected.id,
        groups: [.init(id: expected.groups[0].id, documentIDs: [], selectedDocumentID: nil)],
        focusedGroupID: expected.focusedGroupID, axis: expected.axis)
    } else {
      result.projected = expected
    }
    result.projectionPending = true
    try validateTransferEndpoint(snapshot, receipt: result)
    return result
  }
  func reconcileSettledTransferEndpoint(
    receipt: EditorTransferEndpointReceipt,
    expected: DocumentWindowSnapshot, endpointID: UUID
  ) throws -> EditorTransferEndpointReceipt {
    try requireReplacementEndpoint(receipt, endpointID: endpointID, expected: expected)
    guard let routing = applicationRouting else { throw NativeDocumentTransferError.changed }
    _ = try routing.registry.captureWindows()
    let revision = routing.registry.workspaceRevision
    let models = try registryModels(expected, revision: revision, endpointID: endpointID)
    var states: [UUID: DocumentTransferState] = [:]
    var views: [UUID: NativeDocumentTransferViewReceipt] = [:]
    for model in receipt.models {
      guard routing.registry.handle(id: model.id) === model, let original = receipt.states[model.id]
      else {
        throw NativeDocumentTransferError.changed
      }
      let authority =
        receipt.acceptedState?.documentID == model.id ? receipt.acceptedState! : original
      let current = try model.captureTransferState(preparation: transferPreparation)
      guard current.ownershipGeneration == authority.ownershipGeneration,
        current.recoveryAuthority == authority.recoveryAuthority,
        !current.isBusy, !current.isComposing, !current.hasPendingTextEdits,
        current.operationID == nil, current.pendingPublicationID == nil
      else {
        throw NativeDocumentTransferError.changed
      }
      states[model.id] = current
      if model.id == expected.groups[0].selectedDocumentID || model === self.current {
        views[model.id] = try model.captureTransferView(preparation: transferPreparation)
      }
    }
    guard models.allSatisfy({ model in receipt.models.contains(where: { $0 === model }) }) else {
      throw NativeDocumentTransferError.changed
    }
    let result = replacementTransferReceipt(receipt, endpointID: endpointID)
    settledTransferProjection = result
    defer { settledTransferProjection = nil }
    try applyRegistryProjection(expected, revision: revision, endpointID: endpointID)
    try validateRegistryProjection(expected, revision: revision, endpointID: endpointID)
    for model in receipt.models {
      guard try model.captureTransferState(preparation: transferPreparation) == states[model.id]
      else {
        throw NativeDocumentTransferError.changed
      }
      if let view = views[model.id], let state = states[model.id] {
        // Current selection/pending presentation are preserved; no original transfer geometry is restored.
        try model.validateTransferView(
          transferViewWithLiveOrigins(view, model: model),
          expectedState: state, preparation: transferPreparation)
      }
    }
    result.projected = expected
    return result
  }
}
