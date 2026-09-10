// Appended only to the frozen SessionRestorationController source for actual callback tests.
extension SessionRestorationController {
  func readForApplicationTesting(_ entry: UnresolvedSessionEntry) async throws
    -> SessionResolvedFile
  {
    try await onRetry(entry)
  }
  func acceptForApplicationTesting(_ entry: UnresolvedSessionEntry, file: SessionResolvedFile)
    async throws
  {
    try await onResolved(entry, file)
  }
}
