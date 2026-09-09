import Foundation

public struct ComparisonRow: Equatable, Sendable {
  /// Original line including its ending; nil is an alignment placeholder.
  public let left: String?
  public let right: String?
}
public struct TextComparisonResult: Sendable {
  public let leftText: String
  public let rightText: String
  public let rows: [ComparisonRow]
  public let differenceRows: [Int]
}
public enum TextComparisonError: Error, LocalizedError {
  case textLimit, lineLimit
  public var errorDescription: String? {
    switch self {
    case .textLimit:
      return
        "Comparison accepts at most 2 MB per file and 2 MB of decoded UTF-8 text per side. Compare smaller excerpts."
    case .lineLimit:
      return "Comparison accepts at most 2,000 logical lines per side. Compare smaller excerpts."
    }
  }
}
public enum TextComparison {
  public static let maximumBytes = 2_000_000
  public static let maximumLines = 2_000

  public static func readFile(_ url: URL, isCancelled: () -> Bool = { false }) throws -> String {
    if isCancelled() { throw CancellationError() }
    let reader = try LargeFileReader(url: url)
    guard reader.identity.size <= maximumBytes else { throw TextComparisonError.textLimit }
    var data = Data()
    var offset: Int64 = 0
    while offset < reader.identity.size {
      if isCancelled() { throw CancellationError() }
      let chunk = try reader.readWindow(
        offset: offset, length: min(1_048_576, Int(reader.identity.size - offset)))
      data.append(chunk)
      offset += Int64(chunk.count)
    }
    _ = try reader.readWindow(offset: offset, length: 0)
    if isCancelled() { throw CancellationError() }
    let text = try DocumentCodec.decode(data).text
    guard text.utf8.count <= maximumBytes else { throw TextComparisonError.textLimit }
    return text
  }

  public static func compare(left: String, right: String, isCancelled: () -> Bool = { false })
    throws -> TextComparisonResult
  {
    func check() throws { if isCancelled() { throw CancellationError() } }
    try check()
    guard left.utf8.count <= maximumBytes, right.utf8.count <= maximumBytes else {
      throw TextComparisonError.textLimit
    }
    var identifiers: [Data: Int] = [:]
    func lines(_ text: String) throws -> [(text: String, id: Int)] {
      let bytes = Array(text.utf8)
      var result: [(text: String, id: Int)] = []
      var start = 0
      var cursor = 0
      func append(_ end: Int) throws {
        try check()
        guard result.count < maximumLines else { throw TextComparisonError.lineLimit }
        let data = Data(bytes[start..<end])
        let id: Int
        if let existing = identifiers[data] {
          id = existing
        } else {
          id = identifiers.count
          identifiers[data] = id
        }
        result.append((String(decoding: data, as: UTF8.self), id))
        start = end
      }
      while cursor < bytes.count {
        if cursor.isMultiple(of: 4096) { try check() }
        if bytes[cursor] == 13 || bytes[cursor] == 10 {
          if bytes[cursor] == 13, cursor + 1 < bytes.count, bytes[cursor + 1] == 10 { cursor += 1 }
          cursor += 1
          try append(cursor)
        } else {
          cursor += 1
        }
      }
      try append(bytes.count)
      return result
    }
    let a = try lines(left)
    let b = try lines(right)
    let width = b.count + 1
    // At most 4 million cell evaluations and 4,004,001 UInt16 entries.
    var lcs = [UInt16](repeating: 0, count: (a.count + 1) * width)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      try check()
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        lcs[i * width + j] =
          a[i].id == b[j].id
          ? 1 + lcs[(i + 1) * width + j + 1]
          : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
      }
    }
    var rows: [ComparisonRow] = []
    var differences: [Int] = []
    var removed: [String] = []
    var inserted: [String] = []
    func flush() {
      for index in 0..<max(removed.count, inserted.count) {
        differences.append(rows.count)
        rows.append(
          ComparisonRow(
            left: index < removed.count ? removed[index] : nil,
            right: index < inserted.count ? inserted[index] : nil))
      }
      removed.removeAll(keepingCapacity: true)
      inserted.removeAll(keepingCapacity: true)
    }
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      try check()
      if i < a.count, j < b.count, a[i].id == b[j].id {
        flush()
        rows.append(ComparisonRow(left: a[i].text, right: b[j].text))
        i += 1
        j += 1
      } else if i < a.count, j == b.count || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
        removed.append(a[i].text)
        i += 1
      } else {
        inserted.append(b[j].text)
        j += 1
      }
    }
    flush()
    return TextComparisonResult(
      leftText: left, rightText: right, rows: rows, differenceRows: differences)
  }
}
