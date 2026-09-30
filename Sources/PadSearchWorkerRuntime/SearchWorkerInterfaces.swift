import Foundation
import PadCore
import SearchExecution

package protocol SearchWorkerBlockingChannel: AnyObject {
  func read(maxBytes: Int) throws -> Data
  func write(_ bytes: Data) throws
}
package protocol SearchWorkerTextAccumulator: AnyObject {
  func appendUTF8(_ bytes: Data) throws
  func finish() throws -> String
}
package typealias SearchWorkerAccumulatorFactory = (Int) throws -> any SearchWorkerTextAccumulator
package protocol SearchWorkerEngine {
  func execute(_ request: SearchWireRequest, text: String) throws -> SearchExecutionOutput
}
package struct SearchWorkerPendingRequest {
  package let request: SearchWireRequest
  package let accumulator: any SearchWorkerTextAccumulator
}
package enum SearchWorkerRunExit: Equatable {
  case cleanEOF, protocolFailure, inputSinkFailure, inputFailure, outputFailure, internalFailure
}
