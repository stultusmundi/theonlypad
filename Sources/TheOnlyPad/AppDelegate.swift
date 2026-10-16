import AppKit
import PadCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  // One lazy process search bridge and one owned application termination attempt.
  typealias DocumentSearchPanelFactory =
    @MainActor (
      ApplicationSearchOwner, ApplicationSearchWindowID,
      any ApplicationDocumentSearchSource,
      @escaping @MainActor (DocumentSearchPanelController) -> Void
    ) throws -> DocumentSearchPanelController
  private let documentSearches: NativeApplicationSearches
  private let cancelExternalCommands: @MainActor () async -> Void
  private let makeDocumentSearchPanel: DocumentSearchPanelFactory
  private let presentDocumentSearchPanel: @MainActor (DocumentSearchPanelController) -> Void
  @MainActor private final class DocumentSearchTerminationAttempt {
    let id = UUID()
    var task: Task<Void, Never>?
    var preparation: NativeApplicationSearchQuitPreparation?
    var catalogPreparation: LanguageCatalogQuitPreparation?
    var nativeReceipt: SessionCheckpointReceipt?
    var searchDecision: NativeApplicationSearchQuitResult?
    var replyConsumed = false
    var setupError: Error?
    private var setupReturned = false
    private var setupContinuation: CheckedContinuation<Void, Never>?

    func waitForSetupReturn() async {
      guard !setupReturned else { return }
      await withCheckedContinuation { continuation in
        if self.setupReturned {
          continuation.resume()
        } else {
          self.setupContinuation = continuation
        }
      }
    }
    func setupDidReturn() {
      guard !setupReturned else { return }
      setupReturned = true
      let continuation = setupContinuation
      setupContinuation = nil
      continuation?.resume()
    }
  }
  @MainActor private enum LanguageCatalogQuitPreparation {
    case notCreated
    case reserved(owner: NativeLanguageCatalogOwner, quitID: UUID)
  }
  private enum ApplicationLanguageCatalogError: LocalizedError {
    case quitRefused(NativeLanguageCatalogMutationRefusal)
    case staleQuitPreparation

    var errorDescription: String? {
      switch self {
      case .quitRefused:
        return
          "The language catalog is busy or has an unresolved change. Wait for its operation or resolve the change before quitting."
      case .staleQuitPreparation:
        return
          "The language catalog changed while preparing to quit. Review its current state and try Quit again."
      }
    }
  }
  private var languageCatalogOwner: NativeLanguageCatalogOwner?
  private var languageCatalogState: NativeLanguageCatalogState?
  private var lastReportedLanguageCatalogFailureID: UUID?
  private var documentSearchTerminationAttempt: DocumentSearchTerminationAttempt?
  private var editors: [EditorWindowController] { documentOwner?.windows ?? [] }
  private var moveDestination: DocumentMoveDestinationController?
  private var movePresentationGeneration = UUID()
  private let presentMoveDestination: @MainActor (DocumentMoveDestinationController) -> Void
  private var palette: CommandPaletteController?
  private var registry = CommandRegistry()
  private var shortcutController: ApplicationShortcutController?
  private var shortcutRegistryReady = false
  private var commandKeyPublication = 0
  private var publishedCommandKeys: [String: PublishedCommandKey] = [:]
  private var preparingQuit = false
  private var preferences: PreferencesController?
  private var settings = EditorSettings.defaults
  private var largeViewers: [LargeFileWindowController] = []
  private var macroManager: MacroManagerController?
  private var externalCommands: [ExternalCommandController] = []
  private var extensionManager: ExtensionManagerController?
  private var extensionCommands: [String: EnabledExtensionCommand] = [:]
  private var extensionGeneration = 0
  private var help: HelpController?
  private let session: SessionCoordinator
  private let documentRecovery: RecoveryCoordinator
  private let presentEditorWindow: @MainActor (EditorWindowController) -> Void
  private let reportDocumentError: @MainActor (Error) -> Void
  private let replyToTermination: @MainActor (Bool) -> Void
  private let presentSessionAdjustment: @MainActor () -> Void
  private var documentOwner: NativeApplicationDocuments?

  override convenience init() {
    self.init(
      session: SessionCoordinator(), recovery: .shared,
      presentEditorWindow: { $0.showWindow(nil) },
      reportDocumentError: { NSAlert(error: $0).runModal() })
  }
  init(
    session: SessionCoordinator, recovery: RecoveryCoordinator,
    documentSearches: NativeApplicationSearches? = nil,
    languageCatalogOwner: NativeLanguageCatalogOwner? = nil,
    cancelExternalCommands: @escaping @MainActor () async -> Void = {
      await ExternalCommandController.cancelAllAndWait()
    },
    makeDocumentSearchPanel: @escaping DocumentSearchPanelFactory = {
      owner, ticket, source, onClose in
      try DocumentSearchPanelController(
        owner: owner, window: ticket, source: source, onClose: onClose)
    },
    presentDocumentSearchPanel: @escaping @MainActor (DocumentSearchPanelController) -> Void = {
      $0.showWindow(nil)
    },
    presentEditorWindow: @escaping @MainActor (EditorWindowController) -> Void,
    reportDocumentError: @escaping @MainActor (Error) -> Void,
    presentMoveDestination: @escaping @MainActor (DocumentMoveDestinationController) -> Void = {
      $0.showWindow(nil)
    },
    replyToTermination: @escaping @MainActor (Bool) -> Void = {
      NSApp.reply(toApplicationShouldTerminate: $0)
    },
    presentSessionAdjustment: @escaping @MainActor () -> Void = {
      let alert = NSAlert()
      alert.messageText = "Saved positions adjusted"
      alert.informativeText =
        "The loaded file differs from its saved positions. Pane selections were clamped where needed and invalid bookmarks were omitted."
      alert.runModal()
    }
  ) {
    self.documentSearches =
      documentSearches ?? NativeApplicationSearches(applicationBundle: Bundle.main.bundleURL)
    self.languageCatalogOwner = languageCatalogOwner
    self.cancelExternalCommands = cancelExternalCommands
    self.makeDocumentSearchPanel = makeDocumentSearchPanel
    self.presentDocumentSearchPanel = presentDocumentSearchPanel
    self.session = session
    self.documentRecovery = recovery
    self.presentEditorWindow = presentEditorWindow
    self.reportDocumentError = reportDocumentError
    self.presentMoveDestination = presentMoveDestination
    self.replyToTermination = replyToTermination
    self.presentSessionAdjustment = presentSessionAdjustment
    super.init()
    if let languageCatalogOwner {
      languageCatalogState = languageCatalogOwner.state
      observeLanguageCatalog(languageCatalogOwner)
    }
  }
  private static var defaultLanguageCatalogDirectory: URL {
    SettingsStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent(
      "Languages", isDirectory: true)
  }
  @discardableResult
  private func startLanguageCatalogIfNeeded() -> NativeLanguageCatalogAdmission? {
    guard !preparingQuit else { return nil }
    let owner: NativeLanguageCatalogOwner
    if let existing = languageCatalogOwner {
      owner = existing
    } else {
      owner = NativeLanguageCatalogOwner(
        store: CustomLanguageStore(directory: Self.defaultLanguageCatalogDirectory))
      languageCatalogOwner = owner
      languageCatalogState = owner.state
      observeLanguageCatalog(owner)
    }
    let state = owner.state
    guard case .active = state.lifetime, state.activeRequestID == nil,
      state.current == nil, state.lastSettledRequestID == nil
    else { return nil }
    return owner.requestLoad()
  }

  private func observeLanguageCatalog(_ owner: NativeLanguageCatalogOwner) {
    owner.onChange = { [weak self, weak owner] state in
      guard let self, let owner, self.languageCatalogOwner === owner else { return }
      self.acceptLanguageCatalogState(state, from: owner)
    }
  }

  private func acceptLanguageCatalogState(
    _ state: NativeLanguageCatalogState, from owner: NativeLanguageCatalogOwner
  ) {
    guard languageCatalogOwner === owner else { return }
    languageCatalogState = state
    guard case .active = state.lifetime, !preparingQuit, let failure = state.failure,
      lastReportedLanguageCatalogFailureID != failure.requestID
    else { return }
    lastReportedLanguageCatalogFailureID = failure.requestID
    reportDocumentError(
      NSError(
        domain: "TheOnlyPad.LanguageCatalog", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The language catalog operation failed. The last confirmed catalog remains available. Review the catalog before retrying the operation.",
          NSUnderlyingErrorKey: failure.underlyingError,
        ]))
    // Error presentation may admit a new operation. Its observer owns all later state.
  }

  private func prepareLanguageCatalogForQuit() throws -> LanguageCatalogQuitPreparation {
    guard preparingQuit else { throw ApplicationLanguageCatalogError.staleQuitPreparation }
    guard let owner = languageCatalogOwner else { return .notCreated }
    switch owner.prepareQuit() {
    case .prepared(let id): return .reserved(owner: owner, quitID: id)
    case .refused(let refusal): throw ApplicationLanguageCatalogError.quitRefused(refusal)
    }
  }

  private func languageCatalogPreparationIsCurrent(
    _ preparation: LanguageCatalogQuitPreparation
  ) -> Bool {
    switch preparation {
    case .notCreated: return languageCatalogOwner == nil
    case .reserved(let owner, let id):
      guard languageCatalogOwner === owner, case .active = owner.state.lifetime else {
        return false
      }
      let state = owner.mutationState
      return state.preparedQuitID == id && state.activeOperation == nil && state.unresolved == nil
    }
  }

  private func resumeLanguageCatalogAfterVeto(
    _ preparation: LanguageCatalogQuitPreparation
  ) -> Bool {
    guard languageCatalogPreparationIsCurrent(preparation) else { return false }
    switch preparation {
    case .notCreated: return true
    case .reserved(let owner, let id): return owner.cancelPreparedQuit(id)
    }
  }

  private func invalidateLanguageCatalogAndWait(
    _ preparation: LanguageCatalogQuitPreparation
  ) async {
    if case .reserved(let owner, _) = preparation { await owner.invalidateAndWait() }
  }

  private func managedDocuments() throws -> NativeApplicationDocuments {
    if let documentOwner { return documentOwner }
    let owner = try NativeApplicationDocuments(
      session: session, recovery: documentRecovery, monitoring: fileMonitoring,
      onWindowCreated: { [weak self] in self?.presentEditorWindow($0) },
      configureWindow: { [weak self] in self?.configureEditor($0) },
      onError: { [weak self] in self?.reportDocumentError($0) },
      openLargeFile: { [weak self] request in
        guard let self else { throw CancellationError() }
        try self.openLargeFile(request)
      })
    documentOwner = owner
    return owner
  }
  private func startManagedDocuments() async throws {
    try await managedDocuments().start()
    // Activation intentionally blocks early settings changes on newly restored models.
    applySettings(settings)
  }
  private func enqueueLaunchRequests(_ requests: [LaunchRequest]) {
    guard !requests.isEmpty else { return }
    guard !preparingQuit else {
      reportDocumentError(
        Self.documentFlowError(
          "Files were not opened because the application is preparing to quit. Try again after cancelling Quit."
        ))
      return
    }
    do {
      let admission = try managedDocuments().enqueueExternal(requests)
      if admission.rejectedOverflowCount > 0 {
        reportDocumentError(
          Self.documentFlowError(
            "The open queue is full. \(admission.rejectedOverflowCount) file requests were not queued; open them again after the current batch finishes."
          ))
      }
      if admission.rejectedQuittingCount > 0 {
        reportDocumentError(
          Self.documentFlowError(
            "Files were not queued because the application is preparing to quit. Try again after cancelling Quit."
          ))
      }
    } catch { reportDocumentError(error) }
  }
  private static func documentFlowError(_ message: String) -> NSError {
    NSError(domain: "TheOnlyPad.Documents", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private var startupTask: Task<Void, Never>?
  private var sessionPanel: SessionRestorationController?
  private var repairAttempts: [UUID: UUID] = [:]
  private var repairTargets: [UUID: EditorWindowController] = [:]
  private var recentFiles: RecentFilesController?
  private lazy var fileMonitoring: ApplicationFileMonitoring = {
    let owner = ApplicationFileMonitoring()
    owner.onStateChange = { [weak self] in
      for editor in self?.editors ?? [] { editor.reconcileFileMonitoring() }
    }
    return owner
  }()
  private var fileMonitoringNotifications: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    do { registry = try AppCommands.registry() } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
      return
    }
    let shortcutOwner = ApplicationShortcuts(
      services: ShortcutServices(store: ShortcutStore()), catalog: registry.commands)
    let shortcuts = ApplicationShortcutController(
      owner: shortcutOwner, isPreparingQuit: { [weak self] in self?.preparingQuit ?? true },
      publish: { [weak self] state in self?.publishShortcuts(state) })
    shortcutController = shortcuts
    publishShortcuts(shortcuts.state)
    shortcuts.start { [weak self] in self?.refreshExtensionCommands() }
    for name in [
      NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification,
      NSWorkspace.didUnmountNotification,
    ] {
      fileMonitoringNotifications.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        {
          [weak self] _ in
          Task { @MainActor [weak self] in self?.fileMonitoring.reconcile() }
        })
    }
    startLanguageCatalogIfNeeded()
    restoreStartupSession()
    do {
      let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
      let requests = try LaunchRequest.parse(
        arguments: arguments,
        workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
      enqueueLaunchRequests(requests)
    } catch { NSAlert(error: error).runModal() }
    Task {
      do {
        let loaded = try await Task.detached {
          try SettingsStore(directory: SettingsStore.defaultDirectory).load()
        }.value
        applySettings(loaded)
      } catch { NSAlert(error: error).runModal() }
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  @discardableResult
  private func newWindow(createDocument: Bool = true) -> EditorWindowController? {
    do {
      let editor = try managedDocuments().createWindow(createDocument: createDocument)
      editor.applySettings(settings)
      return editor
    } catch {
      reportDocumentError(error)
      return nil
    }
  }
  private func configureEditor(_ editor: EditorWindowController) {
    editor.configureManagedDocumentSearch(
      ownerForFind: { [weak self] in
        guard let self, !self.preparingQuit else {
          throw ApplicationDocumentSearchFailure.sourceUnavailable
        }
        return try self.documentSearches.ownerForFind()
      },
      makePanel: { [weak self] owner, ticket, source, onClose in
        guard let self, !self.preparingQuit else {
          throw ApplicationDocumentSearchFailure.sourceUnavailable
        }
        return try self.makeDocumentSearchPanel(owner, ticket, source, onClose)
      },
      presentPanel: { [weak self] panel in
        guard let self, !self.preparingQuit else {
          panel.close()
          return
        }
        self.presentDocumentSearchPanel(panel)
      })
    editor.applySettings(settings)
    editor.onOpenedURL = { [weak self] url in
      guard let self else { return }
      do {
        try self.session.recordRecentOpen(url)
        self.recentFiles?.refreshPresentation(
          paths: self.session.recentPaths, openedPath: url.standardizedFileURL.path)
      } catch { self.reportDocumentError(error) }
    }
    editor.onOpenLargeFile = { [weak self] url in
      guard let self else { return }
      do { try self.openLargeFile(.init(url: url)) } catch { self.reportDocumentError(error) }
    }
  }
  private func openLargeFile(_ request: LaunchRequest) throws {
    guard !preparingQuit else { throw CancellationError() }
    guard request.line == 1, request.column == 1 else {
      throw Self.documentFlowError(
        "Line and column navigation is not supported in the large-file viewer. Open this file without a position to view it."
      )
    }
    let viewer = LargeFileWindowController(url: request.url)
    largeViewers.append(viewer)
    viewer.onClose = { [weak self, weak viewer] in self?.largeViewers.removeAll { $0 === viewer } }
    viewer.showWindow(nil)
  }
  private func requireCommandEditor() -> EditorWindowController? {
    guard let editor = activeEditor ?? newWindow() else { return nil }
    guard editor.selectedDocumentID != nil else {
      reportDocumentError(
        Self.documentFlowError("Finish opening the document, then run this command again."))
      return nil
    }
    return editor
  }
  private func restoreStartupSession() {
    guard startupTask == nil else { return }
    startupTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.startManagedDocuments()
        guard !self.preparingQuit else { return }
        if !self.session.unresolved.isEmpty { self.showUnresolvedSession() }
        let notices = self.session.startupErrors + self.session.warnings
        if !notices.isEmpty {
          self.reportDocumentError(Self.documentFlowError(notices.joined(separator: "\n\n")))
        }
      } catch { self.reportDocumentError(error) }
    }
  }

  private func showUnresolvedSession() {
    if let sessionPanel {
      sessionPanel.refreshPresentation(entries: session.unresolved)
      sessionPanel.showWindow(nil)
      return
    }
    makeSessionPanel().showWindow(nil)
  }
  private func makeSessionPanel() -> SessionRestorationController {
    weak var originatingPanel: SessionRestorationController?
    let controller = SessionRestorationController(
      entries: session.unresolved,
      onRetry: { [weak self] entry in
        guard let self, !self.preparingQuit, let panel = originatingPanel,
          self.sessionPanel === panel
        else { throw CancellationError() }
        self.repairAttempts[entry.metadata.id] = UUID()
        self.repairTargets[entry.metadata.id] = self.editors.first {
          $0.sessionMetadata.id == entry.windowID
        }
        return try await self.session.retry(entry)
      },
      onLocate: { [weak self] entry, url in
        guard let self, !self.preparingQuit, let panel = originatingPanel,
          self.sessionPanel === panel
        else { throw CancellationError() }
        self.repairAttempts[entry.metadata.id] = UUID()
        self.repairTargets[entry.metadata.id] = self.editors.first {
          $0.sessionMetadata.id == entry.windowID
        }
        return try await self.session.locate(entry, url: url)
      },
      onResolved: { [weak self] entry, file in
        guard let self, !self.preparingQuit, let panel = originatingPanel,
          self.sessionPanel === panel, let attempt = self.repairAttempts[entry.metadata.id],
          let state = file.resolvedViewState,
          file.resolvedPresentation != nil
            || entry.metadata.presentation == .single(selection: entry.metadata.selection)
        else {
          throw CancellationError()
        }
        if let target = self.repairTargets[entry.metadata.id],
          !self.editors.contains(where: { $0 === target })
        {
          throw CancellationError()
        }
        try await self.managedDocuments().acceptSession(entry, file: file)
        let completedCurrentAttempt = self.repairAttempts[entry.metadata.id] == attempt
        if completedCurrentAttempt {
          self.repairTargets[entry.metadata.id] = nil
          self.repairAttempts[entry.metadata.id] = nil
        }
        if completedCurrentAttempt, !self.preparingQuit, self.sessionPanel === panel,
          state.selectionAdjusted || !state.invalidBookmarks.isEmpty
            || file.resolvedPresentation?.adjustedPaneIndices.isEmpty == false
        {
          self.presentSessionAdjustment()
        }
      },
      onRemove: { [weak self] entry in
        guard let self, !self.preparingQuit, let panel = originatingPanel,
          self.sessionPanel === panel
        else { throw CancellationError() }
        let attempt = UUID()
        self.repairAttempts[entry.metadata.id] = attempt
        try await self.session.remove(entry)
        if self.repairAttempts[entry.metadata.id] == attempt {
          self.repairTargets[entry.metadata.id] = nil
          self.repairAttempts[entry.metadata.id] = nil
        }
      })
    controller.onClose = { [weak self] in
      guard let self, let panel = originatingPanel, self.sessionPanel === panel else { return }
      self.sessionPanel = nil
      self.repairTargets.removeAll()
      self.repairAttempts.removeAll()
    }
    originatingPanel = controller
    sessionPanel = controller
    return controller
  }

  private func showRecentFiles() {
    guard session.restorationComplete else { return }
    if let recentFiles {
      recentFiles.refreshPresentation(paths: session.recentPaths)
      recentFiles.showWindow(nil)
      return
    }
    guard let target = activeEditor ?? newWindow(createDocument: false) else { return }
    let controller = RecentFilesController(
      paths: session.recentPaths,
      onOpen: { [weak self, weak target] url, isCurrent in
        guard let self, !self.preparingQuit, isCurrent() else { throw CancellationError() }
        guard let target, self.editors.contains(where: { $0 === target }) else {
          throw Self.recentTargetClosedError()
        }
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          target.open(
            url,
            shouldAccept: { [weak self, weak target] in
              guard let self, let target else { return false }
              return !self.preparingQuit && self.editors.contains(where: { $0 === target })
                && isCurrent()
            },
            onFailure: { [weak self, weak target] error in
              guard let self, let target, self.editors.contains(where: { $0 === target }) else {
                continuation.resume(throwing: Self.recentTargetClosedError())
                return
              }
              continuation.resume(throwing: error)
            }, onOpened: { continuation.resume() }
          )
        }
      },
      onRemove: { [weak self] path in
        guard let self, !self.preparingQuit else { return }
        self.session.removeRecent(path)
      },
      onClear: { [weak self] in
        guard let self, !self.preparingQuit else { return }
        self.session.clearRecent()
      })
    controller.onClose = { [weak self] in self?.recentFiles = nil }
    recentFiles = controller
    controller.showWindow(nil)
  }

  private static func recentTargetClosedError() -> NSError {
    NSError(
      domain: "TheOnlyPad.RecentFiles", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The target editor window is closed. Reopen Recent Files from another editor window."
      ])
  }

  private var activeEditor: EditorWindowController? {
    editors.first { $0.window === NSApp.keyWindow }
      ?? editors.first { $0.window === NSApp.mainWindow }
      ?? editors.last
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    var requests: [LaunchRequest] = []
    for url in urls.prefix(128) {
      do {
        requests.append(url.isFileURL ? .init(url: url) : try LaunchRequest.parse(url: url))
      } catch { reportDocumentError(error) }
    }
    enqueueLaunchRequests(requests)
    if urls.count > 128 {
      reportDocumentError(
        Self.documentFlowError(
          "Only the first 128 incoming file requests were considered. Open the remaining files in a separate batch."
        ))
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    guard !preparingQuit else { return false }
    if !flag { newWindow() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !preparingQuit, documentSearchTerminationAttempt == nil else { return .terminateLater }
    movePresentationGeneration = UUID()
    guard shortcutController?.canQuit != false else {
      shortcutController?.explainQuitVeto()
      return .terminateCancel
    }
    let originalEditors = editors
    let attempt = DocumentSearchTerminationAttempt()
    documentSearchTerminationAttempt = attempt
    preparingQuit = true
    // Even nested modal/run-loop execution can only await this exact setup frame's return.
    defer { attempt.setupDidReturn() }
    attempt.task = Task { [self, attempt] in
      await attempt.waitForSetupReturn()
      await completeDocumentSearchTermination(attempt)
    }
    do {
      let catalogPreparation = try prepareLanguageCatalogForQuit()
      attempt.catalogPreparation = catalogPreparation
      guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
      let preparation = try documentSearches.prepareQuitIfCreated()
      guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
      attempt.preparation = preparation
      for editor in originalEditors {
        editor.retireManagedDocumentSearchForQuit()
        guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
      }
      let previousMoveDestination = moveDestination
      moveDestination = nil
      previousMoveDestination?.close()
      guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
      fileMonitoring.suspend()
      guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
      recentFiles?.setSuspended(true)
      guard ownsDocumentSearchTermination(attempt) else { return .terminateLater }
    } catch {
      if ownsDocumentSearchTermination(attempt) { attempt.setupError = error }
    }
    return .terminateLater
  }

  private func ownsDocumentSearchTermination(_ attempt: DocumentSearchTerminationAttempt) -> Bool {
    documentSearchTerminationAttempt === attempt && preparingQuit && !attempt.replyConsumed
  }

  private func completeDocumentSearchTermination(_ attempt: DocumentSearchTerminationAttempt) async
  {
    guard ownsDocumentSearchTermination(attempt) else { return }
    do {
      if let error = attempt.setupError { throw error }
      guard let preparation = attempt.preparation else { throw NativeWorkspaceError.notReady }
      guard let catalogPreparation = attempt.catalogPreparation,
        languageCatalogPreparationIsCurrent(catalogPreparation)
      else { throw ApplicationLanguageCatalogError.staleQuitPreparation }
      await startupTask?.value
      guard ownsDocumentSearchTermination(attempt) else { return }
      try Task.checkCancellation()
      sessionPanel?.update(entries: session.unresolved)
      guard ownsDocumentSearchTermination(attempt) else { return }
      guard languageCatalogPreparationIsCurrent(catalogPreparation) else {
        throw ApplicationLanguageCatalogError.staleQuitPreparation
      }
      let decision = try await documentSearches.completeQuit(preparation) { [self, attempt] in
        guard ownsDocumentSearchTermination(attempt) else { throw CancellationError() }
        guard languageCatalogPreparationIsCurrent(catalogPreparation) else {
          throw ApplicationLanguageCatalogError.staleQuitPreparation
        }
        let owner = try managedDocuments()
        guard ownsDocumentSearchTermination(attempt) else { throw CancellationError() }
        let receipt = try await owner.prepareQuit()
        guard ownsDocumentSearchTermination(attempt), documentOwner === owner else {
          throw CancellationError()
        }
        // Only the actual native producer's return can fill this authority-bearing field.
        attempt.nativeReceipt = receipt
        guard languageCatalogPreparationIsCurrent(catalogPreparation) else {
          throw ApplicationLanguageCatalogError.staleQuitPreparation
        }
      }
      guard ownsDocumentSearchTermination(attempt) else { return }
      attempt.searchDecision = decision
      guard attempt.nativeReceipt != nil else { throw NativeWorkspaceError.notReady }
      let settled: Bool
      switch decision {
      case .noSearchOwner: settled = true
      case .terminal(_, _, _, .settled): settled = true
      case .terminal(_, _, _, .unsettled), .admissionRefused(_): settled = false
      }
      guard settled else {
        refuseDocumentSearchTermination(attempt, error: nil)
        return
      }
      try Task.checkCancellation()
      guard languageCatalogPreparationIsCurrent(catalogPreparation) else {
        throw ApplicationLanguageCatalogError.staleQuitPreparation
      }
      // Commit: neither catalog retirement nor the permanent external drain can be rolled back.
      await invalidateLanguageCatalogAndWait(catalogPreparation)
      guard ownsDocumentSearchTermination(attempt) else { return }
      if case .reserved(let owner, _) = catalogPreparation, languageCatalogOwner === owner {
        languageCatalogState = owner.state
      }
      await cancelExternalCommands()
      guard ownsDocumentSearchTermination(attempt) else { return }
      attempt.replyConsumed = true
      replyToTermination(true)
      // No mutation after the reply callout; a successful attempt remains reserved.
    } catch {
      guard ownsDocumentSearchTermination(attempt) else { return }
      refuseDocumentSearchTermination(attempt, error: error)
    }
  }

  private func refuseDocumentSearchTermination(
    _ attempt: DocumentSearchTerminationAttempt, error: Error?
  ) {
    guard ownsDocumentSearchTermination(attempt) else { return }
    if let error {
      reportDocumentError(error)
      guard ownsDocumentSearchTermination(attempt) else { return }
    }
    // Native prepareQuit rolls back its own throwing paths. A returned receipt leaves
    // a real prepared owner which this attempt must explicitly restore on later refusal.
    if attempt.nativeReceipt != nil {
      documentOwner?.cancelPreparedQuit()
      guard ownsDocumentSearchTermination(attempt) else { return }
    }
    if let preparation = attempt.preparation, documentSearches.phase == .prepared {
      // A refused resume stays honestly unavailable/prepared; terminal custody is never reopened.
      let resumed = documentSearches.resumeAfterVeto(preparation)
      guard ownsDocumentSearchTermination(attempt) else { return }
      if case .refused(let refusal) = resumed {
        reportDocumentError(refusal)
        guard ownsDocumentSearchTermination(attempt) else { return }
      }
    }
    if let preparation = attempt.catalogPreparation {
      let resumed = resumeLanguageCatalogAfterVeto(preparation)
      guard ownsDocumentSearchTermination(attempt) else { return }
      if !resumed {
        reportDocumentError(ApplicationLanguageCatalogError.staleQuitPreparation)
        guard ownsDocumentSearchTermination(attempt) else { return }
      }
    }
    fileMonitoring.resume()
    guard ownsDocumentSearchTermination(attempt) else { return }
    recentFiles?.setSuspended(false)
    guard ownsDocumentSearchTermination(attempt) else { return }
    preparingQuit = false
    attempt.replyConsumed = true
    documentSearchTerminationAttempt = nil
    replyToTermination(false)
    // The false-reply callback may already own a new attempt. Never clear it here.
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    fileMonitoring.reconcile()
  }

  func applicationWillTerminate(_ notification: Notification) {
    fileMonitoring.stop()
    for observer in fileMonitoringNotifications {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    fileMonitoringNotifications.removeAll()
  }

  @objc private func command(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    guard
      !NativeCommandKeyAdmission.shouldReject(
        sender: sender, snapshot: publishedCommandKeys[id], publication: commandKeyPublication,
        scopedEvent: (NSApp as? CommandDispatchApplication)?.keyboardDispatchEvent,
        currentEvent: NSApp.currentEvent
      )
    else { return }
    dispatch(id)
  }

  private func dispatchCapturedDocumentSearchCommand(
    _ id: String, capturedWindow: NSWindow?,
    sendNativeAction: @MainActor (Selector, Any?) -> Bool = { action, sender in
      NSApp.sendAction(action, to: nil, from: sender)
    }
  ) -> Bool {
    guard let capturedWindow,
      let panel = capturedWindow.windowController as? DocumentSearchPanelController,
      panel.window === capturedWindow
    else { return false }
    if id == "file.close" {
      panel.close()
    } else if let action = Self.nativeEditingActions[id] {
      _ = sendNativeAction(action, self)
    }
    return true  // Exact search scope is claimed even for refusal or no native responder.
  }
  private func capturedDocumentSearchCommandAvailability(_ id: String, capturedWindow: NSWindow?)
    -> Bool?
  {
    guard let capturedWindow,
      let panel = capturedWindow.windowController as? DocumentSearchPanelController,
      panel.window === capturedWindow
    else { return nil }
    return id == "file.close" || Self.nativeEditingActions[id] != nil
  }
  private func dispatchDocumentSearchCapturedThroughGuards(
    _ id: String, capturedWindow: NSWindow?,
    sendNativeAction: @MainActor (Selector, Any?) -> Bool
  ) -> Bool {
    guard !preparingQuit, id != "app.shortcuts", shortcutRegistryReady,
      registry.commands.contains(where: { $0.id == id })
    else { return false }
    return dispatchCapturedDocumentSearchCommand(
      id, capturedWindow: capturedWindow, sendNativeAction: sendNativeAction)
  }
  private func documentSearchCapturedAvailabilityThroughGuards(
    _ id: String, capturedWindow: NSWindow?
  ) -> Bool? {
    guard !preparingQuit else { return false }
    if id == "app.shortcuts" { return shortcutController != nil }
    guard shortcutRegistryReady, registry.commands.contains(where: { $0.id == id }) else {
      return false
    }
    return capturedDocumentSearchCommandAvailability(id, capturedWindow: capturedWindow)
  }

  private static let nativeEditingActions: [String: Selector] = [
    "edit.undo": Selector(("undo:")), "edit.redo": Selector(("redo:")),
    "edit.cut": #selector(NSText.cut(_:)), "edit.copy": #selector(NSText.copy(_:)),
    "edit.paste": #selector(NSText.paste(_:)), "edit.selectAll": #selector(NSText.selectAll(_:)),
  ]

  /// Claims the exact tool scope even when a command or native responder is unavailable.
  private func dispatchCapturedPreviewCommand(
    _ id: String, capturedWindow: NSWindow?,
    sendNativeAction: @MainActor (Selector, Any?) -> Bool = { action, sender in
      NSApp.sendAction(action, to: nil, from: sender)
    }
  ) -> Bool {
    guard let capturedWindow,
      let preview = capturedWindow.windowController as? FolderReplacementPreviewController,
      preview.window === capturedWindow
    else { return false }
    if id == "file.close" {
      preview.close()
    } else if let action = Self.nativeEditingActions[id] {
      _ = sendNativeAction(action, self)
    }
    return true
  }

  private func capturedPreviewCommandAvailability(
    _ id: String, capturedWindow: NSWindow?
  ) -> Bool? {
    guard let capturedWindow,
      let preview = capturedWindow.windowController as? FolderReplacementPreviewController,
      preview.window === capturedWindow
    else { return nil }
    return id == "file.close" || Self.nativeEditingActions[id] != nil
  }

  private func dispatch(_ id: String) {
    guard !preparingQuit else { return }
    if id == "app.shortcuts" {
      shortcutController?.showEditor()
      return
    }
    guard shortcutRegistryReady, registry.commands.contains(where: { $0.id == id }) else { return }
    let commandWindow = NSApp.keyWindow
    if dispatchDocumentSearchCapturedThroughGuards(
      id, capturedWindow: commandWindow,
      sendNativeAction: { action, sender in NSApp.sendAction(action, to: nil, from: sender) })
    {
      return
    }
    if dispatchCapturedPreviewCommand(id, capturedWindow: commandWindow) { return }
    if let viewer = NSApp.keyWindow?.windowController as? LargeFileWindowController {
      if id == "file.close" {
        viewer.close()
        return
      }
      if !Self.largeViewerCommands.contains(id) { return }
    }
    if let action = Self.nativeEditingActions[id] {
      NSApp.sendAction(action, to: nil, from: self)
      return
    }
    switch id {
    case "file.retrySession":
      Task { [weak self] in
        guard let self, !self.preparingQuit else { return }
        do {
          try await self.managedDocuments().retryRecovery()
          self.applySettings(self.settings)
        } catch { self.reportDocumentError(error) }
      }
    case "file.recent":
      Task { [weak self] in
        await self?.startupTask?.value
        guard let self, !self.preparingQuit else { return }
        self.showRecentFiles()
      }
    case "file.restoreSession": showUnresolvedSession()
    case "app.help":
      help?.close()
      let controller = HelpController(commands: registry.commands)
      help = controller
      controller.showWindow(nil)
    case "tool.extensions":
      extensionManager?.close()
      guard let editor = requireCommandEditor() else { return }
      let manager = ExtensionManagerController { [weak editor] _, transform in
        guard let editor, editor.window?.isVisible == true else {
          let alert = NSAlert()
          alert.messageText = "The target editor window is closed"
          alert.informativeText =
            "Open extension management from the editor window you want to change."
          alert.runModal()
          return
        }
        editor.execute("edit." + transform.rawValue)
      }
      manager.onChanged = { [weak self] in self?.refreshExtensionCommands() }
      extensionManager = manager
      manager.showWindow(nil)
    case "tool.externalCommand":
      guard let editor = requireCommandEditor() else { return }
      do {
        let controller = ExternalCommandController(context: try editor.externalCommandContext())
        externalCommands.append(controller)
        controller.onClose = { [weak self, weak controller] in
          self?.externalCommands.removeAll { $0 === controller }
        }
        controller.showWindow(nil)
      } catch { NSAlert(error: error).runModal() }
    case "macro.manage":
      macroManager?.close()
      guard let editor = requireCommandEditor() else { return }
      let manager = MacroManagerController { [weak editor] macro, count in
        guard let editor, editor.window?.isVisible == true else {
          let alert = NSAlert()
          alert.messageText = "The target editor window is closed"
          alert.informativeText =
            "Open macro management from an editor window to select a new target."
          alert.runModal()
          return
        }
        editor.replay(macro, repeatCount: count)
      }
      manager.onCancel = { [weak editor] in editor?.cancelMacroReplay() }
      macroManager = manager
      manager.showWindow(nil)
    case "app.preferences":
      if let preferences {
        preferences.showWindow(nil)
      } else {
        let controller = PreferencesController { [weak self] settings in
          self?.applySettings(settings)
        }
        controller.onShowShortcuts = { [weak self] in self?.dispatch("app.shortcuts") }
        controller.updateShortcutAttention(shortcutController?.needsAttention == true)
        preferences = controller
        controller.showWindow(nil)
      }
    case "file.reopenClosed":
      guard let editor = activeEditor, editor.isCommandAvailable(id) else {
        reportDocumentError(
          Self.documentFlowError("There is no closed document available in this window."))
        return
      }
      editor.execute(id)
    case "file.moveToWindow": showMoveDestination()
    case "file.newWindow": newWindow()
    case "view.palette":
      palette?.close()
      let panel = CommandPaletteController(commands: registry.commands) { [weak self] id in
        self?.dispatch(id)
      }
      palette = panel
      panel.showWindow(nil)
    default:
      if let command = extensionCommands[id] {
        guard let editor = requireCommandEditor() else { return }
        let documentID = editor.selectedDocumentID
        let shortcutRevision = shortcutController?.state.catalogRevision
        Task { [weak self, weak editor] in
          do {
            let enabled = try await Task.detached {
              try ExtensionCatalog(directory: ExtensionCatalog.defaultDirectory).enabledCommands()
            }.value
            guard let self, !self.preparingQuit, let editor, self.shortcutRegistryReady,
              self.shortcutController?.state.catalogRevision == shortcutRevision
            else { return }
            guard let current = enabled.first(where: { $0.id == command.id }),
              current == command
            else { throw ExtensionCatalogError.missing }
            guard editor.window?.isVisible == true, editor.selectedDocumentID == documentID else {
              throw NSError(
                domain: "TheOnlyPad", code: 10,
                userInfo: [
                  NSLocalizedDescriptionKey:
                    "The target document changed. Select the intended document and run the extension command again."
                ])
            }
            editor.execute("edit." + current.transform.rawValue)
          } catch { NSAlert(error: error).runModal() }
        }
      } else if !id.hasPrefix("extension.") {
        let createsOrOpens = ["file.new", "file.open", "file.openEncoding", "file.openFolder"]
          .contains(id)
        let editor =
          createsOrOpens
          ? (activeEditor ?? newWindow(createDocument: false)) : requireCommandEditor()
        editor?.execute(id)
      }
    }
  }

  private func showMoveDestination() {
    movePresentationGeneration = UUID()
    moveDestination?.close()
    moveDestination = nil
    do {
      guard let owner = documentOwner, let documentID = activeEditor?.selectedDocumentID else {
        throw Self.documentFlowError("Select an editable document to move.")
      }
      var choices = try owner.prepareMove(documentID: documentID)
      choices.newWindowRefusalReason = owner.newWindowMoveRefusalReason()
      weak var originating: DocumentMoveDestinationController?
      let chooser = DocumentMoveDestinationController(
        choices: choices,
        onChoose: { [weak self, weak owner] target in
          guard let self, let owner, self.documentOwner === owner, !self.preparingQuit,
            let originating, self.moveDestination === originating
          else { return }
          self.moveDestination = nil
          do {
            let generation = UUID()
            self.movePresentationGeneration = generation
            let waitForDestination: () async throws -> NativeDocumentMoveDestination
            switch target {
            case .existing(let destination):
              let id = try owner.moveDocument(choices, to: destination)
              waitForDestination = {
                switch try await owner.waitForTransfer(id) {
                case .moved: return destination
                case .restored(let error), .retained(let error): throw error
                }
              }
            case .newWindow:
              let id = try owner.startMoveToNewWindow(choices)
              waitForDestination = {
                switch try await owner.waitForNewWindowMove(id) {
                case .moved(let destination): return destination
                case .restored(let error), .retained(let error): throw error
                }
              }
            }
            Task { [weak self] in
              do {
                let destination = try await waitForDestination()
                self?.presentMovedDocument(
                  choices.documentID, destination: destination,
                  owner: owner, generation: generation)
              } catch {
                guard let self, !self.preparingQuit, self.documentOwner === owner,
                  self.movePresentationGeneration == generation
                else { return }
                self.reportDocumentError(error)
              }
            }
          } catch { self.reportDocumentError(error) }
        },
        onCancel: { [weak self] in
          guard let self, let originating, self.moveDestination === originating else { return }
          self.moveDestination = nil
        })
      originating = chooser
      moveDestination = chooser
      presentMoveDestination(chooser)
    } catch { reportDocumentError(error) }
  }

  private func presentMovedDocument(
    _ documentID: UUID,
    destination: NativeDocumentMoveDestination, owner: NativeApplicationDocuments, generation: UUID
  ) {
    guard !preparingQuit, documentOwner === owner, movePresentationGeneration == generation else {
      return
    }
    do {
      let target = try owner.movePresentation(documentID: documentID, destination: destination)
      guard !preparingQuit, documentOwner === owner, movePresentationGeneration == generation else {
        return
      }
      // Presentation follows completed ownership transfer; a refusal never rolls the move back.
      presentEditorWindow(target)
    } catch {
      guard !preparingQuit, documentOwner === owner, movePresentationGeneration == generation else {
        return
      }
      reportDocumentError(
        Self.documentFlowError(
          "The document was moved, but its destination could not be shown automatically. \(error.localizedDescription)"
        ))
    }
  }

  private static let largeViewerCommands: Set<String> = [
    "file.close", "file.new", "file.newWindow", "file.open", "file.restoreSession", "file.recent",
    "file.retrySession",
    "app.preferences", "edit.copy",
    "edit.selectAll",
  ]
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let id = menuItem.representedObject as? String else { return true }
    if preparingQuit { return false }
    if id == "app.shortcuts" { return shortcutController != nil }
    guard shortcutRegistryReady, registry.commands.contains(where: { $0.id == id }) else {
      return false
    }
    let commandWindow = NSApp.keyWindow
    if let available = documentSearchCapturedAvailabilityThroughGuards(
      id, capturedWindow: commandWindow)
    {
      return available
    }
    if let available = capturedPreviewCommandAvailability(id, capturedWindow: commandWindow) {
      return available
    }
    if id == "file.recent" { return true }
    if id == "file.retrySession" { return documentOwner?.canRetryRecovery == true }
    if id == "file.restoreSession" { return !session.unresolved.isEmpty }
    if NSApp.keyWindow?.windowController is LargeFileWindowController {
      return Self.largeViewerCommands.contains(id)
    }
    if id == "file.moveToWindow" {
      guard let owner = documentOwner, let id = activeEditor?.selectedDocumentID else {
        return false
      }
      return (try? owner.prepareMove(documentID: id)) != nil
    }
    if let activeEditor { return activeEditor.isCommandAvailable(id) }
    return [
      "file.new", "file.newWindow", "file.open", "file.openEncoding", "file.openFolder",
      "app.preferences", "app.help", "view.palette", "macro.manage", "tool.extensions",
      "tool.externalCommand",
    ].contains(id)
  }

  private func applySettings(_ settings: EditorSettings) {
    self.settings = settings
    switch settings.theme {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    for editor in editors { editor.applySettings(settings) }
  }

  private func refreshExtensionCommands() {
    guard !preparingQuit else { return }
    extensionGeneration += 1
    let generation = extensionGeneration
    extensionCommands = [:]
    if let base = try? AppCommands.registry() { shortcutController?.updateCatalog(base.commands) }
    Task { [weak self] in
      do {
        let commands = try await Task.detached {
          try ExtensionCatalog(directory: ExtensionCatalog.defaultDirectory).enabledCommands()
        }.value
        guard let self, !self.preparingQuit, self.extensionGeneration == generation else { return }
        var updated = try AppCommands.registry()
        for command in commands {
          try updated.register(
            CommandDescriptor(id: command.id, title: command.extensionName + ": " + command.title))
        }
        self.extensionCommands = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        self.shortcutController?.updateCatalog(updated.commands)
      } catch {
        guard let self, !self.preparingQuit, self.extensionGeneration == generation else { return }
        if let base = try? AppCommands.registry() {
          self.shortcutController?.updateCatalog(base.commands)
        }
        NSAlert(error: error).runModal()
      }
    }
  }

  private func publishShortcuts(_ state: ShortcutOwnerState) {
    guard !preparingQuit else { return }
    shortcutRegistryReady = state.composition != nil
    if let effective = state.composition { registry = effective.registry }
    palette?.close()
    palette = nil
    help?.close()
    help = nil
    preferences?.updateShortcutAttention(shortcutController?.needsAttention == true)
    buildMenus()
  }
  private func withdrawShortcutEquivalents(_ menu: NSMenu) {
    for item in menu.items {
      if item.representedObject is String {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
      }
      if let submenu = item.submenu { withdrawShortcutEquivalents(submenu) }
    }
  }

  private func buildMenus() {
    commandKeyPublication += 1
    var nextCommandKeys: [String: PublishedCommandKey] = [:]
    let main = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      item.submenu = menu
      main.addItem(item)
      return menu
    }
    let app = submenu(AppIdentity.name)
    app.addItem(
      withTitle: "About \(AppIdentity.name)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let services = NSMenu(title: "Services")
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    app.addItem(servicesItem)
    NSApp.servicesMenu = services
    app.addItem(.separator())
    app.addItem(
      withTitle: "Hide \(AppIdentity.name)", action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    app.addItem(
      withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let file = submenu("File")
    let edit = submenu("Edit")
    let view = submenu("View")
    let tools = submenu("Tools")
    let macros = submenu("Macro")
    for descriptor in registry.commands {
      let menu =
        descriptor.id.hasPrefix("file.")
        ? file
        : descriptor.id.hasPrefix("edit.")
          ? edit
          : descriptor.id.hasPrefix("tool.") || descriptor.id.hasPrefix("document.")
            || descriptor.id.hasPrefix("extension.")
            ? tools
            : descriptor.id.hasPrefix("macro.")
              ? macros : descriptor.id.hasPrefix("app.") ? app : view
      let title =
        descriptor.id == "app.shortcuts" && shortcutController?.needsAttention == true
        ? "Keyboard Shortcuts — Needs Attention…" : descriptor.title
      let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = descriptor.id
      let shortcut =
        shortcutRegistryReady
        ? descriptor.shortcut.flatMap { try? KeyboardShortcut(canonicalString: $0) } : nil
      NativeKeyboardShortcut.configure(item, shortcut: shortcut)
      nextCommandKeys[descriptor.id] = PublishedCommandKey(
        item: item, id: descriptor.id, shortcut: shortcut, publication: commandKeyPublication)
      if menu === app { menu.insertItem(item, at: 1) } else { menu.addItem(item) }
    }
    let window = submenu("Window")
    window.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(
      withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "")
    NSApp.windowsMenu = window
    if !shortcutRegistryReady { withdrawShortcutEquivalents(main) }
    NSApp.mainMenu = main
    publishedCommandKeys = nextCommandKeys
  }
}
