import Foundation

public struct DocumentStatistics: Equatable, Sendable {
  public let characters: Int
  public let utf16Units: Int
  public let unicodeScalars: Int
  /// The current text serialized as UTF-8 without a BOM, independent of save encoding.
  public let utf8Bytes: Int
  public let lines: Int
  public let lfEndings: Int
  public let crlfEndings: Int
  public let crEndings: Int
  public let selectedCharacters: Int
  public let selectedUTF16Units: Int

  /// Linear analysis; invoke off the UI thread for documents of arbitrary size.
  public static func measure(
    _ text: String, selection: NSRange, isCancelled: () -> Bool = { false }
  ) throws -> Self {
    let units = text.utf16
    let length = units.count
    func boundary(_ offset: Int) -> Bool {
      offset == 0 || offset == length
        || !(0xDC00...0xDFFF).contains(units[units.index(units.startIndex, offsetBy: offset)])
    }
    guard selection.location >= 0, selection.length >= 0, selection.location <= length,
      selection.length <= length - selection.location, boundary(selection.location),
      boundary(NSMaxRange(selection)),
      let selected = Range(selection, in: text)
    else { throw TextEditError.invalidRange }
    var characters = 0
    var lf = 0
    var crlf = 0
    var cr = 0
    for character in text {
      if characters.isMultiple(of: 4096), isCancelled() { throw CancellationError() }
      characters += 1
      if character == "\r\n" {
        crlf += 1
      } else if character == "\n" {
        lf += 1
      } else if character == "\r" {
        cr += 1
      }
    }
    var selectedCharacters = 0
    for _ in text[selected] {
      if selectedCharacters.isMultiple(of: 4096), isCancelled() { throw CancellationError() }
      selectedCharacters += 1
    }
    if isCancelled() { throw CancellationError() }
    return Self(
      characters: characters, utf16Units: length, unicodeScalars: text.unicodeScalars.count,
      utf8Bytes: text.utf8.count,
      lines: lf + crlf + cr + 1, lfEndings: lf, crlfEndings: crlf, crEndings: cr,
      selectedCharacters: selectedCharacters, selectedUTF16Units: selection.length)
  }
}
