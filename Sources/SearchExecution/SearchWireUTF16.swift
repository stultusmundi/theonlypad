import Foundation

private let searchWireMaximumUTF16 = 100_000_000
private let searchWireMaximumUTF16ChunkBytes = 65_536

public final class SearchWireUTF16Decoder {
  private enum State {
    case idle
    case inCall
    case finished
    case failed
  }

  private let expectedUTF16: Int
  private var consumedUTF16 = 0
  private var pendingHighSurrogate: UInt16?
  private var state = State.idle

  public init(expectedUTF16: Int) throws {
    guard (0...searchWireMaximumUTF16).contains(expectedUTF16) else {
      throw SearchWireError.invalidMetadata
    }
    self.expectedUTF16 = expectedUTF16
  }

  public func consume(_ utf16LE: Data, emitUTF8: (Data) throws -> Void) throws {
    switch state {
    case .idle:
      state = .inCall
    case .inCall:
      state = .failed
      throw SearchWireError.reentrantUse
    case .finished:
      state = .failed
      throw SearchWireError.invalidPhase
    case .failed:
      throw SearchWireError.poisoned
    }

    do {
      try validateDirectInput(utf16LE)
      try decode(utf16LE, emitUTF8: emitUTF8)
    } catch {
      if state == .inCall {
        state = .failed
      }
      throw error
    }

    guard state == .inCall else {
      throw SearchWireError.poisoned
    }
    state = .idle
  }

  public func finish() throws {
    switch state {
    case .idle:
      guard consumedUTF16 == expectedUTF16 else {
        state = .failed
        throw SearchWireError.lengthMismatch
      }
      guard pendingHighSurrogate == nil else {
        state = .failed
        throw SearchWireError.malformedUTF16
      }
      state = .finished
    case .inCall:
      state = .failed
      throw SearchWireError.reentrantUse
    case .finished:
      return
    case .failed:
      throw SearchWireError.poisoned
    }
  }

  private func validateDirectInput(_ utf16LE: Data) throws {
    guard !utf16LE.isEmpty, utf16LE.count.isMultiple(of: 2) else {
      throw SearchWireError.lengthMismatch
    }
    guard utf16LE.count <= searchWireMaximumUTF16ChunkBytes else {
      throw SearchWireError.payloadLimit
    }
    let addedUTF16 = utf16LE.count / 2
    guard consumedUTF16 <= expectedUTF16, addedUTF16 <= expectedUTF16 - consumedUTF16 else {
      throw SearchWireError.lengthMismatch
    }
  }

  private func decode(_ utf16LE: Data, emitUTF8: (Data) throws -> Void) throws {
    var output = Data()
    output.reserveCapacity(searchWireMaximumUTF16ChunkBytes)

    try utf16LE.withUnsafeBytes { rawBytes in
      for offset in stride(from: 0, to: rawBytes.count, by: 2) {
        let unit = UInt16(rawBytes[offset]) | (UInt16(rawBytes[offset + 1]) << 8)
        consumedUTF16 += 1

        if let high = pendingHighSurrogate {
          guard isLowSurrogate(unit) else {
            throw SearchWireError.malformedUTF16
          }
          pendingHighSurrogate = nil
          let scalar =
            0x1_0000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
          try appendUTF8(scalar, to: &output, emitUTF8: emitUTF8)
        } else if isHighSurrogate(unit) {
          pendingHighSurrogate = unit
        } else {
          guard !isLowSurrogate(unit) else {
            throw SearchWireError.malformedUTF16
          }
          try appendUTF8(UInt32(unit), to: &output, emitUTF8: emitUTF8)
        }
      }
    }

    if !output.isEmpty {
      try emit(&output, to: emitUTF8)
    }
  }

