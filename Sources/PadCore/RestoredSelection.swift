import Foundation

/// Resolves one range without bridging, copying, or enumerating text.
/// Uses one length query and at most four character queries; NSString implementations may vary in cost.
public enum RestoredSelection {
  public static func resolve(_ selection: NSRange, inUTF16 source: NSString) throws -> NSRange {
    try validate(selection)
    let length = source.length
    guard length >= 0, length <= DocumentBookmarks.maximumNativeUTF16 else {
      throw DocumentBookmarkError.nativeTextLimit
    }
    var start = min(selection.location, length)
    var end = min(selection.location + selection.length, length)
    func splitsScalar(_ position: Int) -> Bool {
      position > 0 && position < length
        && (0xD800...0xDBFF).contains(source.character(at: position - 1))
        && (0xDC00...0xDFFF).contains(source.character(at: position))
    }
    if splitsScalar(start) { start -= 1 }
    if selection.length == 0 {
      end = start
    } else if splitsScalar(end) {
      end += 1
    }
    return NSRange(location: start, length: end - start)
  }

  static func validate(_ selection: NSRange) throws {
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= 100_000_000,
      selection.length <= 100_000_000 - selection.location
    else { throw SessionStoreError.invalidMetadata }
  }
}
