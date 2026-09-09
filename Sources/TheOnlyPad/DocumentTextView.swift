import AppKit

enum SelectionInstallationError: Error { case nested, unauthorized }

@MainActor
final class DocumentTextView: NSTextView {
  let documentUndo: UndoManager
  init(frame: NSRect, textContainer: NSTextContainer, undoManager: UndoManager) {
    documentUndo = undoManager
    super.init(frame: frame, textContainer: textContainer)
  }
  required init?(coder: NSCoder) { fatalError("Use injected document undo manager") }
  var onFocus: (() -> Void)?
  var canFocus: (() -> Bool)?
  var canMutate: (() -> Bool)?
  var canChangeSelection: (() -> Bool)?
  private var selectionInstallation: (() -> Bool)?
  private var checkingSelectionAdmission = false
  func withSelectionInstallation<T>(
    authorizedBy: @escaping () -> Bool, _ body: () throws -> T
  ) throws -> T {
    guard selectionInstallation == nil else { throw SelectionInstallationError.nested }
    selectionInstallation = authorizedBy
    defer { selectionInstallation = nil }
    guard allowsSelection() else { throw SelectionInstallationError.unauthorized }
    return try body()
  }
  private func allowsSelection() -> Bool {
    guard !checkingSelectionAdmission else { return false }
    checkingSelectionAdmission = true
    defer { checkingSelectionAdmission = false }
    if let selectionInstallation { return selectionInstallation() }
    return canChangeSelection?() ?? true
  }
  override func becomeFirstResponder() -> Bool {
    guard canFocus?() ?? true else { return false }
    let accepted = super.becomeFirstResponder()
    if accepted { onFocus?() }
    return accepted
  }
  override var undoManager: UndoManager? { documentUndo }
  var onMarkedTextUpdated: (() -> Void)?
  var onTypingRunEnded: (() -> Void)?
  private(set) var isOrdinaryTextInsertion = false
  var onCompositionBegan: (() -> Void)?
  var onCompositionEnded: (() -> Void)?
  private(set) var isComposingText = false
  // AppKit may call setMarkedText again inside unmarkText; finalize only at the outer boundary.
  private var compositionOperationDepth = 0
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard canMutate?() ?? true else { return }
    if !isComposingText {
      isComposingText = true
      onCompositionBegan?()
    }
    compositionOperationDepth += 1
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    onMarkedTextUpdated?()
    compositionOperationDepth -= 1
    if compositionOperationDepth == 0, !hasMarkedText() { finishComposition() }
  }
  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    guard canMutate?() ?? true else { return }
    let previousInsertion = isOrdinaryTextInsertion
    isOrdinaryTextInsertion = !isComposingText && replacementRange.location == NSNotFound
    compositionOperationDepth += 1
    super.insertText(insertString, replacementRange: replacementRange)
    compositionOperationDepth -= 1
    isOrdinaryTextInsertion = previousInsertion
    if compositionOperationDepth == 0, !hasMarkedText() { finishComposition() }
  }
  override func unmarkText() {
    compositionOperationDepth += 1
    super.unmarkText()
    compositionOperationDepth -= 1
    if compositionOperationDepth == 0 { finishComposition() }
  }
  override func breakUndoCoalescing() {
    onTypingRunEnded?()
    super.breakUndoCoalescing()
  }
  override func setSelectedRange(_ charRange: NSRange) {
    guard allowsSelection() else { return }
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    guard allowsSelection() else { return }
    super.setSelectedRange(charRange)
  }
  override func setSelectedRange(
    _ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    guard allowsSelection() else { return }
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    guard allowsSelection() else { return }
    super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
  }
  override func setSelectedRanges(
    _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
  ) {
    guard allowsSelection() else { return }
    if compositionOperationDepth == 0 { onTypingRunEnded?() }
    guard allowsSelection() else { return }
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
  }
  private func finishComposition() {
    guard isComposingText else { return }
    isComposingText = false
    onCompositionEnded?()
  }

}
