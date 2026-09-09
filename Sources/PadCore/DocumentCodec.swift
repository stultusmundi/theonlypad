import Foundation

public enum DocumentEncoding: String, Codable, CaseIterable, Sendable {
  case utf8, utf16LE, utf16BE, windows1252, latin1
}

public struct DecodedDocument: Equatable, Codable, Sendable {
  public var text: String
  public var encoding: DocumentEncoding
  public var hasBOM: Bool
  public init(text: String, encoding: DocumentEncoding = .utf8, hasBOM: Bool = false) {
    self.text = text
    self.encoding = encoding
    self.hasBOM = hasBOM
  }
}

public enum DocumentCodecError: Error, LocalizedError {
  case invalidBytes, unrepresentableText, unsupportedBOM
  public var errorDescription: String? {
    switch self {
    case .invalidBytes:
      return "The bytes are invalid for this encoding. Reopen with an explicit encoding."
    case .unrepresentableText:
      return "This encoding cannot represent every character. Choose a Unicode encoding."
    case .unsupportedBOM: return "A byte-order mark is only supported for Unicode encodings."
    }
  }
}

public enum DocumentCodec {
  // Undefined Windows-1252 slots retain their corresponding C1 controls for reversible decoding.
  private static let windows: [UInt32] = [
    0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178,
  ]
  private static func bom(_ encoding: DocumentEncoding) -> Data {
    switch encoding {
    case .utf8: return Data([0xEF, 0xBB, 0xBF])
    case .utf16LE: return Data([0xFF, 0xFE])
    case .utf16BE: return Data([0xFE, 0xFF])
    default: return Data()
    }
  }

  public static func decode(_ data: Data, encoding explicit: DocumentEncoding? = nil) throws
    -> DecodedDocument
  {
    let detected = [DocumentEncoding.utf8, .utf16LE, .utf16BE].first { data.starts(with: bom($0)) }
    let encoding = explicit ?? detected ?? .utf8
    let marker = bom(encoding)
    let hasBOM = !marker.isEmpty && data.starts(with: marker)
    let bytes = hasBOM ? Data(data.dropFirst(marker.count)) : data
    let text: String
    switch encoding {
    case .utf8:
      text = String(decoding: bytes, as: UTF8.self)
      guard Data(text.utf8) == bytes else { throw DocumentCodecError.invalidBytes }
    case .utf16LE, .utf16BE:
      guard bytes.count.isMultiple(of: 2) else { throw DocumentCodecError.invalidBytes }
      let array = Array(bytes)
      let units: [UInt16] = stride(from: 0, to: array.count, by: 2).map {
        encoding == .utf16LE
          ? UInt16(array[$0]) | UInt16(array[$0 + 1]) << 8
          : UInt16(array[$0]) << 8 | UInt16(array[$0 + 1])
      }
      text = String(decoding: units, as: UTF16.self)
      guard Array(text.utf16) == units else { throw DocumentCodecError.invalidBytes }
    case .windows1252, .latin1:
      text = String(
        String.UnicodeScalarView(
          bytes.map { byte in
            UnicodeScalar(
              encoding == .windows1252 && (0x80...0x9F).contains(byte)
                ? windows[Int(byte) - 0x80] : UInt32(byte))!
          }))
    }
    return DecodedDocument(text: text, encoding: encoding, hasBOM: hasBOM)
  }

  public static func encode(_ document: DecodedDocument) throws -> Data {
    var result = Data()
    if document.hasBOM {
      let marker = bom(document.encoding)
      guard !marker.isEmpty else { throw DocumentCodecError.unsupportedBOM }
      result.append(marker)
    }
    switch document.encoding {
    case .utf8: result.append(contentsOf: document.text.utf8)
    case .utf16LE, .utf16BE:
      for unit in document.text.utf16 {
        let low = UInt8(truncatingIfNeeded: unit)
        let high = UInt8(unit >> 8)
        result.append(contentsOf: document.encoding == .utf16LE ? [low, high] : [high, low])
      }
    case .windows1252, .latin1:
      for scalar in document.text.unicodeScalars {
        if document.encoding == .windows1252, let index = windows.firstIndex(of: scalar.value) {
          result.append(UInt8(index + 0x80))
        } else if scalar.value <= 255
          && (document.encoding == .latin1 || !(0x80...0x9F).contains(scalar.value))
        {
          result.append(UInt8(scalar.value))
        } else {
          throw DocumentCodecError.unrepresentableText
        }
      }
    }
    return result
  }
}
