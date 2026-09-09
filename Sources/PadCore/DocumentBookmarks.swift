import Foundation

public enum BookmarkDirection: Sendable { case next, previous }
public enum DocumentBookmarkError: Error, LocalizedError {
  case textLimit, nativeTextLimit, bookmarkLimit, staleAnchors
  public var errorDescription: String? {
    switch self {
    case .textLimit: return "Bookmark operations accept at most 100 MB of UTF-8 text."
    case .nativeTextLimit:
      return
        "Native bookmark tracking accepts at most 100 million UTF-16 units (up to 200 MB of UTF-16 backing storage)."
    case .bookmarkLimit: return "A document can contain at most 10,000 bookmarks."
    case .staleAnchors:
      return
        "Bookmark positions no longer match logical line starts. Restore the matching bookmark snapshot or reset the bookmarks."
    }
  }
}
/// Value-semantic per-document metadata. Pair snapshots with native undo/redo;
/// inverse edits cannot recover bookmarks lost through line deletion or merging.
public struct DocumentBookmarks: Equatable, Sendable {
  public static let maximumTextBytes = 100_000_000
  public static let maximumBookmarks = 10_000
  public static let maximumNativeUTF16 = 100_000_000
  public private(set) var offsets: [Int] = []
  public init() {}
  public init(offsets: [Int], in text: String) throws {
    guard offsets.count <= Self.maximumBookmarks else { throw DocumentBookmarkError.bookmarkLimit }
    self.offsets = Array(Set(offsets)).sorted()
    _ = try validatedLines(in: text)
  }
  /// Validates native persisted anchors without converting UTF16 storage to UTF8.
  /// The caller keeps storage unchanged throughout this synchronous call.
  public init(offsets: [Int], inUTF16 text: NSString) throws {
    guard offsets.count <= Self.maximumBookmarks else { throw DocumentBookmarkError.bookmarkLimit }
    guard text.length <= Self.maximumNativeUTF16 else {
      throw DocumentBookmarkError.nativeTextLimit
    }
    guard offsets.allSatisfy({ $0 >= 0 && $0 <= text.length }) else {
      throw TextEditError.invalidRange
    }
    guard
      offsets.allSatisfy({ offset in
        if offset == 0 { return true }
        let previous = text.character(at: offset - 1)
        return previous == 10
          || (previous == 13 && (offset == text.length || text.character(at: offset) != 10))
      })
    else { throw DocumentBookmarkError.staleAnchors }
    self.offsets = Array(Set(offsets)).sorted()
  }
  public mutating func removeAll() { offsets = [] }
  public mutating func toggle(atUTF16Offset offset: Int, in text: String) throws {
    let lines = try validatedLines(in: text, additional: [offset])
    let start = lines[offset]!.start
    if let index = offsets.firstIndex(of: start) {
      offsets.remove(at: index)
    } else {
      guard offsets.count < Self.maximumBookmarks else { throw DocumentBookmarkError.bookmarkLimit }
      offsets.append(start)
      offsets.sort()
    }
  }
  /// Exact source ranges, including each original line ending; EOF empty line is zero-length.
  public func ranges(in text: String) throws -> [NSRange] {
    let lines = try validatedLines(in: text)
    return offsets.map { NSRange(location: $0, length: lines[$0]!.end - $0) }
  }
  public func export(from text: String) throws -> String {
    let source = text as NSString
    return try ranges(in: text).map { source.substring(with: $0) }.joined()
  }
  /// Moves relative to the current logical line; wraps, including a sole bookmark.
  public func destination(from offset: Int, direction: BookmarkDirection, in text: String) throws
    -> Int?
  {
    let lines = try validatedLines(in: text, additional: [offset])
    let start = lines[offset]!.start
    switch direction {
    case .next: return offsets.first(where: { $0 > start }) ?? offsets.first
    case .previous: return offsets.last(where: { $0 < start }) ?? offsets.last
    }
  }
  /// Call in edit order with the exact pre-edit text. Apply only after the native
  /// edit succeeds, or keep/restore the prior value if the native edit is rejected.
  /// No edit may mutate this value on failure.
  public mutating func remap(through edit: TextEdit, in oldText: String) throws {
    let lines = try validatedLines(in: oldText)
    guard edit.replacement.utf8.count <= Self.maximumTextBytes else {
      throw DocumentBookmarkError.textLimit
    }
    let newText = try TextEdits.apply([edit], to: oldText)
    guard newText.utf8.count <= Self.maximumTextBytes else { throw DocumentBookmarkError.textLimit }
    if oldText.utf16.elementsEqual(newText.utf16) { return }
    let start = edit.range.location
    let end = NSMaxRange(edit.range)
    let replacementLength = edit.replacement.utf16.count
    let delta = replacementLength - edit.range.length
    var mapped: [Int] = []
    for anchor in offsets {
      let line = lines[anchor]!
      if edit.range.length > 0 {
        if line.start == line.end {
          if start < anchor, end >= anchor { continue }
        } else if start <= line.start, end >= line.end {
          continue
        }
      }
      if anchor < start {
        mapped.append(anchor)
      } else if anchor >= end {
        mapped.append(anchor + delta)
      } else {
        mapped.append(start + replacementLength)
      }
    }
    let mappedLines = try Self.lookup(mapped, in: newText)
    let remapped = Array(Set(mapped.map { mappedLines[$0]!.start })).sorted()
    offsets = remapped
  }
  /// Edit-local native adapter. Pass NSTextStorage.mutableString without copying;
  /// the caller must keep that storage unchanged for this synchronous call.
  /// Limits native storage/result to 100 million UTF-16 units (200 MB backing),
  /// unlike the reference String API's 100 MB UTF-8 limit. No full new string or
  /// full-document index is constructed. Work is bounded by bookmark count and
  /// affected logical lines/replacement, assuming native UTF-16 random access.
  public mutating func remap(through edit: TextEdit, inUTF16 old: NSString) throws {
    let maximumUnits = Self.maximumNativeUTF16
    let length = old.length
    guard length <= maximumUnits else { throw DocumentBookmarkError.nativeTextLimit }
    guard edit.replacement.utf8.count <= Self.maximumTextBytes else {
      throw DocumentBookmarkError.textLimit
    }
    let start = edit.range.location
    guard start >= 0, edit.range.length >= 0, start <= length, edit.range.length <= length - start
    else {
      throw TextEditError.invalidRange
    }
    let end = NSMaxRange(edit.range)
    func boundary(_ position: Int) -> Bool {
      position == 0 || position == length
        || !(0xDC00...0xDFFF).contains(old.character(at: position))
    }
    guard boundary(start), boundary(end) else { throw TextEditError.invalidRange }
    func lineStart(_ position: Int) -> Bool {
      guard position >= 0, position <= length else { return false }
      if position == 0 { return true }
      let previous = old.character(at: position - 1)
      return previous == 10
        || (previous == 13 && (position == length || old.character(at: position) != 10))
    }
    guard offsets.allSatisfy(lineStart) else { throw DocumentBookmarkError.staleAnchors }
    let replacement = edit.replacement as NSString
    let replacementLength = replacement.length
    guard replacementLength <= maximumUnits - (length - edit.range.length) else {
      throw DocumentBookmarkError.nativeTextLimit
    }
    if replacementLength == edit.range.length {
      var identical = true
      for index in 0..<replacementLength
      where old.character(at: start + index) != replacement.character(at: index) {
        identical = false
        break
      }
      if identical { return }
    }
    let delta = replacementLength - edit.range.length
    let newLength = length + delta
    let replacementEnd = start + replacementLength
    func newUnit(_ position: Int) -> unichar {
      if position < start { return old.character(at: position) }
      if position < replacementEnd { return replacement.character(at: position - start) }
      return old.character(at: position - delta)
    }
    func normalizedReplacementEnd() -> Int {
      var cursor = replacementEnd
      // An offset inside CRLF belongs to the preceding logical line.
      if cursor > 0, cursor < newLength, newUnit(cursor) == 10, newUnit(cursor - 1) == 13 {
        cursor -= 1
      }
      while cursor > 0 {
        let previous = newUnit(cursor - 1)
        if previous == 10 || previous == 13 { return cursor }
        cursor -= 1
      }
      return 0
    }
    func lineFullyRemoved(_ anchor: Int) -> Bool {
      guard edit.range.length > 0 else { return false }
      if anchor == length { return start < anchor && end >= anchor }
      guard start <= anchor, anchor < end else { return false }
      var cursor = anchor
      while cursor < length, cursor < end {
        let unit = old.character(at: cursor)
        cursor += 1
        if unit == 13 || unit == 10 {
          if unit == 13, cursor < length, old.character(at: cursor) == 10 { cursor += 1 }
          return cursor <= end
        }
      }
      return cursor == length
    }
    var normalized: Int?
    var remapped: [Int] = []
    for anchor in offsets {
      if lineFullyRemoved(anchor) { continue }
      if anchor < start {
        remapped.append(anchor)
      } else if anchor > end {
        remapped.append(anchor + delta)
      } else {
        if normalized == nil { normalized = normalizedReplacementEnd() }
        remapped.append(normalized!)
      }
    }
    offsets = Array(Set(remapped)).sorted()
  }

