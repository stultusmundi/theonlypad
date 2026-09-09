import Foundation

public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: String
  public init(range: NSRange, replacement: String) {
    self.range = range
    self.replacement = replacement
  }
}

public enum TextEditError: Error { case invalidRange, overlappingRanges }

public enum TextEdits {
  public static func apply(_ edits: [TextEdit], to text: String) throws -> String {
    let ordered = edits.sorted { $0.range.location < $1.range.location }
    let utf16 = text.utf16
    func scalarBoundary(_ offset: Int) -> Bool {
      guard offset > 0, offset < utf16.count else { return true }
      let index = utf16.index(utf16.startIndex, offsetBy: offset)
      return !(0xDC00...0xDFFF).contains(utf16[index])
    }
    var previous: NSRange?
    for edit in ordered {
      guard edit.range.location >= 0, edit.range.length >= 0,
        edit.range.location <= text.utf16.count,
        edit.range.length <= text.utf16.count - edit.range.location,
        scalarBoundary(edit.range.location), scalarBoundary(NSMaxRange(edit.range)),
        Range(edit.range, in: text) != nil
      else { throw TextEditError.invalidRange }
      if let previous,
        NSMaxRange(previous) > edit.range.location || previous.location == edit.range.location
      {
        throw TextEditError.overlappingRanges
      }
      previous = edit.range
    }
    var result = text
    for edit in ordered.reversed() {
      guard let range = Range(edit.range, in: result) else { throw TextEditError.invalidRange }
      result.replaceSubrange(range, with: edit.replacement)
    }
    return result
  }
}
