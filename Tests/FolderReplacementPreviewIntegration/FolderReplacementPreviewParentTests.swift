import AppKit
import Darwin
import Foundation
import PadCore
import XCTest

@testable import FolderReplacementPreviewComponent

@MainActor
final class FolderReplacementPreviewParentTests: XCTestCase {
  // Missing entry/wrong seed must fail before an unentered downstream child horizon.
  func testParentPreviewButtonCreatesActualChildAndSeedsLiteralOnly() async throws {
    try await withRig { rig in
      let parent = rig.parent
      let raw = " e\u{301}\r\n😀 $1\\n "
      parent.parentContractQuery.stringValue = raw
      parent.parentContractCase.state = .off
      parent.parentContractWholeWord.state = .on
      let button = parent.replacementPreviewButton
      XCTAssertEqual(button.title, "Read-only Replacement Preview…")
      XCTAssertEqual(button.identifier?.rawValue, "folder.replacementPreview")
      XCTAssertTrue(descendants(parent.window?.contentView).contains { $0 === button })
      XCTAssertTrue(button.target as AnyObject? === parent)
      XCTAssertNotNil(button.action)
      guard let action = button.action, button.target as AnyObject? === parent else {
        throw ParentContractFailure.noReach
      }
      XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))
      let first = try requireCurrent(parent)
      XCTAssertEqual(rig.records.children.count, 1)
      XCTAssertEqual(rig.records.presented, [ObjectIdentifier(first)])
      XCTAssertEqual(first.rootURL, rig.root)
      XCTAssertEqual(Data(first.patternView.string.utf8), Data(raw.utf8))
      XCTAssertEqual(first.caseButton.state, .off)
      XCTAssertEqual(first.wholeWordButton.state, .on)
      XCTAssertTrue(first.selectedURLs.isEmpty)
      XCTAssertFalse(first.window?.isVisible ?? true)
      XCTAssertFalse(parent.window?.isVisible ?? true)
      for selection in [1, 2, -1] {
        if selection == -1 {
          parent.parentContractMode.removeAllItems()
        } else {
          parent.parentContractMode.selectItem(at: selection)
        }
        XCTAssertEqual(parent.parentContractMode.indexOfSelectedItem, selection)
        let child = try launch(parent)
        XCTAssertEqual(child.patternView.string, "")
        XCTAssertTrue(child.selectedURLs.isEmpty)
        let recorded = try rig.records.lastSeed()
        XCTAssertNil(recorded)
        XCTAssertEqual(child.rootURL, rig.root)
      }
      XCTAssertEqual(rig.records.children.count, 4)
      let noRoot = rig.makeAdditionalParent(root: nil)
      let child = try launch(noRoot)
      XCTAssertNil(child.rootURL)
      XCTAssertTrue(child.selectedURLs.isEmpty)
      XCTAssertEqual(rig.executor.submitted, 0)
    }
  }

  // Old onClose must not clear a replacement, even when invoked again after replacement.
  func testParentReplacementClosesOldAndOldCallbackCannotRetireSuccessor() async throws {
    try await withRig { rig in
      let a = try launch(rig.parent)
      XCTAssertNotNil(a.onClose)
      guard let staleClose = a.onClose else { throw ParentContractFailure.noReach }
      let b = try launch(rig.parent)
      XCTAssertFalse(a === b)
      XCTAssertTrue(a.isClosed)
      XCTAssertFalse(b.isClosed)
      XCTAssertTrue(rig.parent.currentPreview === b)
      staleClose()
      XCTAssertTrue(rig.parent.currentPreview === b)
      XCTAssertFalse(b.isClosed)
      XCTAssertEqual(rig.records.presented, [ObjectIdentifier(a), ObjectIdentifier(b)])
      b.close()
      XCTAssertNil(rig.parent.currentPreview)
      staleClose()
      XCTAssertNil(rig.parent.currentPreview)
    }
  }

  // A stale outer launch must not overwrite a child or reopen after cancellation reentry.
  func testParentReplacementCancellationReentryPreservesNewestIntent() async throws {
    try await withRig { rig in
      let parent = rig.parent
      let a = try launch(parent)
      let chooser = try rig.records.chooser(for: a)
      try a.chooseFiles()
      var successor: FolderReplacementPreviewController?
      chooser.onCancel = { [weak parent] in successor = parent?.showPreview() }
      let staleOuter = parent.showPreview()
      XCTAssertNil(staleOuter)
      XCTAssertNotNil(successor)
      guard let b = successor else { throw ParentContractFailure.noReach }
      XCTAssertTrue(a.isClosed)
      XCTAssertTrue(parent.currentPreview === b)
      XCTAssertFalse(b.isClosed)
      XCTAssertEqual(rig.records.children.count, 2)
      XCTAssertEqual(rig.records.presented, [ObjectIdentifier(a), ObjectIdentifier(b)])
      let secondChooser = try rig.records.chooser(for: b)
      try b.chooseFiles()
      secondChooser.onCancel = { [weak parent] in parent?.close() }
      let closedOuter = parent.showPreview()
      XCTAssertNil(closedOuter)
      XCTAssertTrue(parent.parentContractClosed)
      XCTAssertTrue(b.isClosed)
      XCTAssertNil(parent.currentPreview)
      XCTAssertEqual(rig.records.children.count, 2)
      XCTAssertEqual(rig.records.presented.count, 2)
    }
  }

  // Root publication must follow old-child invalidation, and a newer nested root wins.
  func testParentRootChangeClosesChildBeforePublicationAndFencesReentry() async throws {
    try await withRig { rig in
      let parent = rig.parent
      let a = try launch(parent)
      let chooser = try rig.records.chooser(for: a)
      try a.chooseFiles()
      let outerRoot = URL(fileURLWithPath: "/synthetic-parent-outer", isDirectory: true)
      let latestRoot = URL(fileURLWithPath: "/synthetic-parent-latest", isDirectory: true)
      var rootAtCancellation: URL?
      var closedAtCancellation = false
      chooser.onCancel = { [weak parent, weak a] in
        rootAtCancellation = parent?.parentContractRoot
        closedAtCancellation = a?.isClosed == true
        parent?.setRoot(latestRoot)
      }
      parent.setRoot(outerRoot)
      XCTAssertEqual(rootAtCancellation, rig.root)
      XCTAssertTrue(closedAtCancellation)
      XCTAssertTrue(a.isClosed)
      XCTAssertNil(parent.currentPreview)
      XCTAssertEqual(parent.parentContractRoot, latestRoot)
      try chooser.reply(0, [rig.file])
      XCTAssertNil(parent.currentPreview)
      XCTAssertTrue(a.selectedURLs.isEmpty)
      let b = try launch(parent)
      XCTAssertEqual(b.rootURL, latestRoot)
      let secondChooser = try rig.records.chooser(for: b)
      try b.chooseFiles()
      var secondObservedRoot: URL?
      secondChooser.onCancel = { [weak parent, weak b] in
        secondObservedRoot = parent?.parentContractRoot
        XCTAssertTrue(b?.isClosed == true)
      }
      parent.setRoot(outerRoot)
      XCTAssertEqual(secondObservedRoot, latestRoot)
      XCTAssertEqual(parent.parentContractRoot, outerRoot)
      XCTAssertTrue(b.isClosed)
      XCTAssertNil(parent.currentPreview)
    }
  }

  // Hidden programmatic close must work without relying on an SDK close notification.
  func testParentHiddenCloseAndDelegateCloseInvalidateExactlyOnce() async throws {
    for delegateFirst in [false, true] {
      try await withRig { rig in
        let parent = rig.parent
        let child = try launch(parent)
        let chooser = try rig.records.chooser(for: child)
        try child.chooseFiles()
        let window = try XCTUnwrap(parent.window)
        let wrong = NSPanel(
          contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        defer { wrong.close() }
        var closedNotifications = 0
        parent.onClose = { [weak parent, weak child] in
          closedNotifications += 1
          XCTAssertTrue(parent?.parentContractClosed == true)
          XCTAssertTrue(child?.isClosed == true)
          XCTAssertNil(parent?.currentPreview)
        }
        parent.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: wrong))
        XCTAssertFalse(parent.parentContractClosed)
        XCTAssertFalse(child.isClosed)
        XCTAssertEqual(closedNotifications, 0)
        guard !parent.parentContractClosed, !child.isClosed else {
          throw ParentContractFailure.noReach
        }
        let oldGeneration = parent.parentContractGeneration
        if delegateFirst {
          parent.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        } else {
          parent.close()
        }
        XCTAssertTrue(parent.parentContractClosed)
        XCTAssertTrue(child.isClosed)
        XCTAssertNil(parent.currentPreview)
        XCTAssertNotEqual(parent.parentContractGeneration, oldGeneration)
        XCTAssertEqual(closedNotifications, 1)
        XCTAssertEqual(chooser.cancelled.count, 1)
        parent.close()
        parent.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(closedNotifications, 1)
        XCTAssertEqual(chooser.cancelled.count, 1)
        let made = rig.records.children.count
        XCTAssertNil(parent.showPreview())
        XCTAssertEqual(rig.records.children.count, made)
        try chooser.reply(0, [rig.file])
        XCTAssertTrue(child.selectedURLs.isEmpty)
        XCTAssertNil(parent.currentPreview)
        XCTAssertFalse(parent.window?.isVisible ?? true)
        XCTAssertFalse(child.window?.isVisible ?? true)
      }
    }
  }

  // Closing the parent must cancel publication, but cannot release a real held lane early.
  func testClosedParentHeldWorkKeepsSharedAdmissionUntilExactSettlement() async throws {
    try await withRig { rig in
      let a = try launch(rig.parent)
      try rig.configure(a)
      let admittedA = try a.preview()
      XCTAssertTrue(admittedA)
      guard admittedA else { throw ParentContractFailure.noReach }
      XCTAssertEqual(rig.executor.submitted, 1)
      XCTAssertTrue(a.hasActiveRequest)
      var lateRefreshes = 0
      a.onRefresh = { lateRefreshes += 1 }
      rig.parent.close()
      XCTAssertTrue(a.isClosed)
      XCTAssertTrue(a.hasActiveRequest)
      let refreshAtClose = lateRefreshes
      let successorParent = rig.makeAdditionalParent(root: rig.root)
      let b = try launch(successorParent)
      XCTAssertTrue(a.workLane === b.workLane)
      try rig.configure(b)
      let premature = try b.preview()
      XCTAssertFalse(premature)
      XCTAssertEqual(rig.executor.submitted, 1)
      try rig.executor.launch()
      try await waitUntil { !a.hasActiveRequest }
      XCTAssertEqual(lateRefreshes, refreshAtClose)
      XCTAssertTrue(a.isClosed)
      XCTAssertNil(a.display)
      XCTAssertEqual(rig.probe.values, [true])
      let admittedB = try b.preview()
      XCTAssertTrue(admittedB)
      guard admittedB else { throw ParentContractFailure.noReach }
      XCTAssertEqual(rig.executor.submitted, 2)
      try rig.executor.launch()
      try await waitUntil { !b.hasActiveRequest }
      XCTAssertEqual(b.phase, .ready)
      XCTAssertNotNil(b.display)
      XCTAssertEqual(rig.probe.values, [true, false])
      XCTAssertEqual(rig.executor.launched, 2)
      XCTAssertFalse(rig.executor.hasPending)
      let defaultParent = FolderSearchController(
        root: rig.root,
        previewPresentation: { child in XCTAssertFalse(child.window?.isVisible ?? true) },
        onOpen: { _ in XCTFail("Preview must not navigate") })
      rig.additionalParents.append(defaultParent)
      let defaultChild = try launch(defaultParent)
      defer { defaultChild.close() }
      XCTAssertTrue(defaultChild.workLane === FolderReplacementPreviewComposition.lane)
      XCTAssertFalse(defaultChild.window?.isVisible ?? true)
    }
  }

  // Opening preview must leave actual original search results/navigation authority intact.
  func testParentPreviewLeavesOriginalSearchAndNavigationIndependent() async throws {
    let fixture = try ParentSearchFixture()
    let searchProbe = ParentSearchProbe()
    var primary: Error?
    do {
      // Independent Foundation expectation, captured before actual search/navigation.
      let expectedNavigationURL = fixture.file.resolvingSymlinksInPath().standardizedFileURL
      let expectedIdentity = try ParentSearchFixture.identity(of: fixture.file)
      let initialBytes = try Data(contentsOf: fixture.file)
      XCTAssertEqual(expectedIdentity.size, 7)
      XCTAssertEqual(initialBytes, Data("needle\n".utf8))
      try await withRig(
        root: fixture.root,
        search: { root, query, includes, excludes in
          defer { searchProbe.didReturn() }
          return try FolderSearch.search(
            root: root, query: query, includes: includes, excludes: excludes)
        }, searchProbe: searchProbe,
        { rig in
          let parent = rig.parent
          parent.parentContractQuery.stringValue = "needle"
          searchProbe.expectReturn()
          let run = parent.parentContractRun
          let action = try XCTUnwrap(run.action)
          XCTAssertTrue(NSApplication.shared.sendAction(action, to: run.target, from: run))
          try await waitUntil { searchProbe.returned && !parent.parentContractSearchBusy }
          XCTAssertEqual(parent.parentContractHitCount, 1)
          XCTAssertEqual(parent.parentContractTable.numberOfRows, 1)
          guard parent.parentContractHitCount == 1 else { throw ParentContractFailure.noReach }
          parent.parentContractTable.selectRowIndexes(
            IndexSet(integer: 0), byExtendingSelection: false)
          let open = try XCTUnwrap(parent.parentContractTable.doubleAction)
          XCTAssertTrue(
            NSApplication.shared.sendAction(
              open, to: parent.parentContractTable.target,
              from: parent.parentContractTable))
          try await waitUntil { rig.records.navigation.count == 1 }
          let request = try XCTUnwrap(rig.records.navigation.first)
          XCTAssertTrue(request.isCurrent)
          XCTAssertTrue(request.belongs(to: parent))
          XCTAssertEqual(request.url, expectedNavigationURL)
          let requestedIdentity = try ParentSearchFixture.identity(of: request.url)
          XCTAssertEqual(requestedIdentity.device, expectedIdentity.device)
          XCTAssertEqual(requestedIdentity.inode, expectedIdentity.inode)
          XCTAssertEqual(requestedIdentity.size, expectedIdentity.size)
          XCTAssertEqual(requestedIdentity.size, 7)
          guard request.url == expectedNavigationURL, requestedIdentity == expectedIdentity,
            requestedIdentity.size == 7
          else { throw ParentContractFailure.noReach }
          let requestedBytes = try Data(contentsOf: request.url)
          XCTAssertEqual(requestedBytes, Data("needle\n".utf8))
          XCTAssertEqual(request.range, NSRange(location: 0, length: 6))
          XCTAssertEqual(request.snapshot, "needle\n")
          let generation = parent.parentContractGeneration
          let child = try launch(parent)
          XCTAssertEqual(parent.parentContractGeneration, generation)
          XCTAssertEqual(parent.parentContractHitCount, 1)
          XCTAssertEqual(parent.parentContractTable.numberOfRows, 1)
          XCTAssertTrue(request.isCurrent)
          XCTAssertTrue(request.belongs(to: parent))
          XCTAssertTrue(child.selectedURLs.isEmpty)
          parent.setRoot(URL(fileURLWithPath: "/synthetic-new-search-root", isDirectory: true))
          XCTAssertFalse(request.isCurrent)
          XCTAssertTrue(child.isClosed)
          XCTAssertEqual(parent.parentContractHitCount, 0)
          XCTAssertEqual(rig.records.navigation.count, 1)
        })
    } catch { primary = error }
    if searchProbe.canRetireFixture {
      fixture.verifyAndRemove()
    } else {
      XCTFail(
        "Original search has not returned; synthetic fixture retained without deleting under it")
      ParentUnsettledResources.retain(fixture)
    }
    if let primary { throw primary }
  }

  // Break: stale factory return closes the exact child already adopted by a newer intent.
  func testParentFactoryReentryReturningSameSuccessorCannotCloseNewestChild() async throws {
    try await withRig { rig in
      let records = rig.records
      let hook = ParentFactoryReentryWeakParentHolder()
      let parent = FolderSearchController(
        root: rig.root,
        previewFactory: { root, seed in
          guard hook.enter() else {
            // Refuse further reentry without producing an unowned third child.
            if let child = records.children.last { return child }
            return records.make(root: root, seed: seed)
          }
          defer { hook.leave() }
          if hook.calls == 1 {
            let nested = hook.parent?.showPreview()
            hook.nestedChild = nested
            XCTAssertNotNil(nested, "Actual nested parent intent must return its own child")
            if let nested {
              // Observe genuine adoption/presentation before stale outer cleanup can run.
              XCTAssertTrue(hook.parent?.currentPreview === nested)
              XCTAssertFalse(nested.isClosed)
              XCTAssertEqual(records.presented, [ObjectIdentifier(nested)])
              hook.returnedToOuter = nested
              return nested
            }
          }
          return records.make(root: root, seed: seed)
        }, previewPresentation: { child in records.present(child) },
        onOpen: { _ in XCTFail("Factory reentry preview must not navigate") })
      rig.additionalParents.append(parent)
      hook.parent = parent
      XCTAssertEqual(rig.additionalParents.count, 1)
      let staleOuter = parent.showPreview()
      XCTAssertNil(staleOuter, "Older intent cannot return a newer intent's child as its own")
      XCTAssertEqual(hook.calls, 2)
      XCTAssertEqual(hook.depth, 0)
      XCTAssertFalse(hook.overflow)
      XCTAssertNotNil(hook.nestedChild)
      XCTAssertEqual(records.children.count, 1, "Only nested factory constructs one actual child")
      guard let b = hook.nestedChild else { throw ParentContractFailure.noReach }
      XCTAssertTrue(hook.returnedToOuter === b)
      XCTAssertTrue(records.children.first === b)
      XCTAssertTrue(
        parent.currentPreview === b, "Stale factory return must preserve newer ownership")
      XCTAssertFalse(b.isClosed, "Stale outer cleanup must not close the same adopted successor")
      XCTAssertEqual(records.presented, [ObjectIdentifier(b)])
      XCTAssertFalse(parent.parentContractClosed)
      XCTAssertFalse(parent.window?.isVisible ?? true)
      XCTAssertFalse(b.window?.isVisible ?? true)
      XCTAssertFalse(b.hasActiveRequest)
      XCTAssertFalse(rig.executor.hasPending)
      XCTAssertEqual(rig.executor.submitted, 0)
      XCTAssertEqual(rig.executor.launched, 0)
    }
  }

  private func withRig(
    root: URL? = URL(fileURLWithPath: "/synthetic-parent", isDirectory: true),
    search: FolderSearchController.SearchOperation? = nil, searchProbe: ParentSearchProbe? = nil,
    _ body: @MainActor (ParentRig) async throws -> Void
  ) async throws {
    _ = NSApplication.shared
    let rig = ParentRig(root: root, search: search, searchProbe: searchProbe)
    var primary: Error?
    do { try await body(rig) } catch { primary = error }
    do { try await rig.retire() } catch {
      XCTFail("Parent contract owned cleanup failed separately: \(error)")
      ParentUnsettledResources.retain(rig)
      if primary == nil { primary = error }
    }
    if let primary { throw primary }
  }
  private func requireCurrent(_ parent: FolderSearchController) throws
    -> FolderReplacementPreviewController
  {
    let value = parent.currentPreview
    XCTAssertNotNil(value, "Desired actual owned preview before downstream guard")
    guard let value else { throw ParentContractFailure.noReach }
    return value
  }
  private func launch(_ parent: FolderSearchController) throws -> FolderReplacementPreviewController
  {
    let child = parent.showPreview()
    XCTAssertNotNil(child, "Desired real parent-created preview before downstream guard")
    guard let child else { throw ParentContractFailure.noReach }
    XCTAssertTrue(parent.currentPreview === child)
    return child
  }
  private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { descendants($0) }
  }
  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(predicate(), "Actual bounded parent/worker/search horizon was not reached")
    guard predicate() else { throw ParentContractFailure.noReach }
  }
}

