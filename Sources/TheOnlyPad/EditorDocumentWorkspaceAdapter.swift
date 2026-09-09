import Foundation

/// Protocol boundary only; standalone editor model harnesses need not import the registry.
extension EditorDocument: WorkspaceDocumentHandle {
  var workspaceKind: WorkspaceDocumentKind { .editable }
}
