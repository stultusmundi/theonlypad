import Foundation

public enum MarkdownBlockKind: Equatable, Sendable {
  case paragraph
  case heading(Int)
  case list, code
}
public struct MarkdownPreviewRun: Sendable {
  public let text: String
  public let bold: Bool
  public let italic: Bool
  public let code: Bool
}
public struct MarkdownPreviewBlock: Sendable {
  public let kind: MarkdownBlockKind
  public let runs: [MarkdownPreviewRun]
}
public enum MarkdownPreviewError: Error, LocalizedError {
  case limit
  public var errorDescription: String? {
    "Preview exceeds its limit (2 MB of input/output, 20,000 lines or 100,000 style runs). Preview a smaller excerpt."
  }
}

/// Deliberately limited preview. URLs and HTML are never interpreted or fetched.
public enum MarkdownPreview {
  public static func parse(_ text: String, isCancelled: () -> Bool = { false }) throws
    -> [MarkdownPreviewBlock]
  {
    guard text.utf8.count <= 2_000_000 else { throw MarkdownPreviewError.limit }
    func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
    try checkCancellation()
    let lines = text.split(maxSplits: 20_000, omittingEmptySubsequences: false) {
      $0 == "\n" || $0 == "\r" || $0 == "\r\n"
    }
    guard lines.count <= 20_000 else { throw MarkdownPreviewError.limit }
    var blocks: [MarkdownPreviewBlock] = []
    var fenced = false
    var fence = ""
    var outputBytes = 0
    var runCount = 0
    for source in lines {
      try checkCancellation()
      let line = String(source)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        // Only the matching fence closes a block; other fence text remains code.
        if !fenced {
          fenced = true
          fence = String(line.prefix(3))
          continue
        }
        if line.hasPrefix(fence) {
          fenced = false
          continue
        }
      }
      var kind: MarkdownBlockKind = fenced ? .code : .paragraph
      var body = line
      var prefix = ""
      if !fenced {
        let hashes = line.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
          kind = .heading(hashes)
          body = String(line.dropFirst(hashes + 1))
        } else if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
          kind = .list
          body = String(line.dropFirst(2))
          prefix = "• "
        } else {
          let digits = line.prefix(10).prefix(while: { $0.isASCII && $0.isNumber })
          if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { kind = .list }
        }
      }
      var runs: [MarkdownPreviewRun] = []
      if !prefix.isEmpty {
        runs.append(.init(text: prefix, bold: false, italic: false, code: false))
      }
      // Preserve entire risky-markup lines literally and discard all Foundation URL attributes.
      if fenced || body.utf8.count > 16_384 || body.contains("<") || body.contains("![")
        || body.contains("](") || body.contains("][")
      {
        runs.append(.init(text: body, bold: false, italic: false, code: fenced))
      } else {
        let attributed = try AttributedString(
          markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        for run in attributed.runs {
          try checkCancellation()
          let intent = run.inlinePresentationIntent ?? []
          runs.append(
            .init(
              text: String(attributed[run.range].characters),
              bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
              code: intent.contains(.code)))
        }
      }
      runCount += runs.count
      outputBytes += runs.reduce(0) { $0 + $1.text.utf8.count } + 1
      guard runCount <= 100_000, outputBytes <= 2_000_000 else { throw MarkdownPreviewError.limit }
      blocks.append(.init(kind: kind, runs: runs))
    }
    try checkCancellation()
    return blocks
  }
}
