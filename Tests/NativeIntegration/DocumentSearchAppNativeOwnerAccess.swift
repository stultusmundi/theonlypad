// FROZEN Task3 access: status observation after a real command; effectful true join.
extension NativeApplicationDocuments {
  var managedSearchTestCloseStatus: DocumentClosingStatus? { closing.status }
  func managedSearchTestWaitClose(_ id: DocumentClosingID) async throws
    -> (result: DocumentClosingResult, status: DocumentClosingStatus?)
  {
    let result = try await closing.wait(for: id)
    try closing.requireSettled()
    return (result, closing.status)
  }
}
