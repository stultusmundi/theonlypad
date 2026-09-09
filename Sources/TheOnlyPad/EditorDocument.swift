import AppKit
import PadCore

@MainActor final class GuardedDocumentUndoManager: UndoManager {
  var admission: (() -> Bool)?
  private var checkingAdmission = false
  private func admitted() -> Bool {
    guard !checkingAdmission else { return false }
    checkingAdmission = true
    defer { checkingAdmission = false }
    return admission?() ?? true
  }
  override func undo() {
    guard admitted() else { return }
    super.undo()
  }
  override func redo() {
    guard admitted() else { return }
    super.redo()
  }
  override func undoNestedGroup() {
    guard admitted() else { return }
    super.undoNestedGroup()
  }
}

enum EditorPaneError: Error { case limit }
enum DocumentRecoveryCaptureError: Error { case revisionExhausted }

struct PendingDocumentPublication: Sendable {
  let id: UUID
  init(evidence: FilePublicationEvidence, bytes: Data) {
    id = UUID()
    self.evidence = evidence
    self.bytes = bytes
  }
  let evidence: FilePublicationEvidence
  let bytes: Data
}
@MainActor
final class EditorDocument {
  let id: UUID
  private(set) var closeMutationGeneration = UUID()
  private func noteCloseMutation() { closeMutationGeneration = UUID() }
  func installRecoveryRepair(
    _ receipt: RecoveryRepairReceipt, expectedAuthority: RecoveryWriteAuthority,
    expectedHighestIssuedRevision: UInt64, expectedOwnershipGeneration: UUID,
    expectedMutationGeneration: UUID
  ) throws {
    guard recoveryAuthority == expectedAuthority, expectedAuthority.documentID == id,
      highestIssuedRecoveryRevision == expectedHighestIssuedRevision,
      ownershipGeneration == expectedOwnershipGeneration,
      closeMutationGeneration == expectedMutationGeneration,
      receipt.mutationGeneration == expectedMutationGeneration,
      receipt.authority.documentID == id, receipt.lease.authority.documentID == id,
      receipt.authority.coordinatorID == expectedAuthority.coordinatorID,
      receipt.lease.authority.coordinatorID == expectedAuthority.coordinatorID,
      receipt.authority != expectedAuthority, receipt.authority != receipt.lease.authority,
      receipt.nextRevision > 0
    else { throw RecoveryAuthorityError.invalidAuthority }
    // No callback/observer/await after validation. Recovery authority is not a semantic edit.
    recoveryAuthority = receipt.authority
    nextManagedRecoveryRevision = receipt.nextRevision
    highestIssuedRecoveryRevision = receipt.nextRevision - 1
  }
  private(set) var ownershipGeneration = UUID()
  private(set) var recoveryAuthority: RecoveryWriteAuthority?
  private var nextManagedRecoveryRevision: UInt64?
  /// Managed epoch fence; unrelated to the legacy recoveryRevision counter.
  private(set) var highestIssuedRecoveryRevision: UInt64 = 0
  func advanceOwnershipGeneration() {
    ownershipGeneration = UUID()
    noteCloseMutation()
  }
  /// Called only by the trusted process owner after legacy work has drained and capture is frozen.
  /// This model adapter does not itself adopt the document into a live registry or scheduler.
  func installRecoveryAdoption(
    _ receipt: RecoveryAdoptionReceipt, expectedOwnershipGeneration: UUID
  ) throws {
    guard recoveryAuthority == nil else { throw RecoveryAuthorityError.alreadyManaged }
    guard ownershipGeneration == expectedOwnershipGeneration,
      receipt.authority.documentID == id, receipt.nextRevision > 0
    else {
      throw RecoveryAuthorityError.invalidAuthority
    }
    recoveryAuthority = receipt.authority
    nextManagedRecoveryRevision = receipt.nextRevision
    highestIssuedRecoveryRevision = receipt.nextRevision - 1
  }
  /// Capture authority at the same synchronous boundary as the bytes; never upgrade it in a writer.
  /// Issuance is not publication acknowledgement. The process owner supplies admission/quota checks.
  func captureAuthorizedRecovery() throws -> AuthorizedRecoveryItem {
    guard let authority = recoveryAuthority else { throw RecoveryAuthorityError.authorityRequired }
    guard let revision = nextManagedRecoveryRevision else {
      throw DocumentRecoveryCaptureError.revisionExhausted
    }
    // Reserve before constructing any snapshot. The final integer is valid once, never wrapped.
    highestIssuedRecoveryRevision = revision
    nextManagedRecoveryRevision = revision == .max ? nil : revision + 1
    let snapshot =
      url == nil || dirty
      ? RecoverySnapshot(
        id: id, text: storage.string, encoding: encoding, hasBOM: hasBOM,
        originalPath: url?.path) : nil
    return AuthorizedRecoveryItem(authority: authority, revision: revision, snapshot: snapshot)
  }
  var fileState: DocumentFileStateController?
  private(set) var fileBindingID = UUID()
  private(set) var baselineRevision: UInt64 = 0
  private(set) var operationID: UUID?
  /// Call after coherent saved-state adoption, before notifying the file-state bridge.
  /// Equality of bytes does not make an acknowledgement the same authority event.
  func acknowledgeFileBaseline() {
    noteCloseMutation()
    if baselineRevision == .max {
      fileBindingID = UUID()
      baselineRevision = 0
    } else {
      baselineRevision += 1
    }
  }
  /// Independent of compatibility `saving`; controllers must migrate all callbacks together.
  func beginFileOperation() -> UUID {
    panePresentation.invalidate(force: true)
    let id = UUID()
    operationID = id
    noteCloseMutation()
    return id
  }
  /// A completion must establish ownership before applying any saved-state mutation.
  @discardableResult func finishFileOperation(_ id: UUID) -> Bool {
    guard operationID == id else { return false }
    operationID = nil
    noteCloseMutation()
    return true
  }
  let storage = NSTextStorage()
  var canUndoRedo: (() -> Bool)?
  let undoManager = GuardedDocumentUndoManager()
  private(set) var panePool: [EditorPane] = []
  private(set) var editRevision: UInt64 = 0
  var composingPaneID: UUID? { didSet { if composingPaneID != oldValue { noteCloseMutation() } } }
  var preferredPaneID: UUID? { didSet { if preferredPaneID != oldValue { noteCloseMutation() } } }
  var splitAxis: PaneAxis = .sideBySide {
    didSet { if splitAxis != oldValue { noteCloseMutation() } }
  }
  let panePresentation = DocumentPanePresentation()
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
  /// Restored saved slots determine visual order; existing view/history objects are retained.
  func orderAttachedPanes(_ panes: [EditorPane]) {
    precondition(panes.count == panePool.filter(\.isAttached).count)
    precondition(Set(panes.map(\.id)) == Set(panePool.filter(\.isAttached).map(\.id)))
    panePool = panes + panePool.filter { !$0.isAttached }
  }
  var url: URL? { didSet { noteCloseMutation() } }
  var originalBytes: Data? { didSet { noteCloseMutation() } }
  var pendingPublication: PendingDocumentPublication? { didSet { noteCloseMutation() } }
  var savedText = "" {
    didSet {
      noteCloseMutation()
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
  var encoding: DocumentEncoding = .utf8 {
    didSet { if encoding != oldValue { noteCloseMutation() } }
  }
  var hasBOM = false { didSet { if hasBOM != oldValue { noteCloseMutation() } } }
  var savedEncoding: DocumentEncoding = .utf8 {
    didSet { if savedEncoding != oldValue { noteCloseMutation() } }
  }
  var savedHasBOM = false { didSet { if savedHasBOM != oldValue { noteCloseMutation() } } }
  var pinned = false { didSet { if pinned != oldValue { noteCloseMutation() } } }
  var saving = false { didSet { if saving != oldValue { noteCloseMutation() } } }
  var bookmarks = DocumentBookmarks() { didSet { noteCloseMutation() } }
  var pendingBookmarks: DocumentBookmarks? { didSet { noteCloseMutation() } }
  var compositionBookmarks: DocumentBookmarks? { didSet { noteCloseMutation() } }
  var compositionOriginalText: String? { didSet { noteCloseMutation() } }
  var compositionUndoRegistered = false {
    didSet { if compositionUndoRegistered != oldValue { noteCloseMutation() } }
  }
  var typingBookmarkNextLocation: Int?
  var pendingBookmarksHaveUndo = false {
    didSet { if pendingBookmarksHaveUndo != oldValue { noteCloseMutation() } }
  }
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

  var language: DocumentLanguage = .plainText {
    didSet { if language != oldValue { noteCloseMutation() } }
  }
  var manualLanguage = false { didSet { if manualLanguage != oldValue { noteCloseMutation() } } }
  var settingsApplied = false
  lazy var highlighter = NativeSyntaxHighlighter(storage: storage)
  var recoveryRevision: UInt64 = 0
  var recoveredName: String? { didSet { noteCloseMutation() } }

  init(id: UUID = UUID()) {
    self.id = id
    undoManager.admission = { [weak self] in self?.canUndoRedo?() ?? (self != nil) }
    panePool.append(EditorPane(document: self))
    storageObserver = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        if let storage = notification.object as? NSTextStorage,
          storage.editedMask.contains(.editedCharacters)
        {
          self?.noteCloseMutation()
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
