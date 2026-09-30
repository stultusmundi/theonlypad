import Foundation
import SearchExecution

/// Collects provisional events only. The runtime drains them after consume succeeds.
package final class SearchWorkerRequestCollector: SearchWireRequestSink {
  private enum Phase {
    case awaitingHello, ready, creating
    case receiving(SearchWorkerPendingRequest)
    case sealed(SearchWorkerPendingRequest)
    case failed
  }

  private let makeAccumulator: SearchWorkerAccumulatorFactory
  private var phase = Phase.awaitingHello
  private var hello: UUID?
  private var inCallback = false
  package private(set) var rejected = false

  package init(makeAccumulator: @escaping SearchWorkerAccumulatorFactory) {
    self.makeAccumulator = makeAccumulator
  }

  package func helloAccepted(generation: UUID) throws {
    try callback {
      guard case .awaitingHello = phase else { throw SearchWireError.invalidPhase }
      phase = .ready
      hello = generation
    }
  }

  package func begin(_ request: SearchWireRequest) throws {
    try callback {
      guard case .ready = phase else { throw SearchWireError.invalidPhase }
      phase = .creating
      let accumulator = try makeAccumulator(request.inputUTF16)
      guard !rejected else { throw SearchWireError.poisoned }
      phase = .receiving(SearchWorkerPendingRequest(request: request, accumulator: accumulator))
    }
  }

  package func appendInputUTF8(_ bytes: Data) throws {
    try callback {
      guard case .receiving(let work) = phase, !bytes.isEmpty else {
        throw SearchWireError.invalidPhase
      }
      try work.accumulator.appendUTF8(bytes)
    }
  }

  package func execute(_ identity: SearchWireIdentity) throws {
    try callback {
      guard case .receiving(let work) = phase else { throw SearchWireError.invalidPhase }
      guard work.request.identity == identity else { throw SearchWireError.identityMismatch }
      phase = .sealed(work)
    }
  }

  package func takeHelloGeneration() -> UUID? {
    guard !inCallback, !rejected else {
      discard()
      return nil
    }
    defer { hello = nil }
    return hello
  }

  package func takeSealedRequest() -> SearchWorkerPendingRequest? {
    guard !inCallback, !rejected else {
      discard()
      return nil
    }
    guard case .sealed(let work) = phase else { return nil }
    phase = .ready
    return work
  }

  package func discard() {
    if inCallback { rejected = true }
    hello = nil
    phase = .failed
  }

  private func callback(_ action: () throws -> Void) throws {
    guard !inCallback, !rejected else {
      rejected = true
      phase = .failed
      throw SearchWireError.reentrantUse
    }
    inCallback = true
    defer { inCallback = false }
    do {
      try action()
      guard !rejected else { throw SearchWireError.poisoned }
    } catch {
      rejected = true
      phase = .failed
      hello = nil
      throw error
    }
  }
}
