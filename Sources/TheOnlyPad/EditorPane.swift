import AppKit

@MainActor final class EditorPane {
  let id = UUID()
  unowned let document: EditorDocument
  let layoutManager: NSLayoutManager
  let textContainer: NSTextContainer
  let editor: DocumentTextView
  let scroll: NSScrollView
  private(set) var isAttached = true
  var selectableBeforeQuit: Bool?

  init(document: EditorDocument) {
    self.document = document
    layoutManager = NSLayoutManager()
    let layout = layoutManager
    textContainer = NSTextContainer(
      size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
    let container = textContainer
    document.storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.allowsNonContiguousLayout = true
    editor = DocumentTextView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 650), textContainer: container,
      undoManager: document.undoManager)
    editor.minSize = NSSize(width: 0, height: 0)
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.isRichText = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.usesFindBar = true
    editor.isIncrementalSearchingEnabled = true
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainerInset = NSSize(width: 12, height: 10)
    container.widthTracksTextView = true
    scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.documentView = editor
    scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: editor)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    editor.setAccessibilityLabel("Document text")
    editor.setAccessibilityIdentifier("editor.text.\(id.uuidString)")
  }
  func attach() {
    guard !isAttached else { return }
    document.storage.addLayoutManager(layoutManager)
    isAttached = true
    editor.isEditable = editor.canMutate?() ?? true
  }
  func detach() {
    guard isAttached else { return }
    scroll.removeFromSuperview()
    document.storage.removeLayoutManager(layoutManager)
    isAttached = false
    editor.isEditable = false
  }
}
