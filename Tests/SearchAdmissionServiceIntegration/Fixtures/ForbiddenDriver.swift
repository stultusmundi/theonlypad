import SearchExecution

@MainActor func forbiddenDriver(_ service: SearchAdmissionService<String>) {
  _ = service.driver
}
