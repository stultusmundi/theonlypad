import Foundation
import PadCore
import SearchExecution

/// A synchronous, single-use loop. Injected collaborators must remain on this lane.
package final class SearchWorkerRuntime {
  private struct Stop: Error {
    let reason: SearchWorkerRunExit
    init(_ reason: SearchWorkerRunExit) { self.reason = reason }
  }

  private let channel: any SearchWorkerBlockingChannel
  private let engine: any SearchWorkerEngine
  private let reader: SearchWireRequestReader
  private let collector: SearchWorkerRequestCollector
  private var started = false
  private var poisoned = false
  private var outputFailed = false

  package init(
    generation: UUID,
    channel: any SearchWorkerBlockingChannel,
    makeAccumulator: @escaping SearchWorkerAccumulatorFactory,
    engine: any SearchWorkerEngine
  ) throws {
    self.channel = channel
    self.engine = engine
    reader = try SearchWireRequestReader(generation: generation)
    collector = SearchWorkerRequestCollector(makeAccumulator: makeAccumulator)
  }

  package func run() -> SearchWorkerRunExit {
    guard !started else {
      poisoned = true
      return .internalFailure
    }
    started = true
    defer { collector.discard() }
    do {
      return try loop()
    } catch {
      if poisoned { return .internalFailure }
      if outputFailed { return .outputFailure }
      return (error as? Stop)?.reason ?? .internalFailure
    }
  }

  private func loop() throws -> SearchWorkerRunExit {
    while true {
      let bytes: Data
      do {
        bytes = try channel.read(maxBytes: 65_568)
      } catch {
        try requireHealthy()
        throw Stop(.inputFailure)
      }
      try requireHealthy()
      guard bytes.count <= 65_568 else { throw Stop(.inputFailure) }
      if bytes.isEmpty {
        do { try reader.finish() } catch { throw Stop(.protocolFailure) }
        return .cleanEOF
      }
      do {
        try bytes.withUnsafeBytes { try reader.consume($0, sink: collector) }
      } catch {
        try requireHealthy()
        // Reader deliberately normalizes thrown sink errors. Preserve their origin.
        throw Stop(collector.rejected ? .inputSinkFailure : .protocolFailure)
      }
      try requireHealthy()
      if let generation = collector.takeHelloGeneration() {
        try SearchWireWriter.hello(generation: generation, fromChild: true, emit: emit)
      }
      var work = collector.takeSealedRequest()
      guard let identity = work?.request.identity else { continue }
      let terminal = try autoreleasepool {
        // No request owner survives this scope, including on fatal local failures.
        defer { work = nil }
        return try executeAndWriteBody(work!)
      }
      try SearchWireWriter.terminal(identity, result: terminal, emit: emit)
      try reader.acknowledgeTerminal(identity)
    }
  }

  private func executeAndWriteBody(_ work: SearchWorkerPendingRequest) throws -> SearchWireTerminal
  {
    let text: String
    do {
      text = try work.accumulator.finish()
    } catch {
      try requireHealthy()
      throw Stop(.inputSinkFailure)
    }
    try requireHealthy()
    guard text.utf16.count == work.request.inputUTF16 else { throw Stop(.inputSinkFailure) }
    let output: SearchExecutionOutput
    do {
      output = try engine.execute(work.request, text: text)
    } catch let error as SearchError {
      try requireHealthy()
      return .failure(error)
    }
    try requireHealthy()
    guard output.matches.count <= work.request.limits.maxMatches else {
      throw Stop(.internalFailure)
    }
    switch (work.request.operation, output.replacement) {
    case (.find, nil), (.replace, .some): break
    default: throw Stop(.internalFailure)
    }
    let replacementUTF16 = output.replacement?.utf16.count
    if let replacementUTF16, replacementUTF16 > work.request.limits.maxOutputUTF16 {
      throw Stop(.internalFailure)
    }
    let response = try SearchWireResponse(
      identity: work.request.identity, matchCount: output.matches.count,
      replacementUTF16: replacementUTF16)
    try SearchWireWriter.responseBody(response, output: output, emit: emit)
    return .success
  }

  private func emit(_ bytes: Data) throws {
    try requireHealthy()
    do { try channel.write(bytes) } catch {
      // FrameEncoder normalizes callback failures to sinkRejected.
      outputFailed = true
      try requireHealthy()
      throw Stop(.outputFailure)
    }
    try requireHealthy()
  }

  private func requireHealthy() throws {
    guard !poisoned else { throw Stop(.internalFailure) }
  }
}
