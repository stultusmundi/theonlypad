// Frozen same-file read-only access. No field writes or alternate authority.
struct LanguageManagerApplicationTestFacts {
  let controller: NativeLanguageManagerController?
  let session: NativeLanguageManagerSession?
  let deliveryID: UUID?
}
extension AppDelegate {
  var languageManagerTestFacts: LanguageManagerApplicationTestFacts {
    .init(
      controller: languageManagerController, session: languageManagerSession,
      deliveryID: languageManagerDeliveryID)
  }
  func languageManagerTestMake() -> NativeLanguageManagerController? { makeLanguageManager() }
}
