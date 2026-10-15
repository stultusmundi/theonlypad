// FROZEN TEST ACCESS ONLY: actual controls/read facts and exact responder forwarding.
struct DocumentSearchPanelTestControls {
  let query: NSSearchField, replacement: NSTextField, mode: NSPopUpButton
  let matchCase: NSButton, wholeWord: NSButton
  let find: NSButton, previous: NSButton, next: NSButton, replace: NSButton, cancel: NSButton
  let status: NSTextField, approvalRow: NSView, approve: NSButton, reject: NSButton
}
extension DocumentSearchPanelController {
  var testOnlyControls: DocumentSearchPanelTestControls {
    .init(
      query: queryField, replacement: replacementField, mode: mode,
      matchCase: matchCase, wholeWord: wholeWord, find: findButton, previous: previousButton,
      next: nextButton, replace: replaceButton, cancel: cancelButton, status: status,
      approvalRow: approvalRow, approve: approveButton, reject: rejectButton)
  }
  var testOnlySessionState: DocumentSearchSessionState? { session?.state }
  var testOnlyRenderedState: DocumentSearchSessionState { renderedState }
  var testOnlyDisplayedApproval: DocumentSearchApprovalToken? { displayedApproval }
  var testOnlyLogicallyClosed: Bool { logicallyClosed }
  func testOnlyRespondToApproval(_ token: DocumentSearchApprovalToken, approved: Bool) -> Bool {
    respondToApproval(token, approved: approved)
  }
}
