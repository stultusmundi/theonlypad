// Appended unchanged to the private AppDelegate source snapshot for tests only.
extension AppDelegate {
  func startDocumentsForTesting() async throws { try await startManagedDocuments() }
  func enqueueDocumentsForTesting(_ requests: [LaunchRequest]) { enqueueLaunchRequests(requests) }
  var documentsOwnerForTesting: NativeApplicationDocuments? { documentOwner }
  var documentWindowsForTesting: [EditorWindowController] { editors }
  func setDocumentSettingsForTesting(_ value: EditorSettings) { settings = value }
  var documentQuitForTesting: Bool { preparingQuit }
  var documentMonitoringSuspendedForTesting: Bool { fileMonitoring.isSuspended }
  func requireDocumentCommandForTesting() -> EditorWindowController? { requireCommandEditor() }
  func setDocumentQuitForTesting(_ value: Bool) { preparingQuit = value }
  func openLargeDocumentForTesting(_ request: LaunchRequest) throws { try openLargeFile(request) }
  func makeSessionPanelForTesting() -> SessionRestorationController { makeSessionPanel() }
  var unresolvedForTesting: [UnresolvedSessionEntry] { session.unresolved }
  func setRepairAttemptForTesting(_ id: UUID, target: EditorWindowController) -> UUID {
    let token = UUID()
    repairAttempts[id] = token
    repairTargets[id] = target
    return token
  }
  func repairAttemptForTesting(_ id: UUID) -> UUID? { repairAttempts[id] }
  func repairTargetForTesting(_ id: UUID) -> EditorWindowController? { repairTargets[id] }

}
