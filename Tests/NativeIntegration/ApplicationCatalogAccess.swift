// Frozen same-file Test access. Actual stored state/task and real startup forward only.
struct ApplicationCatalogTestFacts {
  let owner: NativeLanguageCatalogOwner?
  let state: NativeLanguageCatalogState?
  let lastReportedFailureID: UUID?
  let attemptID: UUID?
  let hasCatalogPreparation: Bool
  let preparationIsNotCreated: Bool
  let reservedOwner: NativeLanguageCatalogOwner?
  let quitID: UUID?
}
struct ApplicationCatalogAttemptTestHandle {
  let id: UUID
  let join: @MainActor () async -> AppSearchAttemptTestFacts
  let cancel: @MainActor () -> Void
}
extension AppDelegate {
  var applicationCatalogTestFacts: ApplicationCatalogTestFacts {
    let attempt = documentSearchTerminationAttempt
    let absent: Bool
    let owner: NativeLanguageCatalogOwner?
    let id: UUID?
    switch attempt?.catalogPreparation {
    case .notCreated?:
      absent = true
      owner = nil
      id = nil
    case .reserved(let actual, let actualID)?:
      absent = false
      owner = actual
      id = actualID
    case nil:
      absent = false
      owner = nil
      id = nil
    }
    return .init(
      owner: languageCatalogOwner, state: languageCatalogState,
      lastReportedFailureID: lastReportedLanguageCatalogFailureID,
      attemptID: attempt?.id, hasCatalogPreparation: attempt?.catalogPreparation != nil,
      preparationIsNotCreated: absent, reservedOwner: owner, quitID: id)
  }
  @discardableResult
  func applicationCatalogTestStart() -> NativeLanguageCatalogAdmission? {
    startLanguageCatalogIfNeeded()
  }
  func applicationCatalogTestCaptureAttempt() -> ApplicationCatalogAttemptTestHandle? {
    guard let original = documentSearchTerminationAttempt, let task = original.task else {
      return nil
    }
    return .init(
      id: original.id,
      join: {
        await task.value
        return .init(
          id: original.id, hasPreparation: original.preparation != nil,
          nativeReceipt: original.nativeReceipt, decision: original.searchDecision,
          hasTask: original.task != nil, replyConsumed: original.replyConsumed)
      }, cancel: { task.cancel() })
  }
}
