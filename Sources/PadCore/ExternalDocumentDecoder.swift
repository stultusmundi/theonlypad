import Foundation

public enum ExternalDocumentDecodingError: Error, LocalizedError {
  case unsupportedUTF32

  public var errorDescription: String? {
    "This file begins with a UTF-32 or ambiguous Unicode byte-order prefix. Automatic interpretation is unavailable; the open buffer was preserved."
  }
}

/// External reloads honor an explicit supported BOM; BOM-less files retain the saved encoding.
/// Explicit Reopen with Encoding remains a separate DocumentCodec operation.
public enum ExternalDocumentDecoder {
  public static func decode(_ data: Data, fallbackEncoding: DocumentEncoding) throws
    -> DecodedDocument
  {
    // Check four-byte signatures first: the little-endian marker starts with the UTF-16 LE marker.
    // Unusual byte orders are refused as well. Ambiguous UTF-16 + initial NUL is conservatively refused.
    let unsupported: [[UInt8]] = [
      [0xFF, 0xFE, 0, 0], [0, 0, 0xFE, 0xFF],
      [0, 0, 0xFF, 0xFE], [0xFE, 0xFF, 0, 0],
    ]
    guard !unsupported.contains(where: { data.starts(with: $0) }) else {
      throw ExternalDocumentDecodingError.unsupportedUTF32
    }
    let supported: [[UInt8]] = [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF]]
    let marked = supported.contains { data.starts(with: $0) }
    return try DocumentCodec.decode(data, encoding: marked ? nil : fallbackEncoding)
  }
}
