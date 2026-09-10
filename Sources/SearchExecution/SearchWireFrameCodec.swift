import Foundation

public final class SearchWireFrameDecoder {
  private static let headerByteCount = 32
  private static let maximumInputByteCount = headerByteCount + searchWireMaximumFramePayload

  private enum State {
    case idle
    case inCall
    case finished
    case failed
  }

  private struct Header {
    let kind: SearchWireKind
    let requestID: UUID
    let payloadByteCount: Int
  }

  private var state = State.idle
  private var headerBytes = Data()
  private var header: Header?
  private var payloadBytes = Data()

  public init() {}

  public var bufferedByteCount: Int {
    headerBytes.count + payloadBytes.count
  }

  public func consume(
    _ bytes: UnsafeRawBufferPointer,
    onFrame: (SearchWireFrame) throws -> Void
  ) throws {
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

    guard bytes.count <= Self.maximumInputByteCount else {
      state = .failed
      throw SearchWireError.payloadLimit
    }

    do {
      try process(bytes, onFrame: onFrame)
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
      guard headerBytes.isEmpty, header == nil, payloadBytes.isEmpty else {
        state = .failed
        throw SearchWireError.truncated
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

  private func process(
    _ bytes: UnsafeRawBufferPointer,
    onFrame: (SearchWireFrame) throws -> Void
  ) throws {
    var offset = 0
    while offset < bytes.count {
      if header == nil {
        let copied = min(Self.headerByteCount - headerBytes.count, bytes.count - offset)
        headerBytes.append(contentsOf: bytes[offset..<(offset + copied)])
        offset += copied
        guard headerBytes.count == Self.headerByteCount else {
          continue
        }

        let parsed = try decodeHeader()
        header = parsed
        headerBytes.removeAll(keepingCapacity: true)
        if parsed.payloadByteCount > 0 {
          payloadBytes.reserveCapacity(parsed.payloadByteCount)
        } else {
          try emitCompletedFrame(parsed, onFrame: onFrame)
        }
      } else if let header {
        let copied = min(header.payloadByteCount - payloadBytes.count, bytes.count - offset)
        payloadBytes.append(contentsOf: bytes[offset..<(offset + copied)])
        offset += copied
        if payloadBytes.count == header.payloadByteCount {
          try emitCompletedFrame(header, onFrame: onFrame)
        }
      }
    }
  }

  private func decodeHeader() throws -> Header {
    guard
      headerBytes[0] == 0x50,
      headerBytes[1] == 0x53,
      headerBytes[2] == 0x52,
      headerBytes[3] == 0x58
    else {
      throw SearchWireError.invalidHeader
    }

    guard decodeUInt16(at: 4) == 1 else {
      throw SearchWireError.unsupportedVersion
    }
    guard let kind = SearchWireKind(rawValue: decodeUInt16(at: 6)) else {
      throw SearchWireError.unknownKind
    }

    let payloadByteCount = decodeUInt64(at: 8)
    guard payloadByteCount <= UInt64(searchWireMaximumFramePayload) else {
      throw SearchWireError.payloadLimit
    }

    let requestID = UUID(
      uuid: (
        headerBytes[16], headerBytes[17], headerBytes[18], headerBytes[19],
        headerBytes[20], headerBytes[21], headerBytes[22], headerBytes[23],
        headerBytes[24], headerBytes[25], headerBytes[26], headerBytes[27],
        headerBytes[28], headerBytes[29], headerBytes[30], headerBytes[31]
      ))
    try validateSearchWireFrameIdentity(kind: kind, requestID: requestID)
    return Header(
      kind: kind, requestID: requestID, payloadByteCount: Int(payloadByteCount))
  }

  private func emitCompletedFrame(
    _ completedHeader: Header,
    onFrame: (SearchWireFrame) throws -> Void
  ) throws {
    let frame = try SearchWireFrame(
      kind: completedHeader.kind,
      requestID: completedHeader.requestID,
      payload: payloadBytes)
    header = nil
    payloadBytes.removeAll(keepingCapacity: true)

    do {
      try onFrame(frame)
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

  private func decodeUInt16(at offset: Int) -> UInt16 {
    UInt16(headerBytes[offset]) | (UInt16(headerBytes[offset + 1]) << 8)
  }

  private func decodeUInt64(at offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for byteOffset in 0..<8 {
      result |= UInt64(headerBytes[offset + byteOffset]) << UInt64(byteOffset * 8)
    }
    return result
  }
}

public enum SearchWireFrameEncoder {
  public static func write(
    _ frame: SearchWireFrame,
    emit: (Data) throws -> Void
  ) throws {
    var header = Data([0x50, 0x53, 0x52, 0x58])
    append(1 as UInt16, to: &header)
    append(frame.kind.rawValue, to: &header)
    append(UInt64(frame.payload.count), to: &header)
    var requestUUID = frame.requestID.uuid
    withUnsafeBytes(of: &requestUUID) {
      header.append(contentsOf: $0)
    }

    do {
      try emit(header)
      if !frame.payload.isEmpty {
        try emit(frame.payload)
      }
    } catch {
      throw SearchWireError.sinkRejected
    }
  }

  private static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  private static func append(_ value: UInt64, to data: inout Data) {
    for byteOffset in 0..<8 {
      data.append(UInt8(truncatingIfNeeded: value >> UInt64(byteOffset * 8)))
    }
  }
}
