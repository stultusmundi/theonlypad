// SPDX-License-Identifier: MIT
// Declaring-manager stored weak owner/association only; never begin history or undo.
@MainActor extension GuardedDocumentUndoManager {
  var nativeManagedAdmissionHistoryOwner: EditorWindowController? { approvedHistoryOwner }
  var nativeManagedAdmissionHistoryRoute: ApprovedViewRoute? { approvedHistoryAssociation }
}
