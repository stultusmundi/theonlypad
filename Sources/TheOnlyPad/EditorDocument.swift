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
  var splitAxis: PaneAxis = .sideBySide
  // Compatibility accessors; interactive controller commands resolve their originating pane.
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
      dirtyProof = .unknown
    }
  }
  private var savedUTF16Length = 0
  var selectableBeforeQuit: Bool? {
    get { panePool[0].selectableBeforeQuit }
    set { panePool[0].selectableBeforeQuit = newValue }
  }
  var onCharactersChanged: (() -> Void)?
  private enum DirtyProof {
    case unknown
    case aligned(NSRange?)  // nil is mathematical empty, never an endpoint at zero
    case suffix(Int)
  }
  private var dirtyProof: DirtyProof = .unknown
  private var dirtyProofPoisoned = false
  private var processedLength = 0
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
    let pending = storage.editedMask.contains(.editedCharacters)
    if pending {
      dirtyProof = .unknown
      dirtyProofPoisoned = true
      cachedTextDirty = nil
    }
    if pendingPublication != nil { return true }
    guard encoding == savedEncoding, hasBOM == savedHasBOM else { return true }
    if !pending && !dirtyProofPoisoned, let cachedTextDirty { return cachedTextDirty }
    if storage.length != savedUTF16Length {
      if !pending && !dirtyProofPoisoned { cachedTextDirty = true }
      return true
    }
    let equal: Bool
    if pending || dirtyProofPoisoned {
      equal = exactDirtyTextEqual()
    } else {
      switch dirtyProof {
      case .unknown:
        equal = exactDirtyTextEqual()
      case .aligned(nil): equal = true
      case .aligned(let range?):
        equal = dirtyRangeEqual(range)
      case .suffix(let low):
        equal = dirtyRangeEqual(NSRange(location: low, length: storage.length - low))
      }
    }
    if !pending {
      dirtyProofPoisoned = false
      if equal { dirtyProof = .aligned(nil) }
      cachedTextDirty = !equal
    }
    return !equal
  }

  private func exactDirtyTextEqual() -> Bool {
    return storage.mutableString.isEqual(to: savedText)
  }
  private func dirtyRangeEqual(_ range: NSRange) -> Bool {
    let current = storage.mutableString
    let baseline = savedText as NSString
    precondition(
      current.length == baseline.length && range.location >= 0 && range.length >= 0
        && range.location <= current.length && range.length <= current.length - range.location)
    var left = [unichar](repeating: 0, count: min(4096, range.length))
    var right = left
    var offset = range.location
    let end = range.location + range.length
    while offset < end {
      let length = min(4096, end - offset)
      let chunk = NSRange(location: offset, length: length)
      left.withUnsafeMutableBufferPointer { current.getCharacters($0.baseAddress!, range: chunk) }
      right.withUnsafeMutableBufferPointer { baseline.getCharacters($0.baseAddress!, range: chunk) }
      for index in 0..<length { if left[index] != right[index] { return false } }
      offset += length
    }
    return true
  }

  private func processDirtyEdit(_ text: NSTextStorage) {
    cachedTextDirty = nil
    defer { processedLength = text.length }
    let range = text.editedRange
    let delta = text.changeInLength
    let (expected, overflow) = processedLength.addingReportingOverflow(delta)
    guard !dirtyProofPoisoned, !overflow, expected == text.length,
      range.location != NSNotFound, range.location >= 0, range.location <= text.length,
      range.length >= 0, range.length <= text.length - range.location
    else {
      dirtyProof = .unknown
      return
    }
    switch dirtyProof {
    case .unknown: return
    case .aligned(let previous):
      if delta == 0 && text.length == savedUTF16Length {
        if range.length == 0 { return }
        dirtyProof = .aligned(previous.map { NSUnionRange($0, range) } ?? range)
      } else {
        dirtyProof = .suffix(min(previous?.location ?? range.location, range.location))
      }
    case .suffix(let low):
      dirtyProof = .suffix(min(low, range.location))
    }
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
          self?.processDirtyEdit(storage)
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