private enum ParentContractFailure: Error { case noReach, missingChooser, missingJob, cleanup }

// The parent's factory retains this hook; the reverse parent edge is weak.
// Both child observations come from actual constructor/showPreview returns.
@MainActor private final class ParentFactoryReentryWeakParentHolder {
  weak var parent: FolderSearchController?
  weak var nestedChild: FolderReplacementPreviewController?
  weak var returnedToOuter: FolderReplacementPreviewController?
  private(set) var calls = 0
  private(set) var depth = 0
  private(set) var overflow = false
  func enter() -> Bool {
    guard calls < 2, depth < 2 else {
      overflow = true
      XCTFail("Factory reentry exceeded two-entry/depth budget")
      return false
    }
    calls += 1
    depth += 1
    return true
  }
  func leave() { depth -= 1 }
}

@MainActor private final class ParentRig {
  let root: URL?
  let executor: ParentHeldExecutor
  let probe: ParentWorkerProbe
  let records: ParentRecords
  let parent: FolderSearchController
  let searchProbe: ParentSearchProbe?
  var additionalParents: [FolderSearchController] = []
  var file: URL {
    (root ?? URL(fileURLWithPath: "/synthetic-parent", isDirectory: true)).appendingPathComponent(
      "a.txt")
  }
  init(root: URL?, search: FolderSearchController.SearchOperation?, searchProbe: ParentSearchProbe?)
  {
    self.root = root
    self.searchProbe = searchProbe
    let executor = ParentHeldExecutor()
    let probe = ParentWorkerProbe()
    self.executor = executor
    self.probe = probe
    let lane = FolderReplacementPreviewWorkLane(
      executor: executor,
      operation: { _, token in
        probe.record(token.isCancelled)
        return .init(operationID: UUID(), rows: [], matchCount: 0, sourceBytes: 0, outputBytes: 0)
      })
    let records = ParentRecords(lane: lane)
    self.records = records
    parent = FolderSearchController(
      root: root,
      previewFactory: { root, seed in records.make(root: root, seed: seed) },
      previewPresentation: { child in records.present(child) },
      onOpen: { request in
        XCTAssertLessThan(records.navigation.count, 2)
        if records.navigation.count < 2 { records.navigation.append(request) }
      }, search: search)
  }
  func makeAdditionalParent(root: URL?) -> FolderSearchController {
    let records = self.records
    let value = FolderSearchController(
      root: root,
      previewFactory: { root, seed in records.make(root: root, seed: seed) },
      previewPresentation: { child in records.present(child) },
      onOpen: { _ in XCTFail("Preview successor must not navigate") })
    additionalParents.append(value)
    XCTAssertLessThanOrEqual(additionalParents.count, 2)
    return value
  }
  func configure(_ child: FolderReplacementPreviewController) throws {
    let chooser = try records.chooser(for: child)
    try child.chooseFiles()
    try chooser.reply(0, [file])
    child.patternView.string = "needle"
    XCTAssertEqual(child.selectedURLs, [file])
  }
  func retire() async throws {
    for chooser in records.choosers { chooser.onCancel = nil }
    parent.close()
    for value in additionalParents { value.close() }
    for child in records.children { child.close() }
    if executor.hasPending { try executor.launch() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while records.children.contains(where: { $0.hasActiveRequest }) || executor.hasPending
      || searchProbe?.canRetireFixture == false, clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertFalse(records.children.contains(where: { $0.hasActiveRequest }))
    XCTAssertFalse(executor.hasPending)
    XCTAssertTrue(searchProbe?.canRetireFixture ?? true)
    guard !records.children.contains(where: { $0.hasActiveRequest }), !executor.hasPending,
      searchProbe?.canRetireFixture ?? true
    else { throw ParentContractFailure.cleanup }
    XCTAssertEqual(executor.submitted, executor.launched)
    XCTAssertLessThanOrEqual(records.children.count, 8)
  }
}

@MainActor private final class ParentRecords {
  let lane: FolderReplacementPreviewWorkLane
  var children: [FolderReplacementPreviewController] = []
  var choosers: [ParentChooser] = []
  var seeds: [SearchQuery?] = []
  var presented: [ObjectIdentifier] = []
  var navigation: [FolderSearchNavigationRequest] = []
  init(lane: FolderReplacementPreviewWorkLane) { self.lane = lane }
  func make(root: URL?, seed: SearchQuery?) -> FolderReplacementPreviewController {
    XCTAssertLessThan(children.count, 8, "Finite actual-child factory budget exceeded")
    if children.count >= 8, let previous = children.last { return previous }
    let chooser = ParentChooser()
    let child = FolderReplacementPreviewController(
      root: root, seedQuery: seed, lane: lane, chooser: chooser)
    children.append(child)
    choosers.append(chooser)
    seeds.append(seed)
    return child
  }
  func present(_ child: FolderReplacementPreviewController) {
    XCTAssertLessThan(presented.count, 8)
    if presented.count < 8 { presented.append(ObjectIdentifier(child)) }
    XCTAssertFalse(child.window?.isVisible ?? true)
  }
  func chooser(for child: FolderReplacementPreviewController) throws -> ParentChooser {
    guard let index = children.firstIndex(where: { $0 === child }), choosers.indices.contains(index)
    else {
      throw ParentContractFailure.missingChooser
    }
    return choosers[index]
  }
  func lastSeed() throws -> SearchQuery? {
    guard !seeds.isEmpty else { throw ParentContractFailure.noReach }
    return seeds[seeds.count - 1]
  }
}

@MainActor private final class ParentChooser: FolderReplacementPreviewChoosing {
  var onCancel: (@MainActor () -> Void)?
  private var completions: [@MainActor ([URL]?) -> Void] = []
  private(set) var cancelled: [UUID] = []
  func begin(
    kind: FolderReplacementPreviewChooserKind, seed: URL?, owner: NSWindow,
    completion: @escaping @MainActor ([URL]?) -> Void
  ) throws -> UUID {
    guard completions.count < 4 else { throw ParentContractFailure.missingChooser }
    completions.append(completion)
    return UUID()
  }
  func cancel(requestID: UUID) {
    XCTAssertLessThan(cancelled.count, 4)
    if cancelled.count < 4 { cancelled.append(requestID) }
    let action = onCancel
    onCancel = nil
    action?()
  }
  func reply(_ index: Int, _ urls: [URL]?) throws {
    guard completions.indices.contains(index) else { throw ParentContractFailure.missingChooser }
    completions[index](urls)
  }
}

private final class ParentHeldExecutor: FolderReplacementPreviewWorkExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var job: (@Sendable () -> Void)?
  private var submitCount = 0, launchCount = 0
  var submitted: Int {
    lock.lock()
    defer { lock.unlock() }
    return submitCount
  }
  var launched: Int {
    lock.lock()
    defer { lock.unlock() }
    return launchCount
  }
  var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return job != nil
  }
  func submit(_ work: @escaping @Sendable () -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard job == nil, submitCount < 4 else { throw ParentContractFailure.missingJob }
    job = work
    submitCount += 1
  }
  func launch() throws {
    lock.lock()
    let work = job
    if work != nil {
      job = nil
      launchCount += 1
    }
    lock.unlock()
    guard let work else { throw ParentContractFailure.missingJob }
    DispatchQueue.global().async { work() }
  }
}
private final class ParentWorkerProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []
  func record(_ value: Bool) {
    lock.lock()
    if storage.count < 4 { storage.append(value) }
    lock.unlock()
  }
  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