  private func appendUTF8(
    _ scalar: UInt32,
    to output: inout Data,
    emitUTF8: (Data) throws -> Void
  ) throws {
    let byteCount: Int
    if scalar <= 0x7F {
      byteCount = 1
    } else if scalar <= 0x7FF {
      byteCount = 2
    } else if scalar <= 0xFFFF {
      byteCount = 3
    } else {
      byteCount = 4
    }

    if output.count > searchWireMaximumUTF16ChunkBytes - byteCount {
      try emit(&output, to: emitUTF8)
    }

    switch byteCount {
    case 1:
      output.append(UInt8(scalar))
    case 2:
      output.append(0xC0 | UInt8(scalar >> 6))
      output.append(0x80 | UInt8(scalar & 0x3F))
    case 3:
      output.append(0xE0 | UInt8(scalar >> 12))
      output.append(0x80 | UInt8((scalar >> 6) & 0x3F))
      output.append(0x80 | UInt8(scalar & 0x3F))
    default:
      output.append(0xF0 | UInt8(scalar >> 18))
      output.append(0x80 | UInt8((scalar >> 12) & 0x3F))
      output.append(0x80 | UInt8((scalar >> 6) & 0x3F))
      output.append(0x80 | UInt8(scalar & 0x3F))
    }
  }

  private func emit(_ output: inout Data, to emitUTF8: (Data) throws -> Void) throws {
    let emitted = output
    output = Data()
    output.reserveCapacity(searchWireMaximumUTF16ChunkBytes)

    do {
      try emitUTF8(emitted)
    } catch {
      if state == .failed {
        if let wireError = error as? SearchWireError, wireError == .reentrantUse {
          throw wireError
        }
        throw SearchWireError.poisoned
      }
      state = .failed
      throw SearchWireError.sinkRejected
    }

    guard state == .inCall else {
      throw SearchWireError.poisoned
    }
  }
}

public final class SearchWireUTF16Encoder {
  private enum State {
    case active
    case finished
    case failed
  }

  private let expectedUTF16: Int
  private var iterator: String.UTF16View.Iterator
  private var emittedUTF16 = 0
  private var state = State.active

  public init(text: String, expectedUTF16: Int) throws {
    guard (0...searchWireMaximumUTF16).contains(expectedUTF16) else {
      throw SearchWireError.invalidMetadata
    }
    self.expectedUTF16 = expectedUTF16
    iterator = text.utf16.makeIterator()
  }

  public func nextChunk() throws -> Data? {
    switch state {
    case .active:
      break
    case .finished:
      return nil
    case .failed:
      throw SearchWireError.poisoned
    }

    var chunk = Data()
    chunk.reserveCapacity(searchWireMaximumUTF16ChunkBytes)

    while chunk.count < searchWireMaximumUTF16ChunkBytes {
      if emittedUTF16 == expectedUTF16 {
        guard iterator.next() == nil else {
          state = .failed
          throw SearchWireError.lengthMismatch
        }
        state = .finished
        return chunk.isEmpty ? nil : chunk
      }

      guard let unit = iterator.next() else {
        state = .failed
        throw SearchWireError.lengthMismatch
      }
      chunk.append(UInt8(truncatingIfNeeded: unit))
      chunk.append(UInt8(truncatingIfNeeded: unit >> 8))
      emittedUTF16 += 1
    }

    if emittedUTF16 == expectedUTF16 {
      guard iterator.next() == nil else {
        state = .failed
        throw SearchWireError.lengthMismatch
      }
      state = .finished
    }
    return chunk
  }
}

public final class SearchWireBoundaryIndex {
  private enum State {
    case active
    case finished
    case failed
  }

  public let identity: SearchWireIdentity
  let expectedUTF16: Int

  private var boundaries: [UInt8]
  private var consumedUTF16 = 0
  private var pendingHighSurrogate: UInt16?
  private var state = State.active

  public init(identity: SearchWireIdentity, expectedUTF16: Int) throws {
    guard (0...searchWireMaximumUTF16).contains(expectedUTF16) else {
      throw SearchWireError.invalidMetadata
    }
    self.identity = identity
    self.expectedUTF16 = expectedUTF16
    boundaries = [UInt8](repeating: 0, count: (expectedUTF16 + 8) / 8)
    markBoundary(at: 0)
  }

