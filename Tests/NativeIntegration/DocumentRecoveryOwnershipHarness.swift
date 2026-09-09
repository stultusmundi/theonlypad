import AppKit
import PadCore

@main struct DocumentRecoveryOwnershipHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      print("\(value ? "PASS" : "FAIL") \(message)")
      if !value { exit(1) }
    }
    func rejects(_ message: String, _ body: () throws -> Void) {
      do {
        try body()
        check(false, message)
      } catch { check(true, message) }
    }
    let document = EditorDocument()
    let initialOwner = document.ownershipGeneration
    let handle: any WorkspaceDocumentHandle = document
    check(
      handle.workspaceKind == .editable && handle.id == document.id,
      "model adapter exposes exact editable identity")
    rejects("unmanaged capture is explicitly refused") {
      _ = try document.captureAuthorizedRecovery()
    }
    let authority = RecoveryWriteAuthority(
      coordinatorID: UUID(), documentID: document.id, epoch: UUID())
    let receipt = RecoveryAdoptionReceipt(authority: authority, nextRevision: 1)
    rejects("adoption rejects wrong owner") {
      try document.installRecoveryAdoption(receipt, expectedOwnershipGeneration: UUID())
    }
    rejects("adoption rejects wrong document") {
      try document.installRecoveryAdoption(
        .init(
          authority: .init(coordinatorID: UUID(), documentID: UUID(), epoch: UUID()),
          nextRevision: 1), expectedOwnershipGeneration: initialOwner)
    }
    rejects("adoption rejects zero next revision") {
      try document.installRecoveryAdoption(
        .init(authority: authority, nextRevision: 0), expectedOwnershipGeneration: initialOwner)
    }
    document.recoveryRevision = 900
    do {
      try document.installRecoveryAdoption(receipt, expectedOwnershipGeneration: initialOwner)
    } catch { check(false, "valid first adoption must succeed") }
    check(
      document.recoveryAuthority == authority, "first adoption installs exact captured authority")
    check(
      document.highestIssuedRecoveryRevision == 0 && document.recoveryRevision == 900,
      "managed fence is independent of the legacy revision counter")
    rejects("duplicate adoption cannot reset revision authority") {
      try document.installRecoveryAdoption(receipt, expectedOwnershipGeneration: initialOwner)
    }
    let text = "first 😀\r\ne\u{301}\n"
    document.storage.mutableString.setString(text)
    document.savedText = text
    let first = try document.captureAuthorizedRecovery()
    check(
      first.authority == authority && first.revision == 1 && first.snapshot?.id == document.id,
      "scratch capture pairs immutable authority revision and identity")
    check(
      first.snapshot!.text.utf16.elementsEqual(text.utf16),
      "scratch captures exact Unicode even when text matches saved baseline")
    let selection = document.editor.selectedRange()
    handle.advanceOwnershipGeneration()
    check(
      document.ownershipGeneration != initialOwner && document.recoveryAuthority == authority,
      "ownership transfer advances native generation without fabricating a writer epoch")
    check(
      document.editor.selectedRange() == selection,
      "ownership advancement does not change view state")
    let file = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"]!
    ).appendingPathComponent("logical.txt")
    document.url = file
    document.encoding = .utf8
    document.savedEncoding = .utf8
    document.hasBOM = false
    document.savedHasBOM = false
    let clean = try document.captureAuthorizedRecovery()
    check(
      clean.revision == 2 && clean.snapshot == nil,
      "clean saved file captures authorized clear disposition")
    document.storage.mutableString.setString("e\u{301}")
    document.savedText = "é"
    let normalization = try document.captureAuthorizedRecovery()
    check(
      normalization.snapshot?.text.utf16.elementsEqual("e\u{301}".utf16) == true,
      "normalization-sensitive dirty text remains recoverable")
    document.savedText = document.storage.string
    document.encoding = .utf16LE
    document.hasBOM = true
    let metadata = try document.captureAuthorizedRecovery()
    check(
      metadata.snapshot?.encoding == .utf16LE && metadata.snapshot?.hasBOM == true,
      "encoding and BOM differences preserve recovery metadata")
    document.savedEncoding = document.encoding
    document.savedHasBOM = document.hasBOM
    do {
      try AtomicFileStore().save(
        Data("pending".utf8), to: file, expected: nil, fault: .directorySync)
      check(false, "publication uncertainty fixture must fail after publication")
    } catch FileStoreError.publicationUncertain(let evidence) {
      document.pendingPublication = PendingDocumentPublication(
        evidence: evidence, bytes: Data("pending".utf8))
    }
    let uncertain = try document.captureAuthorizedRecovery()
    check(
      uncertain.snapshot != nil && uncertain.snapshot?.originalPath == file.path,
      "pending publication remains recoverable with coherent logical path")
    document.pendingPublication = nil
    let second = try document.makePane()
    let undo = document.undoManager
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    document.editor.insertText(
      "!", replacementRange: .init(location: document.storage.length, length: 0))
    undo.endUndoGrouping()
    let edited = try document.captureAuthorizedRecovery()
    check(
      edited.snapshot != nil && second.editor.undoManager === undo,
      "two native panes share one recovery identity and undo manager")
    second.editor.undoManager!.undo()
    let undone = try document.captureAuthorizedRecovery()
    check(
      undone.snapshot == nil && !document.dirty,
      "other-pane undo returns clean authorized disposition")
    second.editor.undoManager!.redo()
    let redone = try document.captureAuthorizedRecovery()
    check(
      redone.snapshot?.text.utf16.elementsEqual(edited.snapshot!.text.utf16) == true,
      "redo captures exact edited text")
    check(
      first.authority == authority && first.revision == 1
        && first.snapshot!.text.utf16.elementsEqual(text.utf16),
      "old capture is immutable across edits ownership changes and later issuance")
    check(
      document.highestIssuedRecoveryRevision == redone.revision && document.recoveryRevision == 900,
      "managed highest-issued fence advances without legacy counter mutation")
    rejects("later duplicate adoption cannot rewind an issued revision") {
      try document.installRecoveryAdoption(
        receipt, expectedOwnershipGeneration: document.ownershipGeneration)
    }
    let afterDuplicate = try document.captureAuthorizedRecovery()
    check(
      afterDuplicate.revision == redone.revision + 1 && afterDuplicate.authority == authority,
      "failed duplicate leaves next issued revision and authority unchanged")
    let exhausted = EditorDocument()
    let lastAuthority = RecoveryWriteAuthority(
      coordinatorID: UUID(), documentID: exhausted.id, epoch: UUID())
    try exhausted.installRecoveryAdoption(
      .init(authority: lastAuthority, nextRevision: .max),
      expectedOwnershipGeneration: exhausted.ownershipGeneration)
    let last = try exhausted.captureAuthorizedRecovery()
    check(
      last.revision == .max && exhausted.highestIssuedRecoveryRevision == .max,
      "last representable revision can be issued exactly once")
    rejects("exhausted capture refuses without wrapping or changing authority") {
      _ = try exhausted.captureAuthorizedRecovery()
    }
    check(
      exhausted.highestIssuedRecoveryRevision == .max
        && exhausted.recoveryAuthority == lastAuthority,
      "exhaustion preserves exact authority and highest-issued fence")
    print("PASS document recovery ownership \(checks) assertions")
  }
}
