import Foundation

/// Validates persisted positions against the text actually loaded at startup.
/// Call off-main for large documents. Rejected anchors are reported, never guessed.
public struct RestoredViewState: Equatable, Sendable {
  public let selection: NSRange
  public let bookmarks: DocumentBookmarks
  public let selectionAdjusted: Bool
  public let invalidBookmarks: [Int]

  public static func resolve(selection: NSRange, bookmarks: [Int], in text: String) throws -> Self {
    try RestoredPositionContext.validate(selection)
    let context = try RestoredPositionContext(bookmarks: bookmarks, in: text)
    let range = try context.resolve(selection)
    return Self(
      selection: range, bookmarks: context.bookmarks,
      selectionAdjusted: range != selection, invalidBookmarks: context.invalidBookmarks)
  }
}

/// One immutable NSString bridge and one shared bookmark result for up to two pane ranges.
struct RestoredPositionContext {
  private let source: NSString
  let bookmarks: DocumentBookmarks
  let invalidBookmarks: [Int]

  static func validate(_ selection: NSRange) throws {
    try RestoredSelection.validate(selection)
  }
  init(bookmarks: [Int], in text: String) throws {
    guard bookmarks.count <= DocumentBookmarks.maximumBookmarks else {
      throw SessionStoreError.invalidMetadata
    }
    var previous = -1
    for offset in bookmarks {
      guard offset > previous, offset <= 100_000_000 else {
        throw SessionStoreError.invalidMetadata
      }
      previous = offset
    }
    source = text as NSString
    guard source.length <= DocumentBookmarks.maximumNativeUTF16 else {
      throw DocumentBookmarkError.nativeTextLimit
    }
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
    self.bookmarks = try DocumentBookmarks(offsets: accepted, inUTF16: source)
    invalidBookmarks = rejected
  }
  func resolve(_ selection: NSRange) throws -> NSRange {
    try RestoredSelection.resolve(selection, inUTF16: source)
  }
}
