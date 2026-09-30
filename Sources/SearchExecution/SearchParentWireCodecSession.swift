import Foundation
import PadCore

/// Transportable owner handle. All mutable state and callbacks stay on its
/// creating codec thread; @unchecked does not authorize concurrent codec use.
final class SearchParentWireCodecSession: @unchecked Sendable, SearchWireResponseSink {
  private enum Phase {
    case parentHello, childHello
    case ready(UInt64?)
    case uploaded, expecting, finished
  }
  private let owner: Thread
  private let generation: UUID
  private let sessionEpoch: UInt64
  private let factory: SearchParentWireResponseAccumulatorFactory
  private var reader: SearchWireResponseReader?
  private var phase = Phase.parentHello
  private var inCall = false
  private var poisoned = false
  private var writerEpoch: UInt64 = 0
  private var request: SearchWireRequest?
  private var boundaries: SearchWireBoundaryIndex?
  private var accumulator: (any SearchParentWireResponseAccumulator)?
  private var advertised: SearchWireResponse?
  private var provisionalHello: UUID?
  private var provisionalTerminal: SearchWireTerminal?

  init(token: SearchParentCodecToken, factory: @escaping SearchParentWireResponseAccumulatorFactory)
    throws
  {
    owner = Thread.current
    generation = token.generation
    sessionEpoch = token.sessionEpoch
    self.factory = factory
    reader = try SearchWireResponseReader(generation: token.generation)
  }

  func writeHello(token: SearchParentCodecToken, bridge: SearchParentWireUploadBridge) throws {
    try perform(token) {
      guard case .parentHello = phase else { throw SearchParentCodecSessionError.invalidPhase }
      try admit(bridge, requestID: nil)
      try SearchWireWriter.hello(generation: generation, fromChild: false, emit: bridge.emit)
      try healthy()
      phase = .childHello
    }
  }

  func writeRequest(
    token: SearchParentCodecToken, request: SearchWireRequest, text: String,
    bridge: SearchParentWireUploadBridge
  ) throws -> SearchParentRequestEncoded {
    try perform(token) {
      guard case .ready(let next) = phase else { throw SearchParentCodecSessionError.invalidPhase }
      guard request.identity.generation == generation else {
        throw SearchWireError.identityMismatch
      }
      guard let next, next == request.identity.ordinal else {
        throw SearchWireError.ordinalMismatch
      }
      try admit(bridge, requestID: request.identity.requestID)
      self.request = request
      // Factory may fail or reenter: no request byte escapes until it returns.
      accumulator = try factory(request)
      try healthy()
      let index = try SearchWireWriter.request(request, text: text, emit: bridge.emit)
      try healthy()
      boundaries = index
      phase = .uploaded
      return SearchParentRequestEncoded(identity: request.identity, inputUTF16: request.inputUTF16)
    }
  }

  func expect(token: SearchParentCodecToken, identity: SearchWireIdentity) throws {
    try perform(token) {
      guard case .uploaded = phase, let request, let boundaries, accumulator != nil else {
        throw SearchParentCodecSessionError.invalidPhase
      }
      guard request.identity == identity else { throw SearchWireError.identityMismatch }
      guard let reader else { throw SearchParentCodecSessionError.poisoned }
      try reader.expect(request, boundaries: boundaries)
      self.boundaries = nil  // reader owns the same exact completed validation index
      phase = .expecting
    }
  }

  func consume(token: SearchParentCodecToken, bytes: Data) throws -> SearchParentCodecProgress {
    try perform(token) {
      switch phase {
      case .childHello, .expecting, .ready: break
      default: throw SearchParentCodecSessionError.invalidPhase
      }
      provisionalHello = nil
      provisionalTerminal = nil
      guard let reader else { throw SearchParentCodecSessionError.poisoned }
      try bytes.withUnsafeBytes { try reader.consume($0, sink: self) }
      try healthy()
      if let hello = provisionalHello {
        provisionalHello = nil
        phase = .ready(1)
        return .hello(hello)
      }
      guard let terminal = provisionalTerminal else { return .needMore }
      guard let request, let accumulator else {
        throw SearchParentCodecSessionError.accumulatorFailure
      }
      // Deliberately outside ResponseReader.consume and every sink callback.
      let taken = try accumulator.takeTerminal(for: request.identity)
      try healthy()
      guard taken.terminal == terminal else {
        throw SearchParentCodecSessionError.accumulatorFailure
      }
      try validate(taken.output, terminal: terminal, request: request)
      let result = SearchParentProvisionalTerminal(
        identity: request.identity, terminal: terminal, output: taken.output)
      clearAccumulator()
      try healthy()  // discard callback may catch a recursive-entry error
      let next = request.identity.ordinal == UInt64.max ? nil : request.identity.ordinal + 1
      clearMetadata()
      phase = .ready(next)
      return .terminal(result)
    }
  }

