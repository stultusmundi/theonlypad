import SearchExecution

@MainActor func forbiddenController(_ service: SearchAdmissionService<String>) {
  _ = service.controller
}
