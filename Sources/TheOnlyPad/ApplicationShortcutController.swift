import AppKit
import PadCore

@MainActor struct ShortcutDialogs {
  enum RecoveryChoice { case verifyAndRetry, reloadDiscard, restoreDefaults }
  var chooseImport: () -> URL? = {
    let panel = NSOpenPanel()
    panel.title = "Import Keyboard Shortcuts"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
  var chooseExport: () -> URL? = {
    let panel = NSSavePanel()
    panel.title = "Export Keyboard Shortcuts"
    panel.message = "Choose a new filename. Existing files will not be replaced."
    panel.nameFieldStringValue = "Keyboard Shortcuts.json"
    return panel.runModal() == .OK ? panel.url : nil
  }
  var confirmRepair: () -> Bool = {
    let alert = NSAlert()
    alert.messageText = "Replace unreadable keyboard shortcut settings?"
    alert.informativeText =
      "The stored settings could not be read. Applying this draft will replace them. Cancel to preserve the stored file."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Replace Stored Settings")
    return alert.runModal() == .alertSecondButtonReturn
  }
  var chooseRecovery: (_ pending: Bool, _ invalid: Bool) -> RecoveryChoice? = { pending, invalid in
    let alert = NSAlert()
    alert.messageText = "Recover Keyboard Shortcut Settings"
    alert.addButton(withTitle: "Cancel")
    if pending {
      alert.informativeText =
        "The last save was not confirmed. Verify and Retry attempts a fresh save. Reload and Discard abandons the pending changes and reads the current stored settings."
      alert.addButton(withTitle: "Verify and Retry")
      alert.addButton(withTitle: "Reload and Discard Pending Changes")
      let response = alert.runModal()
      return response == .alertSecondButtonReturn
        ? .verifyAndRetry : response == .alertThirdButtonReturn ? .reloadDiscard : nil
    }
    alert.informativeText =
      invalid
      ? "The unreadable settings are preserved. Reload reads them again. Restore Defaults replaces them with default keyboard shortcuts."
      : "Reload reads the current stored settings without changing the file."
    alert.addButton(withTitle: "Reload Stored Settings")
    if invalid { alert.addButton(withTitle: "Restore Defaults and Replace Stored Settings") }
    let response = alert.runModal()
    return response == .alertSecondButtonReturn
      ? .reloadDiscard : response == .alertThirdButtonReturn && invalid ? .restoreDefaults : nil
  }
}
struct ShortcutTransferServices: Sendable {
  var read: @Sendable (URL) throws -> ShortcutProfile = {
    try ShortcutTransfer().importProfile(from: $0)
  }
  var write: @Sendable (ShortcutProfile, URL) throws -> Void = {
    try ShortcutTransfer().export($0, to: $1)
  }
}
@MainActor final class ApplicationShortcutController {
  private let owner: ApplicationShortcuts
  private let dialogs: ShortcutDialogs
  private let transfer: ShortcutTransferServices
  private let isPreparingQuit: () -> Bool
  private let publish: (ShortcutOwnerState) -> Void
  private var window: KeyboardShortcutController?
  private var windowGeneration = UUID()
  private var interaction: UUID?
  private var starting = false
  private(set) var lastTransferError: Error?
  var state: ShortcutOwnerState { owner.state }
  var canQuit: Bool { !starting && interaction == nil && owner.state.canQuit }
  var needsAttention: Bool { !state.issues.isEmpty || lastTransferError != nil }
  init(
    owner: ApplicationShortcuts, dialogs: ShortcutDialogs? = nil,
    transfer: ShortcutTransferServices = ShortcutTransferServices(),
    isPreparingQuit: @escaping () -> Bool, publish: @escaping (ShortcutOwnerState) -> Void
  ) {
    self.owner = owner
    self.dialogs = dialogs ?? ShortcutDialogs()
    self.transfer = transfer
    self.isPreparingQuit = isPreparingQuit
    self.publish = publish
    owner.onChange = { [weak self] in self?.changed() }
  }
  private func changed() {
    let value = state
    window?.update(snapshot())
    publish(value)
  }
  func start(completion: @escaping () -> Void) {
    guard !starting, !isPreparingQuit() else { return }
    starting = true
    changed()
    Task {
      do { try await owner.load() } catch {
        // Owner retains the failure as persistent state.
      }
      starting = false
      guard !isPreparingQuit() else { return }
      changed()
      completion()
    }
  }
  func updateCatalog(_ commands: [CommandDescriptor]) {
    guard !isPreparingQuit() else { return }
    owner.updateCatalog(commands)
  }
  private func statusText() -> String? {
    var reasons: [String] = []
    for issue in state.issues {
      switch issue {
      case .invalidStoredProfile:
        reasons.append(
          "Stored shortcuts could not be read and were preserved. Import valid settings, restore defaults, or reload them."
        )
      case .readFailure:
        reasons.append(
          "Shortcut settings could not be loaded. The previous settings remain in use. Recover Stored Settings to retry."
        )
      case .writeFailure:
        reasons.append(
          "Shortcut settings were not saved. Review the current stored settings before trying again."
        )
      case .uncertainPublication:
        reasons.append(
          "The last shortcut save was not confirmed. Recover Stored Settings to Verify and Retry or explicitly Reload and Discard Pending Changes."
        )
      case .invalidCatalog:
        reasons.append(
          "The command catalog could not be validated. Commands are temporarily unavailable while shortcut settings are repaired."
        )
      case .conflicts:
        reasons.append(
          "Stored custom shortcuts conflict with the current commands. Default shortcuts are in use; your customizations are preserved. Resolve the conflicts before applying."
        )
      }
    }
    if starting { reasons.append("Loading keyboard shortcut settings…") }
    if let lastTransferError { reasons.append(lastTransferError.localizedDescription) }
    return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
  }
  func snapshot() -> ShortcutEditorSnapshot {
    ShortcutEditorSnapshot(
      catalog: state.catalog, profile: state.profile, catalogRevision: state.catalogRevision,
      profileRevision: state.profileRevision, status: statusText(),
      canApply: !starting && interaction == nil && !state.isBusy && !state.hasPendingPublication
        && state.composition != nil && !isPreparingQuit(),
      recoveryTitle: !state.issues.isEmpty && !starting && interaction == nil && !state.isBusy
        && !isPreparingQuit() ? "Recover Stored Settings…" : nil)
  }
  func showEditor() { prepareEditor()?.showWindow(nil) }
  /// Construct/update independently from presentation, keeping hidden lifecycle checks possible.
  func prepareEditor() -> KeyboardShortcutController? {
    guard !isPreparingQuit() else { return nil }
    if let window {
      window.update(snapshot())
      return window
    }
    let generation = UUID()
    windowGeneration = generation
    let controller = KeyboardShortcutController(
      snapshot: snapshot(),
      actions: ShortcutEditorActions(
        apply: { [weak self] profile, catalog, revision in
          guard let self else { throw CancellationError() }
          return try await self.apply(profile, catalog: catalog, revision: revision)
        },
        importProfile: { [weak self] in
          guard let self else { throw CancellationError() }
          return try await self.importProfile(window: generation)
        },
        recover: { [weak self] in
          guard let self else { throw CancellationError() }
          return try await self.recover()
        },
        exportProfile: { [weak self] profile in
          guard let self else { throw CancellationError() }
          return try await self.exportProfile(profile, window: generation)
        }))
    controller.onClose = { [weak self] in
      guard let self, self.windowGeneration == generation else { return }
      self.window = nil
      self.windowGeneration = UUID()
    }
    window = controller
    return controller
  }
  private func begin() throws -> UUID {
    guard !isPreparingQuit(), !starting, interaction == nil, !state.isBusy else {
      throw ApplicationShortcutError.busy
    }
    let id = UUID()
    interaction = id
    changed()
    return id
  }
  private func end(_ id: UUID) {
    guard interaction == id else { return }
    interaction = nil
    changed()
  }
  private func requireCurrent(catalog: UUID, revision: UUID) throws {
    guard !isPreparingQuit(), state.catalogRevision == catalog, state.profileRevision == revision
    else { throw CancellationError() }
  }
  func apply(_ profile: ShortcutProfile, catalog: UUID, revision: UUID) async throws
    -> ShortcutEditorSnapshot
  {
    try requireCurrent(catalog: catalog, revision: revision)
    let id = try begin()
    defer { end(id) }
    let repair = state.issues.contains(.invalidStoredProfile)
    if repair && !dialogs.confirmRepair() { throw CancellationError() }
    try requireCurrent(catalog: catalog, revision: revision)
    try await owner.apply(profile, allowReplacingInvalidStorage: repair)
    end(id)
    return snapshot()
  }
  func recover() async throws -> ShortcutEditorSnapshot {
    let id = try begin()
    defer { end(id) }
    let before = state
    guard
      let choice = dialogs.chooseRecovery(
        before.hasPendingPublication, before.issues.contains(.invalidStoredProfile))
    else { throw CancellationError() }
    try requireCurrent(catalog: before.catalogRevision, revision: before.profileRevision)
    switch choice {
    case .verifyAndRetry: try await owner.verifyAndRetry()
    case .reloadDiscard: try await owner.reload(discardPending: before.hasPendingPublication)
    case .restoreDefaults:
      guard before.issues.contains(.invalidStoredProfile), !before.hasPendingPublication else {
        throw CancellationError()
      }
      try await owner.apply(.defaults, allowReplacingInvalidStorage: true)
    }
    end(id)
    return snapshot()
  }
  func importProfile(window generation: UUID) async throws -> ShortcutProfile? {
    let id = try begin()
    defer { end(id) }
    let before = state
    guard let url = dialogs.chooseImport() else { return nil }
    try requireCurrent(catalog: before.catalogRevision, revision: before.profileRevision)
    guard windowGeneration == generation else { throw CancellationError() }
    let read = transfer.read
    do {
      let profile = try await Task.detached { try read(url) }.value
      try requireCurrent(catalog: before.catalogRevision, revision: before.profileRevision)
      guard windowGeneration == generation else { throw CancellationError() }
      lastTransferError = nil
      return profile
    } catch {
      if error is CancellationError { throw error }
      let detail =
        (error as? LocalizedError)?.errorDescription
        ?? "Choose a valid supported keyboard shortcut export."
      let visible = NSError(
        domain: "TheOnlyPad.ShortcutImport", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Keyboard shortcuts could not be imported. " + detail
            + " Your draft and stored settings were preserved.",
          NSUnderlyingErrorKey: error,
        ])
      lastTransferError = visible
      throw visible
    }
  }
  func exportProfile(_ profile: ShortcutProfile, window generation: UUID) async throws -> Bool {
    let id = try begin()
    defer { end(id) }
    let before = state
    guard let url = dialogs.chooseExport() else { return false }
    try requireCurrent(catalog: before.catalogRevision, revision: before.profileRevision)
    guard windowGeneration == generation else { throw CancellationError() }
    let write = transfer.write
    do {
      try await Task.detached { try write(profile, url) }.value
      lastTransferError = nil
      guard !isPreparingQuit(), windowGeneration == generation else { throw CancellationError() }
      return true
    } catch let error as ShortcutPublicationUncertain {
      let visible = NSError(
        domain: "TheOnlyPad.ShortcutExport", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The export may have been written but could not be confirmed. Keep the destination file for inspection, or export again using a new filename. No existing file was replaced.",
          NSUnderlyingErrorKey: error,
        ])
      lastTransferError = visible
      throw visible
    } catch {
      if !(error is CancellationError) { lastTransferError = error }
      throw error
    }
  }
  func explainQuitVeto() {
    let alert = NSAlert()
    alert.messageText = "Keyboard shortcut settings need attention before quitting"
    alert.informativeText =
      state.hasPendingPublication
      ? "The last shortcut save was not confirmed. Open Keyboard Shortcuts and use Recover Stored Settings to verify and retry, or explicitly reload and discard pending changes."
      : "A shortcut settings operation is still running. Wait for it to finish, then try quitting again."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
