import Foundation

/// Validates persisted positions against the bytes actually loaded at startup.
/// Call off-main for large documents. Rejected anchors are reported, never guessed.
public struct RestoredViewState: Equatable, Sendable {
  public let selection: NSRange
  public let bookmarks: DocumentBookmarks
  public let selectionAdjusted: Bool
  public let invalidBookmarks: [Int]

  public static func resolve(selection: NSRange, bookmarks: [Int], in text: String) throws -> Self {
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= 100_000_000,
      selection.length <= 100_000_000 - selection.location,
      bookmarks.count <= DocumentBookmarks.maximumBookmarks
    else { throw SessionStoreError.invalidMetadata }
    var previous = -1
    for offset in bookmarks {
      guard offset > previous, offset <= 100_000_000 else {
        throw SessionStoreError.invalidMetadata
      }
      previous = offset
    }
    let source = text as NSString
    guard source.length <= DocumentBookmarks.maximumNativeUTF16 else {
      throw DocumentBookmarkError.nativeTextLimit
    }
    var start = min(selection.location, source.length)
    var end = min(selection.location + selection.length, source.length)
    func splitsScalar(_ position: Int) -> Bool {
      position > 0 && position < source.length
        && (0xD800...0xDBFF).contains(source.character(at: position - 1))
        && (0xDC00...0xDFFF).contains(source.character(at: position))
    }
    if splitsScalar(start) { start -= 1 }
    if selection.length == 0 {
      end = start
    } else if splitsScalar(end) {
      end += 1
    }
    let resolvedSelection = NSRange(location: start, length: end - start)
    var accepted: [Int] = []
    var rejected: [Int] = []
    for offset in bookmarks {
      let isStart: Bool
      if offset == 0 {
        isStart = true
      } else if offset > source.length {
        isStart = false
      } else {
        let prior = source.character(at: offset - 1)
        isStart =
          prior == 10
          || (prior == 13 && (offset == source.length || source.character(at: offset) != 10))
      }
      if isStart { accepted.append(offset) } else { rejected.append(offset) }
    }
    return Self(
      selection: resolvedSelection,
      bookmarks: try DocumentBookmarks(offsets: accepted, inUTF16: source),
      selectionAdjusted: resolvedSelection != selection, invalidBookmarks: rejected)
  }
}
