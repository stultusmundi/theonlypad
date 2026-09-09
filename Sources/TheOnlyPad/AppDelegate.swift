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

  func applicationDidFinishLaunching(_ notification: Notification) {
    do { registry = try AppCommands.registry() } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
      return
    }
    buildMenus()
    refreshExtensionCommands()
    if editors.isEmpty { newWindow() }
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
  private func newWindow() -> EditorWindowController {
    let editor = EditorWindowController()
    editor.applySettings(settings)
    editors.append(editor)
    editor.onClose = { [weak self, weak editor] in
      self?.editors.removeAll { $0 === editor }
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
    editor.open(request.url) { [weak editor] in
      editor?.navigate(line: request.line, column: request.column)
    }
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
    Task {
      for editor in editors {
        guard await editor.prepareToQuit() else {
          for editor in editors { editor.cancelPreparedQuit() }
          preparingQuit = false
          NSApp.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      guard await EditorWindowController.finishPendingCloses() else {
        for editor in editors { editor.cancelPreparedQuit() }
        preparingQuit = false
        NSApp.reply(toApplicationShouldTerminate: false)
        return
      }
      await ExternalCommandController.cancelAllAndWait()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
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
    "file.close", "file.new", "file.newWindow", "file.open", "app.preferences", "edit.copy",
    "edit.selectAll",
  ]
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let id = menuItem.representedObject as? String else { return true }
    if preparingQuit { return false }
    if NSApp.keyWindow?.windowController is LargeFileWindowController {
      return Self.largeViewerCommands.contains(id)
    }
    return true
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
      let item = NSMenuItem(
        title: descriptor.title, action: #selector(command(_:)),
        keyEquivalent: components.last ?? "")
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
