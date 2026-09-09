import Foundation

public enum TextDifferenceError: Error, LocalizedError {
  case textLimit
  public var errorDescription: String? {
    "Editing snapshots are limited to 100 million UTF-16 units. Use a smaller document."
  }
}

/// One contiguous replacement preserving the longest exact scalar-safe prefix and suffix.
/// This is a textual difference, not a multi-hunk diff or semantic edit description.
public enum TextDifference {
  public static func singleEdit(
    from source: String, to target: String,
    isCancelled: () -> Bool = { false }
  ) throws -> TextEdit? {
    if isCancelled() { throw CancellationError() }
    guard source.utf16.count <= 100_000_000, target.utf16.count <= 100_000_000 else {
      throw TextDifferenceError.textLimit
    }
    let old = source as NSString
    let new = target as NSString
    let oldCount = old.length
    let newCount = new.length
    var prefix = 0
    while prefix < min(oldCount, newCount), old.character(at: prefix) == new.character(at: prefix) {
      if prefix.isMultiple(of: 4_096), isCancelled() { throw CancellationError() }
      prefix += 1
    }
    if prefix == oldCount, prefix == newCount { return nil }
    func isLowSurrogate(_ text: NSString, at offset: Int) -> Bool {
      offset < text.length && (0xDC00...0xDFFF).contains(text.character(at: offset))
    }
    if prefix > 0, isLowSurrogate(old, at: prefix) || isLowSurrogate(new, at: prefix) {
      prefix -= 1
    }
    var suffix = 0
    while suffix < oldCount - prefix, suffix < newCount - prefix,
      old.character(at: oldCount - suffix - 1) == new.character(at: newCount - suffix - 1)
    {
      if suffix.isMultiple(of: 4_096), isCancelled() { throw CancellationError() }
      suffix += 1
    }
    if suffix > 0,
      isLowSurrogate(old, at: oldCount - suffix) || isLowSurrogate(new, at: newCount - suffix)
    {
      suffix -= 1
    }
    if isCancelled() { throw CancellationError() }
    return TextEdit(
      range: NSRange(location: prefix, length: oldCount - prefix - suffix),
      replacement: new.substring(
        with: NSRange(location: prefix, length: newCount - prefix - suffix)))
  }
}
