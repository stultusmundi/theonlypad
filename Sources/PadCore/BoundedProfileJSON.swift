import Foundation

/// Parsing mechanics only. Schemas and owned publication belong to their callers.
struct BoundedProfileJSON {
  struct Limits {
    let maximumBytes: Int
    let maximumDepth: Int
    let maximumValues: Int
  }
  enum Failure: Error, Equatable { case invalid, duplicateKey, limit, unimplemented }
  indirect enum Value {
    case object([String: Value])
    case array([Value])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
  }

  static func parse(_ data: Data, limits: Limits) throws -> Value {
    guard limits.maximumBytes >= 0, limits.maximumDepth >= 0, limits.maximumValues >= 0,
      data.count <= limits.maximumBytes
    else { throw Failure.limit }
    var reader = Reader(bytes: Array(data), limits: limits)
    let result = try reader.value(depth: 0)
    reader.whitespace()
    guard reader.index == reader.bytes.count else { throw Failure.invalid }
    return result
  }

  private struct Reader {
    let bytes: [UInt8]
    let limits: Limits
    var index = 0
    var values = 0

    mutating func whitespace() {
      while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
      whitespace()
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }
    mutating func string() throws -> String {
      whitespace()
      let start = index
      guard index < bytes.count, bytes[index] == 34 else { throw Failure.invalid }
      index += 1
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 {
          do {
            return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
          } catch { throw Failure.invalid }
        }
        if byte == 92 {
          guard index < bytes.count else { throw Failure.invalid }
          index += 1
        }
      }
      throw Failure.invalid
    }
    mutating func value(depth: Int) throws -> Value {
      guard depth <= limits.maximumDepth, values < limits.maximumValues else {
        throw Failure.limit
      }
      values += 1  // Reserve this value, including a container, before constructing it.
      whitespace()
      guard index < bytes.count else { throw Failure.invalid }
      if consume(123) {
        var object: [String: Value] = [:]
        if consume(125) { return .object(object) }
        repeat {
          let key = try string()
          guard object[key] == nil else { throw Failure.duplicateKey }
          guard consume(58) else { throw Failure.invalid }
          object[key] = try value(depth: depth + 1)
          if consume(125) { return .object(object) }
        } while consume(44)
        throw Failure.invalid
      }
      if consume(91) {
        var array: [Value] = []
        if consume(93) { return .array(array) }
        repeat {
          array.append(try value(depth: depth + 1))
          if consume(93) { return .array(array) }
        } while consume(44)
        throw Failure.invalid
      }
      if bytes[index] == 34 { return .string(try string()) }
      let start = index
      while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
        index += 1
      }
      guard index > start else { throw Failure.invalid }
      let token = String(decoding: bytes[start..<index], as: UTF8.self)
      switch token {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      default: break
      }
      // Preserve the strict shortcut adapter's original numeric spelling grammar.
      guard
        token.range(
          of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$",
          options: .regularExpression) != nil
      else { throw Failure.invalid }
      return .number(token)
    }
  }
}
