import Foundation
import PadCore

let searchWireMaximumFramePayload = 65_536
let searchWireGlobalMaximumUTF16 = 100_000_000
let searchWireGlobalMaximumMatches = 100_000
let searchWireMaximumRequestBlobUTF16 = 4_096
let searchWireMaximumCooperativeMilliseconds: UInt32 = 60_000
let searchWireSemanticVersion: UInt32 = 1

public struct SearchWireIdentity: Equatable, Sendable {
  public let generation: UUID
  public let requestID: UUID
  public let ordinal: UInt64

  public init(generation: UUID, requestID: UUID, ordinal: UInt64) throws {
    guard generation != SearchWireBinary.zeroUUID, requestID != SearchWireBinary.zeroUUID else {
      throw SearchWireError.identityMismatch
    }
    guard ordinal != 0 else {
      throw SearchWireError.ordinalMismatch
    }
    self.generation = generation
    self.requestID = requestID
    self.ordinal = ordinal
  }
}

public struct SearchWireResponse: Equatable, Sendable {
  public let identity: SearchWireIdentity
  public let matchCount: Int
  public let replacementUTF16: Int?

  public init(
    identity: SearchWireIdentity,
    matchCount: Int,
    replacementUTF16: Int?
  ) throws {
    guard (0...searchWireGlobalMaximumMatches).contains(matchCount) else {
      throw SearchWireError.invalidMetadata
    }
    if let replacementUTF16 {
      guard (0...searchWireGlobalMaximumUTF16).contains(replacementUTF16) else {
        throw SearchWireError.invalidMetadata
      }
    }
    self.identity = identity
    self.matchCount = matchCount
    self.replacementUTF16 = replacementUTF16
  }
}

public enum SearchWireTerminal: Equatable, Sendable {
  case success
  case failure(SearchError)
}

public struct SearchWireLimits: Equatable, Sendable {
  public let maxTextUTF16: Int
  public let maxOutputUTF16: Int
  public let maxMatches: Int
  public let cooperativeMilliseconds: UInt32

  public init(
    maxTextUTF16: Int,
    maxOutputUTF16: Int,
    maxMatches: Int,
    cooperativeMilliseconds: UInt32
  ) throws {
    guard
      (0...searchWireGlobalMaximumUTF16).contains(maxTextUTF16),
      (0...searchWireGlobalMaximumUTF16).contains(maxOutputUTF16),
      (0...searchWireGlobalMaximumMatches).contains(maxMatches),
      cooperativeMilliseconds <= searchWireMaximumCooperativeMilliseconds
    else {
      throw SearchWireError.invalidMetadata
    }
    self.maxTextUTF16 = maxTextUTF16
    self.maxOutputUTF16 = maxOutputUTF16
    self.maxMatches = maxMatches
    self.cooperativeMilliseconds = cooperativeMilliseconds
  }
}

public struct SearchWireRequest: Sendable {
  public let identity: SearchWireIdentity
  public let query: SearchQuery
  public let operation: SearchExecutionOperation
  public let inputUTF16: Int
  public let scope: NSRange?
  public let limits: SearchWireLimits

  public init(
    identity: SearchWireIdentity,
    query: SearchQuery,
    operation: SearchExecutionOperation,
    inputUTF16: Int,
    scope: NSRange?,
    limits: SearchWireLimits
  ) throws {
    guard
      (0...searchWireGlobalMaximumUTF16).contains(inputUTF16),
      inputUTF16 <= limits.maxTextUTF16,
      searchWireRequestBlobFits(query.pattern)
    else {
      throw SearchWireError.invalidMetadata
    }

    if case .replace(let template) = operation {
      guard searchWireRequestBlobFits(template) else {
        throw SearchWireError.invalidMetadata
      }
    }

    if let scope {
      guard
        scope.location >= 0,
        scope.length >= 0,
        scope.location <= inputUTF16,
        scope.length <= inputUTF16 - scope.location
      else {
        throw SearchWireError.invalidMetadata
      }
    }

    self.identity = identity
    self.query = query
    self.operation = operation
    self.inputUTF16 = inputUTF16
    self.scope = scope
    self.limits = limits
  }
}

private func searchWireRequestBlobFits(_ text: String) -> Bool {
  text.utf16.prefix(searchWireMaximumRequestBlobUTF16 + 1).count
    <= searchWireMaximumRequestBlobUTF16
}

public enum SearchWireError: Error, Equatable, Sendable {
  case invalidHeader, unsupportedVersion, unknownKind, payloadLimit
  case invalidMetadata, identityMismatch, ordinalMismatch, invalidPhase
  case truncated, lengthMismatch, malformedUTF16, invalidRange, poisoned
  case reentrantUse, sinkRejected
}

public enum SearchWireKind: UInt16, Sendable {
  case parentHello = 1
  case childHello = 2
  case requestStart = 16
  case inputChunk = 17
  case execute = 18
  case responseStart = 32
  case rangeChunk = 33
  case replacementChunk = 34
  case terminal = 35
}

public struct SearchWireFrame: Sendable {
  public let kind: SearchWireKind
  public let requestID: UUID
  public let payload: Data

  public init(kind: SearchWireKind, requestID: UUID, payload: Data) throws {
    guard payload.count <= searchWireMaximumFramePayload else {
      throw SearchWireError.payloadLimit
    }
    try validateSearchWireFrameIdentity(kind: kind, requestID: requestID)
    self.kind = kind
    self.requestID = requestID
    self.payload = payload
  }
}

func validateSearchWireFrameIdentity(kind: SearchWireKind, requestID: UUID) throws {
  let isHello = kind == .parentHello || kind == .childHello
  guard isHello == (requestID == SearchWireBinary.zeroUUID) else {
    throw SearchWireError.identityMismatch
  }
}

enum SearchWireBinary {
  static let zeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

  static func writeFrame(
    kind: SearchWireKind,
    requestID: UUID,
    payload: Data,
    emit: (Data) throws -> Void
  ) throws {
    let frame = try SearchWireFrame(kind: kind, requestID: requestID, payload: payload)
    try SearchWireFrameEncoder.write(frame, emit: emit)
  }

  static func decodeUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  static func decodeUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var result: UInt32 = 0
    for byteOffset in 0..<4 {
      result |= UInt32(data[offset + byteOffset]) << UInt32(byteOffset * 8)
    }
    return result
  }

  static func decodeUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for byteOffset in 0..<8 {
      result |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
    }
    return result
  }

  static func decodeUUID(_ data: Data, at offset: Int) -> UUID {
    UUID(
      uuid: (
        data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
        data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
        data[offset + 8], data[offset + 9], data[offset + 10], data[offset + 11],
        data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]
      ))
  }

  static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
  }

  static func append(_ value: UInt32, to data: inout Data) {
    for offset in 0..<4 {
      data.append(UInt8(truncatingIfNeeded: value >> UInt32(offset * 8)))
    }
  }

  static func append(_ value: UInt64, to data: inout Data) {
    for offset in 0..<8 {
      data.append(UInt8(truncatingIfNeeded: value >> UInt64(offset * 8)))
    }
  }
}
