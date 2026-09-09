import AppKit
import PadCore

private actor ParserGate {
  private var texts: [String] = []
  private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
  private var cancellations: [Int: Bool] = [:]
  func parse(_ text: String, language: DocumentLanguage, cancelled: @escaping @Sendable () -> Bool)
    async throws -> [SyntaxToken]
  {
    let index = texts.count
    texts.append(text)
    await withCheckedContinuation { waiting[index] = $0 }
    cancellations[index] = cancelled()
    // Deliberately return a stale result despite cancellation to exercise consumer guards.
    return try LanguageService.tokens(in: text, language: language)
  }
  var count: Int { texts.count }
  func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
  func cancellation(_ index: Int) -> Bool? { cancellations[index] }
}

@main struct SharedPaneHighlightHarness {
  @MainActor static func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<500 {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    preconditionFailure("Timed out awaiting highlighter state")
  }
  @MainActor static func makeView(_ storage: NSTextStorage) -> NSTextView {
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    let view = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
    view.allowsUndo = true
    return view
  }
  @MainActor static func color(_ layout: NSLayoutManager, at offset: Int = 0) -> NSColor? {
    layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil)
      as? NSColor
  }
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let text = "true\r\n\"😀e\u{301}\"\n"
    let document = EditorDocument()
    let storage = document.storage
    storage.mutableString.setString(text)
    let first = document.panePool[0].editor
    let second = try document.makePane().editor
    first.setSelectedRange(NSRange(location: 0, length: 4))
    second.setSelectedRange(NSRange(location: 7, length: 2))
    let selections = [first.selectedRange(), second.selectedRange()]
    let undoBefore = [first.undoManager?.canUndo, second.undoManager?.canUndo]
    let gate = ParserGate()
    let highlighter = NativeSyntaxHighlighter(storage: storage, debounceNanoseconds: 0) {
      text, language, cancelled in
      try await gate.parse(text, language: language, cancelled: cancelled)
    }
    document.highlighter = highlighter
    highlighter.update(language: .json)
    try await wait { await gate.count == 1 }
    await gate.release(0)
    try await wait { color(first.layoutManager!) != nil && color(second.layoutManager!) != nil }
    let initialCalls = await gate.count
    precondition(initialCalls == 1, "One shared update must parse exactly once")
    let third = makeView(storage)
    precondition(highlighter.applyCachedTokens(to: third.layoutManager!))
    precondition(color(third.layoutManager!) == .systemPurple)
    let attachedCalls = await gate.count
    precondition(attachedCalls == 1, "Attach must reuse tokens without parser work")
    let foreign = makeView(NSTextStorage(string: text))
    precondition(!highlighter.applyCachedTokens(to: foreign.layoutManager!))
    let detached = third.layoutManager!
    storage.removeLayoutManager(detached)
    precondition(!highlighter.applyCachedTokens(to: detached))
    storage.addLayoutManager(detached)
    precondition(highlighter.applyCachedTokens(to: detached))
    precondition(Array(storage.string.utf16) == Array(text.utf16))
    precondition(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    precondition([first.selectedRange(), second.selectedRange()] == selections)
    precondition([first.undoManager?.canUndo, second.undoManager?.canUndo] == undoBefore)

    // Unannounced A->B->A edits still invalidate previously accepted cache.
    storage.mutableString.setString("false")
    storage.mutableString.setString(text)
    precondition(!highlighter.applyCachedTokens(to: first.layoutManager!))
    highlighter.update(language: .json)
    try await wait { await gate.count == 2 }
    storage.mutableString.setString("\"new\"")
    highlighter.update(language: .json)
    try await wait { await gate.count == 3 }
    await gate.release(2)
    try await wait { color(first.layoutManager!) == .systemRed }
    await gate.release(1)
    try await wait { await gate.cancellation(1) != nil }
    let cancellation = await gate.cancellation(1)
    precondition(cancellation == true)
    for _ in 0..<20 { await Task.yield() }
    precondition(
      color(first.layoutManager!) == .systemRed,
      "Late cancelled tokens must not replace current result")
    highlighter.update(language: .plainText)
    precondition(color(first.layoutManager!) == nil && color(second.layoutManager!) == nil)
    precondition(!highlighter.applyCachedTokens(to: first.layoutManager!))
    storage.mutableString.setString(String(repeating: "x", count: 2_000_001))
    highlighter.update(language: .json)
    precondition(!highlighter.applyCachedTokens(to: first.layoutManager!))
    for _ in 0..<20 { await Task.yield() }
    let finalCalls = await gate.count
    precondition(finalCalls == 3, "Plain text and over-limit buffers must not parse")
    print(
      "PASS shared highlighter cache: one parser, attach validation, edit invalidation, stale/cancelled results, temporary attributes and cap"
    )
  }
}
