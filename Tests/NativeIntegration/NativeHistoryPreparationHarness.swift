import AppKit
import PadCore

@main struct NativeHistoryPreparationHarness {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    let registry = ApplicationDocuments(
      closeServices: .init { handle in
        try (handle as! EditorDocument).captureCloseState()
      })
    let assignment = DocumentAssignment(windowID: UUID(), groupID: UUID())
    try registry.registerWindow(id: assignment.windowID, initialGroupID: assignment.groupID)
    var checks = 0
    func check(_ value: Bool, _ label: String) {
      checks += 1
      print("\(value ? "PASS" : "FAIL") \(label)")
      if !value { exit(1) }
    }
    do {
      _ = try await NativeHistoryPreparation.prepare(
        registry: registry, windowID: assignment.windowID)
      check(false, "empty history refuses")
    } catch { check(true, "empty history refuses") }
    let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("saved😀\r\nsecond line".utf8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".txt")
    let source = try EditorDocumentFactory.make(.opened(url: url, bytes: bytes))
    try registry.registerDocument(
      source, metadata: .init(pinned: true), in: assignment, at: 0, select: true)
    let ticket = try registry.beginClose(
      registry.requestClose(documentID: source.id), disposition: .retainCleanHistory)
    _ = try registry.completeClose(ticket, result: .removed)
    let result: (claim: DocumentHistoryClaim, seed: NativeDocumentSeed)
    do {
      result = try await NativeHistoryPreparation.prepare(
        registry: registry, windowID: assignment.windowID)
    } catch {
      check(false, "actual clean history prepares: \(error)")
      return
    }
    check(
      result.seed.id != source.id && result.seed.id == result.claim.replacementID,
      "fresh prebound identity")
    check(result.seed.pinned && result.seed.kind == .reopened, "pinned reopen metadata preserved")
    check(
      result.seed.text == source.storage.string && result.seed.savedText == source.savedText,
      "exact saved text preserved")
    check(
      registry.closedHistoryCount(windowID: assignment.windowID) == 1,
      "preparation does not consume history")
    check(
      result.seed.originalBytes == bytes && result.seed.url == url && result.seed.hasBOM,
      "exact file bytes URL and BOM preserved")
    try registry.validateHistory(result.claim)
    source.acknowledgeFileBaseline()
    do {
      _ = try await NativeHistoryPreparation.prepare(
        registry: registry, windowID: assignment.windowID)
      check(false, "mutated history refuses")
    } catch { check(true, "mutated history refuses") }
    print("Native history preparation checks: \(checks), failures: 0")
  }
}
