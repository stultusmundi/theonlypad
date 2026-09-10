import Foundation

let searchWireMaximumFramePayload = 65_536

private let searchWireZeroUUID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

public struct SearchWireIdentity: Equatable, Sendable {
  public let generation: UUID
  public let requestID: UUID
  public let ordinal: UInt64

  public init(generation: UUID, requestID: UUID, ordinal: UInt64) throws {
    guard generation != searchWireZeroUUID, requestID != searchWireZeroUUID else {
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
  guard isHello == (requestID == searchWireZeroUUID) else {
    throw SearchWireError.identityMismatch
  }
}
