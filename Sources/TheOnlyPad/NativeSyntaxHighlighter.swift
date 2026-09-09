import AppKit
import PadCore

/// Temporary display colors never enter document bytes or native undo history.
@MainActor
final class NativeSyntaxHighlighter {
  private weak var editor: NSTextView?
  private var generation: UInt64 = 0
  private var pending: Task<Void, Never>?
  private var worker: Task<[SyntaxToken], Error>?
  init(editor: NSTextView) { self.editor = editor }

  func update(language: DocumentLanguage) {
    generation &+= 1
    let revision = generation
    pending?.cancel()
    worker?.cancel()
    guard let editor else { return }
    let text = editor.string
    let full = NSRange(location: 0, length: text.utf16.count)
    editor.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    guard full.length <= 2_000_000, language != .plainText else { return }
    pending = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      let task = Task.detached(priority: .utility) {
        try LanguageService.tokens(in: text, language: language, isCancelled: { Task.isCancelled })
      }
      self?.worker = task
      let tokens = try? await task.value
      guard let self, let editor = self.editor, !Task.isCancelled,
        self.generation == revision, editor.string.utf16.elementsEqual(text.utf16), let tokens
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
        editor.layoutManager?.addTemporaryAttribute(
          .foregroundColor, value: color, forCharacterRange: token.range)
      }
    }
  }
}