private final class ParentSearchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var expected = false, finished = false
  func expectReturn() {
    lock.lock()
    expected = true
    lock.unlock()
  }
  func didReturn() {
    lock.lock()
    finished = true
    lock.unlock()
  }
  var returned: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }
  var canRetireFixture: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !expected || finished
  }
}
@MainActor private enum ParentUnsettledResources {
  static var values: [AnyObject] = []
  static func retain(_ value: AnyObject) {
    XCTAssertLessThan(values.count, 10, "Finite unresolved parent fixture cap")
    if values.count < 10 { values.append(value) }
  }
}
private struct ParentFixtureFileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let size: off_t
}
@MainActor private final class ParentSearchFixture {
  let root: URL, file: URL
  private let expected = Data("needle\n".utf8)
  init() throws {
    let path = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation {
      p -> String? in
      guard let p, let actual = realpath(p, nil) else { return nil }
      defer { free(actual) }
      return String(validatingCString: actual)
    }
    guard let path else { throw ParentContractFailure.noReach }
    root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    file = root.appendingPathComponent("original.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    do { try expected.write(to: file) } catch {
      let primary = error
      do { try FileManager.default.removeItem(at: root) } catch {
        XCTFail("Synthetic original-search constructor cleanup failed separately: \(error)")
      }
      throw primary
    }
  }
  static func identity(of url: URL) throws -> ParentFixtureFileIdentity {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return .init(device: value.st_dev, inode: value.st_ino, size: value.st_size)
  }
  func verifyAndRemove() {
    do {
      let actual = try Data(contentsOf: file)
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      XCTAssertEqual(actual, expected)
      XCTAssertEqual(Set(entries), Set(["original.txt"]))
      try FileManager.default.removeItem(at: root)
    } catch { XCTFail("Synthetic original-search cleanup failed separately: \(error)") }
  }
}
