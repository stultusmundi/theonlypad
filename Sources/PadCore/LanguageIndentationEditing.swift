import Foundation

public enum LanguageIndentationCommand: Sendable {
  case indent, outdent
}

public enum LanguageIndentationError: Error, Equatable, LocalizedError, Sendable {
  case invalidWidth, invalidSelection, textLimit, lineLimit

  public var errorDescription: String? {
    switch self {
    case .invalidWidth:
      return "Choose an indentation width from 1 through 8."
    case .invalidSelection:
      return
        "The selection is outside the document or divides a Unicode scalar. Select the text again."
    case .textLimit:
      return
        "Indentation commands accept input and output up to 2 million UTF-16 units. Select a smaller document."
    case .lineLimit:
      return "Indentation commands accept up to 20,000 logical lines. Select a smaller document."
    }
  }
}

/// Pure textual indentation. The insertion unit supplies text only; callers
/// still own native admission, caret installation, and undo grouping.
public enum LanguageIndentationEditing {
  private static func width(for policy: LanguageIndentation) throws -> Int {
    switch policy {
    case .legacy:
      return 4
    case .spaces(let width), .tabs(let width):
      guard (1...8).contains(width) else { throw LanguageIndentationError.invalidWidth }
      return width
    }
  }

  public static func insertion(for policy: LanguageIndentation) throws -> String {
    let width = try width(for: policy)
    switch policy {
    case .spaces: return String(repeating: " ", count: width)
    case .tabs, .legacy: return "\t"
    }
  }

  public static func apply(
    command: LanguageIndentationCommand, text: String, selection: NSRange,
    policy: LanguageIndentation, isCancelled: () -> Bool = { false }
  ) throws -> LineCommandResult {
    let width = try width(for: policy)
    var work = BoundedLanguageEditing()
    do {
      let units = try work.read(text, isCancelled: isCancelled)
      try work.validate(selection, in: units)
      let lines = try work.lines(in: units, isCancelled: isCancelled)
      let touched = try work.touched(lines, selection: selection, isCancelled: isCancelled)
      let prefix: [UInt16]
      switch policy {
      case .tabs: prefix = [9]
      case .spaces, .legacy: prefix = [UInt16](repeating: 32, count: width)
      }
      var edits: [BoundedLanguageEditing.Edit] = []
      for index in touched.first...touched.last {
        try work.step(isCancelled)
        let line = lines[index]
        switch command {
        case .indent:
          edits.append(.init(start: line.start, removed: 0, inserted: prefix))
        case .outdent:
          var removed = 0
          if line.start < line.bodyEnd, units[line.start] == 9 {
            removed = 1
          } else {
            while removed < width, line.start + removed < line.bodyEnd,
              units[line.start + removed] == 32
            {
              try work.step(isCancelled)
              removed += 1
            }
          }
          edits.append(.init(start: line.start, removed: removed, inserted: []))
        }
      }
      let result = try work.applying(edits, to: units, isCancelled: isCancelled)
      let mapped = try work.selection(
        selection, lines: lines, first: touched.first,
        last: touched.last, edits: edits, isCancelled: isCancelled)
      try work.check(isCancelled)
      return LineCommandResult(text: result, selection: mapped)
    } catch let error as BoundedLanguageEditing.Failure {
      switch error {
      case .invalidSelection: throw LanguageIndentationError.invalidSelection
      case .textLimit: throw LanguageIndentationError.textLimit
      case .lineLimit: throw LanguageIndentationError.lineLimit
      }
    }
  }
}
