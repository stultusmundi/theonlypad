import AppKit
import PadCore

enum EditorPaneError: Error { case limit }

struct PendingDocumentPublication: Sendable {
  let evidence: FilePublicationEvidence
  let bytes: Data
}
@MainActor
final class EditorDocument {
  let id: UUID
  let storage = NSTextStorage()
  let undoManager = UndoManager()
  private(set) var panePool: [EditorPane] = []
  private(set) var editRevision: UInt64 = 0
  var composingPaneID: UUID?
  var preferredPaneID: UUID?
  // Transitional single-pane accessors; focus routing is a subsequent integration step.
  var editor: DocumentTextView { panePool[0].editor }
  var scroll: NSScrollView { panePool[0].scroll }
  func makePane() throws -> EditorPane {
    if let detached = panePool.first(where: { !$0.isAttached }) { return detached }
    guard panePool.count < 2 else { throw EditorPaneError.limit }
    let pane = EditorPane(document: self)
    panePool.append(pane)
    return pane
  }
  var url: URL?
  var originalBytes: Data?
  var pendingPublication: PendingDocumentPublication?
  var savedText = "" {
    didSet {
      savedUTF16Length = (savedText as NSString).length
      cachedTextDirty = nil
    }
  }
  private var savedUTF16Length = 0
  var selectableBeforeQuit: Bool? {
    get { panePool[0].selectableBeforeQuit }
    set { panePool[0].selectableBeforeQuit = newValue }
  }
  var onCharactersChanged: (() -> Void)?
  private var cachedTextDirty: Bool?
  private var storageObserver: NSObjectProtocol?
  var encoding: DocumentEncoding = .utf8
  var hasBOM = false
  var savedEncoding: DocumentEncoding = .utf8
  var savedHasBOM = false
  var pinned = false
  var saving = false
  var bookmarks = DocumentBookmarks()
  var pendingBookmarks: DocumentBookmarks?
  var compositionBookmarks: DocumentBookmarks?
  var compositionOriginalText: String?
  var compositionUndoRegistered = false
  var typingBookmarkNextLocation: Int?
  var pendingBookmarksHaveUndo = false
  var dirty: Bool {
    if pendingPublication != nil { return true }
    guard encoding == savedEncoding, hasBOM == savedHasBOM else { return true }
    // Queries inside an unfinished editing batch must not reuse the previous result.
    if storage.editedMask.contains(.editedCharacters) { cachedTextDirty = nil }
    if let cachedTextDirty { return cachedTextDirty }
    let changed =
      storage.length != savedUTF16Length
      || !storage.mutableString.isEqual(to: savedText)
    cachedTextDirty = changed
    return changed
  }
  var name: String { url?.lastPathComponent ?? recoveredName ?? "Untitled" }

  var language: DocumentLanguage = .plainText
  var manualLanguage = false
  var settingsApplied = false
  lazy var highlighter = NativeSyntaxHighlighter(storage: storage)
  var recoveryRevision: UInt64 = 0
  var recoveredName: String?

  init(id: UUID = UUID()) {
    self.id = id
    panePool.append(EditorPane(document: self))
    storageObserver = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        if let storage = notification.object as? NSTextStorage,
          storage.editedMask.contains(.editedCharacters)
        {
          self?.editRevision &+= 1
          self?.cachedTextDirty = nil
          self?.highlighter.invalidateForCharacterEdit()
          self?.onCharactersChanged?()
        }
      }
    }
  }

  deinit {
    if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
  }
}
