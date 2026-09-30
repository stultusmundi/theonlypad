import Foundation
import PadCore
import SearchExecution

/// Each admitted request supplies every semantic limit. Hard cancellation remains
/// parent-owned; the service's time limit is cooperative.
package struct FoundationSearchWorkerEngine: SearchWorkerEngine {
  package init() {}

  package func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput {
    let limits = request.limits
    let service = SearchService(
      maxTextUTF16: limits.maxTextUTF16,
      maxMatches: limits.maxMatches,
      maxOutputUTF16: limits.maxOutputUTF16,
      timeLimit: TimeInterval(limits.cooperativeMilliseconds) / 1_000)
    return try service.execute(
      request.query, in: text, scope: request.scope, operation: request.operation)
  }
}
