import Foundation
import PadCore

public protocol SearchWireRequestSink: AnyObject {
  func helloAccepted(generation: UUID) throws
  func begin(_ request: SearchWireRequest) throws
  func appendInputUTF8(_ bytes: Data) throws
  func execute(_ identity: SearchWireIdentity) throws
}

public final class SearchWireRequestReader {
  private enum State {
    case idle
    case inCall
    case finished
    case failed
  }

  private enum Phase {
    case awaitingHello
    case ready(expectedOrdinal: UInt64?)
    case receiving(RequestContext)
    case executing(SearchWireIdentity)
  }

  private let generation: UUID
  private let frameDecoder = SearchWireFrameDecoder()
  private var state = State.idle
  private var phase = Phase.awaitingHello

  public init(generation: UUID) throws {
    guard generation != searchWireZeroRequestID else {
      throw SearchWireError.identityMismatch
    }
    self.generation = generation
  }

  public func consume(
    _ bytes: UnsafeRawBufferPointer,
    sink: SearchWireRequestSink
  ) throws {
    try beginCall()
    if !bytes.isEmpty, case .executing = phase {
      state = .failed
      throw SearchWireError.invalidPhase
    }
    var preservedError: SearchWireError?

    do {
      try frameDecoder.consume(bytes) { frame in
        do {
          try self.accept(frame, sink: sink)
        } catch let failure as RequestReaderFailure {
          preservedError = failure.error
          throw failure
        }
      }
    } catch {
      let result: SearchWireError
      if let preservedError {
        result = preservedError
      } else if state == .failed {
        result = .poisoned
      } else {
        result = error as? SearchWireError ?? .sinkRejected
      }
      if state == .inCall {
        state = .failed
      }
      throw result
    }

    if case .executing = phase, frameDecoder.bufferedByteCount > 0 {
      state = .failed
      throw SearchWireError.invalidPhase
    }
    guard state == .inCall else {
      throw SearchWireError.poisoned
    }
    state = .idle
  }

