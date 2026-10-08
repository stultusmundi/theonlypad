import Foundation
import PadCore

package enum SearchParentResponseAccumulatorError: Error, Equatable {
  case wrongLane, invalidPhase, identityMismatch, invalidMetadata
  case invalidRange, lengthMismatch, invalidChunk, poisoned
}

/// Codec-thread confined. Sendability transports the handle, not concurrent use.
package final class SearchParentResponseAccumulator: SearchParentWireResponseAccumulator,
  @unchecked Sendable
{
  private enum Phase {
    case awaitingBegin, receiving, terminal, taken, discarded, failed
  }
  private let owner = Thread.current
  private let identity: SearchWireIdentity
  private let inputUTF16: Int
  private let scope: NSRange?
  private let replacing: Bool
  private let maximumMatches: Int
  private let maximumOutputUTF16: Int
  private var phase = Phase.awaitingBegin
  private var advertised: SearchWireResponse?
  private var ranges: [NSRange] = []
  private var replacement = Data()
  private var receivedUTF16 = 0
  private var replacementStarted = false
  private var terminal: SearchWireTerminal?

  package init(request: SearchWireRequest) {
    identity = request.identity
    inputUTF16 = request.inputUTF16
    scope = request.scope
    if case .replace = request.operation {
      replacing = true
    } else {
      replacing = false
    }
    maximumMatches = request.limits.maxMatches
    maximumOutputUTF16 = request.limits.maxOutputUTF16
  }

  package func helloAccepted(generation: UUID) throws {
    try checkOwner()
    // The session consumes hello before this request-bound sink exists.
    throw fail(.invalidPhase)
  }

  package func begin(_ response: SearchWireResponse) throws {
    try checkOwner()
    guard phase == .awaitingBegin else { throw fail(.invalidPhase) }
    guard response.identity == identity else { throw fail(.identityMismatch) }
    guard response.matchCount <= maximumMatches else { throw fail(.invalidMetadata) }
    if replacing {
      guard let length = response.replacementUTF16, length <= maximumOutputUTF16 else {
        throw fail(.invalidMetadata)
      }
    } else {
      guard response.replacementUTF16 == nil else { throw fail(.invalidMetadata) }
    }
    advertised = response
    phase = .receiving
  }

  package func appendRanges(_ values: [NSRange]) throws {
    try checkOwner()
    guard phase == .receiving, !replacementStarted, let advertised else {
      throw fail(.invalidPhase)
    }
    guard values.count <= advertised.matchCount - ranges.count else {
      throw fail(.lengthMismatch)
    }
    var previous = ranges.last
    for range in values {
      guard range.location >= 0, range.length >= 0, range.location <= inputUTF16,
        range.length <= inputUTF16 - range.location
      else { throw fail(.invalidRange) }
      if let scope {
        // Request validation already bounds this endpoint within inputUTF16.
        let end = scope.location + scope.length
        guard range.location >= scope.location, range.location <= end,
          range.length <= end - range.location
        else { throw fail(.invalidRange) }
      }
      if let previous {
        // Previous ranges passed the subtractive input guard above.
        guard range.location >= previous.location + previous.length,
          previous.length != 0 || range.location > previous.location
        else { throw fail(.invalidRange) }
      }
      previous = range
    }
    // No element escapes validation, even when a later element is invalid.
    ranges.append(contentsOf: values)
  }

  package func appendReplacementUTF8(_ bytes: Data) throws {
    try checkOwner()
    guard phase == .receiving, replacing, let advertised,
      ranges.count == advertised.matchCount, let declared = advertised.replacementUTF16
    else { throw fail(.invalidPhase) }
    guard bytes.count <= 65_536 else { throw fail(.invalidChunk) }
    let units = try countUTF16(bytes)
    guard units <= declared - receivedUTF16,
      bytes.count <= declared * 3 - replacement.count
    else { throw fail(.lengthMismatch) }
    replacementStarted = true  // Empty append still closes range collection.
    replacement.append(bytes)
    receivedUTF16 += units
  }

  package func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws {
    try checkOwner()
    switch terminal {
    case .success:
      guard phase == .receiving else { throw fail(.invalidPhase) }
    case .failure:
      guard phase == .awaitingBegin || phase == .receiving else { throw fail(.invalidPhase) }
    }
    guard identity == self.identity else { throw fail(.identityMismatch) }
    switch terminal {
    case .success:
      guard let advertised, ranges.count == advertised.matchCount,
        !replacing || receivedUTF16 == advertised.replacementUTF16
      else { throw fail(.lengthMismatch) }
    case .failure:
      // Failure needs neither responseStart nor a complete partial body.
      clearPayload()
    }
    self.terminal = terminal
    phase = .terminal
  }

  package func takeTerminal(for identity: SearchWireIdentity) throws -> (
    terminal: SearchWireTerminal, output: SearchExecutionOutput?
  ) {
    try checkOwner()
    guard phase == .terminal, let terminal else { throw fail(.invalidPhase) }
    guard identity == self.identity else { throw fail(.identityMismatch) }
    let output: SearchExecutionOutput?
    switch terminal {
    case .failure:
      output = nil
    case .success:
      let text: String?
      if replacing {
        // Whole-result validation deliberately has no per-append chunk limit.
        let units = try countUTF16(replacement)
        guard units == advertised?.replacementUTF16 else { throw fail(.lengthMismatch) }
        text = String(decoding: replacement, as: UTF8.self)
      } else {
        text = nil
      }
      output = SearchExecutionOutput(matches: ranges, replacement: text)
    }
    clearPayload()
    phase = .taken
    return (terminal, output)
  }

  package func discard() {
    precondition(Thread.current === owner, "Response accumulator discard requires its codec thread")
    clearPayload()
    if phase != .failed { phase = .discarded }
  }

  private func checkOwner() throws {
    guard Thread.current === owner else { throw SearchParentResponseAccumulatorError.wrongLane }
    guard phase != .failed else { throw SearchParentResponseAccumulatorError.poisoned }
  }

  private func countUTF16(_ bytes: Data) throws -> Int {
    var units = 0
    let invalid = transcode(
      bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true,
      into: { _ in units += 1 })
    guard !invalid else { throw fail(.invalidChunk) }
    return units
  }

  private func clearPayload() {
    advertised = nil
    ranges = []
    replacement = Data()
    receivedUTF16 = 0
    replacementStarted = false
    terminal = nil
  }

  private func fail(_ error: SearchParentResponseAccumulatorError)
    -> SearchParentResponseAccumulatorError
  {
    clearPayload()
    phase = .failed
    return error
  }
}
