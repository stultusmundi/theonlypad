import Foundation

package enum SearchWorkerTextAccumulatorError: Error, Equatable {
  case invalidDeclaredLength, invalidChunk, inputExceeded, lengthMismatch, invalidState
}

package final class SearchWorkerUTF8Accumulator: SearchWorkerTextAccumulator {
  private enum State: Equatable {
    case receiving, finished, failed
  }
  private let declaredUTF16: Int
  private let byteLimit: Int
  private var receivedUTF16 = 0
  private var storage = Data()
  private var state = State.receiving

  package init(declaredUTF16: Int) throws {
    guard (0...100_000_000).contains(declaredUTF16) else {
      throw SearchWorkerTextAccumulatorError.invalidDeclaredLength
    }
    self.declaredUTF16 = declaredUTF16
    byteLimit = declaredUTF16 * 3
  }

  package func appendUTF8(_ bytes: Data) throws {
    guard state == .receiving else { throw fail(.invalidState) }
    guard bytes.count <= 65_536 else { throw fail(.invalidChunk) }
    guard !bytes.isEmpty else { return }
    let units = try countUTF16(bytes)
    guard units <= declaredUTF16 - receivedUTF16,
      bytes.count <= byteLimit - storage.count
    else { throw fail(.inputExceeded) }
    storage.append(bytes)
    receivedUTF16 += units
  }

  package func finish() throws -> String {
    guard state == .receiving else { throw fail(.invalidState) }
    guard receivedUTF16 == declaredUTF16 else { throw fail(.lengthMismatch) }
    guard try countUTF16(storage) == declaredUTF16 else { throw fail(.lengthMismatch) }
    // Materialize only private bytes proven valid above; no repair path is reachable.
    let result = String(decoding: storage, as: UTF8.self)
    storage = Data()
    state = .finished
    return result
  }

  private func countUTF16(_ bytes: Data) throws -> Int {
    var units = 0
    let invalid = transcode(
      bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true,
      into: { _ in units += 1 })
    guard !invalid else { throw fail(.invalidChunk) }
    return units
  }

  private func fail(_ error: SearchWorkerTextAccumulatorError) -> SearchWorkerTextAccumulatorError {
    storage = Data()
    state = .failed
    return error
  }
}
