import Foundation
import PadCore

enum NativeHistoryPreparationError: Error { case unavailable, unsupportedSource }
@MainActor enum NativeHistoryPreparation {
  static func prepare(registry: ApplicationDocuments, windowID: UUID) async throws
    -> (claim: DocumentHistoryClaim, seed: NativeDocumentSeed)
  {
    let replacementID = UUID()
    guard let claim = try registry.peekHistory(windowID: windowID, replacementID: replacementID)
    else {
      throw NativeHistoryPreparationError.unavailable
    }
    let value = try registry.withHistorySource(claim) { handle in
      guard let model = handle as? EditorDocument else {
        throw NativeHistoryPreparationError.unsupportedSource
      }
      return (
        text: model.storage.string, url: model.url, bytes: model.originalBytes,
        encoding: model.encoding, bom: model.hasBOM,
        saved: DecodedDocument(
          text: model.savedText, encoding: model.savedEncoding, hasBOM: model.savedHasBOM),
        bookmarks: model.bookmarks, language: model.language, manual: model.manualLanguage
      )
    }
    let pinned = claim.metadata.pinned
    let seed = try await Task.detached {
      try NativeDocumentSeed.reopened(
        id: replacementID, text: value.text, url: value.url, originalBytes: value.bytes,
        encoding: value.encoding, hasBOM: value.bom, saved: value.saved,
        bookmarks: value.bookmarks, language: value.language, manualLanguage: value.manual,
        pinned: pinned)
    }.value
    try registry.validateHistory(claim)
    return (claim, seed)
  }
}
