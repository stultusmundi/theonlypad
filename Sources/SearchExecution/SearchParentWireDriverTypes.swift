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

package struct SearchParentWireJob: Sendable {
  package let requestID: UUID
  package let query: SearchQuery
  package let operation: SearchExecutionOperation
  package let text: String
  package let inputUTF16: Int
  package let scope: NSRange?
  package let limits: SearchWireLimits

  package init(
    requestID: UUID, query: SearchQuery, operation: SearchExecutionOperation,
    text: String, inputUTF16: Int, scope: NSRange?, limits: SearchWireLimits
  ) throws {
    guard requestID != SearchWireBinary.zeroUUID,
      inputUTF16 >= 0, inputUTF16 <= limits.maxTextUTF16,
      query.pattern.utf16.prefix(searchWireMaximumRequestBlobUTF16 + 1).count
        <= searchWireMaximumRequestBlobUTF16
    else { throw SearchParentWireDriverError.invalidJob }
    if case .replace(let template) = operation,
      template.utf16.prefix(searchWireMaximumRequestBlobUTF16 + 1).count
        > searchWireMaximumRequestBlobUTF16
    {
      throw SearchParentWireDriverError.invalidJob
    }
    if let scope {
      guard scope.location >= 0, scope.length >= 0, scope.location <= inputUTF16,
        scope.length <= inputUTF16 - scope.location
      else { throw SearchParentWireDriverError.invalidJob }
    }
    self.requestID = requestID
    self.query = query
    self.operation = operation
    self.text = text
    self.inputUTF16 = inputUTF16
    self.scope = scope
    self.limits = limits
  }
}
package struct SearchParentWireHandle: Sendable, Equatable {
  let nonce: UUID
  let requestID: UUID
}
package enum SearchParentWireOutcome: Sendable, Equatable {
  case completed(identity: SearchWireIdentity, source: String, output: SearchExecutionOutput)
  case semanticFailure(identity: SearchWireIdentity, error: SearchError)
  case failed(identity: SearchWireIdentity?, failure: SearchChildFailure)
}
package enum SearchParentWireDriverError: Error, Sendable, Equatable {
  case busy, observerBusy, staleHandle, notSettled, invalidJob, shutDown
}
package struct SearchParentWireShutdown: Sendable, Equatable {
  package let child: SearchChildShutdown
  package let parentLaneSettled: Bool
  package let retainedParentLanes: Int
}
package protocol SearchParentWireDriving: AnyObject, Sendable {
  func submit(_ job: SearchParentWireJob) async throws -> SearchParentWireHandle
  func wait(for handle: SearchParentWireHandle) async throws -> SearchParentWireOutcome
  func cancel(_ handle: SearchParentWireHandle) async throws
  func discard(_ handle: SearchParentWireHandle) async throws
  func shutdown() async -> SearchParentWireShutdown
}
