extension EditorWindowController {
  func fixtureDocument(_ id: UUID) -> EditorDocument? { documents.first { $0.id == id } }
  func fixtureRestore() { restoreSavedPanePresentation() }
}
