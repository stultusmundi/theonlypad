import CryptoKit
import Foundation

public enum TextUtilityOperation: String, CaseIterable, Sendable {
  case base64Encode, base64Decode, urlEncode, urlDecode, jsonEscape, jsonUnescape, sha256
  public var allowsReplacement: Bool { self != .sha256 }
  public var title: String {
    switch self {
    case .base64Encode: return String(localized: "Base64 Encode (UTF-8)")
    case .base64Decode: return String(localized: "Base64 Decode (UTF-8)")
    case .urlEncode: return String(localized: "URL Component Encode")
    case .urlDecode: return String(localized: "URL Component Decode")
    case .jsonEscape: return String(localized: "Escape as JSON String")
    case .jsonUnescape: return String(localized: "Unescape JSON String")
    case .sha256: return String(localized: "SHA-256 (UTF-8)")
    }
  }
}
public enum TextUtilityError: Error, LocalizedError {
  case inputLimit, outputLimit, invalidBase64, invalidUTF8, invalidPercentEncoding,
    invalidJSONString
  public var errorDescription: String? {
    switch self {
    case .inputLimit:
      return "The input exceeds the 2,000,000 UTF-8 byte limit. Select a smaller portion of text."
    case .outputLimit:
      return
        "The converted output would exceed 2,000,000 UTF-8 bytes. Select a smaller portion of text."
    case .invalidBase64:
      return
        "Enter canonical Base64 using the standard alphabet, correct padding and no whitespace."
    case .invalidUTF8: return "The decoded bytes are not valid UTF-8 text."
    case .invalidPercentEncoding:
      return "Every percent escape must contain exactly two hexadecimal digits."
    case .invalidJSONString: return "Enter one complete quoted JSON string value."
    }
  }
}

public enum TextUtilities {
  public static let maximumBytes = 2_000_000
  public static func process(_ text: String, operation: TextUtilityOperation) throws -> String {
    guard text.utf8.count <= maximumBytes else { throw TextUtilityError.inputLimit }
    let result: String
    switch operation {
    case .base64Encode:
      guard ((text.utf8.count + 2) / 3) * 4 <= maximumBytes else {
        throw TextUtilityError.outputLimit
      }
      result = Data(text.utf8).base64EncodedString()
    case .base64Decode:
      guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else {
        throw TextUtilityError.invalidBase64
      }
      result = try strictUTF8(bytes)
    case .urlEncode: result = try percentEncode(text)
    case .urlDecode: result = try percentDecode(text)
    case .jsonEscape: result = try jsonEscape(text)
    case .jsonUnescape:
      do { result = try JSONDecoder().decode(String.self, from: Data(text.utf8)) } catch {
        throw TextUtilityError.invalidJSONString
      }
    case .sha256:
      result = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    guard result.utf8.count <= maximumBytes else { throw TextUtilityError.outputLimit }
    return result
  }
  private static func strictUTF8(_ bytes: Data) throws -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    guard Data(text.utf8) == bytes else { throw TextUtilityError.invalidUTF8 }
    return text
  }
  private static let hex = Array("0123456789ABCDEF".utf8)
  private static func append(_ bytes: [UInt8], to output: inout Data) throws {
    guard bytes.count <= maximumBytes - output.count else { throw TextUtilityError.outputLimit }
    output.append(contentsOf: bytes)
  }
  private static func percentEncode(_ text: String) throws -> String {
    var output = Data()
    output.reserveCapacity(min(text.utf8.count * 3, maximumBytes))
    for byte in text.utf8 {
      let unreserved =
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || [45, 46, 95, 126].contains(byte)
      try append(unreserved ? [byte] : [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]], to: &output)
    }
    return String(decoding: output, as: UTF8.self)
  }
  private static func percentDecode(_ text: String) throws -> String {
    let bytes = Array(text.utf8)
    var output = Data()
    output.reserveCapacity(bytes.count)
    var index = 0
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: return byte - 48
      case 65...70: return byte - 65 + 10
      case 97...102: return byte - 97 + 10
      default: return nil
      }
    }
    while index < bytes.count {
      if bytes[index] == 37 {
        guard index + 2 < bytes.count, let high = nibble(bytes[index + 1]),
          let low = nibble(bytes[index + 2])
        else { throw TextUtilityError.invalidPercentEncoding }
        output.append((high << 4) | low)
        index += 3
      } else {
        output.append(bytes[index])
        index += 1
      }
    }
    return try strictUTF8(output)
  }
  private static func jsonEscape(_ text: String) throws -> String {
    var output = Data([34])
    for byte in text.utf8 {
      switch byte {
      case 34, 92: try append([92, byte], to: &output)
      case 8: try append([92, 98], to: &output)
      case 9: try append([92, 116], to: &output)
      case 10: try append([92, 110], to: &output)
      case 12: try append([92, 102], to: &output)
      case 13: try append([92, 114], to: &output)
      case 0...31:
        try append([92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]], to: &output)
      default: try append([byte], to: &output)
      }
    }
    try append([34], to: &output)
    return String(decoding: output, as: UTF8.self)
  }
}
