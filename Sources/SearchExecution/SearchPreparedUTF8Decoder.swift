enum SearchPreparedUTF8Error: Error, Equatable {
  case invalidBounds, windowLimit, inputByteLimit, inputUnitLimit, outputLimit
  case invalidScalar, invalidUTF8, binaryInput, lengthMismatch, invalidPhase, poisoned
  case internalFailure
}

struct SearchPreparedUTF8Result: Sendable, Equatable {
  let text: String
  let inputUTF16: Int
}

// Synchronous, caller-confined storage. Any reservation belongs to the caller.
final class SearchPreparedUTF16Builder {
  private var storage: [UInt16]
  private var committed = 0
  private var borrowing = false

  init(capacity: Int) throws {
    guard capacity >= 0, capacity <= 10_000_000 else {
      throw SearchPreparedUTF8Error.invalidBounds
    }
    storage = [UInt16](repeating: 0, count: capacity)
  }

  func append(scalar: UInt32) throws {
    guard !borrowing else { throw SearchPreparedUTF8Error.invalidPhase }
    guard scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else {
      throw SearchPreparedUTF8Error.invalidScalar
    }
    let needed = scalar <= 0xFFFF ? 1 : 2
    guard needed <= storage.count - committed else {
      throw SearchPreparedUTF8Error.inputUnitLimit
    }
    if needed == 1 {
      storage[committed] = UInt16(scalar)
    } else {
      let offset = scalar - 0x10000
      storage[committed] = UInt16(0xD800 | (offset >> 10))
      storage[committed + 1] = UInt16(0xDC00 | (offset & 0x3FF))
    }
    committed += needed
  }

  // The readonly view and its count are valid only during this callback.
  func withStorage(_ body: (UnsafeBufferPointer<UInt16>, Int) throws -> Void) throws {
    guard !borrowing else { throw SearchPreparedUTF8Error.invalidPhase }
    borrowing = true
    defer { borrowing = false }
    try storage.withUnsafeBufferPointer { units in
      try body(units, committed)
    }
  }
}

// Strict UTF8 only; the input window is borrowed, never retained or copied.
final class SearchPreparedUTF8Decoder {
  private enum Phase { case active, finished, failed }

  private let expectedInputBytes: Int
  private let maxWindowBytes: Int
  private let maxOutputUTF8Bytes: Int
  private var builder: SearchPreparedUTF16Builder?
  private var phase = Phase.active
  private var consumedBytes = 0
  private var outputBytes = 0
  private var initialPrefix = 0
  private var initialResolved = false
  private var scalar: UInt32 = 0
  private var remaining = 0
  private var nextMinimum: UInt8 = 0x80
  private var nextMaximum: UInt8 = 0xBF

  init(
    expectedInputBytes: Int, maxInputUTF16: Int,
    maxWindowBytes: Int, maxOutputUTF8Bytes: Int
  ) throws {
    guard expectedInputBytes >= 0, expectedInputBytes <= 10_000_000,
      maxInputUTF16 >= 0, maxInputUTF16 <= 10_000_000,
      maxWindowBytes >= 1, maxWindowBytes <= 65_536,
      maxOutputUTF8Bytes >= 0
    else { throw SearchPreparedUTF8Error.invalidBounds }
    let ceiling = maxInputUTF16.multipliedReportingOverflow(by: 3)
    guard !ceiling.overflow, maxOutputUTF8Bytes <= ceiling.partialValue else {
      throw SearchPreparedUTF8Error.invalidBounds
    }
    self.expectedInputBytes = expectedInputBytes
    self.maxWindowBytes = maxWindowBytes
    self.maxOutputUTF8Bytes = maxOutputUTF8Bytes
    builder = try SearchPreparedUTF16Builder(capacity: maxInputUTF16)
  }

