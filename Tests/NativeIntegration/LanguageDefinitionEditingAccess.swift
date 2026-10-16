struct LanguageDefinitionEditingTestFacts {
  let handle: NativeLanguageManagerFormHandle
  let name: NSTextField
  let extensions: NSTextView
  let keywords: NSTextView
  let lineEnabled: NSButton
  let line: NSTextField
  let blockEnabled: NSButton
  let blockOpening: NSTextField
  let blockClosing: NSTextField
  let decimal: NSButton
  let indentation: NSPopUpButton
  let width: NSTextField
  let done: NSButton
  let discard: NSButton
}
extension NativeLanguageDefinitionEditorController {
  var languageDefinitionEditingTestFacts: LanguageDefinitionEditingTestFacts {
    .init(
      handle: handle, name: nameField, extensions: extensionsTextView,
      keywords: keywordsTextView, lineEnabled: lineToggle, line: lineField,
      blockEnabled: blockToggle, blockOpening: blockOpeningField,
      blockClosing: blockClosingField, decimal: decimalToggle,
      indentation: indentationPopup, width: widthField, done: doneButton, discard: discardButton)
  }
}
