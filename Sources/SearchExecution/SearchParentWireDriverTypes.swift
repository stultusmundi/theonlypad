import Foundation
import PadCore

package protocol SearchParentWireResponseAccumulator: SearchWireResponseSink, AnyObject, Sendable {
  func takeTerminal(for identity: SearchWireIdentity) throws -> (
    terminal: SearchWireTerminal, output: SearchExecutionOutput?
  )
  func discard()
}
package typealias SearchParentWireResponseAccumulatorFactory =
  @Sendable (SearchWireRequest) throws -> any SearchParentWireResponseAccumulator

struct SearchParentRequestEncoded: Equatable, Sendable {
  let identity: SearchWireIdentity
  let inputUTF16: Int
}
struct SearchParentProvisionalTerminal: Equatable, Sendable {
  let identity: SearchWireIdentity
  let terminal: SearchWireTerminal
  let output: SearchExecutionOutput?
}
enum SearchParentCodecProgress: Equatable, Sendable {
  case needMore
  case hello(UUID)
  case terminal(SearchParentProvisionalTerminal)
}
enum SearchParentCodecSessionError: Error, Equatable, Sendable {
  case wrongLane, staleSession, invalidPhase, invalidBridge, poisoned, reentrantUse
  case wire(SearchWireError)
  case accumulatorFailure
}
