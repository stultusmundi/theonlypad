import Foundation
import PadCore
import SearchExecution

@MainActor func allowed(bundle: URL, descriptor: SearchAdmissionDescriptor) async throws {
  let service = try SearchAdmissionService<String>(applicationBundle: bundle)
  let consumer = service.register()
  let id = try service.submit(
    consumer: consumer, descriptor: descriptor,
    capture: { SearchAdmissionCapture(text: "x", inputUTF16: 1, context: "synthetic") },
    completion: { delivery in
      if case .completed(let lease) = delivery {
        _ = service.withResult(lease) { _, _, _ in }
        service.release(lease)
      }
    })
  service.cancel(id)
  service.unregister(consumer)
  let result: SearchAdmissionJoinedShutdownResult = await service.shutdownJoined()
  _ = result
}
