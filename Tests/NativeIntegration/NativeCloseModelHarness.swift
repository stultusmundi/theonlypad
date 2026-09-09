import AppKit
import PadCore

@main struct NativeCloseModelHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    var checks = 0
    var failures = 0
    func check(_ value: Bool, _ name: String) {
      checks += 1
      if !value { failures += 1 }
      print("\(value ? "PASS" : "FAIL") \(name)")
    }
    func rejects(_ name: String, _ body: () throws -> Void) {
      do {
        try body()
        check(false, name)
      } catch { check(true, name) }
    }
    let mutations: [(String, (EditorDocument) -> Void)] = [
      ("characters", { $0.storage.mutableString.setString("😀e\u{301}") }),
      (
        "encoding return",
        {
          $0.encoding = .utf16LE
          $0.encoding = .utf8
        }
      ),
      (
        "BOM return",
        {
          $0.hasBOM = true
          $0.hasBOM = false
        }
      ),
      ("saved equal text assignment", { $0.savedText = "" }),
      ("saved encoding", { $0.savedEncoding = .latin1 }),
      ("saved BOM", { $0.savedHasBOM = true }),
      ("equal original bytes assignment", { $0.originalBytes = nil }),
      ("equal URL assignment", { $0.url = nil }),
      ("baseline acknowledgment", { $0.acknowledgeFileBaseline() }),
      (
        "operation completed",
        {
          let id = $0.beginFileOperation()
          $0.finishFileOperation(id)
        }
      ),
      (
        "legacy saving return",
        {
          $0.saving = true
          $0.saving = false
        }
      ),
      (
        "composition return",
        {
          $0.composingPaneID = UUID()
          $0.composingPaneID = nil
        }
      ),
      ("bookmarks assignment", { $0.bookmarks = DocumentBookmarks() }),
      (
        "pending remap return",
        {
          $0.pendingBookmarks = DocumentBookmarks()
          $0.pendingBookmarks = nil
        }
      ),
      ("composition baseline", { $0.compositionOriginalText = "" }),
      (
        "composition bookmark return",
        {
          $0.compositionBookmarks = DocumentBookmarks()
          $0.compositionBookmarks = nil
        }
      ),
      ("composition undo", { $0.compositionUndoRegistered = true }),
      ("pending undo", { $0.pendingBookmarksHaveUndo = true }),
      (
        "pin return",
        {
          $0.pinned = true
          $0.pinned = false
        }
      ),
      ("language", { $0.language = .swift }),
      ("manual language", { $0.manualLanguage = true }),
      ("name", { $0.recoveredName = "Name" }),
      ("preferred pane", { $0.preferredPaneID = $0.panePool[0].id }),
      (
        "axis return",
        {
          $0.splitAxis = .stacked
          $0.splitAxis = .sideBySide
        }
      ),
      ("ownership", { $0.advanceOwnershipGeneration() }),
    ]
    for (name, mutate) in mutations {
      let model = EditorDocument()
      let before = model.closeMutationGeneration
      mutate(model)
      check(model.closeMutationGeneration != before, name + " invalidates close")
    }
    let model = EditorDocument()
    let beforeStaleFinish = model.closeMutationGeneration
    check(
      !model.finishFileOperation(UUID()) && model.closeMutationGeneration == beforeStaleFinish,
      "stale operation finish does not invalidate")
    do {
      let clean = try model.captureCloseState()
      check(
        !clean.isDirty && !clean.hasPendingTextEdits && !clean.isComposing, "truthful clean state")
      model.saving = true
      rejects("legacy saving refuses state") { _ = try model.captureCloseState() }
      model.saving = false
      model.pendingBookmarks = DocumentBookmarks()
      rejects("pending remapping refuses state") { _ = try model.captureCloseState() }
      model.pendingBookmarks = nil
      model.storage.beginEditing()
      model.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
      rejects("unfinished text batch refuses state") { _ = try model.captureCloseState() }
      model.storage.endEditing()
      let dirty = try model.captureCloseState()
      check(dirty.isDirty, "post-batch state exact dirty")
    } catch { check(false, "valid state must be readable: \(error)") }
    let managed = EditorDocument()
    let authority = RecoveryWriteAuthority(
      coordinatorID: UUID(), documentID: managed.id, epoch: UUID())
    let beforeAdoption = managed.closeMutationGeneration
    try managed.installRecoveryAdoption(
      .init(authority: authority, nextRevision: 1),
      expectedOwnershipGeneration: managed.ownershipGeneration)
    check(
      managed.closeMutationGeneration == beforeAdoption, "adoption authority not semantic mutation")
    managed.storage.mutableString.setString("first 😀\r\ne\u{301}")
    managed.savedText = managed.storage.string
    managed.url = URL(fileURLWithPath: "/synthetic/clean.txt")
    let firstPane = managed.panePool[0]
    let second = try managed.makePane()
    second.editor.setSelectedRange(NSRange(location: 2, length: 0))
    let geometry = managed.captureCloseGeometry()
    do {
      let capture = try managed.captureCloseRecovery()
      check(
        !capture.state.isDirty
          && capture.snapshot.text.utf16.elementsEqual(managed.storage.string.utf16),
        "clean saved file captures full repair snapshot")
      check(
        capture.authority == authority && capture.highestIssuedRevision == 0
          && managed.highestIssuedRecoveryRevision == 0, "close capture does not issue revision")
      let context = NativeRepairInstallationContext(
        state: capture.state, modelAuthority: capture.authority,
        highestIssuedRevision: capture.highestIssuedRevision)
      // Actor lease may already be newer than model after a previous installation refusal.
      let intermediate = RecoveryWriteAuthority(
        coordinatorID: authority.coordinatorID, documentID: managed.id, epoch: UUID())
      let lease = RecoveryCloseLease(
        authority: intermediate, transactionID: UUID(), registryTicketID: UUID())
      let newAuthority = RecoveryWriteAuthority(
        coordinatorID: authority.coordinatorID, documentID: managed.id, epoch: UUID())
      func receipt(_ target: RecoveryWriteAuthority, next: UInt64 = 2, mutation: UUID? = nil)
        -> RecoveryRepairReceipt
      {
        .init(
          lease: lease, attemptID: UUID(),
          mutationGeneration: mutation ?? context.state.mutationGeneration,
          publicationID: UUID(), authority: target, nextRevision: next)
      }
      let originalGeneration = managed.closeMutationGeneration
      let originalOwner = managed.ownershipGeneration
      for (name, invalid) in [
        ("same authority", receipt(authority)),
        ("zero revision", receipt(newAuthority, next: 0)),
        ("wrong generation", receipt(newAuthority, mutation: UUID())),
        (
          "wrong document",
          receipt(.init(coordinatorID: authority.coordinatorID, documentID: UUID(), epoch: UUID()))
        ),
        (
          "wrong coordinator",
          receipt(.init(coordinatorID: UUID(), documentID: managed.id, epoch: UUID()))
        ),
      ] {
        rejects(name + " repair refuses") {
          try managed.installCloseRepair(invalid, expected: context)
        }
        check(
          managed.recoveryAuthority == authority && managed.highestIssuedRecoveryRevision == 0
            && managed.closeMutationGeneration == originalGeneration
            && managed.ownershipGeneration == originalOwner
            && managed.captureCloseGeometry() == geometry, name + " refusal preserves state")
      }
      let changedFence = NativeRepairInstallationContext(
        state: capture.state, modelAuthority: authority, highestIssuedRevision: 1)
      rejects("wrong captured revision fence refuses") {
        try managed.installCloseRepair(receipt(newAuthority), expected: changedFence)
      }
      try managed.installCloseRepair(receipt(newAuthority), expected: context)
      check(
        managed.recoveryAuthority == newAuthority && managed.highestIssuedRecoveryRevision == 1,
        "lagged model repair installs fresh authority")
      check(
        managed.closeMutationGeneration == originalGeneration
          && managed.ownershipGeneration == originalOwner,
        "repair leaves semantic generations unchanged")
      check(
        managed.panePool[0] === firstPane && managed.panePool[1] === second
          && managed.captureCloseGeometry() == geometry && !managed.dirty,
        "repair preserves views selection and baseline")
      rejects("duplicate repair cannot reset revision") {
        try managed.installCloseRepair(receipt(newAuthority), expected: context)
      }
      let issued = try managed.captureAuthorizedRecovery()
      check(
        issued.authority == newAuthority && issued.revision == 2 && issued.snapshot == nil,
        "new authority issues next revision once")
    } catch { check(false, "valid repair capture/installation must succeed: \(error)") }
    let undoModel = EditorDocument()
    undoModel.storage.mutableString.setString("a😀e\u{301}\r\n")
    undoModel.savedText = undoModel.storage.string
    let undoPeer = try undoModel.makePane()
    let beforeEdit = undoModel.closeMutationGeneration
    undoModel.undoManager.beginUndoGrouping()
    undoModel.editor.insertText("X", replacementRange: NSRange(location: 0, length: 1))
    undoModel.undoManager.endUndoGrouping()
    let afterEdit = undoModel.closeMutationGeneration
    undoPeer.editor.undoManager!.undo()
    check(
      afterEdit != beforeEdit && undoModel.closeMutationGeneration != afterEdit && !undoModel.dirty,
      "actual shared-pane undo returns exact clean text with new mutation authority")
    let beforeRedo = undoModel.closeMutationGeneration
    undoPeer.editor.undoManager!.redo()
    check(
      undoModel.closeMutationGeneration != beforeRedo && undoModel.dirty,
      "actual shared redo invalidates")
    let marked = EditorDocument()
    marked.editor.setMarkedText(
      "é", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    do {
      check(
        try marked.captureCloseState().isComposing,
        "actual native marked text detected without controller callback")
    } catch { check(false, "marked state readable when no pending remap") }
    rejects("actual native composition refuses recovery capture") {
      _ = try marked.captureCloseRecovery()
    }
    marked.editor.unmarkText()
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    do {
      try AtomicFileStore().save(
        Data("same".utf8), to: fixture.appendingPathComponent("x"), expected: nil,
        fault: .directorySync)
      check(false, "expected injected publication uncertainty")
    } catch FileStoreError.publicationUncertain(let evidence) {
      let pending = EditorDocument()
      pending.pendingPublication = .init(evidence: evidence, bytes: Data("same".utf8))
      let previousID = pending.pendingPublication!.id
      let generation = pending.closeMutationGeneration
      pending.pendingPublication = .init(evidence: evidence, bytes: Data("same".utf8))
      check(
        pending.pendingPublication!.id != previousID
          && pending.closeMutationGeneration != generation,
        "same-byte pending publication replacement invalidates")
      do {
        check(
          try pending.captureCloseState().hasPendingPublication,
          "pending publication state explicit")
      } catch { check(false, "pending publication state readable") }
    }
    for (name, mutate) in mutations {
      let changed = EditorDocument()
      let a0 = RecoveryWriteAuthority(coordinatorID: UUID(), documentID: changed.id, epoch: UUID())
      try changed.installRecoveryAdoption(
        .init(authority: a0, nextRevision: 1),
        expectedOwnershipGeneration: changed.ownershipGeneration)
      let captured = try changed.captureCloseRecovery()
      let context = NativeRepairInstallationContext(
        state: captured.state, modelAuthority: a0, highestIssuedRevision: 0)
      let next = RecoveryWriteAuthority(
        coordinatorID: a0.coordinatorID, documentID: changed.id, epoch: UUID())
      let repair = RecoveryRepairReceipt(
        lease: .init(authority: a0, transactionID: UUID(), registryTicketID: UUID()),
        attemptID: UUID(), mutationGeneration: captured.state.mutationGeneration,
        publicationID: UUID(), authority: next, nextRevision: 2)
      mutate(changed)
      let textAfter = changed.storage.string
      let baselineAfter = changed.savedText
      let generationAfter = changed.closeMutationGeneration
      rejects(name + " after capture refuses repair") {
        try changed.installCloseRepair(repair, expected: context)
      }
      check(
        changed.recoveryAuthority == a0 && changed.highestIssuedRecoveryRevision == 0
          && changed.storage.string.utf16.elementsEqual(textAfter.utf16)
          && changed.savedText.utf16.elementsEqual(baselineAfter.utf16)
          && changed.closeMutationGeneration == generationAfter,
        name + " refusal has no partial model changes")
    }
    print("Native close model checks: \(checks), failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