  public var storageByteCount: Int { boundaries.count }

  public func append(_ utf16LE: Data) throws {
    switch state {
    case .active:
      break
    case .finished:
      state = .failed
      throw SearchWireError.invalidPhase
    case .failed:
      throw SearchWireError.poisoned
    }

    do {
      try validateDirectInput(utf16LE)
      try appendUnits(utf16LE)
    } catch {
      state = .failed
      throw error
    }
  }

  public func finish() throws {
    switch state {
    case .active:
      guard consumedUTF16 == expectedUTF16 else {
        state = .failed
        throw SearchWireError.lengthMismatch
      }
      guard pendingHighSurrogate == nil else {
        state = .failed
        throw SearchWireError.malformedUTF16
      }
      state = .finished
    case .finished:
      return
    case .failed:
      throw SearchWireError.poisoned
    }
  }

  public func validate(_ range: NSRange, within scope: NSRange?) throws {
    switch state {
    case .active:
      throw SearchWireError.invalidPhase
    case .finished:
      break
    case .failed:
      throw SearchWireError.poisoned
    }

    guard hasValidEndpoints(range) else {
      throw SearchWireError.invalidRange
    }
    guard let scope else {
      return
    }
    guard hasValidEndpoints(scope) else {
      throw SearchWireError.invalidRange
    }

    let scopeEnd = scope.location + scope.length
    guard
      range.location >= scope.location,
      range.location <= scopeEnd,
      range.length <= scopeEnd - range.location
    else {
      throw SearchWireError.invalidRange
    }
  }

  private func validateDirectInput(_ utf16LE: Data) throws {
    guard !utf16LE.isEmpty, utf16LE.count.isMultiple(of: 2) else {
      throw SearchWireError.lengthMismatch
    }
    guard utf16LE.count <= searchWireMaximumUTF16ChunkBytes else {
      throw SearchWireError.payloadLimit
    }
    let addedUTF16 = utf16LE.count / 2
    guard consumedUTF16 <= expectedUTF16, addedUTF16 <= expectedUTF16 - consumedUTF16 else {
      throw SearchWireError.lengthMismatch
    }
  }

  private func appendUnits(_ utf16LE: Data) throws {
    try utf16LE.withUnsafeBytes { rawBytes in
      for offset in stride(from: 0, to: rawBytes.count, by: 2) {
        let unit = UInt16(rawBytes[offset]) | (UInt16(rawBytes[offset + 1]) << 8)
        consumedUTF16 += 1

        if pendingHighSurrogate != nil {
          guard isLowSurrogate(unit) else {
            throw SearchWireError.malformedUTF16
          }
          pendingHighSurrogate = nil
          markBoundary(at: consumedUTF16)
        } else if isHighSurrogate(unit) {
          pendingHighSurrogate = unit
        } else {
          guard !isLowSurrogate(unit) else {
            throw SearchWireError.malformedUTF16
          }
          markBoundary(at: consumedUTF16)
        }
      }
    }
  }

  private func markBoundary(at offset: Int) {
    boundaries[offset >> 3] |= UInt8(1 << (offset & 7))
  }

  private func hasValidEndpoints(_ range: NSRange) -> Bool {
    guard
      range.location >= 0,
      range.length >= 0,
      range.location <= expectedUTF16,
      range.length <= expectedUTF16 - range.location
    else {
      return false
    }
    let end = range.location + range.length
    return isBoundary(at: range.location) && isBoundary(at: end)
  }

  private func isBoundary(at offset: Int) -> Bool {
    boundaries[offset >> 3] & UInt8(1 << (offset & 7)) != 0
  }
}

private func isHighSurrogate(_ unit: UInt16) -> Bool {
  (0xD800...0xDBFF).contains(unit)
}

private func isLowSurrogate(_ unit: UInt16) -> Bool {
  (0xDC00...0xDFFF).contains(unit)
}
