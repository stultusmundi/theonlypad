import AppKit
import PadCore

struct Seeded {
  var state: UInt64
  mutating func next(_ upper: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 32) % UInt64(upper))
  }
}
@main struct DirtyDifferentialHarness {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    var checkpoints = 0
    var proofChecks = 0
    var descriptor = "setup"
    func check(_ doc: EditorDocument) {
      let expected =
        doc.pendingPublication != nil || doc.encoding != doc.savedEncoding
        || doc.hasBOM != doc.savedHasBOM
        || !doc.storage.string.utf16.elementsEqual(doc.savedText.utf16)
      if !doc.storage.editedMask.contains(.editedCharacters) {
        doc.assertDirtyProofInvariant()
        proofChecks += 1
      }
      precondition(doc.dirty == expected, "dirty mismatch: \(descriptor)")
      doc.assertDirtyProofInvariant()
      proofChecks += 1
      checkpoints += 1
    }
    func boundaries(_ text: String) -> [Int] {
      var result = [0]
      for scalar in text.unicodeScalars {
        result.append(result.last! + (scalar.value > 0xFFFF ? 2 : 1))
      }
      return result
    }
    let pool = [
      "", "a", "Z", "\r", "\n", "\r\n", "\0", "é", "e\u{301}", "a\u{301}\u{327}", "a\u{327}\u{301}",
      "😀", "👩‍💻", "\u{202E}",
    ]
    for seed in 0..<100 {
      var random = Seeded(state: UInt64(seed + 1))
      let doc = EditorDocument()
      doc.storage.mutableString.setString("start😀e\u{301}\r\n")
      doc.savedText = doc.storage.string
      var depth = 0
      check(doc)
      for step in 0..<200 {
        descriptor = "seed=\(seed) step=\(step)"
        let offsets = boundaries(doc.storage.string)
        let a = random.next(offsets.count)
        let b = random.next(offsets.count)
        let range = NSRange(
          location: offsets[min(a, b)], length: offsets[max(a, b)] - offsets[min(a, b)])
        switch random.next(12) {
        case 0, 1, 2, 3:
          doc.storage.replaceCharacters(in: range, with: pool[random.next(pool.count)])
        case 4:
          if depth < 4 {
            doc.storage.beginEditing()
            depth += 1
          }
        case 5:
          if depth > 0 {
            doc.storage.endEditing()
            depth -= 1
          }
        case 6:
          doc.savedText = random.next(2) == 0 ? doc.storage.string : pool[random.next(pool.count)]
        case 7:
          doc.encoding = random.next(2) == 0 ? .utf8 : .utf16LE
          doc.hasBOM = random.next(2) == 0
        case 8:
          doc.savedEncoding = doc.encoding
          doc.savedHasBOM = doc.hasBOM
        case 9:
          doc.storage.addAttribute(.foregroundColor, value: NSColor.red, range: range)
        case 10:
          doc.editor.string = pool[random.next(pool.count)]
        default:
          let same = doc.storage.mutableString.substring(with: range)
          doc.storage.replaceCharacters(in: range, with: same)
        }
        check(doc)
        if step.isMultiple(of: 7) { check(doc) }
      }
      while depth > 0 {
        doc.storage.endEditing()
        depth -= 1
        check(doc)
      }
    }
    // Seeded NATIVE undo histories are separate from storage batching histories.
    for seed in 0..<100 {
      let historyDoc = EditorDocument()
      var random = Seeded(state: UInt64(seed + 1001))
      historyDoc.storage.mutableString.setString("base😀")
      historyDoc.savedText = historyDoc.storage.string
      historyDoc.undoManager.groupsByEvent = false
      var past: [String] = []
      var future: [String] = []
      for step in 0..<200 {
        descriptor = "native seed=\(seed) step=\(step)"
        let action = random.next(3)
        if action == 0 && !past.isEmpty {
          precondition(historyDoc.undoManager.canUndo)
          let expected = past.removeLast()
          future.append(historyDoc.storage.string)
          historyDoc.undoManager.undo()
          precondition(historyDoc.storage.string.utf16.elementsEqual(expected.utf16))
        } else if action == 1 && !future.isEmpty {
          precondition(historyDoc.undoManager.canRedo)
          let expected = future.removeLast()
          past.append(historyDoc.storage.string)
          historyDoc.undoManager.redo()
          precondition(historyDoc.storage.string.utf16.elementsEqual(expected.utf16))
        } else {
          let offsets = boundaries(historyDoc.storage.string)
          let offset = offsets[random.next(offsets.count)]
          let value = pool[1 + random.next(pool.count - 1)]
          past.append(historyDoc.storage.string)
          future.removeAll()
          historyDoc.editor.breakUndoCoalescing()
          historyDoc.undoManager.beginUndoGrouping()
          historyDoc.editor.insertText(
            value, replacementRange: NSRange(location: offset, length: 0))
          historyDoc.undoManager.endUndoGrouping()
        }
        check(historyDoc)
      }
      historyDoc.undoManager.removeAllActions()
    }
    // Deterministic span/fallback coverage on native storage; not timing assertions.
    let coverage = EditorDocument()
    let baseline = String(repeating: "a", count: 10000)
    coverage.storage.mutableString.setString(baseline)
    coverage.savedText = baseline
    check(coverage)
    func measured(_ name: String, expectedSpan: Int, full: Int, action: () -> Void) {
      DirtyProofMetrics.reset()
      action()
      check(coverage)
      precondition(DirtyProofMetrics.comparisonSpanUnits == expectedSpan, "span: \(name)")
      precondition(
        DirtyProofMetrics.calls["dirty.fullCompare", default: 0] == full, "fallback: \(name)")
      print(
        "COVERAGE \(name) span=\(DirtyProofMetrics.comparisonSpanUnits) full=\(full) rangeCalls=\(DirtyProofMetrics.calls["dirty.rangeCompare", default: 0])"
      )
    }
    measured("EOF interval", expectedSpan: 1, full: 0) {
      coverage.storage.replaceCharacters(in: NSRange(location: 9999, length: 1), with: "Z")
    }
    measured("exact inverse", expectedSpan: 1, full: 0) {
      coverage.storage.replaceCharacters(in: NSRange(location: 9999, length: 1), with: "a")
    }
    measured("append length", expectedSpan: 0, full: 0) {
      coverage.storage.replaceCharacters(in: NSRange(location: 10000, length: 0), with: "!")
    }
    measured("restored empty suffix", expectedSpan: 0, full: 0) {
      coverage.storage.replaceCharacters(in: NSRange(location: 10000, length: 1), with: "")
    }
    measured("baseline reset", expectedSpan: 10000, full: 1) { coverage.savedText = baseline }
    coverage.storage.beginEditing()
    measured("unfinished batch", expectedSpan: 10000, full: 1) {
      coverage.storage.replaceCharacters(in: NSRange(location: 9999, length: 1), with: "Z")
    }
    measured("poison stable fallback", expectedSpan: 10000, full: 1) {
      coverage.storage.endEditing()
    }
    let doc = EditorDocument()
    let storage = doc.storage
    storage.mutableString.setString("abcdef😀e\u{301}\r\n")
    doc.savedText = storage.string
    check(doc)
    let last = NSRange(location: storage.length - 1, length: 1)
    storage.replaceCharacters(in: last, with: "!")
    doc.assertAlignedDirtyRange(last)
    check(doc)
    // Distinct edits and exact inverse restoration, without trusting undo tokens.
    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
    check(doc)
    storage.replaceCharacters(in: last, with: "\n")
    check(doc)
    precondition(doc.dirty)
    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "a")
    check(doc)
    precondition(!doc.dirty)
    // Late-registered dirty query intentionally poisons after processed notification.
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification,
      object: storage, queue: nil
    ) { _ in
      MainActor.assumeIsolated { _ = doc.dirty }
    }
    storage.replaceCharacters(in: last, with: "!")
    precondition(doc.testDirtyProofIsPoisoned)
    check(doc)
    precondition(!doc.testDirtyProofIsPoisoned)
    NotificationCenter.default.removeObserver(observer)
    storage.mutableString.setString(doc.savedText)
    check(doc)
    // Shared panes/native undo, including detached originating view.
    let second = try doc.makePane()
    doc.undoManager.groupsByEvent = false
    doc.undoManager.beginUndoGrouping()
    second.editor.insertText("Z", replacementRange: last)
    doc.undoManager.endUndoGrouping()
    check(doc)
    precondition(doc.undoManager.canUndo)
    second.detach()
    doc.editor.undoManager!.undo()
    check(doc)
    precondition(!doc.dirty)
    doc.editor.undoManager!.redo()
    check(doc)
    precondition(doc.dirty)
    second.attach()
    precondition(second.document === doc && second.editor.undoManager === doc.undoManager)
    // Pending publication must not mask later text/proof updates.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data("synthetic".utf8)
    do {
      try AtomicFileStore().save(
        bytes, to: directory.appendingPathComponent("publication.txt"), expected: nil,
        fault: .directorySync)
      preconditionFailure("expected publication uncertainty")
    } catch FileStoreError.publicationUncertain(let evidence) {
      doc.pendingPublication = PendingDocumentPublication(evidence: evidence, bytes: bytes)
    }
    check(doc)
    storage.beginEditing()
    storage.mutableString.setString(doc.savedText)
    doc.savedText = storage.string
    check(doc)
    storage.endEditing()
    check(doc)
    doc.pendingPublication = nil
    check(doc)
    precondition(!doc.dirty)
    // Marked APIs produce intermediate edits and remain exact, not physical IME evidence.
    doc.undoManager.removeAllActions()
    doc.undoManager.beginUndoGrouping()
    doc.editor.setMarkedText(
      "漢", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 1))
    check(doc)
    doc.editor.setMarkedText(
      "漢字", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    check(doc)
    doc.editor.unmarkText()
    doc.undoManager.endUndoGrouping()
    check(doc)
    print(
      "PASS exact dirty histories seeds=100 storageOperations=20000 nativeHistoryOperations=20000 checkpoints=\(checkpoints) proofChecks=\(proofChecks)"
    )
  }
}
