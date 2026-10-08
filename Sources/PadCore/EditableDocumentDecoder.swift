import Foundation

public enum EditableDocumentDecodingError: Error, Equatable, LocalizedError, Sendable {
  case suspectedBinary, unsupportedUTF32

  public var errorDescription: String? {
    switch self {
    case .suspectedBinary:
      return
        "This file contains NUL characters and may be binary. Editable text opening was refused; the file was not changed. Inspect it with a suitable read-only binary viewer."
    case .unsupportedUTF32:
      return
        "This file begins with an unsupported UTF-32 or ambiguous Unicode prefix. Editable text opening was refused; the file was not changed. Inspect it with a suitable viewer or convert a copy to a supported encoding."
    }
  }
}

/// Conservative admission for newly read disk content, not a universal binary detector.
/// Raw codecs and already-owned recovery/backup/history text retain their reversible contracts.
public enum EditableDocumentDecoder {
  public static func decode(_ data: Data, encoding: DocumentEncoding? = nil) throws
    -> DecodedDocument
  {
    // UTF-32 LE begins with the UTF-16 LE marker. Check complete signatures first.
    // UTF-16 with a leading decoded NUL is deliberately refused as ambiguous as well.
    let unsupported: [[UInt8]] = [
      [0xFF, 0xFE, 0, 0], [0, 0, 0xFE, 0xFF],
      [0, 0, 0xFF, 0xFE], [0xFE, 0xFF, 0, 0],
    ]
    guard !unsupported.contains(where: { data.starts(with: $0) }) else {
      throw EditableDocumentDecodingError.unsupportedUTF32
    }
    let document = try DocumentCodec.decode(data, encoding: encoding)
    // Scan decoded units: zero bytes are ordinary in valid UTF-16 encoded text.
    guard !document.text.utf16.contains(0) else {
      throw EditableDocumentDecodingError.suspectedBinary
    }
    return document
  }
}
