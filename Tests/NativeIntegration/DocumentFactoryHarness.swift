import AppKit
import PadCore

@main struct DocumentFactoryHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    var checks = 0
    var failures = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value { failures += 1 }
      print("\(value ? "PASS" : "FAIL") \(message)")
    }
    func rejects(_ message: String, _ body: () throws -> Void) {
      do {
        try body()
        check(false, message)
      } catch { check(true, message) }
    }
    func make(_ seed: NativeDocumentSeed, _ name: String) -> EditorDocument? {
      do {
        let model = try EditorDocumentFactory.make(seed)
        check(model.id == seed.id, "\(name) exact ID")
        check(model.storage.string.utf16.elementsEqual(seed.text.utf16), "\(name) exact UTF16")
        check(
          model.encoding == seed.encoding && model.hasBOM == seed.hasBOM,
          "\(name) current encoding/BOM")
        check(
          model.savedText.utf16.elementsEqual(seed.savedText.utf16)
            && model.savedEncoding == seed.savedEncoding && model.savedHasBOM == seed.savedHasBOM,
          "\(name) saved baseline")
        check(
          model.url == seed.url && model.originalBytes == seed.originalBytes,
          "\(name) URL/bytes pairing")
        check(model.panePool.count == 1 && model.panePool[0].isAttached, "\(name) one initial pane")
        check(
          model.onCharactersChanged == nil && model.fileState == nil
            && model.recoveryAuthority == nil && model.recoveryRevision == 0
            && model.highestIssuedRecoveryRevision == 0,
          "\(name) no endpoint/monitor/writer installed")
        check(
          !model.undoManager.canUndo && !model.undoManager.canRedo && model.operationID == nil
            && model.pendingPublication == nil, "\(name) no inherited operation/history/publication"
        )
        check(
          model.baselineRevision == (seed.url == nil ? 0 : 1),
          "\(name) baseline acknowledgment only for files")
        return model
      } catch {
        check(false, "\(name) valid seed must construct: \(error)")
        return nil
      }
    }
    let text = "first 😀\r\ne\u{301}\nlast\r"
    let bytes = try DocumentCodec.encode(.init(text: text, encoding: .utf16LE, hasBOM: true))
    let url = URL(fileURLWithPath: "/synthetic/document.json")
    if let scratch = make(try .scratch(), "scratch") {
      check(!scratch.dirty && scratch.url == nil && scratch.storage.length == 0, "scratch defaults")
    }
    if let file = make(try .opened(url: url, bytes: bytes), "opened") {
      check(!file.dirty && file.language == .json, "opened clean detected language")
    }
    let presentation = SessionPresentation(
      axis: .stacked,
      panes: [
        .init(selection: NSRange(location: 0, length: 5), scrollOrigin: .init(x: 0, y: 21)),
        .init(selection: NSRange(location: 10, length: 2), scrollOrigin: .init(x: 11, y: 45)),
      ], focusedPaneIndex: 1)
    let metadata = SessionTab(
      originalPath: "/informational/original.json", pinned: true,
      encoding: .utf16LE, manualLanguage: .swift, selection: NSRange(location: 0, length: 0),
      bookmarks: [0, 10], presentation: presentation)
    let decoded = try DocumentCodec.decode(bytes)
    let restoredSeed = try NativeDocumentSeed.restored(
      metadata, decoded: decoded, originalBytes: nil, url: nil)
    if let restored = make(restoredSeed, "restored") {
      check(
        restored.url == nil && restored.recoveredName == "Recovered original.json",
        "recovery path informational only")
      check(
        restored.pinned && restored.manualLanguage && restored.language == .swift,
        "restored pin/manual language")
      check(
        restored.bookmarks == restoredSeed.presentation!.bookmarks, "restored validated bookmarks")
      let pending = restored.panePresentation.pending
      check(
        pending?.presentation == restoredSeed.presentation!.presentation && pending?.liveSlot == 1
          && pending?.presented == false, "restored independent lazy pane metadata")
      check(
        restored.editor.selectedRange() == restoredSeed.presentation!.focusedViewState.selection
          && restored.preferredPaneID == restored.panePool[0].id,
        "restored focused slot mapped to sole live pane")
    }
    if let restoredFile = make(
      try .restored(metadata, decoded: decoded, originalBytes: bytes, url: url), "restored-file")
    {
      check(
        !restoredFile.dirty && restoredFile.recoveredName == nil, "restored file baseline exact")
    }
    if let backup = make(
      try .backup(originalPath: "/synthetic/original.txt", data: bytes, encoding: .utf16LE),
      "backup")
    {
      check(
        backup.recoveredName == "Backup — original.txt" && backup.dirty && backup.url == nil,
        "backup is unsaved scratch")
    }
    if let copy = make(try .diskCopy(sourceName: "source", decoded: decoded), "disk-copy") {
      check(
        copy.recoveredName == "Disk Copy — source" && copy.url == nil && copy.dirty,
        "disk copy no source binding")
    }
    let duplicateSeed = try NativeDocumentSeed.duplicate(
      text: text, encoding: .utf16LE, hasBOM: true, language: .swift, manualLanguage: true)
    if let a = make(duplicateSeed, "duplicate"),
      let b = make(
        try .duplicate(
          text: text, encoding: .utf16LE, hasBOM: true, language: .swift, manualLanguage: true),
        "duplicate-independent")
    {
      check(
        a.id != b.id && a.storage !== b.storage && a.undoManager !== b.undoManager,
        "duplicates own independent text and undo")
      check(
        a.language == .swift && a.manualLanguage && a.dirty,
        "duplicate preserves language, remains unsaved")
      a.storage.mutableString.append("!")
      check(
        b.storage.string.utf16.elementsEqual(text.utf16), "duplicate mutation never aliases source")
    }
    let bookmarks = try DocumentBookmarks(offsets: [0, 10], in: text)
    if let reopened = make(
      try .reopened(
        text: text, url: url, originalBytes: bytes, encoding: .utf16LE, hasBOM: true,
        saved: decoded, bookmarks: bookmarks, language: .swift, manualLanguage: true), "reopened")
    {
      check(
        !reopened.dirty && reopened.bookmarks == bookmarks && reopened.manualLanguage,
        "reopened clean history values exact")
    }
    let pinnedReopenSeed = try NativeDocumentSeed.reopened(
      text: text, url: url, originalBytes: bytes, encoding: .utf16LE, hasBOM: true,
      saved: decoded, bookmarks: bookmarks, language: .swift, manualLanguage: true, pinned: true)
    if let pinnedReopen = make(pinnedReopenSeed, "pinned-reopened") {
      check(
        pinnedReopenSeed.pinned && pinnedReopen.pinned,
        "reopened history pin preserved by native factory")
    }
    let legacyReopenSeed = try NativeDocumentSeed.reopened(
      text: text, url: url, originalBytes: bytes, encoding: .utf16LE, hasBOM: true,
      saved: decoded, bookmarks: bookmarks, language: .swift, manualLanguage: true)
    check(!legacyReopenSeed.pinned, "legacy reopened seed defaults unpinned")
    let snapshot = RecoverySnapshot(
      id: UUID(), text: text, encoding: .utf16LE, hasBOM: true,
      originalPath: "/informational/original.txt")
    if let recovered = make(try .legacyRecovery(snapshot), "legacy-recovery") {
      check(
        recovered.id == snapshot.id && recovered.url == nil
          && recovered.recoveredName == "Recovered original.txt",
        "legacy recovery retains ID but never original URL")
    }
    let automatic = SessionTab(originalPath: "/synthetic/source.py", encoding: .utf16LE)
    let recoveredAutomatic = try NativeDocumentSeed.restored(
      automatic, decoded: decoded, originalBytes: nil, url: nil)
    check(
      recoveredAutomatic.language == .python, "recovery detects final informational display name")
    let backupLanguage = try NativeDocumentSeed.backup(
      originalPath: "/synthetic/source.py", data: bytes, encoding: .utf16LE)
    check(backupLanguage.language == .python, "backup detects final display name")
    let copyLanguage = try NativeDocumentSeed.diskCopy(sourceName: "source.py", decoded: decoded)
    check(copyLanguage.language == .python, "disk copy detects captured display name")
    let legacyLanguage = try NativeDocumentSeed.legacyRecovery(
      .init(
        id: UUID(), text: text, encoding: .utf16LE, hasBOM: true,
        originalPath: "/synthetic/source.py"))
    check(legacyLanguage.language == .python, "legacy recovery detects final display name")
    let shebang = DecodedDocument(text: "#!/usr/bin/python\nprint(1)")
    check(
      try NativeDocumentSeed.diskCopy(sourceName: "script", decoded: shebang).language == .python,
      "extensionless copy detects shebang")
    check(
      try NativeDocumentSeed.diskCopy(sourceName: "script.json", decoded: shebang).language
        == .json,
      "filename extension keeps priority over shebang")
    do {
      let encoded = try NativeDocumentSeed.restored(metadata, url: url, originalBytes: bytes)
      check(
        encoded.text.utf16.elementsEqual(decoded.text.utf16) && encoded.encoding == .utf16LE
          && encoded.hasBOM && encoded.originalBytes == bytes
          && encoded.presentation == restoredSeed.presentation
          && encoded.language == .swift,
        "encoded restoration preserves exact decoded baseline and metadata")
    } catch { check(false, "encoded restoration valid input must succeed") }
    let small = try NativeDocumentSeed.Limits(utf16: 2, bytes: 4)
    rejects("text limit refuses oversize before model") {
      _ = try NativeDocumentSeed.duplicate(
        text: "123", encoding: .utf8, hasBOM: false, language: .plainText, manualLanguage: false,
        limits: small)
    }
    rejects("byte limit refuses oversize before decode") {
      _ = try NativeDocumentSeed.opened(
        url: url, bytes: Data(repeating: 65, count: 5), limits: small)
    }
    rejects("limits cannot increase production ceiling") {
      _ = try NativeDocumentSeed.Limits(utf16: 100_000_001)
    }
    rejects("restored missing URL/bytes pair") {
      _ = try NativeDocumentSeed.restored(
        metadata, decoded: decoded, originalBytes: bytes, url: nil)
    }
    rejects("restored mismatched exact text refuses") {
      _ = try NativeDocumentSeed.restored(
        metadata, decoded: .init(text: "wrong", encoding: .utf16LE, hasBOM: true),
        originalBytes: bytes, url: url)
    }
    rejects("opened nonfile URL refuses") {
      _ = try NativeDocumentSeed.opened(
        url: URL(string: "https://example.invalid/x")!, bytes: Data("x".utf8))
    }
    rejects("dirty history refuses rather than fabricating clean baseline") {
      _ = try NativeDocumentSeed.reopened(
        text: text + "!", url: url, originalBytes: bytes, encoding: .utf16LE, hasBOM: true,
        saved: decoded, bookmarks: bookmarks, language: .swift, manualLanguage: true)
    }
    let decomposed = "e\u{301}"
    rejects("normalization-equivalent bytes cannot substitute restored baseline") {
      _ = try NativeDocumentSeed.restored(
        SessionTab(), decoded: .init(text: "é"), originalBytes: Data(decomposed.utf8), url: url)
    }
    rejects("history bookmarks from another text refuse") {
      _ = try NativeDocumentSeed.reopened(
        text: "x", url: nil, originalBytes: nil,
        encoding: .utf8, hasBOM: false, saved: .init(text: "x"), bookmarks: bookmarks,
        language: .plainText, manualLanguage: false)
    }
    var mutable = decoded
    let immutable = try NativeDocumentSeed.diskCopy(sourceName: "source", decoded: mutable)
    mutable.text = "later"
    check(immutable.text.utf16.elementsEqual(text.utf16), "seed captures immutable decoded value")

    // Binary admission: removing either external seed guard must admit these valid decoded NULs.
    // Literal bytes/text keep this independent of the codec's encoder and any new error cases.
    let nulText = "A\u{0}B"
    let nulFixtures: [(String, Data, DocumentEncoding, Bool)] = [
      ("UTF8", Data([0x41, 0x00, 0x42]), .utf8, false),
      ("UTF16LE", Data([0xFF, 0xFE, 0x41, 0x00, 0x00, 0x00, 0x42, 0x00]), .utf16LE, true),
      ("UTF16BE", Data([0xFE, 0xFF, 0x00, 0x41, 0x00, 0x00, 0x00, 0x42]), .utf16BE, true),
    ]
    for (name, raw, encoding, bom) in nulFixtures {
      let rawDecoded = try DocumentCodec.decode(raw, encoding: encoding)
      check(
        rawDecoded.text.utf16.elementsEqual(nulText.utf16)
          && rawDecoded.encoding == encoding && rawDecoded.hasBOM == bom,
        "binary admission \(name): raw codec retains literal decoded NUL")
      check(
        try DocumentCodec.encode(rawDecoded) == raw,
        "binary admission \(name): raw codec remains byte reversible")
      rejects("binary admission \(name): opened refuses decoded NUL before model creation") {
        _ = try NativeDocumentSeed.opened(url: url, bytes: raw)
      }
      rejects("binary admission \(name): explicit encoding cannot bypass decoded NUL refusal") {
        _ = try NativeDocumentSeed.opened(url: url, bytes: raw, encoding: encoding)
      }
      rejects("binary admission \(name): disk-only restoration refuses decoded NUL") {
        _ = try NativeDocumentSeed.restored(
          SessionTab(encoding: encoding), url: url, originalBytes: raw)
      }
    }

    // Four 32-bit BOM orders must not be treated as an editable supported encoding.
    let unsupportedMarkers: [(String, Data)] = [
      ("UTF32BE", Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])),
      ("UTF32LE", Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])),
      ("UTF32-2143", Data([0x00, 0x00, 0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00])),
      ("UTF32-3412", Data([0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00])),
    ]
    for (name, raw) in unsupportedMarkers {
      rejects("binary admission \(name): normal open refuses unsupported or ambiguous BOM") {
        _ = try NativeDocumentSeed.opened(url: url, bytes: raw)
      }
      rejects("binary admission \(name): disk-only restore refuses unsupported BOM") {
        _ = try NativeDocumentSeed.restored(
          SessionTab(encoding: .latin1), url: url, originalBytes: raw)
      }
    }

    // A raw-zero-byte heuristic would break these valid UTF16 documents. The expected
    // supplementary character, mixed endings, encoding and BOM are all literal fixtures.
    let safeText = "A😀\r\nB\rc\n"
    let safeLE = Data([
      0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0x0D, 0x00, 0x0A, 0x00,
      0x42, 0x00, 0x0D, 0x00, 0x63, 0x00, 0x0A, 0x00,
    ])
    let safeBE = Data([
      0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x0D, 0x00, 0x0A,
      0x00, 0x42, 0x00, 0x0D, 0x00, 0x63, 0x00, 0x0A,
    ])
    func admitExact(
      _ name: String, expectedText: String, raw: Data, encoding: DocumentEncoding, bom: Bool,
      _ seed: () throws -> NativeDocumentSeed
    ) {
      do {
        let model = try EditorDocumentFactory.make(seed())
        check(
          model.storage.string.utf16.elementsEqual(expectedText.utf16)
            && model.savedText.utf16.elementsEqual(expectedText.utf16)
            && model.encoding == encoding && model.savedEncoding == encoding
            && model.hasBOM == bom && model.savedHasBOM == bom,
          "binary admission \(name): exact editable text and saved encoding/BOM")
        check(
          !model.dirty && model.originalBytes == raw && model.url == url,
          "binary admission \(name): clean model keeps exact disk bytes and URL")
      } catch { check(false, "binary admission \(name): supported text must construct: \(error)") }
    }
    let safeFixtures: [(String, Data, DocumentEncoding, Bool)] = [
      ("UTF16LE BOM", Data([0xFF, 0xFE]) + safeLE, .utf16LE, true),
      ("UTF16BE BOM", Data([0xFE, 0xFF]) + safeBE, .utf16BE, true),
      ("explicit UTF16LE without BOM", safeLE, .utf16LE, false),
      ("explicit UTF16BE without BOM", safeBE, .utf16BE, false),
    ]
    for (name, raw, encoding, bom) in safeFixtures {
      admitExact(name + " open", expectedText: safeText, raw: raw, encoding: encoding, bom: bom) {
        try NativeDocumentSeed.opened(url: url, bytes: raw, encoding: bom ? nil : encoding)
      }
      admitExact(
        name + " disk restore", expectedText: safeText, raw: raw, encoding: encoding, bom: bom
      ) {
        try NativeDocumentSeed.restored(
          SessionTab(encoding: encoding), url: url, originalBytes: raw)
      }
    }
    for (name, raw, encoding) in [
      ("explicit UTF8", Data([0xC3, 0xA9, 0x0D, 0x0A]), DocumentEncoding.utf8),
      ("explicit Windows1252", Data([0xE9, 0x0D, 0x0A]), DocumentEncoding.windows1252),
      ("explicit Latin1", Data([0xE9, 0x0D, 0x0A]), DocumentEncoding.latin1),
    ] {
      admitExact(name, expectedText: "é\r\n", raw: raw, encoding: encoding, bom: false) {
        try NativeDocumentSeed.opened(url: url, bytes: raw, encoding: encoding)
      }
    }

    // Recovery already owns text: moving the admission guard into shared construction or
    // DocumentCodec would lose this NUL, so exercise the unchanged real recovery paths.
    let recoveredNUL = DecodedDocument(text: nulText)
    if let recovery = make(
      try .restored(SessionTab(), decoded: recoveredNUL, originalBytes: nil, url: nil),
      "recovered-NUL")
    {
      check(
        recovery.storage.string.utf16.elementsEqual(nulText.utf16) && recovery.url == nil
          && recovery.originalBytes == nil && recovery.dirty,
        "binary admission recovery: decoded no-file NUL remains exact and unsaved")
    }
    if let nulBackup = make(
      try .backup(
        originalPath: "/synthetic/nul-backup.txt", data: Data([0x41, 0x00, 0x42]),
        encoding: .utf8), "backup-NUL")
    {
      check(
        nulBackup.storage.string.utf16.elementsEqual(nulText.utf16) && nulBackup.url == nil
          && nulBackup.dirty && nulBackup.recoveredName == "Backup — nul-backup.txt",
        "binary admission recovery: backup NUL remains exact and unsaved")
    }
    print("Factory checks: \(checks), failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
