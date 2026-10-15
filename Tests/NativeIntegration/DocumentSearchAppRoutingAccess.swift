// FROZEN Task4 access only. Stored observations and qualified real-action forwarding.
struct AppSearchAttemptTestFacts {
  let id: UUID, hasPreparation: Bool
  let nativeReceipt: SessionCheckpointReceipt?, decision: NativeApplicationSearchQuitResult?
  let hasTask: Bool, replyConsumed: Bool
}
extension AppDelegate {
  func task4StartDocuments() async throws { try await startManagedDocuments() }
  var task4Owner: NativeApplicationDocuments? { documentOwner }
  var task4Editors: [EditorWindowController] { editors }
  var task4RegistryReady: Bool { shortcutRegistryReady }
  var task4PreparingQuit: Bool { preparingQuit }
  var task4MonitoringSuspended: Bool { fileMonitoring.isSuspended }
  var task4PublishedKeys: [String: PublishedCommandKey] { publishedCommandKeys }
  var task4CommandPublication: Int { commandKeyPublication }
  var task4RegisteredCommandIDs: [String] { registry.commands.map(\.id) }
  var task4Attempt: AppSearchAttemptTestFacts? {
    documentSearchTerminationAttempt.map {
      .init(
        id: $0.id, hasPreparation: $0.preparation != nil, nativeReceipt: $0.nativeReceipt,
        decision: $0.searchDecision, hasTask: $0.task != nil, replyConsumed: $0.replyConsumed)
    }
  }
  // Real constructor/publish path. The supplied actual owner must already have loaded its real store.
  func task4InstallLoadedShortcuts(_ owner: ApplicationShortcuts) throws {
    registry = try AppCommands.registry()
    let controller = ApplicationShortcutController(
      owner: owner,
      isPreparingQuit: { [weak self] in self?.preparingQuit ?? true },
      publish: { [weak self] state in self?.publishShortcuts(state) })
    shortcutController = controller
    publishShortcuts(controller.state)
  }
  func task4DispatchCaptured(
    _ id: String, window: NSWindow?,
    send: @MainActor (Selector, Any?) -> Bool
  ) -> Bool {
    dispatchDocumentSearchCapturedThroughGuards(id, capturedWindow: window, sendNativeAction: send)
  }
  func task4Availability(_ id: String, window: NSWindow?) -> Bool? {
    documentSearchCapturedAvailabilityThroughGuards(id, capturedWindow: window)
  }
  // Capture synchronously before any release/reply callout; invocation performs the real original-task join.
  func task4CaptureCurrentAttemptJoin() throws -> @MainActor () async -> AppSearchAttemptTestFacts {
    guard let original = documentSearchTerminationAttempt, let task = original.task else {
      throw NativeWorkspaceError.notReady
    }
    return {
      await task.value
      return .init(
        id: original.id, hasPreparation: original.preparation != nil,
        nativeReceipt: original.nativeReceipt,
        decision: original.searchDecision, hasTask: original.task != nil,
        replyConsumed: original.replyConsumed)
    }
  }
}
