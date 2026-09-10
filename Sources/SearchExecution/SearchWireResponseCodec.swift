import Foundation
import PadCore

public protocol SearchWireResponseSink: AnyObject {
  func helloAccepted(generation: UUID) throws
  func begin(_ response: SearchWireResponse) throws
  func appendRanges(_ ranges: [NSRange]) throws
  func appendReplacementUTF8(_ bytes: Data) throws
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws
}

public final class SearchWireResponseReader {
  private enum State {
    case idle
    case inCall
    case finished
    case failed
  }

  private enum Phase {
    case awaitingHello
    case ready(expectedOrdinal: UInt64?)
    case waiting(ResponseContext)
  }

  private struct PendingCompletion {
    let identity: SearchWireIdentity
    let terminal: SearchWireTerminal
  }

  private let generation: UUID
  private let frameDecoder = SearchWireFrameDecoder()
  private var state = State.idle
  private var phase = Phase.awaitingHello
  private var pendingCompletion: PendingCompletion?

  public init(generation: UUID) throws {
    guard generation != SearchWireBinary.zeroUUID else {
      throw SearchWireError.identityMismatch
    }
    self.generation = generation
  }

  public func expect(
    _ request: SearchWireRequest,
    boundaries: SearchWireBoundaryIndex
  ) throws {
    try beginCall()
    do {
      guard case .ready(let expectedOrdinal) = phase else {
        throw SearchWireError.invalidPhase
      }
      guard request.identity.generation == generation else {
        throw SearchWireError.identityMismatch
      }
      guard let expectedOrdinal, request.identity.ordinal == expectedOrdinal else {
        throw SearchWireError.ordinalMismatch
      }
      guard
        boundaries.identity.generation == request.identity.generation,
        boundaries.identity.requestID == request.identity.requestID
      else {
        throw SearchWireError.identityMismatch
      }
      guard boundaries.identity.ordinal == request.identity.ordinal else {
        throw SearchWireError.ordinalMismatch
      }
      guard boundaries.expectedUTF16 == request.inputUTF16 else {
        throw SearchWireError.lengthMismatch
      }
      try boundaries.validate(NSRange(location: 0, length: request.inputUTF16), within: nil)

      phase = .waiting(try ResponseContext(request: request, boundaries: boundaries))
      state = .idle
    } catch {
      if state == .inCall {
        state = .failed
      }
      throw error
    }
  }

