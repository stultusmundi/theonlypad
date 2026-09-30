import Foundation

enum SearchParentWireByteCounterError: Error, Equatable, Sendable {
  case invalidIdentity, invalidLimit, invalidByteCount
}

/// Driver-confined metadata only; callers record each completed stream operation once.
/// A threshold requests healthy retirement after the active request settles, not cancellation.
struct SearchParentWireByteCounter: Sendable {
  private let generation: UUID
  private let sessionEpoch: UInt64
  private let maximumWireBytes: UInt64
  private(set) var totalBytes: UInt64 = 0

  var retirementRequired: Bool { totalBytes >= maximumWireBytes }

  init(generation: UUID, sessionEpoch: UInt64, maximumWireBytes: UInt64) throws {
    guard generation != SearchWireBinary.zeroUUID, sessionEpoch > 0 else {
      throw SearchParentWireByteCounterError.invalidIdentity
    }
    guard maximumWireBytes > 0 else { throw SearchParentWireByteCounterError.invalidLimit }
    self.generation = generation
    self.sessionEpoch = sessionEpoch
    self.maximumWireBytes = maximumWireBytes
  }

  mutating func record(_ byteCount: Int, generation: UUID, sessionEpoch: UInt64) throws {
    guard generation == self.generation, sessionEpoch == self.sessionEpoch else { return }
    guard byteCount >= 0 else { throw SearchParentWireByteCounterError.invalidByteCount }
    let (sum, overflow) = totalBytes.addingReportingOverflow(UInt64(byteCount))
    totalBytes = overflow ? UInt64.max : sum
  }
}
