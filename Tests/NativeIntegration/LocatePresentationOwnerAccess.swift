// FROZEN access only: real production installation, existing render, and immutable owned facts.
struct LocatePresentationOwnerFacts {
  let panel: DocumentDiskConflictController?
  let documentID: UUID?
  let binding: FileStateBindingIdentity?
  let token: FileObservationToken?
}
extension EditorWindowController {
  func locatePresentationTestInstallNoShow(_ document: EditorDocument)
    -> DocumentDiskConflictController?
  {
    installDiskConflict(document)
  }
  var locatePresentationTestOwnerFacts: LocatePresentationOwnerFacts {
    .init(
      panel: diskConflict, documentID: diskConflictDocumentID,
      binding: diskConflictPresentationIdentity?.binding,
      token: diskConflictPresentationIdentity?.token)
  }
}
