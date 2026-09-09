// Appended only to a hashed test copy. Confirmation is injected; no native sheet is tested.
extension SessionRestorationController {
  func fixtureConfirmRemoval(
    window: NSWindow, _ completion: (NSApplication.ModalResponse) -> Void
  ) { completion(.alertSecondButtonReturn) }
  func fixtureSelect() {
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  }
  func fixtureRetry() { retrySelected() }
  func fixtureRemove() { confirmRemoval() }
  var fixtureStatus: String { status.stringValue }
}
