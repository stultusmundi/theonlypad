extension EditorWindowController {
  func fixturePaneDocument(_ id: UUID) -> EditorDocument? { documents.first { $0.id == id } }
  func fixtureRestoreSavedPanes() { restoreSavedPanePresentation() }
  func fixtureQueuePaneStatusHeight(_ height: CGFloat) {
    panePresentationStatus.heightAnchor.constraint(equalToConstant: height).isActive = true
    window?.contentView?.needsLayout = true
  }
  var fixtureRestoreEnabled: Bool { restorePanePresentationButton.isEnabled }
  var fixtureDiscardEnabled: Bool { discardPanePresentationButton.isEnabled }
  func fixtureRenderPaneStatus() { renderPanePresentationStatus() }
  var fixturePaneStatus: String { panePresentationStatus.stringValue }
  func fixtureDiscardSavedPanes() { discardSavedPanePresentation() }
}
