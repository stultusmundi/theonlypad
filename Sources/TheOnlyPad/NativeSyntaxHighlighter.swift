import AppKit
import PadCore

/// Temporary display colors never enter document bytes or native undo history.
@MainActor
final class NativeSyntaxHighlighter {
  private weak var storage: NSTextStorage?
  private var generation: UInt64 = 0
  private var pending: Task<Void, Never>?
  private var worker: Task<[SyntaxToken], Error>?
  init(storage: NSTextStorage) { self.storage = storage }
  init(editor: NSTextView) { self.storage = editor.textStorage }

  func update(language: DocumentLanguage) {
    generation &+= 1
    let revision = generation
    pending?.cancel()
    worker?.cancel()
    guard let storage else { return }
    let text = storage.string
    let full = NSRange(location: 0, length: text.utf16.count)
    for layout in storage.layoutManagers {
      layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }
    guard full.length <= 2_000_000, language != .plainText else { return }
    pending = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      let task = Task.detached(priority: .utility) {
        try LanguageService.tokens(in: text, language: language, isCancelled: { Task.isCancelled })
      }
      self?.worker = task
      let tokens = try? await task.value
      guard let self, let storage = self.storage, !Task.isCancelled,
        self.generation == revision, storage.string.utf16.elementsEqual(text.utf16), let tokens
      else { return }
      for token in tokens {
        let color: NSColor
        switch token.kind {
        case .comment: color = .secondaryLabelColor
        case .string: color = .systemRed
        case .keyword: color = .systemPurple
        case .number: color = .systemBlue
        case .markup: color = .systemTeal
        }
        for layout in storage.layoutManagers {
          layout.addTemporaryAttribute(
            .foregroundColor, value: color, forCharacterRange: token.range)
        }
      }
    }
  }
}
