// FROZEN Task3 access: exact read facts or existing real action forwarding only.
struct ManagedSearchEditorTestFacts {
  let configured: Bool, windowClosed: Bool
  let endpointID: UUID?, selectedDocumentID: UUID?, documentIDs: [UUID]
  let recordIdentity: UUID?, originDocumentID: UUID?, originPaneID: UUID?
}
extension EditorWindowController {
  var managedSearchTestFacts: ManagedSearchEditorTestFacts {
    .init(
      configured: managedDocumentSearchConfiguration != nil, windowClosed: windowClosed,
      endpointID: applicationRouting?.endpointID, selectedDocumentID: selectedID,
      documentIDs: documents.map(\.id), recordIdentity: managedDocumentSearchRecord?.identity,
      originDocumentID: managedDocumentSearchRecord?.document?.id,
      originPaneID: managedDocumentSearchRecord?.pane?.id)
  }
  var managedSearchTestPanel: DocumentSearchPanelController? { managedDocumentSearchRecord?.panel }
  var managedSearchTestTicket: ApplicationSearchWindowID? { managedDocumentSearchRecord?.ticket }
  func managedSearchTestShow() throws -> DocumentSearchPanelController? {
    try showManagedDocumentSearch()
  }
}
