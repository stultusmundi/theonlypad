import AppKit
import Darwin
import PadCore

@main struct OwnerHarness {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    var failures = 0
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value {
        failures += 1
        print("FAIL \(message)")
      }
    }
    let doc = EditorDocument()
    let initialBinding = doc.fileBindingID
    doc.url = URL(fileURLWithPath: "/tmp/synthetic-owner.txt")
    doc.originalBytes = Data("base😀\r\n".utf8)
    doc.savedText = "base😀\r\n"
    doc.storage.mutableString.setString(doc.savedText)
    doc.acknowledgeFileBaseline()
    check(doc.baselineRevision == 1, "first logical baseline adoption advances")
    check(doc.fileBindingID == initialBinding, "ordinary adoption preserves binding")
    doc.acknowledgeFileBaseline()
    check(doc.baselineRevision == 2, "equal-byte acknowledgement advances")
    let adopted = doc.baselineRevision
    doc.encoding = .utf16LE
    doc.hasBOM = true
    doc.storage.mutableString.append("edit")
    check(
      doc.baselineRevision == adopted && doc.fileBindingID == initialBinding,
      "current encoding/BOM/text edits do not advance acknowledged baseline")
    doc.url = URL(fileURLWithPath: "/tmp/synthetic-owner-renamed.txt")
    doc.acknowledgeFileBaseline()
    check(doc.baselineRevision == adopted + 1, "acknowledged URL adoption advances")
    doc.seedBaselineRevisionForTest(.max)
    let beforeOverflow = doc.fileBindingID
    doc.acknowledgeFileBaseline()
    check(
      doc.baselineRevision == 0 && doc.fileBindingID != beforeOverflow,
      "overflow rotates binding and resets revision without wrapping same authority")
    let rotated = doc.fileBindingID
    doc.acknowledgeFileBaseline()
    check(
      doc.baselineRevision == 1 && doc.fileBindingID == rotated, "new binding increments normally")
    doc.saving = true
    let a = doc.beginFileOperation()
    check(doc.operationID == a, "operation begin publishes identity")
    let b = doc.beginFileOperation()
    check(a != b && doc.operationID == b, "new operation supersedes old identity")
    check(
      !doc.finishFileOperation(a) && doc.operationID == b,
      "stale completion cannot clear newer operation")
    check(doc.saving, "token helpers do not alter compatibility saving")
    check(
      doc.finishFileOperation(b) && doc.operationID == nil, "matching completion clears operation")
    check(!doc.finishFileOperation(b), "duplicate completion rejected")
    doc.saving = false
    let c = doc.beginFileOperation()
    check(!doc.saving, "begin does not implicitly change saving")
    check(doc.finishFileOperation(c), "independent operation completes")
    let evidence = try await Task.detached {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: url) }
      do {
        try AtomicFileStore().save(Data([1]), to: url, expected: nil, fault: .directorySync)
      } catch FileStoreError.publicationUncertain(let evidence) { return evidence }
      throw NSError(domain: "ExpectedPublicationEvidence", code: 1)
    }.value
    let p = PendingDocumentPublication(evidence: evidence, bytes: Data([1]))
    let copy = p
    let replacement = PendingDocumentPublication(evidence: evidence, bytes: Data([1]))
    check(copy.id == p.id, "pending struct copy preserves identity")
    check(replacement.id != p.id, "equal pending replacement has fresh identity")
    doc.pendingPublication = p
    let pendingID = doc.pendingPublication!.id
    doc.pendingPublication = copy
    check(doc.pendingPublication!.id == pendingID, "pending owner copy preserves context")
    doc.pendingPublication = replacement
    check(doc.pendingPublication!.id != pendingID, "new publication invalidates captured identity")
    check(doc.dirty, "pending publication retains existing dirty semantics")
    print("CHECKS \(checks) FAILURES \(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
