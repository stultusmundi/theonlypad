import AppKit
import Darwin
import PadCore
import XCTest

@testable import FolderReplacementPreviewComponent

@MainActor
final class FolderReplacementPreviewControllerTests: XCTestCase {
  func testNativeViewsDescribeReadonlyLimitsAndExposePlainLiteralInputs() throws {
    _ = NSApplication.shared
    let controller = FolderReplacementPreviewController()
    defer { controller.close() }
    XCTAssertTrue(controller.window is NSPanel)
    XCTAssertEqual(controller.window?.title, "Read-only Replacement Preview")
    XCTAssertFalse(controller.originalView.isEditable)
    XCTAssertFalse(controller.proposedView.isEditable)
    XCTAssertTrue(controller.originalView.isSelectable)
    XCTAssertTrue(controller.proposedView.isSelectable)
    for (view, id) in [
      (controller.patternView, "folderPreview.pattern"),
      (controller.replacementView, "folderPreview.replacement"),
      (controller.originalView, "folderPreview.original"),
      (controller.proposedView, "folderPreview.proposed"),
    ] {
      XCTAssertEqual(view.accessibilityIdentifier(), id)
      XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
      XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
      XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
    }
    for word in ["saved", "1–2", "UTF-8", "1 MiB", "1000", "not applied"] {
      XCTAssertTrue(controller.instructionLabel.stringValue.contains(word), word)
    }
    XCTAssertEqual(controller.previewButton.accessibilityIdentifier(), "folderPreview.preview")
    XCTAssertEqual(controller.cancelButton.accessibilityIdentifier(), "folderPreview.cancel")
    let titles = buttons(in: controller.window?.contentView).map(\.title)
    XCTAssertFalse(titles.contains { $0.lowercased().contains("apply") })
    XCTAssertTrue(titles.contains("Preview"))
    XCTAssertTrue(titles.contains("Close"))
    XCTAssertFalse(controller.window?.isVisible ?? true)
  }

  func testLiteralSeedOptionsPreservedAndRegexSeedNeverReinterpreted() throws {
    _ = NSApplication.shared
    let literal = FolderReplacementPreviewController(
      seedQuery: .init(
        pattern: " e\u{301}\r\n😀 ", mode: .literal, caseSensitive: false, wholeWord: true))
    let regex = FolderReplacementPreviewController(
      seedQuery: .init(pattern: "(needle)+", mode: .regex))
    defer {
      literal.close()
      regex.close()
    }
    XCTAssertEqual(Data(literal.patternView.string.utf8), Data(" e\u{301}\r\n😀 ".utf8))
    XCTAssertEqual(literal.caseButton.state, .off)
    XCTAssertEqual(literal.wholeWordButton.state, .on)
    XCTAssertEqual(regex.patternView.string, "")
    XCTAssertTrue(regex.statusLabel.stringValue.lowercased().contains("literal"))
  }