  /// Retires this owner; cannot reset a failed reader into a healthy generation.
  func discard(token: SearchParentCodecToken) throws {
    try checkOwner(token)
    guard !inCall else {
      poisoned = true
      throw SearchParentCodecSessionError.reentrantUse
    }
    inCall = true
    defer { inCall = false }
    let wasPoisoned = poisoned
    clearAccumulator()
    clearMetadata()
    reader = nil
    phase = .finished
    if poisoned && !wasPoisoned { throw SearchParentCodecSessionError.poisoned }
  }

  private func perform<T>(_ token: SearchParentCodecToken, _ body: () throws -> T) throws -> T {
    try checkOwner(token)
    guard !inCall else {
      poisoned = true
      throw SearchParentCodecSessionError.reentrantUse
    }
    try healthy()
    inCall = true
    defer { inCall = false }
    do {
      let result = try body()
      try healthy()
      return result
    } catch {
      poisoned = true
      reader = nil
      clearAccumulator()
      clearMetadata()
      if let error = error as? SearchParentCodecSessionError { throw error }
      if let error = error as? SearchWireError { throw SearchParentCodecSessionError.wire(error) }
      if let error = error as? SearchParentWireFailure { throw error }
      throw SearchParentCodecSessionError.accumulatorFailure
    }
  }

  private func checkOwner(_ token: SearchParentCodecToken) throws {
    guard Thread.current === owner else { throw SearchParentCodecSessionError.wrongLane }
    guard token.generation == generation, token.sessionEpoch == sessionEpoch else {
      throw SearchParentCodecSessionError.staleSession
    }
  }
  private func healthy() throws {
    guard !poisoned else { throw SearchParentCodecSessionError.poisoned }
  }
  private func admit(_ bridge: SearchParentWireUploadBridge, requestID: UUID?) throws {
    let identity = bridge.writerIdentity
    guard identity.generation == generation, identity.requestID == requestID,
      identity.writerEpoch > writerEpoch
    else { throw SearchParentCodecSessionError.invalidBridge }
    writerEpoch = identity.writerEpoch
  }
  private func clearAccumulator() {
    // Detach first. A reentrant discard can never invoke it a second time.
    let old = accumulator
    accumulator = nil
    old?.discard()
  }
  private func clearMetadata() {
    request = nil
    boundaries = nil
    advertised = nil
    provisionalHello = nil
    provisionalTerminal = nil
  }
  private func validate(
    _ output: SearchExecutionOutput?, terminal: SearchWireTerminal, request: SearchWireRequest
  ) throws {
    switch terminal {
    case .failure:
      guard output == nil else { throw SearchParentCodecSessionError.accumulatorFailure }
    case .success:
      guard let output, let advertised, advertised.identity == request.identity,
        output.matches.count == advertised.matchCount
      else { throw SearchParentCodecSessionError.accumulatorFailure }
      switch request.operation {
      case .find:
        guard output.replacement == nil, advertised.replacementUTF16 == nil else {
          throw SearchParentCodecSessionError.accumulatorFailure
        }
      case .replace:
        guard let replacement = output.replacement, let length = advertised.replacementUTF16,
          replacement.utf16.count == length
        else { throw SearchParentCodecSessionError.accumulatorFailure }
      }
    }
  }
  private func callback() throws {
    guard Thread.current === owner else { throw SearchParentCodecSessionError.wrongLane }
    guard inCall else { throw SearchParentCodecSessionError.invalidPhase }
    try healthy()
  }
  func helloAccepted(generation: UUID) throws {
    try callback()
    guard case .childHello = phase, generation == self.generation, provisionalHello == nil else {
      throw SearchParentCodecSessionError.invalidPhase
    }
    provisionalHello = generation
  }
  func begin(_ response: SearchWireResponse) throws {
    try callback()
    guard case .expecting = phase, let accumulator, response.identity == request?.identity else {
      throw SearchParentCodecSessionError.invalidPhase
    }
    advertised = response
    try accumulator.begin(response)
    try healthy()
  }
  func appendRanges(_ ranges: [NSRange]) throws {
    try callback()
    guard let accumulator else { throw SearchParentCodecSessionError.accumulatorFailure }
    try accumulator.appendRanges(ranges)
    try healthy()
  }
  func appendReplacementUTF8(_ bytes: Data) throws {
    try callback()
    guard let accumulator else { throw SearchParentCodecSessionError.accumulatorFailure }
    try accumulator.appendReplacementUTF8(bytes)
    try healthy()
  }
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    try callback()
    guard let accumulator, identity == request?.identity, provisionalTerminal == nil else {
      throw SearchParentCodecSessionError.accumulatorFailure
    }
    try accumulator.complete(identity, terminal: terminal)
    try healthy()
    provisionalTerminal = terminal
  }
}
