import SearchExecution

@MainActor func forbiddenLegacy(_ service: SearchAdmissionService<String>) async {
  _ = await service.shutdown()
}
