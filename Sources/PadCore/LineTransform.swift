import Foundation

public enum LineTransform: String, CaseIterable, Codable, Sendable {
  case sorted, deduplicated, trimTrailingWhitespace, uppercase, lowercase, indent, outdent

  public func apply(to text: String) -> String {
    if self == .uppercase { return text.uppercased() }
    if self == .lowercase { return text.lowercased() }
    var lines: [String] = []
    var separators: [String] = []
    var start = text.startIndex
    for index in text.indices {
      let c = text[index]
      if c == "\n" || c == "\r" || c == "\r\n" {
        lines.append(String(text[start..<index]))
        separators.append(String(c))
        start = text.index(after: index)
      }
    }
    let terminated = start == text.endIndex && !separators.isEmpty
    if !terminated { lines.append(String(text[start...])) }
    switch self {
    case .sorted: lines.sort()
    case .deduplicated:
      var seen = Set<Data>()
      var keptLines: [String] = []
      var keptSeparators: [String] = []
      for (index, line) in lines.enumerated() where seen.insert(Data(line.utf8)).inserted {
        keptLines.append(line)
        keptSeparators.append(index < separators.count ? separators[index] : "")
      }
      if !terminated, !keptSeparators.isEmpty { keptSeparators[keptSeparators.count - 1] = "" }
      return zip(keptLines, keptSeparators).map { $0 + $1 }.joined()
    case .trimTrailingWhitespace:
      lines = lines.map { line in
        var line = line
        while line.last == " " || line.last == "\t" { line.removeLast() }
        return line
      }
    case .indent: lines = lines.map { "    " + $0 }
    case .outdent:
      lines = lines.map { line in
        if line.first == "\t" { return String(line.dropFirst()) }
        return String(line.dropFirst(min(4, line.prefix(while: { $0 == " " }).count)))
      }
    default: break
    }
    var result = ""
    for (index, line) in lines.enumerated() {
      result += line
      if index < lines.count - 1 || terminated {
        result += index < separators.count ? separators[index] : (separators.first ?? "\n")
      }
    }
    return result
  }
}
