// Same-file readonly references to actual controls; no state, authority or permission injection.
struct LanguageManagerEditingTestFacts {
  let editor: NativeLanguageDefinitionEditorController?
  let new: NSButton
  let edit: NSButton
  let delete: NSButton
  let revert: NSButton
  let save: NSButton
  let discard: NSButton
}
extension NativeLanguageManagerController {
  var languageManagerEditingTestFacts: LanguageManagerEditingTestFacts {
    .init(
      editor: definitionEditor, new: newDefinitionButton, edit: editDefinitionButton,
      delete: deleteDefinitionButton, revert: revertDefinitionButton, save: saveDraftButton,
      discard: discardDraftButton)
  }
}
