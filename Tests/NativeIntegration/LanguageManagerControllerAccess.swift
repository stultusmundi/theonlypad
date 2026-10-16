// Reads actual stored native controls/rendered values, never a synthetic acceptance flag.
struct LanguageManagerControllerTestFacts {
  let session: NativeLanguageManagerSession
  let table: NSTableView
  let details: NSTextView
  let overrides: NSTextView
  let status: NSTextField
  let refresh: NSButton
  let close: NSButton
  let renderedDefinitions: [LiteralLanguageDefinition]
  let renderedOverrides: [BuiltInLanguageOverride]
  let selectedDefinition: LiteralLanguageDefinition?
}
extension NativeLanguageManagerController {
  var languageManagerTestFacts: LanguageManagerControllerTestFacts {
    .init(
      session: session, table: tableView, details: detailTextView,
      overrides: overrideTextView, status: statusField, refresh: refreshButton,
      close: closeButton, renderedDefinitions: renderedDefinitions,
      renderedOverrides: renderedOverrides, selectedDefinition: selectedDefinition)
  }
}
