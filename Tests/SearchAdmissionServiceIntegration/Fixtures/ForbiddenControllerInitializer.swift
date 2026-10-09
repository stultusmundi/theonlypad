import SearchExecution

@MainActor func forbiddenControllerInit(_ controller: SearchAdmissionController<String>) throws {
  _ = try SearchAdmissionService<String>(controller: controller)
}