  func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
    try requireActive()
    do {
      guard bytes.count <= maxWindowBytes else { throw SearchPreparedUTF8Error.windowLimit }
      guard bytes.count <= expectedInputBytes - consumedBytes else {
        throw SearchPreparedUTF8Error.inputByteLimit
      }
      for byte in bytes {
        consumedBytes += 1
        guard byte != 0 else { throw SearchPreparedUTF8Error.binaryInput }
        try consumeInitial(byte)
      }
    } catch {
      poison()
      throw error
    }
  }

  func finish() throws -> SearchPreparedUTF8Result {
    try requireActive()
    do {
      guard consumedBytes == expectedInputBytes else {
        throw SearchPreparedUTF8Error.lengthMismatch
      }
      guard initialPrefix == 0, remaining == 0 else {
        throw SearchPreparedUTF8Error.invalidUTF8
      }
      guard outputBytes <= maxOutputUTF8Bytes else { throw SearchPreparedUTF8Error.outputLimit }
      guard let builder else { throw SearchPreparedUTF8Error.internalFailure }
      let result = try materialize(builder)
      self.builder = nil
      clearCarry()
      phase = .finished
      return result
    } catch {
      poison()
      throw error
    }
  }

  private func requireActive() throws {
    switch phase {
    case .active: return
    case .finished: throw SearchPreparedUTF8Error.invalidPhase
    case .failed: throw SearchPreparedUTF8Error.poisoned
    }
  }

  private func poison() {
    phase = .failed
    builder = nil
    clearCarry()
  }

  private func clearCarry() {
    scalar = 0
    remaining = 0
    initialPrefix = 0
    nextMinimum = 0x80
    nextMaximum = 0xBF
  }

  private func consumeInitial(_ byte: UInt8) throws {
    if initialResolved {
      try consumeScalarByte(byte)
      return
    }
    switch initialPrefix {
    case 0:
      if byte == 0xEF {
        initialPrefix = 1
      } else {
        initialResolved = true
        try consumeScalarByte(byte)
      }
    case 1:
      if byte == 0xBB {
        initialPrefix = 2
      } else {
        initialPrefix = 0
        initialResolved = true
        try consumeScalarByte(0xEF)
        try consumeScalarByte(byte)
      }
    case 2:
      initialPrefix = 0
      initialResolved = true
      if byte != 0xBF {
        try consumeScalarByte(0xEF)
        try consumeScalarByte(0xBB)
        try consumeScalarByte(byte)
      }
    default: throw SearchPreparedUTF8Error.internalFailure
    }
  }

  private func consumeScalarByte(_ byte: UInt8) throws {
    if remaining > 0 {
      guard byte >= nextMinimum, byte <= nextMaximum else {
        throw SearchPreparedUTF8Error.invalidUTF8
      }
      scalar = (scalar << 6) | UInt32(byte & 0x3F)
      remaining -= 1
      nextMinimum = 0x80
      nextMaximum = 0xBF
      if remaining == 0 { try appendScalar() }
      return
    }
    switch byte {
    case 0x01...0x7F:
      scalar = UInt32(byte)
      try appendScalar()
    case 0xC2...0xDF:
      scalar = UInt32(byte & 0x1F)
      remaining = 1
    case 0xE0...0xEF:
      scalar = UInt32(byte & 0x0F)
      remaining = 2
      if byte == 0xE0 { nextMinimum = 0xA0 }
      if byte == 0xED { nextMaximum = 0x9F }
    case 0xF0...0xF4:
      scalar = UInt32(byte & 0x07)
      remaining = 3
      if byte == 0xF0 { nextMinimum = 0x90 }
      if byte == 0xF4 { nextMaximum = 0x8F }
    default: throw SearchPreparedUTF8Error.invalidUTF8
    }
  }

  private func appendScalar() throws {
    guard let builder else { throw SearchPreparedUTF8Error.internalFailure }
    try builder.append(scalar: scalar)
    let next = outputBytes.addingReportingOverflow(Self.utf8Width(scalar))
    guard !next.overflow else { throw SearchPreparedUTF8Error.internalFailure }
    outputBytes = next.partialValue
    scalar = 0
  }

  private func materialize(_ builder: SearchPreparedUTF16Builder) throws
    -> SearchPreparedUTF8Result
  {
    var text = ""
    var count = 0
    try builder.withStorage { units, committed in
      guard committed >= 0, committed <= units.count else {
        throw SearchPreparedUTF8Error.internalFailure
      }
      let ceiling = committed.multipliedReportingOverflow(by: 3)
      guard !ceiling.overflow, outputBytes <= ceiling.partialValue else {
        throw SearchPreparedUTF8Error.internalFailure
      }
      count = committed
      text = try String(unsafeUninitializedCapacity: outputBytes) { output in
        try Self.encode(units, count: committed, into: output, expectedBytes: outputBytes)
      }
    }
    return SearchPreparedUTF8Result(text: text, inputUTF16: count)
  }

  private static func utf8Width(_ scalar: UInt32) -> Int {
    if scalar <= 0x7F { return 1 }
    if scalar <= 0x7FF { return 2 }
    if scalar <= 0xFFFF { return 3 }
    return 4
  }

  private static func encode(
    _ units: UnsafeBufferPointer<UInt16>, count: Int,
    into output: UnsafeMutableBufferPointer<UInt8>, expectedBytes: Int
  ) throws -> Int {
    guard output.count >= expectedBytes else { throw SearchPreparedUTF8Error.internalFailure }
    var index = 0
    var cursor = 0
    while index < count {
      let first = UInt32(units[index])
      let scalar: UInt32
      if (0xD800...0xDBFF).contains(first) {
        guard count - index >= 2 else { throw SearchPreparedUTF8Error.internalFailure }
        let second = UInt32(units[index + 1])
        guard (0xDC00...0xDFFF).contains(second) else {
          throw SearchPreparedUTF8Error.internalFailure
        }
        scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        index += 2
      } else {
        guard !(0xDC00...0xDFFF).contains(first) else {
          throw SearchPreparedUTF8Error.internalFailure
        }
        scalar = first
        index += 1
      }
      let width = utf8Width(scalar)
      guard width <= expectedBytes - cursor else {
        throw SearchPreparedUTF8Error.internalFailure
      }
      switch width {
      case 1:
        output[cursor] = UInt8(scalar)
      case 2:
        output[cursor] = UInt8(0xC0 | (scalar >> 6))
        output[cursor + 1] = UInt8(0x80 | (scalar & 0x3F))
      case 3:
        output[cursor] = UInt8(0xE0 | (scalar >> 12))
        output[cursor + 1] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
        output[cursor + 2] = UInt8(0x80 | (scalar & 0x3F))
      case 4:
        output[cursor] = UInt8(0xF0 | (scalar >> 18))
        output[cursor + 1] = UInt8(0x80 | ((scalar >> 12) & 0x3F))
        output[cursor + 2] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
        output[cursor + 3] = UInt8(0x80 | (scalar & 0x3F))
      default: throw SearchPreparedUTF8Error.internalFailure
      }
      cursor += width
    }
    guard cursor == expectedBytes else { throw SearchPreparedUTF8Error.internalFailure }
    return cursor
  }
}
