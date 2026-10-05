import Foundation
import PadCore

package struct SearchConsumerID: Hashable, Sendable {
  private let id: UUID
  init() { id = UUID() }
}

package struct SearchJobID: Hashable, Sendable {
  private let id: UUID
  init() { id = UUID() }
}

package struct SearchResultLeaseID: Hashable, Sendable {
  private let id: UUID
  init() { id = UUID() }
}

package struct SearchAdmissionDescriptor: Sendable {
  package let query: SearchQuery
  package let operation: SearchExecutionOperation
  package let estimatedInputUTF16: Int
  package let scope: NSRange?
  package let limits: SearchWireLimits

  package init(
    query: SearchQuery, operation: SearchExecutionOperation, estimatedInputUTF16: Int,
    scope: NSRange?, limits: SearchWireLimits
  ) throws {
    guard estimatedInputUTF16 >= 0, estimatedInputUTF16 <= limits.maxTextUTF16,
      query.pattern.utf16.prefix(searchWireMaximumRequestBlobUTF16 + 1).count
        <= searchWireMaximumRequestBlobUTF16
    else { throw SearchAdmissionFailure.invalidDescriptor }
    if case .replace(let template) = operation,
      template.utf16.prefix(searchWireMaximumRequestBlobUTF16 + 1).count
        > searchWireMaximumRequestBlobUTF16
    {
      throw SearchAdmissionFailure.invalidDescriptor
    }
    if let scope {
      guard scope.location >= 0, scope.length >= 0,
        scope.location <= estimatedInputUTF16,
        scope.length <= estimatedInputUTF16 - scope.location
      else { throw SearchAdmissionFailure.invalidDescriptor }
    }
    self.query = query
    self.operation = operation
    self.estimatedInputUTF16 = estimatedInputUTF16
    self.scope = scope
    self.limits = limits
  }
}

package struct SearchAdmissionCapture<Context> {
  package let text: String
  package let inputUTF16: Int
  package let context: Context

  package init(text: String, inputUTF16: Int, context: Context) {
    self.text = text
    self.inputUTF16 = inputUTF16
    self.context = context
  }
}

package enum SearchAdmissionDelivery: Sendable, Equatable {
  case completed(SearchResultLeaseID)
  case failed(SearchAdmissionFailure)
}

package enum SearchAdmissionFailure: Error, Sendable, Equatable {
  case queueFull, consumerBusy, unknownConsumer, invalidDescriptor, resultBudget
  case captureRefused, sourceChanged, cancelled, shutdown, internalFailure
  case driver(SearchParentWireDriverError)
  case child(SearchChildFailure)
  case semantic(SearchError)
}

package struct SearchAdmissionCharge: Sendable, Equatable {
  package let active: UInt64
  package let retained: UInt64

  package init(active: UInt64, retained: UInt64) {
    self.active = active
    self.retained = retained
  }
}

package protocol SearchAdmissionAccounting {
  var activeLimit: UInt64 { get }
  var retainedLimit: UInt64 { get }
  var resident: UInt64 { get }
  func charge(for descriptor: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge
}

@MainActor package protocol SearchAdmissionRetryScheduler {
  func schedule(_ action: @escaping @MainActor () -> Void) -> any SearchAdmissionRetryToken
}

@MainActor package protocol SearchAdmissionRetryToken {
  func cancel()
}

package struct SearchAdmissionShutdown: Sendable, Equatable {
  package let driver: SearchParentWireShutdown
  package let retainedActiveJobs: Int
  package let retainedLeases: Int
}
