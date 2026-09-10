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
  var onBoundsChanged: (() -> Void)?
  private var boundsObserver: NSObjectProtocol?

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
      undoManager: document.undoManager,
      configurationAllowsInteraction: { [weak document] in
        guard let document else { return false }
        return document.nativeConfigurationToken == nil
      })
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
    scroll.contentView.postsBoundsChangedNotifications = true
    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onBoundsChanged?() }
    }
    editor.setAccessibilityLabel("Document text")
    editor.setAccessibilityIdentifier("editor.text.\(id.uuidString)")
  }
  deinit {
    if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
  }
  /// Geometry may need refreshing even when the semantic wrap proof is unchanged.
  func configureWrapGeometry(enabled wrap: Bool, validate: () throws -> Void) throws {
    try validate()
    editor.isHorizontallyResizable = !wrap
    try validate()
    scroll.hasHorizontalScroller = !wrap
    try validate()
    textContainer.widthTracksTextView = wrap
    try validate()
    textContainer.containerSize = NSSize(
      width: wrap ? max(100, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    try validate()
    if wrap {
      editor.setFrameSize(
        NSSize(width: max(100, scroll.contentSize.width), height: editor.frame.height))
      try validate()
    }
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
