import AppKit
import Darwin

@testable import PadCore

@main struct DocumentDiskStatusHarness {
  @MainActor static func main() {
    var failures = 0
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      checks += 1
      if !value {
        failures += 1
        print("FAIL \(message)")
      }
    }
    var actions: [DocumentDiskStatusView.Action] = []
    let view = DocumentDiskStatusView { actions.append($0) }
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    func button(_ id: String) -> NSButton? {
      descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id }
    }
    func text() -> String {
      descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
    }
    func state(
      _ relation: DiskContentRelation = .differsFromBaseline,
      problem: DiskLocationProblem? = nil, readOnly: Bool = false, moved: Bool = false,
      dismissed: Bool = false
    ) -> ObservedFileState {
      let identity = FileTargetIdentity(
        parentDevice: 1, parentInode: 2, fileDevice: 3, fileInode: 4)
      let metadata = FileMetadata(
        identity: identity, byteCount: 1, mode: 0o600, flags: 0,
        modificationSeconds: 1, modificationNanoseconds: 0, changeSeconds: 1, changeNanoseconds: 0)
      let observation = DiskObservation(
        metadata: problem == nil ? metadata : nil,
        content: relation, locationProblem: problem, readOnlyHint: readOnly,
        movedCandidate: moved ? URL(fileURLWithPath: "/tmp/synthetic-moved.txt") : nil)
      let token = FileObservationToken(
        documentID: UUID(), epoch: 1, baselineRevision: 1, sequence: 1)
      var value = ObservedFileState()
      _ = value.accept(observation, token: token, currentToken: token)
      if dismissed { value.dismiss(token: token) }
      return value
    }
    func render(
      _ value: ObservedFileState, manual: String? = nil, failure: MonitorFailure? = nil,
      source: Bool = true, enabled: Bool = true
    ) {
      view.render(
        state: value, manualNotice: manual, failure: failure, hasSource: source, enabled: enabled)
    }
    render(state(), source: false)
    check(view.isHidden, "source-less row hidden")
    render(state(.matchesBaseline))
    check(view.isHidden, "ordinary matching row hidden")
    render(state(dismissed: true))
    check(view.isHidden, "dismissed observation row hidden")
    render(state(readOnly: true, moved: true))
    check(!view.isHidden, "changed row visible")
    check(text().localizedCaseInsensitiveContains("changed"), "changed facet rendered")
    check(text().localizedCaseInsensitiveContains("read-only"), "read-only facet preserved")
    check(text().localizedCaseInsensitiveContains("moved"), "moved hint rendered")
    check(view.accessibilityIdentifier() == "document.diskStatus", "row AX identifier")
    check(view.accessibilityLabel() == text(), "row AX label communicates all status reasons")
    let checkButton = button("document.checkDisk")
    let resolveButton = button("document.resolveDiskChange")
    let retryButton = button("document.retryMonitoring")
    check(
      checkButton != nil && resolveButton != nil && retryButton != nil,
      "native action AX identifiers")
    check(checkButton?.accessibilityLabel() == "Check Again", "check AX label")
    check(resolveButton?.accessibilityLabel() == "Resolve Disk Change", "resolve AX label")
    check(retryButton?.accessibilityLabel() == "Retry Monitoring", "retry AX label")
    check(checkButton?.isEnabled == true && checkButton?.isHidden == false, "check available")
    check(resolveButton?.isEnabled == true && resolveButton?.isHidden == false, "resolve available")
    check(retryButton?.isHidden == true, "retry hidden for healthy automatic monitoring")
    check(actions.isEmpty, "render never triggers actions")
    checkButton?.performClick(nil)
    resolveButton?.performClick(nil)
    retryButton?.performClick(nil)
    check(actions == [.checkAgain, .resolve], "native buttons deliver only relevant actions")
    render(state(.matchesBaseline), manual: "Manual checks only", failure: .capacity)
    check(
      !view.isHidden && text().contains("Manual checks only") && text().contains("limit"),
      "manual matching/capacity notice retained")
    check(
      resolveButton?.isHidden == true && retryButton?.isHidden == false,
      "manual matching action relevance")
    retryButton?.performClick(nil)
    check(actions.last == .retryMonitoring, "native retry callback")
    let count = actions.count
    render(state(), manual: "Manual checks only", enabled: false)
    for button in [checkButton, resolveButton, retryButton] { button?.performClick(nil) }
    check(
      [checkButton, resolveButton, retryButton].allSatisfy { $0?.isEnabled == false },
      "busy disables all actions")
    check(actions.count == count, "disabled actions cannot call owner")
    render(state(), source: false)
    for button in [checkButton, resolveButton, retryButton] { button?.performClick(nil) }
    check(actions.count == count, "hidden row cannot call owner")
    let facets: [(DiskLocationProblem, String)] = [
      (.missing, "missing"), (.inaccessible, "access"),
      (.symbolicLink, "symbolic link"), (.nonregular, "regular file"), (.parentChanged, "folder"),
      (.changedDuringRead, "changed while"), (.unsupportedVolume, "unsupported"),
      (.tooLarge, "100 MB"),
      (.checkDelayed, "delayed"), (.notDownloaded, "downloaded"),
    ]
    for (problem, phrase) in facets {
      render(state(.unavailable, problem: problem))
      check(
        !view.isHidden && text().localizedCaseInsensitiveContains(phrase),
        "explicit \(problem) message")
    }
    render(ObservedFileState(), failure: .unavailable)
    check(
      !view.isHidden && text().contains("unavailable") && retryButton?.isHidden == false,
      "failure without observation actionable")
    render(ObservedFileState(), failure: .cancelled)
    check(
      text().contains("cancelled") && retryButton?.isHidden == true,
      "cancellation is not monitoring failure")
    print("DISK STATUS CHECKS \(checks) FAILURES \(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