  private struct Line {
    let start: Int
    let end: Int
  }
  private func validatedLines(in text: String, additional: [Int] = []) throws -> [Int: Line] {
    let lines = try Self.lookup(offsets + additional, in: text)
    guard offsets.allSatisfy({ lines[$0]?.start == $0 }) else {
      throw DocumentBookmarkError.staleAnchors
    }
    return lines
  }
  /// Sparse lookup bounds auxiliary metadata by bookmark count, not document line count.
  private static func lookup(_ requested: [Int], in text: String) throws -> [Int: Line] {
    guard text.utf8.count <= maximumTextBytes else { throw DocumentBookmarkError.textLimit }
    let units = text.utf16
    let length = units.count
    guard requested.allSatisfy({ $0 >= 0 && $0 <= length }) else {
      throw TextEditError.invalidRange
    }
    let queries = Array(Set(requested)).sorted()
    guard !queries.isEmpty else { return [:] }
    let wanted = Set(queries)
    var result: [Int: Line] = [:]
    var query = 0
    var start = 0
    var cursor = 0
    var index = units.startIndex
    func finish(_ end: Int, final: Bool = false) {
      while query < queries.count, queries[query] < end || (final && queries[query] == end) {
        result[queries[query]] = Line(start: start, end: end)
        query += 1
      }
      start = end
    }
    while index < units.endIndex {
      let unit = units[index]
      if (0xDC00...0xDFFF).contains(unit), wanted.contains(cursor) {
        throw TextEditError.invalidRange
      }
      units.formIndex(after: &index)
      cursor += 1
      if unit == 13 || unit == 10 {
        if unit == 13, index < units.endIndex, units[index] == 10 {
          units.formIndex(after: &index)
          cursor += 1
        }
        finish(cursor)
        if query == queries.count { return result }
      }
    }
    finish(cursor, final: true)
    return result
  }
}
