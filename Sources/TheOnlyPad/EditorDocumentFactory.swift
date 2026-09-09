import AppKit
import PadCore

/// Builds an unregistered model only. The caller owns capacity, placement and recovery adoption.
@MainActor enum EditorDocumentFactory {
  static func make(_ seed: NativeDocumentSeed) throws -> EditorDocument {
    let document = EditorDocument(id: seed.id)
    if !seed.text.isEmpty { document.storage.mutableString.setString(seed.text) }
    document.encoding = seed.encoding
    document.hasBOM = seed.hasBOM
    document.savedText = seed.savedText
    document.savedEncoding = seed.savedEncoding
    document.savedHasBOM = seed.savedHasBOM
    document.url = seed.url
    document.originalBytes = seed.originalBytes
    document.recoveredName = seed.name
    document.pinned = seed.pinned
    document.language = seed.language
    document.manualLanguage = seed.manualLanguage
    document.bookmarks = seed.bookmarks
    if seed.url != nil { document.acknowledgeFileBaseline() }
    if let resolved = seed.presentation {
      let presentation = resolved.presentation
      let live = document.panePool[0]
      live.editor.setSelectedRange(presentation.panes[presentation.focusedPaneIndex].selection)
      document.preferredPaneID = live.id
      document.panePresentation.pending = .init(
        presentation: presentation, livePaneID: live.id,
        liveSlot: presentation.focusedPaneIndex, resolvedAtRevision: document.editRevision)
    }
    return document
  }
}
