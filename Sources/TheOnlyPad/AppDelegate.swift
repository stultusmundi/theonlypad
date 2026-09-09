import AppKit
import PadCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var editors: [EditorWindowController] = []
  private var palette: CommandPaletteController?
  private var registry = CommandRegistry()
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
  private let session = SessionCoordinator()
  private lazy var checkpoints = ApplicationSessionCheckpoints(
    session: session, windows: { [weak self] in self?.editors ?? [] },
    onRetry: { [weak self] in self?.dispatch("file.retrySession") })
  private var startupTask: Task<Void, Never>?
  private var sessionPanel: SessionRestorationController?
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
    buildMenus()
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
    refreshExtensionCommands()
    session.onSessionChange = { [weak self] in self?.checkpoints.requestCheckpoint() }
    restoreStartupSession()
    do {
      let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
      let requests = try LaunchRequest.parse(
        arguments: arguments,
        workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
      for request in requests { open(request) }
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
  private func newWindow(id: UUID = UUID(), createDocument: Bool = true) -> EditorWindowController {
    let editor = EditorWindowController(
      id: id, restoreStartup: false,
      onSessionChange: { [weak self] in self?.checkpoints.requestCheckpoint() })
    editor.configureFileMonitoring(fileMonitoring)
    if createDocument { editor.newDocument() }
    editor.applySettings(settings)
    editors.append(editor)
    editor.onOpenedURL = { [weak self] url in
      guard let self else { return }
      do {
        try self.session.recordRecentOpen(url)
        self.recentFiles?.update(
          paths: self.session.recentPaths, openedPath: url.standardizedFileURL.path)
      } catch { NSAlert(error: error).runModal() }
    }
    editor.onClose = { [weak self, weak editor] in
      self?.editors.removeAll { $0 === editor }
      self?.checkpoints.requestCheckpoint()
    }
    editor.onOpenLargeFile = { [weak self] url in
      guard let self, !self.preparingQuit else { return }
      let viewer = LargeFileWindowController(url: url)
      self.largeViewers.append(viewer)
      viewer.onClose = { [weak self, weak viewer] in self?.largeViewers.removeAll { $0 === viewer }
      }
      viewer.showWindow(nil)
    }
    editor.showWindow(nil)
    return editor
  }

  private func restoreStartupSession() {
    startupTask = Task { [weak self] in
      guard let self else { return }
      await self.session.restore { [weak self] prepared in
        guard let self else {
          return Dictionary(
            uniqueKeysWithValues: prepared.tabs.map {
              ($0.metadata.id, "The application is closing.")
            })
        }
        let editor = self.newWindow(id: prepared.id, createDocument: false)
        var failures: [UUID: String] = [:]
        for tab in prepared.tabs {
          do {
            try editor.restoreSessionTab(
              tab.metadata, decoded: tab.decoded, originalBytes: tab.originalBytes, url: tab.url,
              viewState: tab.viewState)
          } catch { failures[tab.metadata.id] = error.localizedDescription }
        }
        editor.selectSessionTab(prepared.selectedTabID)
        if editor.sessionMetadata.tabs.isEmpty { editor.close() }
        return failures
      }
      if self.editors.isEmpty { self.newWindow() }
      self.checkpoints.startAfterRestoration()
      if !self.session.unresolved.isEmpty { self.showUnresolvedSession() }
      let notices = self.session.startupErrors + self.session.warnings
      if !notices.isEmpty {
        let alert = NSAlert()
        alert.messageText = "Session restoration needs attention"
        alert.informativeText = notices.joined(separator: "\n\n")
        alert.runModal()
      }
    }
  }

  private func showUnresolvedSession() {
    if let sessionPanel {
      sessionPanel.update(entries: session.unresolved)
      sessionPanel.showWindow(nil)
      return
    }
    let controller = SessionRestorationController(
      entries: session.unresolved,
      onRetry: { [weak self] entry in
        guard let self, !self.preparingQuit else { throw CancellationError() }
        self.repairTargets[entry.metadata.id] = self.editors.first {
          $0.sessionMetadata.id == entry.windowID
        }
        return try await self.session.retry(entry)
      },
      onLocate: { [weak self] entry, url in
        guard let self, !self.preparingQuit else { throw CancellationError() }
        self.repairTargets[entry.metadata.id] = self.editors.first {
          $0.sessionMetadata.id == entry.windowID
        }
        return try await self.session.locate(entry, url: url)
      },
      onResolved: { [weak self] entry, file in
        guard let self, !self.preparingQuit, let state = file.resolvedViewState else {
          throw CancellationError()
        }
        if let target = self.repairTargets[entry.metadata.id],
          !self.editors.contains(where: { $0 === target })
        {
          throw CancellationError()
        }
        var budget = SessionStartupBudget()
        for window in self.editors {
          let usage = window.sessionResourceUsage
          try budget.admit(utf16Count: usage.utf16Count, originalByteCount: usage.originalByteCount)
        }
        try budget.admit(
          utf16Count: file.utf16Count, originalByteCount: file.originalBytes?.count ?? 0)
        let editor =
          self.editors.first { $0.sessionMetadata.id == entry.windowID }
          ?? self.newWindow(id: entry.windowID, createDocument: false)
        try editor.restoreSessionTab(
          entry.metadata, decoded: file.decoded, originalBytes: file.originalBytes, url: file.url,
          viewState: state,
          insertionIndex: self.session.insertionIndex(for: entry, in: editor.sessionMetadata))
        if self.session.shouldSelect(entry) { editor.selectSessionTab(entry.metadata.id) }
        self.session.resolved(entry)
        self.repairTargets[entry.metadata.id] = nil
        if state.selectionAdjusted || !state.invalidBookmarks.isEmpty {
          let alert = NSAlert()
          alert.messageText = "Saved positions adjusted"
          alert.informativeText =
            "The loaded file differs from its saved positions. Selection was clamped and invalid bookmarks were omitted."
          alert.runModal()
        }
      },
      onRemove: { [weak self] entry in
        guard let self, !self.preparingQuit else { throw CancellationError() }
        try await self.session.remove(entry)
        self.repairTargets[entry.metadata.id] = nil
      })
    controller.onClose = { [weak self] in
      self?.sessionPanel = nil
      self?.repairTargets.removeAll()
    }
    sessionPanel = controller
    controller.showWindow(nil)
  }

  private func showRecentFiles() {
    guard session.restorationComplete else { return }
    if let recentFiles {
      recentFiles.update(paths: session.recentPaths)
      recentFiles.showWindow(nil)
      return
    }
    let target = activeEditor ?? newWindow()
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
    guard !preparingQuit else { return }
    let editor = activeEditor ?? newWindow()
    for url in urls.prefix(128) {
      if url.isFileURL {
        editor.open(url)
      } else {
        do { open(try LaunchRequest.parse(url: url)) } catch { NSAlert(error: error).runModal() }
      }
    }
    if urls.count > 128 {
      let alert = NSAlert()
      alert.messageText = "Only the first 128 files were opened"
      alert.informativeText = "Open additional files in a separate batch."
      alert.runModal()
    }
  }

  private func open(_ request: LaunchRequest) {
    let editor = activeEditor ?? newWindow()
    editor.open(
      request.url,
      onOpened: { [weak editor] in
        // A later file in the same batch may become active before this offset is ready.
        editor?.navigate(line: request.line, column: request.column, requireFocus: false)
      })
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    guard !preparingQuit else { return false }
    if !flag { newWindow() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !preparingQuit else { return .terminateLater }
    preparingQuit = true
    fileMonitoring.suspend()
    recentFiles?.setSuspended(true)
    Task {
      await startupTask?.value
      await checkpoints.pauseAndDrain()
      // Invalidate pending repair callbacks before capturing the frozen session.
      sessionPanel?.update(entries: session.unresolved)
      for editor in editors {
        guard await editor.prepareToQuit(persistRecovery: false) else {
          for editor in editors { editor.cancelPreparedQuit() }
          preparingQuit = false
          fileMonitoring.resume()
          recentFiles?.setSuspended(false)
          checkpoints.resumeAfterVeto()
          NSApp.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      do {
        _ = try await checkpoints.commitFinal()
      } catch {
        for editor in editors { editor.cancelPreparedQuit() }
        preparingQuit = false
        fileMonitoring.resume()
        recentFiles?.setSuspended(false)
        checkpoints.resumeAfterVeto()
        NSAlert(error: error).runModal()
        NSApp.reply(toApplicationShouldTerminate: false)
        return
      }
      await ExternalCommandController.cancelAllAndWait()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
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
    dispatch(id)
  }

  private func dispatch(_ id: String) {
    guard !preparingQuit else { return }
    if let viewer = NSApp.keyWindow?.windowController as? LargeFileWindowController {
      if id == "file.close" {
        viewer.close()
        return
      }
      if !Self.largeViewerCommands.contains(id) { return }
    }
    let nativeActions: [String: Selector] = [
      "edit.undo": Selector(("undo:")), "edit.redo": Selector(("redo:")),
      "edit.cut": #selector(NSText.cut(_:)), "edit.copy": #selector(NSText.copy(_:)),
      "edit.paste": #selector(NSText.paste(_:)), "edit.selectAll": #selector(NSText.selectAll(_:)),
    ]
    if let action = nativeActions[id] {
      NSApp.sendAction(action, to: nil, from: self)
      return
    }
    switch id {
    case "file.retrySession": checkpoints.requestCheckpoint()
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
      let editor = activeEditor ?? newWindow()
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
      let editor = activeEditor ?? newWindow()
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
      let editor = activeEditor ?? newWindow()
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
        preferences = controller
        controller.showWindow(nil)
      }
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
        let editor = activeEditor ?? newWindow()
        let documentID = editor.selectedDocumentID
        Task { [weak self, weak editor] in
          do {
            let enabled = try await Task.detached {
              try ExtensionCatalog(directory: ExtensionCatalog.defaultDirectory).enabledCommands()
            }.value
            guard let self, !self.preparingQuit, let editor else { return }
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
        (activeEditor ?? newWindow()).execute(id)
      }
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
    if id == "file.recent" { return true }
    if id == "file.retrySession" { return checkpoints.lastError != nil }
    if id == "file.restoreSession" { return !session.unresolved.isEmpty }
    if NSApp.keyWindow?.windowController is LargeFileWindowController {
      return Self.largeViewerCommands.contains(id)
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
    extensionGeneration += 1
    let generation = extensionGeneration
    extensionCommands = [:]
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
        self.registry = updated
        self.extensionCommands = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        self.buildMenus()
      } catch {
        guard let self, !self.preparingQuit, self.extensionGeneration == generation else { return }
        self.registry = (try? AppCommands.registry()) ?? CommandRegistry()
        self.buildMenus()
        NSAlert(error: error).runModal()
      }
    }
  }

  private func buildMenus() {
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
      let components = descriptor.shortcut?.split(separator: "+").map(String.init) ?? []
      let key = components.last ?? ""
      let functionKeys = ["up": "\u{F700}", "down": "\u{F701}"]
      let item = NSMenuItem(
        title: descriptor.title, action: #selector(command(_:)),
        keyEquivalent: functionKeys[key] ?? key)
      item.target = self
      item.representedObject = descriptor.id
      var modifiers: NSEvent.ModifierFlags = []
      if components.contains("cmd") { modifiers.insert(.command) }
      if components.contains("shift") { modifiers.insert(.shift) }
      if components.contains("ctrl") { modifiers.insert(.control) }
      if components.contains("alt") { modifiers.insert(.option) }
      item.keyEquivalentModifierMask = modifiers
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
    NSApp.mainMenu = main
  }
}