  public func consume(
    _ bytes: UnsafeRawBufferPointer,
    sink: SearchWireResponseSink
  ) throws {
    try beginCall()
    if !bytes.isEmpty, case .ready = phase {
      state = .failed
      throw SearchWireError.invalidPhase
    }
    var preservedError: SearchWireError?

    do {
      try frameDecoder.consume(bytes) { frame in
        do {
          try self.accept(frame, sink: sink)
        } catch let failure as ResponseReaderFailure {
          preservedError = failure.error
          throw failure
        }
      }
    } catch {
      let result: SearchWireError
      if state == .failed {
        result = .poisoned
      } else if let preservedError {
        result = preservedError
      } else {
        result = error as? SearchWireError ?? .sinkRejected
      }
      if state == .inCall {
        state = .failed
      }
      pendingCompletion = nil
      throw result
    }

    if case .ready = phase, frameDecoder.bufferedByteCount > 0 {
      state = .failed
      pendingCompletion = nil
      throw SearchWireError.invalidPhase
    }

    if let completion = pendingCompletion {
      pendingCompletion = nil
      do {
        try sink.complete(completion.identity, terminal: completion.terminal)
      } catch {
        if state == .failed {
          throw SearchWireError.poisoned
        }
        state = .failed
        throw SearchWireError.sinkRejected
      }
      guard state == .inCall else {
        throw SearchWireError.poisoned
      }
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

  private func accept(_ frame: SearchWireFrame, sink: SearchWireResponseSink) throws {
    switch phase {
    case .awaitingHello:
      try acceptHello(frame, sink: sink)
    case .ready:
      throw ResponseReaderFailure(.invalidPhase)
    case .waiting(let context):
      try acceptResponse(frame, context: context, sink: sink)
    }
  }

  private func acceptHello(_ frame: SearchWireFrame, sink: SearchWireResponseSink) throws {
    guard frame.kind == .childHello else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    guard frame.payload.count == 24 else {
      throw ResponseReaderFailure(.invalidMetadata)
    }
    guard SearchWireBinary.decodeUUID(frame.payload, at: 0) == generation else {
      throw ResponseReaderFailure(.identityMismatch)
    }
    guard SearchWireBinary.decodeUInt32(frame.payload, at: 16) == searchWireSemanticVersion else {
      throw ResponseReaderFailure(.unsupportedVersion)
    }
    guard SearchWireBinary.decodeUInt32(frame.payload, at: 20) == 0 else {
      throw ResponseReaderFailure(.invalidMetadata)
    }

    phase = .ready(expectedOrdinal: 1)
    try sink.helloAccepted(generation: generation)
    guard state == .inCall else {
      throw ResponseReaderFailure(.poisoned)
    }
  }

  private func acceptResponse(
    _ frame: SearchWireFrame,
    context: ResponseContext,
    sink: SearchWireResponseSink
  ) throws {
    guard frame.requestID == context.request.identity.requestID else {
      throw ResponseReaderFailure(.identityMismatch)
    }

    switch frame.kind {
    case .responseStart:
      try acceptResponseStart(frame, context: context, sink: sink)
    case .rangeChunk:
      try acceptRanges(frame, context: context, sink: sink)
    case .replacementChunk:
      try acceptReplacement(frame, context: context, sink: sink)
    case .terminal:
      try acceptTerminal(frame, context: context)
    default:
      throw ResponseReaderFailure(.invalidPhase)
    }
  }

  private func acceptResponseStart(
    _ frame: SearchWireFrame,
    context: ResponseContext,
    sink: SearchWireResponseSink
  ) throws {
    guard context.response == nil else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    guard frame.payload.count == 32 else {
      throw ResponseReaderFailure(.invalidMetadata)
    }

    let ordinal = SearchWireBinary.decodeUInt64(frame.payload, at: 0)
    guard ordinal == context.request.identity.ordinal else {
      throw ResponseReaderFailure(.ordinalMismatch)
    }
    let matchCount = SearchWireBinary.decodeUInt32(frame.payload, at: 8)
    let reserved = SearchWireBinary.decodeUInt32(frame.payload, at: 12)
    let replacementUTF16 = SearchWireBinary.decodeUInt64(frame.payload, at: 16)
    let hasReplacement = frame.payload[24]
    guard
      reserved == 0,
      frame.payload[25..<32].allSatisfy({ $0 == 0 }),
      hasReplacement <= 1,
      matchCount <= UInt32(context.request.limits.maxMatches),
      replacementUTF16 <= UInt64(context.request.limits.maxOutputUTF16)
    else {
      throw ResponseReaderFailure(.invalidMetadata)
    }

    let declaredReplacement: Int?
    switch context.request.operation {
    case .find:
      guard hasReplacement == 0, replacementUTF16 == 0 else {
        throw ResponseReaderFailure(.invalidMetadata)
      }
      declaredReplacement = nil
    case .replace:
      guard hasReplacement == 1 else {
        throw ResponseReaderFailure(.invalidMetadata)
      }
      declaredReplacement = Int(replacementUTF16)
    }

    let response: SearchWireResponse
    do {
      response = try SearchWireResponse(
        identity: context.request.identity, matchCount: Int(matchCount),
        replacementUTF16: declaredReplacement)
      try context.begin(response)
    } catch let error as SearchWireError {
      throw ResponseReaderFailure(error)
    }
    try sink.begin(response)
    guard state == .inCall else {
      throw ResponseReaderFailure(.poisoned)
    }
  }

  private func acceptRanges(
    _ frame: SearchWireFrame,
    context: ResponseContext,
    sink: SearchWireResponseSink
  ) throws {
    guard let response = context.response else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    guard !context.replacementStarted else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    guard !frame.payload.isEmpty, frame.payload.count.isMultiple(of: 16) else {
      throw ResponseReaderFailure(.lengthMismatch)
    }
    let addedCount = frame.payload.count / 16
    guard context.receivedRanges <= response.matchCount,
      addedCount <= response.matchCount - context.receivedRanges
    else {
      throw ResponseReaderFailure(.lengthMismatch)
    }

    var decoded: [NSRange] = []
    decoded.reserveCapacity(addedCount)
    for offset in stride(from: 0, to: frame.payload.count, by: 16) {
      let rawLocation = SearchWireBinary.decodeUInt64(frame.payload, at: offset)
      let rawLength = SearchWireBinary.decodeUInt64(frame.payload, at: offset + 8)
      guard
        rawLocation <= UInt64(searchWireGlobalMaximumUTF16),
        rawLength <= UInt64(searchWireGlobalMaximumUTF16),
        rawLength <= UInt64(searchWireGlobalMaximumUTF16) - rawLocation
      else {
        throw ResponseReaderFailure(.invalidRange)
      }
      let range = NSRange(location: Int(rawLocation), length: Int(rawLength))
      do {
        try context.boundaries.validate(range, within: context.request.scope)
      } catch let error as SearchWireError {
        throw ResponseReaderFailure(error)
      }
      guard searchWireRangeFollows(range, previous: context.lastRange) else {
        throw ResponseReaderFailure(.invalidRange)
      }
      context.lastRange = range
      decoded.append(range)
    }

    context.receivedRanges += decoded.count
    try sink.appendRanges(decoded)
    guard state == .inCall else {
      throw ResponseReaderFailure(.poisoned)
    }
  }

  private func acceptReplacement(
    _ frame: SearchWireFrame,
    context: ResponseContext,
    sink: SearchWireResponseSink
  ) throws {
    guard let response = context.response, let decoder = context.replacementDecoder,
      response.replacementUTF16 != nil
    else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    guard context.receivedRanges == response.matchCount else {
      throw ResponseReaderFailure(.invalidPhase)
    }
    context.replacementStarted = true
    do {
      try decoder.consume(frame.payload) { bytes in
        try sink.appendReplacementUTF8(bytes)
      }
    } catch let error as SearchWireError {
      if state == .failed {
        throw ResponseReaderFailure(.poisoned)
      }
      throw ResponseReaderFailure(error)
    }
    guard state == .inCall else {
      throw ResponseReaderFailure(.poisoned)
    }
  }

  private func acceptTerminal(
    _ frame: SearchWireFrame,
    context: ResponseContext
  ) throws {
    guard frame.payload.count == 16 else {
      throw ResponseReaderFailure(.invalidMetadata)
    }
    let ordinal = SearchWireBinary.decodeUInt64(frame.payload, at: 0)
    guard ordinal == context.request.identity.ordinal else {
      throw ResponseReaderFailure(.ordinalMismatch)
    }
    let status = SearchWireBinary.decodeUInt16(frame.payload, at: 8)
    guard frame.payload[10..<16].allSatisfy({ $0 == 0 }) else {
      throw ResponseReaderFailure(.invalidMetadata)
    }
    let terminal = try decodeTerminal(status)

    if terminal == .success {
      guard let response = context.response,
        context.receivedRanges == response.matchCount
      else {
        throw ResponseReaderFailure(.lengthMismatch)
      }
      if let decoder = context.replacementDecoder {
        do {
          try decoder.finish()
        } catch let error as SearchWireError {
          throw ResponseReaderFailure(error)
        }
      }
    }

    let identity = context.request.identity
    phase = .ready(expectedOrdinal: searchWireSuccessor(after: identity.ordinal))
    pendingCompletion = PendingCompletion(identity: identity, terminal: terminal)
  }

  private func decodeTerminal(_ status: UInt16) throws -> SearchWireTerminal {
    switch status {
    case 0: return .success
    case 1: return .failure(.invalidScope)
    case 2: return .failure(.invalidEscape)
    case 3: return .failure(.invalidPattern)
    case 4: return .failure(.invalidReplacement)
    case 5: return .failure(.textLimit)
    case 6: return .failure(.matchLimit)
    case 7: return .failure(.outputLimit)
    case 8: return .failure(.cancelled)
    case 9: return .failure(.timedOut)
    case 10: return .failure(.engineFailure)
    default: throw ResponseReaderFailure(.invalidMetadata)
    }
  }
}

private final class ResponseContext {
  let request: SearchWireRequest
  let boundaries: SearchWireBoundaryIndex
  var response: SearchWireResponse?
  var replacementDecoder: SearchWireUTF16Decoder?
  var receivedRanges = 0
  var lastRange: NSRange?
  var replacementStarted = false

  init(request: SearchWireRequest, boundaries: SearchWireBoundaryIndex) throws {
    self.request = request
    self.boundaries = boundaries
  }

  func begin(_ response: SearchWireResponse) throws {
    self.response = response
    if let replacementUTF16 = response.replacementUTF16 {
      replacementDecoder = try SearchWireUTF16Decoder(expectedUTF16: replacementUTF16)
    }
  }
}

private struct ResponseReaderFailure: Error {
  let error: SearchWireError

  init(_ error: SearchWireError) {
    self.error = error
  }
}

private func searchWireRangeFollows(_ range: NSRange, previous: NSRange?) -> Bool {
  guard let previous else { return true }
  let previousEnd = previous.location + previous.length
  guard range.location >= previousEnd else { return false }
  return previous.length != 0 || range.location > previous.location
}

extension SearchWireWriter {
  public static func responseBody(
    _ response: SearchWireResponse,
    output: SearchExecutionOutput,
    emit: (Data) throws -> Void
  ) throws {
    try validateResponseBody(response, output: output)

    var metadata = Data()
    metadata.reserveCapacity(32)
    SearchWireBinary.append(response.identity.ordinal, to: &metadata)
    SearchWireBinary.append(UInt32(response.matchCount), to: &metadata)
    SearchWireBinary.append(0 as UInt32, to: &metadata)
    SearchWireBinary.append(UInt64(response.replacementUTF16 ?? 0), to: &metadata)
    metadata.append(response.replacementUTF16 == nil ? 0 : 1)
    metadata.append(contentsOf: repeatElement(UInt8(0), count: 7))
    try SearchWireBinary.writeFrame(
      kind: .responseStart,
      requestID: response.identity.requestID,
      payload: metadata,
      emit: emit)

    var rangeOffset = 0
    while rangeOffset < output.matches.count {
      let end = min(rangeOffset + 4_096, output.matches.count)
      var payload = Data()
      payload.reserveCapacity((end - rangeOffset) * 16)
      for range in output.matches[rangeOffset..<end] {
        SearchWireBinary.append(UInt64(range.location), to: &payload)
        SearchWireBinary.append(UInt64(range.length), to: &payload)
      }
      try SearchWireBinary.writeFrame(
        kind: .rangeChunk,
        requestID: response.identity.requestID,
        payload: payload,
        emit: emit)
      rangeOffset = end
    }

    if let replacement = output.replacement, let expectedUTF16 = response.replacementUTF16 {
      let encoder = try SearchWireUTF16Encoder(text: replacement, expectedUTF16: expectedUTF16)
      while let chunk = try encoder.nextChunk() {
        try SearchWireBinary.writeFrame(
          kind: .replacementChunk,
          requestID: response.identity.requestID,
          payload: chunk,
          emit: emit)
      }
    }
  }

  public static func terminal(
    _ identity: SearchWireIdentity,
    result: SearchWireTerminal,
    emit: (Data) throws -> Void
  ) throws {
    var payload = Data()
    payload.reserveCapacity(16)
    SearchWireBinary.append(identity.ordinal, to: &payload)
    SearchWireBinary.append(terminalStatus(result), to: &payload)
    payload.append(contentsOf: repeatElement(UInt8(0), count: 6))
    try SearchWireBinary.writeFrame(
      kind: .terminal,
      requestID: identity.requestID,
      payload: payload,
      emit: emit)
  }

  private static func validateResponseBody(
    _ response: SearchWireResponse,
    output: SearchExecutionOutput
  ) throws {
    guard output.matches.count == response.matchCount else {
      throw SearchWireError.lengthMismatch
    }
    switch (response.replacementUTF16, output.replacement) {
    case (nil, nil):
      break
    case (.some(let expectedUTF16), .some(let replacement)):
      guard replacement.utf16.count == expectedUTF16 else {
        throw SearchWireError.lengthMismatch
      }
    default:
      throw SearchWireError.invalidMetadata
    }

    var previous: NSRange?
    for range in output.matches {
      guard
        range.location >= 0,
        range.length >= 0,
        range.location <= searchWireGlobalMaximumUTF16,
        range.length <= searchWireGlobalMaximumUTF16 - range.location,
        searchWireRangeFollows(range, previous: previous)
      else {
        throw SearchWireError.invalidRange
      }
      previous = range
    }
  }

  private static func terminalStatus(_ terminal: SearchWireTerminal) -> UInt16 {
    switch terminal {
    case .success: return 0
    case .failure(.invalidScope): return 1
    case .failure(.invalidEscape): return 2
    case .failure(.invalidPattern): return 3
    case .failure(.invalidReplacement): return 4
    case .failure(.textLimit): return 5
    case .failure(.matchLimit): return 6
    case .failure(.outputLimit): return 7
    case .failure(.cancelled): return 8
    case .failure(.timedOut): return 9
    case .failure(.engineFailure): return 10
    }
  }
}
