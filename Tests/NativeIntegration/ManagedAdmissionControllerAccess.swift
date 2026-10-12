// SPDX-License-Identifier: MIT
// Frozen observations plus the existing public32 disk-conflict construction forwarder.
@MainActor extension EditorWindowController {
  func nativeManagedAdmissionRawRoute(_ pane: EditorPane) -> ApprovedViewRoute? {
    approvedRoutes[ObjectIdentifier(pane.editor)]?.value
  }
  var nativeManagedAdmissionWindowIsClosed: Bool { windowClosed }
  func monitorHarnessDiskConflict(_ document: EditorDocument) -> DocumentDiskConflictController? {
    makeDiskConflict(document)
  }
}
