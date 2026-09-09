// Appended to a temporary controller copy by test-file-state-owner.sh; never compiled separately.

@MainActor private var ownerTestCompletedOperations: Set<UUID> = []
extension EditorWindowController {
  var ownerTestReplayCancellation: MacroCancellation? { replayCancellation }
  func ownerTestSetReplayCancellation(_ value: MacroCancellation?) { replayCancellation = value }
  func ownerTestFinished(_ id: UUID) -> Bool { ownerTestCompletedOperations.contains(id) }
  func ownerTestLineEndings() {
    convertLineEndings(current!, source: preferredPane(in: current!), to: .lf)
  }
  func ownerTestCommand(
    _ operation: @escaping @Sendable (String, NSRange) throws -> LineCommandResult
  ) {
    performDocumentCommand("Synthetic gated command", operation: operation)
  }
  func ownerTestConvertGated(
    _ validate: @escaping @Sendable (DecodedDocument) throws -> Void, onFinish: @escaping () -> Void
  ) {
    convertEncoding(current!, encoding: .utf16BE, bom: true, validate: validate, onFinish: onFinish)
  }
  var ownerTestDocument: EditorDocument? { current }
  func ownerTestSave() { save(current!, saveAs: false) }
  func ownerTestConvert(_ encoding: DocumentEncoding, onFinish: @escaping () -> Void) {
    convertEncoding(current!, encoding: encoding, bom: false, onFinish: onFinish)
  }
  func ownerTestReload(onReload: @escaping () -> Void) { reload(onReload: onReload) }
}