  func testCancelledChooserPreservesInputsNewRootClearsAndThreeFilesRefusesWithoutTruncation()
    throws
  {
    _ = NSApplication.shared
    let picker = HeldPanelChooser()
    let controller = FolderReplacementPreviewController(root: root, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    try picker.reply(0, [fileA, fileB])
    XCTAssertEqual(controller.selectedURLs, [fileA, fileB])
    try controller.chooseFiles()
    try picker.reply(1, nil)
    XCTAssertEqual(controller.selectedURLs, [fileA, fileB])
    try controller.chooseFiles()
    try picker.reply(2, [fileA, fileB, root.appendingPathComponent("c")])
    XCTAssertEqual(controller.selectedURLs, [])
    XCTAssertNil(controller.display)
    XCTAssertTrue(controller.statusLabel.stringValue.contains("1 or 2"))
    try controller.chooseFiles()
    try picker.reply(3, [fileA])
    try controller.chooseFolder()
    let newRoot = URL(fileURLWithPath: "/synthetic-new-root", isDirectory: true)
    try picker.reply(4, [newRoot])
    XCTAssertEqual(controller.rootURL, newRoot)
    XCTAssertTrue(controller.selectedURLs.isEmpty)
    // Duplicate old accepted chooser callback cannot retarget a new root.
    try picker.reply(3, [fileB])
    XCTAssertTrue(controller.selectedURLs.isEmpty)
    XCTAssertEqual(picker.kinds, [.files, .files, .files, .files, .folder])
    XCTAssertEqual(picker.seeds, [root, root, root, root, root])
  }

  func testInputAdmissionPreservesRawURLsWhitespaceLiteralAndCheckboxes() async throws {
    _ = NSApplication.shared
    let picker = HeldPanelChooser()
    let executor = HeldPanelExecutor()
    let recorder = PanelInputRecorder()
    let lane = FolderReplacementPreviewWorkLane(
      executor: executor,
      operation: { input, _ in
        recorder.record(input)
        return Self.stub()
      })
    let unsafe = URL(fileURLWithPath: "/synthetic-root/alias/../needle")
    let controller = FolderReplacementPreviewController(root: root, lane: lane, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    try picker.reply(0, [unsafe])
    controller.patternView.string = ""
    XCTAssertFalse(try controller.preview())
    XCTAssertEqual(executor.count, 0)
    controller.patternView.string = String(repeating: "😀", count: 1025)
    XCTAssertFalse(try controller.preview())
    controller.patternView.string = " "
    controller.replacementView.string = String(repeating: "x", count: 4097)
    XCTAssertFalse(try controller.preview())
    controller.replacementView.string = #"$1$&\n"#
    controller.caseButton.state = .off
    controller.wholeWordButton.state = .on
    XCTAssertTrue(try controller.preview())
    let retired = expectation(description: "raw literal input delivered and retired")
    var observed = false
    controller.onRefresh = {
      if controller.phase == .ready && controller.previewButton.isEnabled && !observed {
        observed = true
        retired.fulfill()
      }
    }
    XCTAssertEqual(controller.selectedURLs, [unsafe])
    XCTAssertEqual(executor.count, 1)
    XCTAssertEqual(Data(controller.patternView.string.utf8), Data([0x20]))
    XCTAssertEqual(
      Data(controller.replacementView.string.utf8), Data([0x24, 0x31, 0x24, 0x26, 0x5c, 0x6e]))
    try executor.launch()
    await fulfillment(of: [retired], timeout: 5)
    let captured = recorder.snapshot
    XCTAssertEqual(captured?.root, root)
    XCTAssertEqual(captured?.files, [unsafe])
    XCTAssertEqual(captured?.query.pattern, " ")
    if let captured {
      guard case .literal = captured.query.mode else { return XCTFail("Not literal") }
    }
    XCTAssertEqual(captured?.query.caseSensitive, false)
    XCTAssertEqual(captured?.query.wholeWord, true)
    XCTAssertEqual(captured?.replacement, #"$1$&\n"#)
  }

  func testActualCoreSavedBytesDisplayLiteralReplacementAndDeletionWithoutWrites() async throws {
    _ = NSApplication.shared
    let fixture = try PanelFixture()
    defer {
      fixture.verify()
      fixture.cleanup()
    }
    let picker = HeldPanelChooser()
    let controller = FolderReplacementPreviewController(root: fixture.root, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    try picker.reply(0, [fixture.file])
    controller.patternView.string = "needle"
    controller.replacementView.string = #"$1$&\n"#
    let ready = expectation(description: "actual Core literal presentation")
    var observed = false
    controller.onRefresh = {
      if controller.phase == .ready && controller.previewButton.isEnabled && !observed {
        observed = true
        ready.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [ready], timeout: 5)
    guard let display = controller.display, let row = display.rows.first else {
      return XCTFail("Missing real saved-file preview")
    }
    XCTAssertEqual(row.sourceBytes, 18)
    XCTAssertEqual(row.outputBytes, 18)
    XCTAssertEqual(row.matches, 1)
    XCTAssertTrue(row.hasBOM)
    XCTAssertTrue(row.wouldChange)
    XCTAssertEqual(Data(controller.originalView.string.utf8), Data("e\u{301}\r\n😀needle".utf8))
    XCTAssertEqual(Data(controller.proposedView.string.utf8), Data("e\u{301}\r\n😀$1$&\\n".utf8))
    XCTAssertEqual(row.proposedAnchorUTF16, 6)
    XCTAssertTrue(controller.summaryLabel.stringValue.contains("1"))
    fixture.verify()
    controller.replacementView.string = ""
    try controller.inputsDidChange()
    let deleted = expectation(description: "actual Core deletion")
    var observedDeletion = false
    controller.onRefresh = {
      if controller.phase == .ready && controller.previewButton.isEnabled && !observedDeletion {
        observedDeletion = true
        deleted.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [deleted], timeout: 5)
    XCTAssertEqual(controller.display?.rows.first?.outputBytes, 12)
    XCTAssertEqual(controller.display?.rows.first?.proposedAnchorUTF16, 6)
    XCTAssertEqual(Data(controller.proposedView.string.utf8), Data("e\u{301}\r\n😀".utf8))
    XCTAssertTrue(controller.excerptLabel.stringValue.lowercased().contains("replacement"))
    controller.replacementView.string = "needle"
    try controller.inputsDidChange()
    let equal = expectation(description: "matches without byte changes")
    var observedEqual = false
    controller.onRefresh = {
      if controller.phase == .ready && controller.previewButton.isEnabled && !observedEqual {
        observedEqual = true
        equal.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [equal], timeout: 5)
    XCTAssertEqual(controller.display?.matchCount, 1)
    XCTAssertEqual(controller.display?.rows.first?.wouldChange, false)
    XCTAssertEqual(controller.display?.sourceBytes, 18)
    XCTAssertEqual(controller.display?.outputBytes, 18)
    XCTAssertEqual(Data(controller.proposedView.string.utf8), Data("e\u{301}\r\n😀needle".utf8))
  }

  func testSharedLaneBusyRefusesAndCancelUnfreezesOnlyAfterExactSettlement() async throws {
    _ = NSApplication.shared
    let executor = HeldPanelExecutor()
    let lane = FolderReplacementPreviewWorkLane(
      executor: executor,
      operation: { _, token in
        if token.isCancelled { throw FolderReplacementPreviewError.cancelled }
        return Self.stub()
      })
    let a = try configured(lane: lane)
    let b = try configured(lane: lane)
    defer {
      a.close()
      b.close()
    }
    XCTAssertTrue(a.workLane === b.workLane)
    XCTAssertTrue(try a.preview())
    XCTAssertFalse(try b.preview())
    XCTAssertEqual(executor.count, 1)
    XCTAssertTrue(b.previewButton.isEnabled)
    XCTAssertTrue(b.statusLabel.stringValue.lowercased().contains("busy"))
    XCTAssertFalse(a.patternView.isEditable)
    XCTAssertFalse(a.replacementView.isEditable)
    try a.cancelPreview()
    XCTAssertEqual(a.phase, .cancelRequested)
    XCTAssertFalse(a.previewButton.isEnabled)
    XCTAssertNil(a.display)
    XCTAssertFalse(try b.preview())
    let settled = expectation(description: "live cancelled panel unfreezes")
    var observed = false
    a.onRefresh = {
      if a.phase == .inputReady && a.previewButton.isEnabled && !observed {
        observed = true
        settled.fulfill()
      }
    }
    try executor.launch()
    await fulfillment(of: [settled], timeout: 5)
    XCTAssertTrue(a.patternView.isEditable)
    XCTAssertNil(a.display)
    XCTAssertTrue(try b.preview())
    try b.cancelPreview()
    try executor.launch()
    try await waitForRetirement(b)
    let defaultA = FolderReplacementPreviewController()
    let defaultB = FolderReplacementPreviewController()
    defer {
      defaultA.close()
      defaultB.close()
    }
    XCTAssertTrue(defaultA.workLane === defaultB.workLane)
  }

  func testProgrammaticInputInvalidationFencesLateSuccessAndError() async throws {
    _ = NSApplication.shared
    for failure in [false, true] {
      let executor = HeldPanelExecutor()
      let lane = FolderReplacementPreviewWorkLane(
        executor: executor,
        operation: { _, _ in
          if failure { throw NSError(domain: "SyntheticLatePanelFailure", code: 17) }
          return Self.stub()
        })
      let controller = try configured(lane: lane)
      defer { controller.close() }
      XCTAssertTrue(try controller.preview())
      controller.patternView.string = "new literal"
      try controller.inputsDidChange()
      XCTAssertEqual(controller.phase, .cancelRequested)
      let done = expectation(description: "invalidated request retires")
      var observed = false
      controller.onRefresh = {
        if controller.phase == .inputReady && controller.previewButton.isEnabled && !observed {
          observed = true
          done.fulfill()
        }
      }
      try executor.launch()
      await fulfillment(of: [done], timeout: 5)
      XCTAssertNil(controller.display)
      XCTAssertEqual(controller.patternView.string, "new literal")
      XCTAssertEqual(controller.originalView.string, "")
      XCTAssertEqual(controller.proposedView.string, "")
      XCTAssertFalse(controller.statusLabel.stringValue.contains("SyntheticLatePanelFailure"))
    }
  }

  func testParentAndDelegateCloseFenceChooserAndWorkWithoutReopening() async throws {
    _ = NSApplication.shared
    for delegateClose in [false, true] {
      let picker = HeldPanelChooser()
      let executor = HeldPanelExecutor()
      let controller = try configured(
        lane: FolderReplacementPreviewWorkLane(
          executor: executor, operation: { _, _ in Self.stub() }), chooser: picker)
      var closes = 0
      controller.onClose = { closes += 1 }
      XCTAssertTrue(try controller.preview())
      XCTAssertTrue(controller.hasActiveRequest)
      var lateRefreshes = 0
      controller.onRefresh = { lateRefreshes += 1 }
      if delegateClose {
        controller.windowWillClose(
          Notification(name: NSWindow.willCloseNotification, object: controller.window))
      } else {
        try controller.parentInvalidated()
      }
      controller.close()
      XCTAssertTrue(controller.isClosed)
      XCTAssertEqual(controller.phase, .closed)
      XCTAssertEqual(closes, 1)
      try executor.launch()
      try await waitForRetirement(controller)
      XCTAssertEqual(lateRefreshes, 0)
      XCTAssertTrue(controller.isClosed)
      XCTAssertNil(controller.display)
      XCTAssertFalse(controller.window?.isVisible ?? true)
    }
    let picker = HeldPanelChooser()
    let controller = FolderReplacementPreviewController(root: root, chooser: picker)
    try controller.chooseFiles()
    try controller.parentInvalidated()
    let pendingChooserID = try picker.id(at: 0)
    XCTAssertEqual(picker.cancelled, [pendingChooserID])
    try picker.reply(0, [fileA])
    XCTAssertTrue(controller.selectedURLs.isEmpty)
    XCTAssertTrue(controller.isClosed)
  }

  func testReadyRowsShowExactFactsBoundedExcerptsAndNoMatchEqualIsNotChanged() async throws {
    _ = NSApplication.shared
    let rows = [
      Self.row(path: "a", count: 4, changed: true, original: "before", proposed: "after"),
      Self.row(path: "b", count: 0, changed: false, original: "unchanged", proposed: "unchanged"),
    ]
    let controller = try configured(
      lane: FolderReplacementPreviewWorkLane(operation: { _, _ in
        .init(
          operationID: UUID(), rows: rows, matchCount: 4, sourceBytes: 200_000, outputBytes: 199_999
        )
      }))
    defer { controller.close() }
    let done = expectation(description: "injected primitive display")
    var observed = false
    controller.onRefresh = {
      if controller.phase == .ready && controller.previewButton.isEnabled && !observed {
        observed = true
        done.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(controller.resultsTable.numberOfRows, 2)
    XCTAssertEqual(controller.display?.sourceBytes, 200_000)
    XCTAssertEqual(controller.display?.outputBytes, 199_999)
    XCTAssertTrue(controller.summaryLabel.stringValue.contains("4 matches"))
    XCTAssertTrue(controller.summaryLabel.stringValue.contains("1 file"))
    XCTAssertTrue(controller.excerptLabel.stringValue.lowercased().contains("excerpt"))
    XCTAssertTrue(controller.excerptLabel.stringValue.lowercased().contains("outside"))
    try controller.selectResult(at: 1)
    XCTAssertEqual(controller.originalView.string, "unchanged")
    XCTAssertEqual(controller.proposedView.string, "unchanged")
    guard let presented = controller.display, presented.rows.indices.contains(1) else {
      return XCTFail("Missing second complete presentation row")
    }
    let secondRow = presented.rows[1]
    XCTAssertNil(secondRow.proposedAnchorUTF16)
    XCTAssertFalse(controller.originalView.isEditable)
    XCTAssertFalse(controller.proposedView.isEditable)
  }

  func testActualUnsafeAliasErrorShowsNoPartialRowsAndDoesNotMutateFiles() async throws {
    _ = NSApplication.shared
    let fixture = try PanelFixture()
    defer {
      fixture.verify()
      fixture.cleanup()
    }
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.file)
    try fixture.expectAlias(alias)
    let picker = HeldPanelChooser()
    let controller = FolderReplacementPreviewController(root: fixture.root, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    try picker.reply(0, [fixture.file, alias])
    controller.patternView.string = "needle"
    let failed = expectation(description: "actual unsafe second input refuses")
    var observed = false
    controller.onRefresh = {
      if controller.phase == .failed && controller.previewButton.isEnabled && !observed {
        observed = true
        failed.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [failed], timeout: 5)
    XCTAssertNil(controller.display)
    XCTAssertEqual(controller.resultsTable.numberOfRows, 0)
    XCTAssertEqual(controller.originalView.string, "")
    XCTAssertEqual(controller.proposedView.string, "")
    XCTAssertTrue(controller.statusLabel.stringValue.contains("unsupportedInput"))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), fixture.file.path)
  }

  // S1: exact caller authority must be rechecked after external chooser.cancel reentry.
  func testChooserCancellationReentryClosePreventsOuterBegin() throws {
    _ = NSApplication.shared
    let picker = ReentryPanelChooser()
    let controller = FolderReplacementPreviewController(root: root, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    picker.onCancel = { controller.close() }
    try controller.chooseFolder()
    XCTAssertTrue(controller.isClosed)
    XCTAssertEqual(picker.kinds, [.files])
    XCTAssertEqual(picker.cancelled.count, 1)
    XCTAssertFalse(controller.window?.isVisible ?? true)
  }

  func testChooserCancellationSuccessorChooserWinsOverOuterBegin() throws {
    _ = NSApplication.shared
    let picker = ReentryPanelChooser()
    let controller = FolderReplacementPreviewController(root: root, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    picker.onCancel = {
      do { try controller.chooseFiles() } catch { XCTFail("Successor chooser failed: \(error)") }
    }
    try controller.chooseFolder()
    XCTAssertEqual(picker.kinds, [.files, .files])
    try picker.reply(1, [fileB])
    XCTAssertEqual(controller.selectedURLs, [fileB])
    XCTAssertEqual(controller.rootURL, root)
  }

  func testInputInvalidationCancellationReentryCannotCancelNewOwnedWork() async throws {
    _ = NSApplication.shared
    let picker = ReentryPanelChooser()
    let executor = HeldPanelExecutor()
    let probe = PanelCancellationProbe()
    let lane = FolderReplacementPreviewWorkLane(
      executor: executor,
      operation: { _, token in
        probe.record(token.isCancelled)
        return Self.stub()
      })
    let controller = FolderReplacementPreviewController(root: root, lane: lane, chooser: picker)
    defer { controller.close() }
    try controller.chooseFiles()
    try picker.reply(0, [fileA])
    controller.patternView.string = "needle"
    try controller.chooseFiles()
    picker.onCancel = {
      do {
        let admitted = try controller.preview()
        XCTAssertTrue(admitted)
      } catch { XCTFail("New work admission failed: \(error)") }
    }
    try controller.inputsDidChange()
    XCTAssertEqual(executor.count, 1)
    XCTAssertTrue(controller.hasActiveRequest)
    XCTAssertEqual(controller.phase, .running)
    XCTAssertEqual(controller.statusLabel.stringValue, "Preparing preview…")
    let retired = expectation(description: "successor work really settles")
    var observed = false
    controller.onRefresh = {
      if !controller.hasActiveRequest && !observed {
        observed = true
        retired.fulfill()
      }
    }
    try executor.launch()
    await fulfillment(of: [retired], timeout: 5)
    XCTAssertEqual(probe.values, [false])
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertNotNil(controller.display)
  }

  // S2: completion may start new work before the older begin returns by throwing.
  func testCompletedChooserThenThrowCannotOverwriteSuccessorWorkPresentation() async throws {
    _ = NSApplication.shared
    let picker = ReentryPanelChooser()
    let executor = HeldPanelExecutor()
    let controller = FolderReplacementPreviewController(
      root: root,
      lane: FolderReplacementPreviewWorkLane(
        executor: executor, operation: { _, _ in Self.stub() }),
      chooser: picker)
    defer { controller.close() }
    controller.patternView.string = "needle"
    picker.onBegin = { completion in
      completion([self.fileA])
      throw NSError(domain: "SyntheticOlderBeginFailure", code: 47)
    }
    controller.onRefresh = {
      controller.onRefresh = nil
      do {
        let admitted = try controller.preview()
        XCTAssertTrue(admitted)
      } catch { XCTFail("Successor work failed: \(error)") }
    }
    XCTAssertThrowsError(try controller.chooseFiles()) {
      XCTAssertEqual(($0 as NSError).domain, "SyntheticOlderBeginFailure")
      XCTAssertEqual(($0 as NSError).code, 47)
    }
    XCTAssertEqual(picker.kinds, [.files])
    XCTAssertEqual(executor.count, 1)
    XCTAssertEqual(controller.phase, .running)
    XCTAssertEqual(controller.statusLabel.stringValue, "Preparing preview…")
    XCTAssertTrue(controller.hasActiveRequest)
    let retired = expectation(description: "new work after older throwing begin settles")
    var observed = false
    controller.onRefresh = {
      if !controller.hasActiveRequest && !observed {
        observed = true
        retired.fulfill()
      }
    }
    try executor.launch()
    await fulfillment(of: [retired], timeout: 5)
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertNotNil(controller.display)
  }

  // S3: visible fact-row selection and the viewers must describe the same selected row.
  func testDirectValidResultSelectionUpdatesActualTableSelection() async throws {
    _ = NSApplication.shared
    let controller = try await selectionReadyController()
    defer { controller.close() }
    XCTAssertEqual(controller.resultsTable.selectedRow, 0)
    try controller.selectResult(at: 1)
    XCTAssertEqual(controller.resultsTable.selectedRow, 1)
    XCTAssertEqual(controller.originalView.string, "second original")
    XCTAssertEqual(controller.proposedView.string, "second proposed")
  }

  func testDirectInvalidResultSelectionDeselectsTableAndClearsViews() async throws {
    _ = NSApplication.shared
    let controller = try await selectionReadyController()
    defer { controller.close() }
    XCTAssertEqual(controller.resultsTable.selectedRow, 0)
    try controller.selectResult(at: -1)
    XCTAssertEqual(controller.resultsTable.selectedRow, -1)
    XCTAssertEqual(controller.resultsTable.selectedRowIndexes, IndexSet())
    XCTAssertEqual(controller.originalView.string, "")
    XCTAssertEqual(controller.proposedView.string, "")
    XCTAssertEqual(controller.excerptLabel.stringValue, "")
    XCTAssertEqual(controller.display?.rows.count, 2)
    XCTAssertEqual(controller.resultsTable.numberOfRows, 2)
  }

  private func selectionReadyController() async throws -> FolderReplacementPreviewController {
    let rows = [
      Self.row(
        path: "first", count: 1, changed: true, original: "first original",
        proposed: "first proposed"),
      Self.row(
        path: "second", count: 1, changed: true, original: "second original",
        proposed: "second proposed"),
    ]
    let controller = try configured(
      lane: FolderReplacementPreviewWorkLane(operation: { _, _ in
        .init(
          operationID: UUID(), rows: rows, matchCount: 2, sourceBytes: 200_000, outputBytes: 199_998
        )
      }))
    let ready = expectation(description: "two primitive rows ready for actual native selection")
    var observed = false
    controller.onRefresh = {
      if controller.phase == .ready && !controller.hasActiveRequest && !observed {
        observed = true
        ready.fulfill()
      }
    }
    XCTAssertTrue(try controller.preview())
    await fulfillment(of: [ready], timeout: 5)
    return controller
  }

  private func waitForRetirement(_ controller: FolderReplacementPreviewController) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while controller.hasActiveRequest && clock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertFalse(controller.hasActiveRequest, "Exact worker settlement did not retire ownership")
  }

  private var root: URL { URL(fileURLWithPath: "/synthetic-root", isDirectory: true) }
  private var fileA: URL { root.appendingPathComponent("a.txt") }
  private var fileB: URL { root.appendingPathComponent("b.txt") }

  private func configured(lane: FolderReplacementPreviewWorkLane, chooser: HeldPanelChooser? = nil)
    throws
    -> FolderReplacementPreviewController
  {
    let picker = chooser ?? HeldPanelChooser()
    let controller = FolderReplacementPreviewController(root: root, lane: lane, chooser: picker)
    try controller.chooseFiles()
    try picker.reply(0, [fileA])
    controller.patternView.string = "needle"
    return controller
  }

  private func buttons(in view: NSView?) -> [NSButton] {
    guard let view else { return [] }
    return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
  }

  nonisolated private static func stub() -> FolderReplacementPreviewDisplay {
    .init(operationID: UUID(), rows: [], matchCount: 0, sourceBytes: 0, outputBytes: 0)
  }
  nonisolated private static func row(
    path: String, count: Int, changed: Bool, original: String, proposed: String
  )
    -> FolderReplacementPreviewRow
  {
    .init(
      path: path, matches: count, sourceBytes: 100_000, outputBytes: changed ? 99_999 : 100_000,
      hasBOM: false, wouldChange: changed, originalExcerpt: original, proposedExcerpt: proposed,
      originalExcerptRange: NSRange(location: 20, length: original.utf16.count),
      proposedExcerptRange: NSRange(location: 20, length: proposed.utf16.count),
      originalMatchRange: count == 0 ? nil : NSRange(location: 20, length: 6),
      proposedAnchorUTF16: count == 0 ? nil : 20, excerptIsLimited: true)
  }
}

@MainActor
private final class HeldPanelChooser: FolderReplacementPreviewChoosing {
  var ids: [UUID] = []
  var kinds: [FolderReplacementPreviewChooserKind] = []
  var seeds: [URL?] = []
  var cancelled: [UUID] = []
  private var completions: [@MainActor ([URL]?) -> Void] = []
  func begin(
    kind: FolderReplacementPreviewChooserKind, seed: URL?, owner: NSWindow,
    completion: @escaping @MainActor ([URL]?) -> Void
  ) throws -> UUID {
    let id = UUID()
    ids.append(id)
    kinds.append(kind)
    seeds.append(seed)
    completions.append(completion)
    return id
  }
  func cancel(requestID: UUID) { cancelled.append(requestID) }
  func id(at index: Int) throws -> UUID {
    guard ids.indices.contains(index) else {
      throw NSError(domain: "SyntheticPanelMissingChooserID", code: index)
    }
    return ids[index]
  }
  func reply(_ index: Int, _ urls: [URL]?) throws {
    guard completions.indices.contains(index) else {
      throw NSError(domain: "SyntheticPanelMissingChooserCompletion", code: index)
    }
    completions[index](urls)
  }
}

private final class HeldPanelExecutor: FolderReplacementPreviewWorkExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var job: (@Sendable () -> Void)?
  private var submitted = 0
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return submitted
  }
  func submit(_ work: @escaping @Sendable () -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    guard job == nil else { throw NSError(domain: "SyntheticPanelExecutorBusy", code: 1) }
    job = work
    submitted += 1
  }
  func launch() throws {
    lock.lock()
    let work = job
    job = nil
    lock.unlock()
    guard let work else { throw NSError(domain: "SyntheticPanelMissingJob", code: 1) }
    DispatchQueue.global().async { work() }
  }
}

private final class PanelInputRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var input: FolderReplacementPreviewInput?
  func record(_ value: FolderReplacementPreviewInput) {
    lock.lock()
    input = value
    lock.unlock()
  }
  var snapshot: FolderReplacementPreviewInput? {
    lock.lock()
    defer { lock.unlock() }
    return input
  }
}

@MainActor
private final class PanelFixture {
  let root: URL
  let file: URL
  private let sentinel: URL
  private let bytes = Data([0xef, 0xbb, 0xbf] + Array("e\u{301}\r\n😀needle".utf8))
  private let sentinelBytes = Data([0x00, 0xff, 0x42])
  private var expectedMetadata: [String: [Int64]] = [:]
  private var aliasTargets: [String: String] = [:]
  init() throws {
    let canonical = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation {
      pointer -> String? in
      guard let pointer, let resolved = realpath(pointer, nil) else { return nil }
      defer { free(resolved) }
      return String(validatingCString: resolved)
    }
    guard let canonical else { throw NSError(domain: "SyntheticPanelRealpathFailure", code: 1) }
    root = URL(fileURLWithPath: canonical, isDirectory: true).appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    file = root.appendingPathComponent("sample.txt")
    sentinel = root.appendingPathComponent("sentinel.backup")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try bytes.write(to: file)
    try sentinelBytes.write(to: sentinel)
    expectedMetadata = [
      file.lastPathComponent: try metadata(file),
      sentinel.lastPathComponent: try metadata(sentinel),
    ]
  }
  func expectAlias(_ url: URL) throws {
    expectedMetadata[url.lastPathComponent] = try metadata(url)
    aliasTargets[url.lastPathComponent] = try FileManager.default.destinationOfSymbolicLink(
      atPath: url.path)
  }
  private func metadata(_ url: URL) throws -> [Int64] {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return [
      Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_mode), Int64(value.st_size),
      Int64(value.st_nlink), Int64(value.st_uid), Int64(value.st_gid),
      Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
      Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec),
    ]
  }
  func verify() {
    do {
      let actualFile = try Data(contentsOf: file)
      let actualSentinel = try Data(contentsOf: sentinel)
      let actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
      XCTAssertEqual(actualFile, bytes)
      XCTAssertEqual(actualSentinel, sentinelBytes)
      XCTAssertEqual(actualNames, Set(expectedMetadata.keys))
      for (name, signature) in expectedMetadata {
        let url = root.appendingPathComponent(name)
        let actualMetadata = try metadata(url)
        XCTAssertEqual(actualMetadata, signature)
        if let target = aliasTargets[name] {
          let actualTarget = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
          XCTAssertEqual(actualTarget, target)
        }
      }
    } catch { XCTFail("Synthetic panel inventory failed: \(error)") }
  }
  func cleanup() {
    do { try FileManager.default.removeItem(at: root) } catch {
      XCTFail("Synthetic panel cleanup failed: \(error)")
    }
  }
}

// Injected chooser callout-order collaborator only; does not imitate SDK completion/permission.
@MainActor
private final class ReentryPanelChooser: FolderReplacementPreviewChoosing {
  private(set) var kinds: [FolderReplacementPreviewChooserKind] = []
  private(set) var cancelled: [UUID] = []
  private var completions: [@MainActor ([URL]?) -> Void] = []
  var onCancel: (@MainActor () -> Void)?
  var onBegin: (@MainActor (@escaping @MainActor ([URL]?) -> Void) throws -> Void)?

  func begin(
    kind: FolderReplacementPreviewChooserKind, seed: URL?, owner: NSWindow,
    completion: @escaping @MainActor ([URL]?) -> Void
  ) throws -> UUID {
    let id = UUID()
    kinds.append(kind)
    completions.append(completion)
    let action = onBegin
    onBegin = nil
    try action?(completion)
    return id
  }
  func cancel(requestID: UUID) {
    cancelled.append(requestID)
    let action = onCancel
    onCancel = nil
    action?()
  }
  func reply(_ index: Int, _ urls: [URL]?) throws {
    guard completions.indices.contains(index) else {
      throw NSError(domain: "SyntheticReentryMissingChooserCompletion", code: index)
    }
    completions[index](urls)
  }
}

private final class PanelCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Bool] = []
  func record(_ value: Bool) {
    lock.lock()
    recorded.append(value)
    lock.unlock()
  }
  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
