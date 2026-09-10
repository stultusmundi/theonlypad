// Appended to an isolated AppDelegate source copy only.
extension AppDelegate {
  func startMoveTest() async throws {
    try await startManagedDocuments()
    registry = try AppCommands.registry()
    shortcutRegistryReady = true
  }
  var moveOwnerTest: NativeApplicationDocuments? {
    get { documentOwner }
    set { documentOwner = newValue }
  }
  func dispatchMoveTest() { dispatch("file.moveToWindow") }
  func dispatchMoveRetryTest() { dispatch("file.retrySession") }
  var movePresentationGenerationTest: UUID { movePresentationGeneration }
  var movePreparingQuitTest: Bool { preparingQuit }
  func completeMovePresentationTest(
    documentID: UUID, destination: NativeDocumentMoveDestination, generation: UUID
  ) {
    guard let owner = documentOwner else { return }
    presentMovedDocument(documentID, destination: destination, owner: owner, generation: generation)
  }

}