  public func finish() throws {
    switch state {
    case .idle:
      guard case .ready = phase else {
        state = .failed
        throw SearchWireError.truncated
      }
      do {
        try frameDecoder.finish()
      } catch {
        state = .failed
        throw error
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

  public func acknowledgeTerminal(_ identity: SearchWireIdentity) throws {
    try beginCall()
    do {
      guard case .executing(let executingIdentity) = phase else {
        throw SearchWireError.invalidPhase
      }
      guard identity.generation == executingIdentity.generation,
        identity.requestID == executingIdentity.requestID
      else {
        throw SearchWireError.identityMismatch
      }
      guard identity.ordinal == executingIdentity.ordinal else {
        throw SearchWireError.ordinalMismatch
      }
      phase = .ready(expectedOrdinal: searchWireSuccessor(after: identity.ordinal))
      state = .idle
    } catch {
      if state == .inCall {
        state = .failed
      }
      throw error
    }
  }

  private func beginCall() throws {
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
  }

  private func accept(_ frame: SearchWireFrame, sink: SearchWireRequestSink) throws {
    switch phase {
    case .awaitingHello:
      try acceptHello(frame, sink: sink)
    case .ready(let expectedOrdinal):
      try acceptRequestStart(frame, expectedOrdinal: expectedOrdinal, sink: sink)
    case .receiving(let context):
      try acceptRequestInput(frame, context: context, sink: sink)
    case .executing:
      throw RequestReaderFailure(.invalidPhase)
    }
  }

  private func acceptHello(_ frame: SearchWireFrame, sink: SearchWireRequestSink) throws {
    guard frame.kind == .parentHello else {
      throw RequestReaderFailure(.invalidPhase)
    }
    guard frame.payload.count == 24 else {
      throw RequestReaderFailure(.invalidMetadata)
    }
    guard decodeUUID(frame.payload, at: 0) == generation else {
      throw RequestReaderFailure(.identityMismatch)
    }
    guard decodeUInt32(frame.payload, at: 16) == searchWireSemanticVersion else {
      throw RequestReaderFailure(.unsupportedVersion)
    }
    guard decodeUInt32(frame.payload, at: 20) == 0 else {
      throw RequestReaderFailure(.invalidMetadata)
    }

    phase = .ready(expectedOrdinal: 1)
    try sink.helloAccepted(generation: generation)
    guard state == .inCall else {
      throw RequestReaderFailure(.poisoned)
    }
  }

  private func acceptRequestStart(
    _ frame: SearchWireFrame,
    expectedOrdinal: UInt64?,
    sink: SearchWireRequestSink
  ) throws {
    guard frame.kind == .requestStart else {
      throw RequestReaderFailure(.invalidPhase)
    }
    guard frame.payload.count >= 64 else {
      throw RequestReaderFailure(.invalidMetadata)
    }

    let ordinal = decodeUInt64(frame.payload, at: 0)
    guard let expectedOrdinal, ordinal == expectedOrdinal else {
      throw RequestReaderFailure(.ordinalMismatch)
    }

    let inputUTF16 = decodeUInt64(frame.payload, at: 8)
    let scopeLocation = decodeUInt64(frame.payload, at: 16)
    let scopeLength = decodeUInt64(frame.payload, at: 24)
    let maxTextUTF16 = decodeUInt64(frame.payload, at: 32)
    let maxOutputUTF16 = decodeUInt64(frame.payload, at: 40)
    let maxMatches = decodeUInt32(frame.payload, at: 48)
    let cooperativeMilliseconds = decodeUInt32(frame.payload, at: 52)
    let patternUTF16 = Int(decodeUInt16(frame.payload, at: 56))
    let templateUTF16 = Int(decodeUInt16(frame.payload, at: 58))
    let modeCode = frame.payload[60]
    let operationCode = frame.payload[61]
    let options = frame.payload[62]
    let hasScope = frame.payload[63]

    guard
      inputUTF16 <= UInt64(searchWireGlobalMaximumUTF16),
      scopeLocation <= UInt64(searchWireGlobalMaximumUTF16),
      scopeLength <= UInt64(searchWireGlobalMaximumUTF16),
      maxTextUTF16 <= UInt64(searchWireGlobalMaximumUTF16),
      maxOutputUTF16 <= UInt64(searchWireGlobalMaximumUTF16),
      maxMatches <= UInt32(searchWireGlobalMaximumMatches),
      cooperativeMilliseconds <= searchWireMaximumCooperativeMilliseconds,
      patternUTF16 <= searchWireMaximumRequestBlobUTF16,
      templateUTF16 <= searchWireMaximumRequestBlobUTF16,
      options & ~UInt8(3) == 0,
      hasScope <= 1
    else {
      throw RequestReaderFailure(.invalidMetadata)
    }

    let patternByteCount = patternUTF16 * 2
    let templateByteCount = templateUTF16 * 2
    guard frame.payload.count == 64 + patternByteCount + templateByteCount else {
      throw RequestReaderFailure(.invalidMetadata)
    }
    guard hasScope == 1 || (scopeLocation == 0 && scopeLength == 0) else {
      throw RequestReaderFailure(.invalidMetadata)
    }
    guard operationCode == 1 || templateUTF16 == 0 else {
      throw RequestReaderFailure(.invalidMetadata)
    }

    let mode: SearchMode
    switch modeCode {
    case 0: mode = .literal
    case 1: mode = .escaped
    case 2: mode = .regex
    default: throw RequestReaderFailure(.invalidMetadata)
    }

    let patternBytes = frame.payload.subdata(in: 64..<(64 + patternByteCount))
    let templateBytes = frame.payload.subdata(
      in: (64 + patternByteCount)..<(64 + patternByteCount + templateByteCount))
    let pattern = try decodeSmallUTF16(patternBytes, expectedUTF16: patternUTF16)
    let operation: SearchExecutionOperation
    switch operationCode {
    case 0:
      operation = .find
    case 1:
      operation = .replace(
        template: try decodeSmallUTF16(templateBytes, expectedUTF16: templateUTF16))
    default:
      throw RequestReaderFailure(.invalidMetadata)
    }

    let request: SearchWireRequest
    let context: RequestContext
    do {
      let identity = try SearchWireIdentity(
        generation: generation, requestID: frame.requestID, ordinal: ordinal)
      let limits = try SearchWireLimits(
        maxTextUTF16: Int(maxTextUTF16),
        maxOutputUTF16: Int(maxOutputUTF16),
        maxMatches: Int(maxMatches),
        cooperativeMilliseconds: cooperativeMilliseconds)
      let scope =
        hasScope == 1
        ? NSRange(location: Int(scopeLocation), length: Int(scopeLength))
        : nil
      request = try SearchWireRequest(
        identity: identity,
        query: SearchQuery(
          pattern: pattern,
          mode: mode,
          caseSensitive: options & 1 != 0,
          wholeWord: options & 2 != 0),
        operation: operation,
        inputUTF16: Int(inputUTF16),
        scope: scope,
        limits: limits)
      context = try RequestContext(request: request)
    } catch let failure as RequestReaderFailure {
      throw failure
    } catch let error as SearchWireError {
      throw RequestReaderFailure(error)
    }

    phase = .receiving(context)
    try sink.begin(request)
    guard state == .inCall else {
      throw RequestReaderFailure(.poisoned)
    }
  }

  private func acceptRequestInput(
    _ frame: SearchWireFrame,
    context: RequestContext,
    sink: SearchWireRequestSink
  ) throws {
    guard frame.requestID == context.request.identity.requestID else {
      throw RequestReaderFailure(.identityMismatch)
    }

    switch frame.kind {
    case .inputChunk:
      do {
        try context.boundaries.append(frame.payload)
        try context.decoder.consume(frame.payload) { bytes in
          try sink.appendInputUTF8(bytes)
        }
      } catch let error as SearchWireError {
        throw RequestReaderFailure(error)
      }
      guard state == .inCall else {
        throw RequestReaderFailure(.poisoned)
      }
    case .execute:
      guard frame.payload.isEmpty else {
        throw RequestReaderFailure(.invalidMetadata)
      }
      do {
        try context.boundaries.finish()
        try context.decoder.finish()
        if let scope = context.request.scope {
          try context.boundaries.validate(scope, within: nil)
        }
      } catch let error as SearchWireError {
        throw RequestReaderFailure(error)
      }

      let identity = context.request.identity
      phase = .executing(identity)
      try sink.execute(identity)
      guard state == .inCall else {
        throw RequestReaderFailure(.poisoned)
      }
    default:
      throw RequestReaderFailure(.invalidPhase)
    }
  }

  private func decodeSmallUTF16(_ data: Data, expectedUTF16: Int) throws -> String {
    do {
      let decoder = try SearchWireUTF16Decoder(expectedUTF16: expectedUTF16)
      var utf8 = Data()
      if !data.isEmpty {
        try decoder.consume(data) { utf8.append($0) }
      }
      try decoder.finish()
      guard let decoded = String(data: utf8, encoding: .utf8) else {
        throw SearchWireError.malformedUTF16
      }
      return decoded
    } catch let error as SearchWireError {
      throw RequestReaderFailure(error)
    }
  }
}

private final class RequestContext {
  let request: SearchWireRequest
  let decoder: SearchWireUTF16Decoder
  let boundaries: SearchWireBoundaryIndex

  init(request: SearchWireRequest) throws {
    self.request = request
    decoder = try SearchWireUTF16Decoder(expectedUTF16: request.inputUTF16)
    boundaries = try SearchWireBoundaryIndex(
      identity: request.identity, expectedUTF16: request.inputUTF16)
  }
}

func searchWireSuccessor(after ordinal: UInt64) -> UInt64? {
  ordinal == UInt64.max ? nil : ordinal + 1
}

public enum SearchWireWriter {
  public static func hello(
    generation: UUID,
    fromChild: Bool,
    emit: (Data) throws -> Void
  ) throws {
    guard generation != searchWireZeroRequestID else {
      throw SearchWireError.identityMismatch
    }

    var payload = Data()
    append(generation, to: &payload)
    append(searchWireSemanticVersion, to: &payload)
    append(0 as UInt32, to: &payload)
    let frame = try SearchWireFrame(
      kind: fromChild ? .childHello : .parentHello,
      requestID: searchWireZeroRequestID,
      payload: payload)
    try SearchWireFrameEncoder.write(frame, emit: emit)
  }

  public static func request(
    _ request: SearchWireRequest,
    text: String,
    emit: (Data) throws -> Void
  ) throws -> SearchWireBoundaryIndex {
    let metadata = try encodeRequestMetadata(request)
    try writeFrame(
      kind: .requestStart,
      requestID: request.identity.requestID,
      payload: metadata,
      emit: emit)

    let encoder = try SearchWireUTF16Encoder(text: text, expectedUTF16: request.inputUTF16)
    let index = try SearchWireBoundaryIndex(
      identity: request.identity, expectedUTF16: request.inputUTF16)
    while let chunk = try encoder.nextChunk() {
      try index.append(chunk)
      try writeFrame(
        kind: .inputChunk,
        requestID: request.identity.requestID,
        payload: chunk,
        emit: emit)
    }
    try index.finish()
    if let scope = request.scope {
      try index.validate(scope, within: nil)
    }

    try writeFrame(
      kind: .execute,
      requestID: request.identity.requestID,
      payload: Data(),
      emit: emit)
    return index
  }

  private static func encodeRequestMetadata(_ request: SearchWireRequest) throws -> Data {
    let pattern = encodeSmallUTF16(request.query.pattern)
    let template: Data
    let operation: UInt8
    switch request.operation {
    case .find:
      template = Data()
      operation = 0
    case .replace(let replacementTemplate):
      template = encodeSmallUTF16(replacementTemplate)
      operation = 1
    }

    var payload = Data()
    payload.reserveCapacity(64 + pattern.count + template.count)
    append(request.identity.ordinal, to: &payload)
    append(UInt64(request.inputUTF16), to: &payload)
    append(UInt64(request.scope?.location ?? 0), to: &payload)
    append(UInt64(request.scope?.length ?? 0), to: &payload)
    append(UInt64(request.limits.maxTextUTF16), to: &payload)
    append(UInt64(request.limits.maxOutputUTF16), to: &payload)
    append(UInt32(request.limits.maxMatches), to: &payload)
    append(request.limits.cooperativeMilliseconds, to: &payload)
    append(UInt16(pattern.count / 2), to: &payload)
    append(UInt16(template.count / 2), to: &payload)
    payload.append(modeCode(request.query.mode))
    payload.append(operation)
    payload.append(
      (request.query.caseSensitive ? 1 : 0) | (request.query.wholeWord ? 2 : 0))
    payload.append(request.scope == nil ? 0 : 1)
    payload.append(pattern)
    payload.append(template)
    return payload
  }

  private static func encodeSmallUTF16(_ text: String) -> Data {
    var encoded = Data()
    encoded.reserveCapacity(text.utf16.count * 2)
    for unit in text.utf16 {
      append(unit, to: &encoded)
    }
    return encoded
  }

  private static func modeCode(_ mode: SearchMode) -> UInt8 {
    switch mode {
    case .literal: return 0
    case .escaped: return 1
    case .regex: return 2
    }
  }

  private static func writeFrame(
    kind: SearchWireKind,
    requestID: UUID,
    payload: Data,
    emit: (Data) throws -> Void
  ) throws {
    let frame = try SearchWireFrame(kind: kind, requestID: requestID, payload: payload)
    try SearchWireFrameEncoder.write(frame, emit: emit)
  }
}

private let searchWireZeroRequestID = UUID(
  uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

private struct RequestReaderFailure: Error {
  let error: SearchWireError

  init(_ error: SearchWireError) {
    self.error = error
  }
}

private func decodeUInt32(_ data: Data, at offset: Int) -> UInt32 {
  var result: UInt32 = 0
  for byteOffset in 0..<4 {
    result |= UInt32(data[offset + byteOffset]) << UInt32(byteOffset * 8)
  }
  return result
}

private func decodeUInt16(_ data: Data, at offset: Int) -> UInt16 {
  UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func decodeUInt64(_ data: Data, at offset: Int) -> UInt64 {
  var result: UInt64 = 0
  for byteOffset in 0..<8 {
    result |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
  }
  return result
}

private func decodeUUID(_ data: Data, at offset: Int) -> UUID {
  UUID(
    uuid: (
      data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
      data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
      data[offset + 8], data[offset + 9], data[offset + 10], data[offset + 11],
      data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]
    ))
}

private func append(_ value: UInt16, to data: inout Data) {
  data.append(UInt8(truncatingIfNeeded: value))
  data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func append(_ value: UInt32, to data: inout Data) {
  for offset in 0..<4 {
    data.append(UInt8(truncatingIfNeeded: value >> UInt32(offset * 8)))
  }
}

private func append(_ value: UInt64, to data: inout Data) {
  for offset in 0..<8 {
    data.append(UInt8(truncatingIfNeeded: value >> UInt64(offset * 8)))
  }
}

private func append(_ value: UUID, to data: inout Data) {
  var bytes = value.uuid
  withUnsafeBytes(of: &bytes) {
    data.append(contentsOf: $0)
  }
}
