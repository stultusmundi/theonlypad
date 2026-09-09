import Foundation

public enum DocumentLanguage: String, CaseIterable, Codable, Sendable {
  case plainText, swift, python, javascript, typescript, json, html, xml, css, shell, c, cpp, java,
    rust, go, yaml, toml, markdown
}
public enum TokenKind: String, Sendable { case comment, string, keyword, number, markup }
public struct SyntaxToken: Equatable, Sendable {
  public let range: NSRange
  public let kind: TokenKind
}
public enum LanguageError: Error { case analysisLimit, cancelled }

/// Small-document lexical assistance, not a parser or semantic language server.
public enum LanguageService {
  public static func detect(filename: String, text: String) -> DocumentLanguage {
    let ext = (filename as NSString).pathExtension.lowercased()
    let map: [String: DocumentLanguage] = [
      "swift": .swift, "py": .python, "js": .javascript, "jsx": .javascript,
      "ts": .typescript, "tsx": .typescript, "json": .json, "html": .html, "htm": .html,
      "xml": .xml, "svg": .xml, "css": .css, "sh": .shell, "zsh": .shell, "bash": .shell,
      "c": .c, "h": .c, "cc": .cpp, "cpp": .cpp, "hpp": .cpp, "java": .java,
      "rs": .rust, "go": .go, "yaml": .yaml, "yml": .yaml, "toml": .toml, "md": .markdown,
    ]
    if let language = map[ext] { return language }
    let first = String(text.prefix(256).split(whereSeparator: \.isNewline).first ?? "")
    if first.hasPrefix("#!") {
      if first.contains("python") { return .python }
      if first.contains("bash") || first.contains("/sh") || first.contains("zsh") { return .shell }
    }
    return .plainText
  }

  public static func tokens(
    in text: String, language: DocumentLanguage, isCancelled: () -> Bool = { false }
  ) throws -> [SyntaxToken] {
    guard text.utf16.count <= 2_000_000 else { throw LanguageError.analysisLimit }
    guard language != .plainText else { return [] }
    let hashComments: Set<DocumentLanguage> = [.python, .shell, .yaml, .toml]
    let slashLineComments: Set<DocumentLanguage> = [
      .swift, .javascript, .typescript, .c, .cpp, .java, .rust, .go,
    ]
    let slashBlockComments = slashLineComments.union([.css])
    let words: String
    switch language {
    case .swift:
      words =
        "let var func class struct enum protocol extension import return if else guard for while switch case throw throws try catch async await actor public private static nil true false"
    case .python:
      words =
        "def class import from return if elif else for while try except finally with as lambda pass raise None True False async await yield in not and or"
    case .javascript, .typescript:
      words =
        "const let var function class interface type import export from return if else for while switch case try catch throw async await new null undefined true false"
    case .json: words = "true false null"
    case .shell: words = "if then else elif fi for do done while case esac function in export local"
    case .yaml, .toml: words = "true false null"
    default:
      words =
        "return if else for while switch case class struct enum public private static const int void bool import package func fn let var new true false null nil"
    }
    let keywords = Set(words.split(separator: " ").map(String.init))
    let units = Array(text.utf16)
    var result: [SyntaxToken] = []
    var index = 0
    func at(_ offset: Int, _ value: UInt16) -> Bool {
      offset < units.count && units[offset] == value
    }
    func identifier(_ value: UInt16) -> Bool {
      (65...90).contains(value) || (97...122).contains(value) || value == 95
        || (48...57).contains(value)
    }
    func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
      result.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
    }
    while index < units.count {
      if isCancelled() { throw LanguageError.cancelled }
      guard result.count < 100_000 else { throw LanguageError.analysisLimit }
      let start = index
      let value = units[index]
      if (hashComments.contains(language) && value == 35)
        || (slashLineComments.contains(language) && value == 47 && at(index + 1, 47))
      {
        while index < units.count && units[index] != 10 && units[index] != 13 { index += 1 }
        emit(start, index, .comment)
      } else if slashBlockComments.contains(language) && value == 47 && at(index + 1, 42) {
        index += 2
        while index < units.count && !(at(index, 42) && at(index + 1, 47)) { index += 1 }
        index = min(units.count, index + 2)
        emit(start, index, .comment)
      } else if value == 34 || value == 39 {
        index += 1
        while index < units.count {
          if units[index] == 92 {
            index = min(units.count, index + 2)
          } else if units[index] == value {
            index += 1
            break
          } else {
            index += 1
          }
        }
        emit(start, index, .string)
      } else if [.html, .xml].contains(language) && value == 60 {
        while index < units.count && units[index] != 62 { index += 1 }
        index = min(units.count, index + 1)
        emit(start, index, .markup)
      } else if language == .markdown && value == 35
        && (index == 0 || units[index - 1] == 10 || units[index - 1] == 13)
      {
        while index < units.count && units[index] != 10 && units[index] != 13 { index += 1 }
        emit(start, index, .markup)
      } else if identifier(value) {
        while index < units.count && identifier(units[index]) { index += 1 }
        let token = String(decoding: units[start..<index], as: UTF16.self)
        if keywords.contains(token) {
          emit(start, index, .keyword)
        } else if token.utf8.allSatisfy({ (48...57).contains($0) }) {
          emit(start, index, .number)
        }
      } else {
        index += 1
      }
    }
    return result
  }

  public static func formatJSON(_ text: String) throws -> String {
    guard text.utf8.count <= 2_000_000 else { throw LanguageError.analysisLimit }
    // Validate syntax, but never serialize Foundation's numeric objects: that
    // can round large numbers or discard duplicate keys. Preserve lexemes.
    _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    let tokens = Array(text.unicodeScalars)
    var output = ""
    var outputBytes = 0
    func append(_ value: String) throws {
      let count = value.utf8.count
      guard count <= 8_000_000 - outputBytes else { throw LanguageError.analysisLimit }
      output += value
      outputBytes += count
    }
    var depth = 0
    var quoted = false
    var escaped = false
    var previous: Unicode.Scalar?
    func newline() throws { try append("\n" + String(repeating: "  ", count: depth)) }
    for (index, character) in tokens.enumerated() {
      if quoted {
        try append(String(character))
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          quoted = false
        }
        continue
      }
      if character.properties.isWhitespace { continue }
      switch character {
      case "\"":
        quoted = true
        try append(String(character))
      case "{", "[":
        try append(String(character))
        depth += 1
        let next = tokens[(index + 1)...].first { !$0.properties.isWhitespace }
        if next != "}" && next != "]" { try newline() }
      case "}", "]":
        depth = max(0, depth - 1)
        if previous != "{" && previous != "[" { try newline() }
        try append(String(character))
      case ",":
        try append(String(character))
        try newline()
      case ":": try append(": ")
      default: try append(String(character))
      }
      previous = character
    }
    return output
  }
}
