// Appended only to the temporary AppDelegate source for same-file private access.
extension AppDelegate {
  func installShortcutsForTesting(_ owner: ApplicationShortcuts) throws {
    registry = try AppCommands.registry()
    let controller = ApplicationShortcutController(
      owner: owner, isPreparingQuit: { [weak self] in self?.preparingQuit ?? true },
      publish: { [weak self] value in self?.publishShortcuts(value) })
    shortcutController = controller
    publishShortcuts(controller.state)
  }
  var shortcutReadyForTesting: Bool { shortcutRegistryReady }
  var shortcutRegistryForTesting: CommandRegistry { registry }
  // Read actual published state; do not synthesize menu snapshots.
  var publishedCommandKeysForTesting: [String: PublishedCommandKey] { publishedCommandKeys }
  var commandKeyPublicationForTesting: Int { commandKeyPublication }
}
