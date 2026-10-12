import AppKit

enum SelectionInstallationError: Error { case nested, unauthorized }

@MainActor
final class DocumentTextView: NSTextView {
  let documentUndo: UndoManager
  // Weak native route only; exact C/D/pane/storage/lease checks grant authority later.
  private(set) weak var controlledStringOwner: EditorWindowController?
  func installControlledStringOwner(_ owner: EditorWindowController) {
    controlledStringOwner = owner
  }
  func retireControlledStringOwner(_ owner: EditorWindowController) {
    if controlledStringOwner === owner { controlledStringOwner = nil }
  }
  // APPROVED-VIEW-DECISION-BEGIN
  private(set) weak var approvedViewOwner: EditorWindowController?
  private(set) weak var approvedViewStorage: DocumentCommitTextStorage?
  private(set) weak var approvedViewWindow: NSWindow?
  private(set) var approvedViewRoute: ApprovedViewRoute?
  func installApprovedViewOwner(
    _ owner: EditorWindowController,
    storage: DocumentCommitTextStorage, window: NSWindow, route: ApprovedViewRoute
  ) {
    approvedViewOwner = owner
    approvedViewStorage = storage
    approvedViewWindow = window
    approvedViewRoute = route
  }
  func retireApprovedViewOwner(_ owner: EditorWindowController) {
    if approvedViewOwner === owner {
      approvedViewOwner = nil
      approvedViewStorage = nil
      approvedViewWindow = nil
      approvedViewRoute = nil
    }
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    approvedViewOwner?.nativeApprovedViewRetire(self)
    EditorWindowController.withNativeMacroProcessingBarrier {
      super.viewWillMove(toWindow: newWindow)
    }
  }
  override func shouldChangeText(
    in affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    let owner = approvedViewOwner
    let decision = owner?.nativeApprovedDecisionBegin(
      self, range: affectedCharRange,
      replacement: replacementString, singular: true)
    defer { EditorWindowController.nativeApprovedDecisionCancel(decision) }
    let result = EditorWindowController.withApprovedViewDecisionBarrier(decision) {
      super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    owner?.nativeApprovedDecisionFinish(self, decision: decision, result: result)
    return result
  }
  override func shouldChangeText(
    inRanges affectedRanges: [NSValue],
    replacementStrings: [String]?
  ) -> Bool {
    let owner = approvedViewOwner
    let decision = owner?.nativeApprovedDecisionBegin(
      self, range: nil,
      replacement: nil, singular: false)
    defer { EditorWindowController.nativeApprovedDecisionCancel(decision) }
    let result = EditorWindowController.withApprovedViewDecisionBarrier(decision) {
      super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }
    owner?.nativeApprovedDecisionFinish(self, decision: decision, result: result)
    return result
  }
  // APPROVED-VIEW-DECISION-END
  init(
    frame: NSRect, textContainer: NSTextContainer, undoManager: UndoManager,
    configurationAllowsInteraction: (() -> Bool)? = nil
  ) {
    documentUndo = undoManager
    self.configurationAllowsInteraction = configurationAllowsInteraction
    super.init(frame: frame, textContainer: textContainer)
  }
  required init?(coder: NSCoder) { fatalError("Use injected document undo manager") }
  var onFocus: (() -> Void)?
  var configurationAllowsInteraction: (() -> Bool)?
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
    guard configurationAllowsInteraction?() ?? true else { return false }
    guard !checkingSelectionAdmission else { return false }
    checkingSelectionAdmission = true
    defer { checkingSelectionAdmission = false }
    let allowed = selectionInstallation?() ?? (canChangeSelection?() ?? true)
    return allowed && (configurationAllowsInteraction?() ?? true)
  }
  override func becomeFirstResponder() -> Bool {
    guard configurationAllowsInteraction?() ?? true else { return false }
    guard canFocus?() ?? true, configurationAllowsInteraction?() ?? true else { return false }
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
    guard configurationAllowsInteraction?() ?? true else { return }
    guard canMutate?() ?? true, configurationAllowsInteraction?() ?? true else { return }
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
    guard configurationAllowsInteraction?() ?? true else { return }
    guard canMutate?() ?? true, configurationAllowsInteraction?() ?? true else { return }
    let previousInsertion = isOrdinaryTextInsertion
    isOrdinaryTextInsertion = !isComposingText && replacementRange.location == NSNotFound
    compositionOperationDepth += 1
    defer {
      compositionOperationDepth -= 1
      isOrdinaryTextInsertion = previousInsertion
      if compositionOperationDepth == 0, !hasMarkedText() { finishComposition() }
    }
    if isOrdinaryTextInsertion, Swift.type(of: insertString) == String.self,
      let replacement = insertString as? String, let owner = controlledStringOwner
    {
      switch owner.controlledStringInsertion(self, replacement: replacement) {
      case .handledRefused, .handledCommitted: return
      case .unhandled: break
      }
    }
    // Inactive/unsupported input retains exactly one actual inherited native attempt.
    super.insertText(insertString, replacementRange: replacementRange)
  }
  override func unmarkText() {
    guard configurationAllowsInteraction?() ?? true else { return }
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
