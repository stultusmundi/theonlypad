import AppKit
import PadCore

/// Storage-owned lexical work; colors remain temporary layout attributes.
@MainActor final class NativeSyntaxHighlighter {
  typealias Parser =
    @Sendable (String, DocumentLanguage, @escaping @Sendable () -> Bool) async throws ->
    [SyntaxToken]
  private weak var storage: NSTextStorage?
  private let parser: Parser
  private let debounceNanoseconds: UInt64
  private var generation: UInt64 = 0
  private var pending: Task<Void, Never>?
  private var worker: Task<[SyntaxToken], Error>?
  private struct Cache {
    let generation: UInt64
    let text: String
    let tokens: [SyntaxToken]
  }
  private var cache: Cache?

  init(storage: NSTextStorage?, debounceNanoseconds: UInt64 = 180_000_000, parser: Parser? = nil) {
    self.storage = storage
    self.debounceNanoseconds = debounceNanoseconds
    self.parser =
      parser ?? { text, language, cancelled in
        try LanguageService.tokens(in: text, language: language, isCancelled: cancelled)
      }
  }
  convenience init(editor: NSTextView) { self.init(storage: editor.textStorage) }
  deinit {
    pending?.cancel()
    worker?.cancel()
  }
  func invalidateForCharacterEdit() {
    invalidate()
  }
  private func invalidate() {
    generation &+= 1
    cache = nil
    pending?.cancel()
    worker?.cancel()
  }
  func update(language: DocumentLanguage) {
    invalidate()
    guard let storage else { return }
    let full = NSRange(location: 0, length: storage.length)
    for layout in storage.layoutManagers {
      layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }
    guard full.length <= 2_000_000, language != .plainText else { return }
    let revision = generation
    let text = storage.string
    let parser = self.parser
    let delay = debounceNanoseconds
    pending = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard !Task.isCancelled, self?.generation == revision else { return }
      let task = Task.detached(priority: .utility) {
        try await parser(text, language, { Task.isCancelled })
      }
      self?.worker = task
      let tokens = try? await task.value
      guard let self, let storage = self.storage, !Task.isCancelled,
        self.generation == revision, storage.string.utf16.elementsEqual(text.utf16),
        let tokens, tokens.count <= 100_000,
        tokens.allSatisfy({ token in
          token.range.location >= 0 && token.range.length >= 0
            && token.range.location <= full.length
            && token.range.length <= full.length - token.range.location
        })
      else { return }
      self.cache = Cache(generation: revision, text: text, tokens: tokens)
      for layout in storage.layoutManagers { self.applyCachedTokens(to: layout) }
    }
  }
  /// False means no current cache or the target is not presently attached to this storage.
  @discardableResult func applyCachedTokens(to layout: NSLayoutManager) -> Bool {
    guard let storage, let cache, cache.generation == generation,
      layout.textStorage === storage, storage.layoutManagers.contains(where: { $0 === layout }),
      storage.length <= 2_000_000, storage.string.utf16.elementsEqual(cache.text.utf16)
    else { return false }
    let full = NSRange(location: 0, length: storage.length)
    layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    for token in cache.tokens {
      let color: NSColor
      switch token.kind {
      case .comment: color = .secondaryLabelColor
      case .string: color = .systemRed
      case .keyword: color = .systemPurple
      case .number: color = .systemBlue
      case .markup: color = .systemTeal
      }
      layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
    }
    return true
  }
}
