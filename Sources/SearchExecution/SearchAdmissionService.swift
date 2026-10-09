import Foundation
import PadCore

@MainActor package final class SearchAdmissionService<Context> {
  private let controller: SearchAdmissionController<Context>

  package convenience init(applicationBundle: URL) throws {
    let parent = try SearchParentWireDriver(applicationBundle: applicationBundle)
    let accounting = SearchAdmissionProductionAccounting()
    let retry = SearchAdmissionDispatchRetryScheduler()
    let controller = try SearchAdmissionController<Context>(
      driver: parent, accounting: accounting, retry: retry)
    self.init(controller: controller)
  }

  init(controller: SearchAdmissionController<Context>) {
    self.controller = controller
  }

  package func register() -> SearchConsumerID { controller.register() }

  package func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID {
    try controller.submit(
      consumer: consumer, descriptor: descriptor, capture: capture, completion: completion)
  }

  package func cancel(_ id: SearchJobID) { controller.cancel(id) }

  package func unregister(_ consumer: SearchConsumerID) { controller.unregister(consumer) }

  package func release(_ id: SearchResultLeaseID) { controller.release(id) }

  package func withResult(
    _ id: SearchResultLeaseID, _ body: (Context, String, SearchExecutionOutput) -> Void
  ) -> Bool {
    controller.withResult(id, body)
  }

  package func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
    await controller.shutdownJoined()
  }
}
