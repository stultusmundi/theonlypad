extension EditorWindowController {
  var monitorHarnessDocuments: [EditorDocument] { documents }
  var monitorHarnessCurrent: EditorDocument? { current }
  func monitorHarnessDisplay(_ document: EditorDocument) { display(document) }
  func monitorHarnessSave(_ document: EditorDocument) { save(document, saveAs: false) }
  func monitorHarnessClose(_ document: EditorDocument) { closeDocuments(ids: [document.id]) }
  func monitorHarnessReopen() { reopenClosed() }
}
extension EditorWindowController {
  func monitorHarnessRenderDiskStatus() { renderDiskStatus() }
  func monitorHarnessDiskConflict(_ document: EditorDocument) -> DocumentDiskConflictController? {
    makeDiskConflict(document)
  }
}
