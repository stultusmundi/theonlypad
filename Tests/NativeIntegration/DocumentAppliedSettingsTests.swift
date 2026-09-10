import AppKit
import PadCore
import XCTest

@testable import NativeRouting

// NATIVE-ACCESS-BEGIN
@MainActor enum AppliedSettingsProbe {
  static var fontWrites = 0
  static var paragraphWrites = 0
  static var typingWrites = 0
  static var beforeWrap: ((DocumentTextView) -> Void)?
  static var beforeFont: ((DocumentTextView) -> Void)?
}
extension EditorWindowController {
  func appliedTestLiveOrigins(_ receipt: NativeDocumentTransferViewReceipt, model: EditorDocument)
    -> NativeDocumentTransferViewReceipt
  {
    transferViewWithLiveOrigins(receipt, model: model)
  }
  func appliedTestConstrained(_ receipt: NativeDocumentTransferViewReceipt, model: EditorDocument)
    -> NativeDocumentTransferViewReceipt
  {
    constrainedTransferView(receipt, model: model)
  }
  func appliedTestReplacement(_ receipt: EditorTransferEndpointReceipt)
    -> EditorTransferEndpointReceipt
  {
    replacementTransferReceipt(receipt, endpointID: UUID())
  }
  func appliedTestToggleWrap() { toggleWrap() }
  func appliedTestInstall(_ presentation: SessionPresentation, document: EditorDocument) throws {
    try installResolvedPanes(presentation, on: document)
  }
}
// NATIVE-ACCESS-END

@MainActor private final class AppliedSettingsFixture {
  let registry: ApplicationDocuments
  let recovery: RecoveryCoordinator
  let source = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let target = DocumentAssignment(windowID: UUID(), groupID: UUID())
  let sourceID = UUID(), targetID = UUID()
  var first: EditorWindowController!
  var second: EditorWindowController!
  var sourceCheck: (() throws -> Void)?
  var userReady = true
  var detached = 0
  var onDetach: ((EditorDocument) -> Void)?
  var liveEndpoints: [UUID: UUID] = [:]
  var reattachCalls = 0
  var lastAttachmentContext: (() -> FileStateLiveContext?)?
  let idle = NativeDocumentTransferPreparation(
    loading: false, macroWork: false,
    applicationPreparation: false, preparingQuit: false)
  init() throws {
    _ = NSApplication.shared
    recovery = RecoveryCoordinator(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    registry = ApplicationDocuments(
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { h in
          let m = h as! EditorDocument
          return .init(
            documentID: m.id, ownershipGeneration: m.ownershipGeneration,
            authority: m.recoveryAuthority, highestIssuedRevision: m.highestIssuedRecoveryRevision)
        }),
      transferServices: .init(
        rotateOwnership: { h in
          let p = (h as! EditorDocument).rotateTransferOwnership()
          return .init(
            ownershipGeneration: p.ownershipGeneration, mutationGeneration: p.mutationGeneration)
        },
        readState: { h in
          try (h as! EditorDocument).captureTransferState(
            preparation:
              .init(
                loading: false, macroWork: false, applicationPreparation: false,
                preparingQuit: false))
        }))
    for a in [source, target] {
      try registry.registerWindow(id: a.windowID, initialGroupID: a.groupID)
    }
    first = try endpoint(source, sourceID)
    second = try endpoint(target, targetID)
  }
  func endpoint(_ a: DocumentAssignment, _ id: UUID) throws -> EditorWindowController {
    liveEndpoints[a.windowID] = id
    let routing = EditorApplicationRouting(
      endpointID: id, assignment: a, registry: registry,
      requireEndpointCurrent: { if a == self.source { try self.sourceCheck?() } },
      requireUserAdmission: { if !self.userReady { throw DocumentTransferError.unavailable } },
      submit: { _ in throw DocumentTransferError.unavailable },
      wait: { _ in throw DocumentTransferError.unavailable },
      requestClose: { _ in throw DocumentTransferError.unavailable },
      requestReopen: { throw DocumentTransferError.unavailable },
      detachDocumentEndpoint: { model in
        self.onDetach?(model)
        self.detached += 1
        throw DocumentTransferError.unavailable
      },
      reattachDocumentEndpoint: { _, context, _ in
        self.lastAttachmentContext = context
        _ = context()
        self.reattachCalls += 1
        throw DocumentTransferError.unavailable
      },
      endpointClosed: { _ in }, requestCheckpoint: {})
    return try EditorWindowController(id: a.windowID, application: routing, onError: { _ in })
  }
  func add(_ a: DocumentAssignment, text: String, select: Bool = true) async throws
    -> EditorDocument
  {
    let m = EditorDocument()
    m.storage.mutableString.setString(text)
    let ticket = try registry.registerPending(
      m, requestID: UUID(), expectedRevision: registry.workspaceRevision,
      metadata: .init(pinned: false), in: a,
      at: registry.window(id: a.windowID)!.groups[0].documentIDs.count, select: select)
    let adoption = try await recovery.adoptManagedDocument(id: m.id)
    try m.installRecoveryAdoption(adoption, expectedOwnershipGeneration: m.ownershipGeneration)
    try registry.activateAdoption(ticket, receipt: adoption)
    return m
  }
  func project() throws {
    try first.applyRegistryProjection(
      registry.window(id: source.windowID)!, revision: registry.workspaceRevision,
      endpointID: sourceID)
    try second.applyRegistryProjection(
      registry.window(id: target.windowID)!, revision: registry.workspaceRevision,
      endpointID: targetID)
  }
  func reserve(_ m: EditorDocument) throws -> DocumentTransferLease {
    try registry.reserveTransfer(
      .init(
        documentID: m.id, source: source, target: target, targetIndex: 0,
        workspaceRevision: registry.workspaceRevision, ownershipGeneration: m.ownershipGeneration))
  }
}
@MainActor final class DocumentAppliedSettingsTests: XCTestCase {
  override func tearDown() {
    MainActor.assumeIsolated {
      AppliedSettingsProbe.beforeFont = nil
      AppliedSettingsProbe.beforeWrap = nil
      AppliedSettingsProbe.fontWrites = 0
    }
    super.tearDown()
  }
  func testUnchangedAndThemeOnlySettingsAvoidNativeTypographyWrites() async throws {
    try await verifyOriginPreservation(applySettings: true)
  }
  func testNoSettingsControlPreservesEstablishedOriginsThroughNextQueueTurn() async throws {
    try await verifyOriginPreservation(applySettings: false)
  }
  private func verifyOriginPreservation(applySettings: Bool) async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: String(repeating: "synthetic line\n", count: 3000))
    _ = try model.makePane()
    try f.project()
    f.first.applySettings(.defaults)
    // This correctness fixture deliberately lays out its small synthetic text; it is not a cost probe.
    for pane in model.panePool { pane.layoutManager.ensureLayout(for: pane.textContainer) }
    for (index, pane) in model.panePool.enumerated() {
      pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: index == 0 ? 240 : 940))
    }
    let origins = model.panePool.map { $0.scroll.contentView.bounds.origin }
    XCTAssertEqual(origins.map(\.y), [240, 940])
    AppliedSettingsProbe.fontWrites = 0
    AppliedSettingsProbe.paragraphWrites = 0
    AppliedSettingsProbe.typingWrites = 0
    if applySettings {
      f.first.applySettings(.defaults)
      f.first.applySettings(EditorSettings(theme: .dark))
    }
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
    XCTAssertEqual(AppliedSettingsProbe.paragraphWrites, 0)
    XCTAssertEqual(AppliedSettingsProbe.typingWrites, 0)
    XCTAssertEqual(model.panePool.map { $0.scroll.contentView.bounds.origin }, origins)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    XCTAssertEqual(model.panePool.map { $0.scroll.contentView.bounds.origin }, origins)
  }
  func testNativeSetterReentryCannotInsertOrMarkText() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "unchanged synthetic")
    try f.project()
    let before = model.storage.string
    var calls = 0
    let selection = model.editor.selectedRange()
    var undoRan = false
    model.undoManager.registerUndo(withTarget: model) { _ in undoRan = true }
    XCTAssertTrue(model.undoManager.canUndo)
    AppliedSettingsProbe.beforeFont = { editor in
      calls += 1
      XCTAssertNotNil(model.nativeConfigurationToken)
      XCTAssertFalse(model.settingsApplied)
      self.assertRefused { _ = try model.captureCloseState() }
      XCTAssertTrue(try! model.captureTransferState(preparation: f.idle).isBusy)
      self.assertRefused { _ = try model.captureTransferView(preparation: f.idle) }
      XCTAssertFalse(editor.becomeFirstResponder())
      editor.setSelectedRange(NSRange(location: 2, length: 0))
      XCTAssertEqual(editor.selectedRange(), selection)
      self.assertRefused {
        try editor.withSelectionInstallation(authorizedBy: { true }) {
          editor.setSelectedRange(NSRange(location: 3, length: 0))
        }
      }
      model.undoManager.undo()
      XCTAssertFalse(undoRan)
      self.assertRefused { try f.first.focusPane(id: model.panePool[0].id) }
      self.assertRefused { try f.first.splitCurrent(.stacked) }
      f.first.appliedTestToggleWrap()
      f.first.applySettings(EditorSettings(fontSize: 22))
      editor.insertText("forbidden", replacementRange: NSRange(location: 0, length: 0))
      editor.setMarkedText(
        "marked", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
    }
    f.first.applySettings(EditorSettings(fontSize: 17, tabWidth: 8))
    XCTAssertGreaterThan(calls, 0)
    XCTAssertEqual(model.storage.string, before)
    XCTAssertFalse(model.editor.hasMarkedText())
  }
  func testNewAndReusedPanePreserveEffectiveTypography() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic inheritance")
    try f.project()
    f.first.applySettings(EditorSettings(fontSize: 17, wrap: false, tabWidth: 8))
    let first = model.panePool[0]
    let font = first.editor.font
    let paragraph = first.editor.defaultParagraphStyle
    let second = try model.makePane()
    XCTAssertEqual(first.editor.font, font)
    XCTAssertEqual(second.editor.font, font)
    XCTAssertEqual(second.editor.defaultParagraphStyle, paragraph)
    XCTAssertTrue(second.editor.isHorizontallyResizable)
    second.detach()
    let reused = try model.makePane()
    XCTAssertTrue(reused === second)
    XCTAssertEqual(reused.editor.font, font)
    XCTAssertEqual(reused.editor.defaultParagraphStyle, paragraph)
  }
  func testReentrantRevisionChangeCannotPublishAppliedProof() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic")
    try f.project()
    var fired = false
    AppliedSettingsProbe.beforeFont = { _ in
      guard !fired else { return }
      fired = true
      model.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
    }
    f.first.applySettings(EditorSettings(fontSize: 17))
    XCTAssertTrue(fired)
    XCTAssertFalse(model.settingsApplied)
  }
  func testEmptyDestinationPolicyChangeInvalidatesCapturedEndpoint() async throws {
    let f = try AppliedSettingsFixture()
    let moved = try await f.add(f.source, text: "synthetic source")
    try f.project()
    let lease = try f.reserve(moved)
    let snapshot = try f.registry.validateTransferSnapshot(lease)
    let receipt = try f.second.captureTransferEndpoint(snapshot, endpointID: f.targetID)
    f.second.applySettings(EditorSettings(fontSize: 17))
    XCTAssertThrowsError(try f.second.validateTransferEndpoint(snapshot, receipt: receipt))
    try f.registry.cancelUnstagedTransfer(lease)
  }

  func assertRefused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line)
  {
    do {
      try body()
      XCTFail("Expected configuration refusal", file: file, line: line)
    } catch {}
  }
  func assertTypography(
    _ model: EditorDocument, settings: EditorSettings,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // Expected native values are derived from AppKit, independently of the production resolver.
    let expectedFont =
      settings.fontName == EditorSettings.systemMonospacedFontName
      ? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
      : NSFont(name: settings.fontName, size: settings.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    let expectedTab =
      (" " as NSString).size(withAttributes: [.font: expectedFont]).width
      * CGFloat(settings.tabWidth)
    XCTAssertEqual(
      model.appliedTypography?.requestedFontName, settings.fontName, file: file, line: line)
    XCTAssertEqual(
      model.appliedTypography?.requestedFontSize, settings.fontSize, file: file, line: line)
    XCTAssertEqual(model.appliedTypography?.tabWidth, settings.tabWidth, file: file, line: line)
    XCTAssertEqual(
      model.appliedTypography?.defaultTabInterval, Double(expectedTab), file: file, line: line)
    for pane in model.panePool {
      XCTAssertEqual(pane.editor.font?.fontName, expectedFont.fontName, file: file, line: line)
      XCTAssertEqual(
        pane.editor.font?.pointSize, CGFloat(settings.fontSize), file: file, line: line)
      XCTAssertEqual(
        pane.editor.defaultParagraphStyle?.defaultTabInterval,
        expectedTab, file: file, line: line)
      XCTAssertEqual(
        (pane.editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.defaultTabInterval,
        expectedTab, file: file, line: line)
    }
    XCTAssertEqual(
      (model.storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
        .defaultTabInterval,
      expectedTab, file: file, line: line)
  }
  func testResolvedFallbackSizeAndTabChangesReachBothPanesAndStorage() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic typography")
    _ = try model.makePane()
    try f.project()
    let fallback = EditorSettings(
      fontSize: 17, fontName: "TheOnlyPadSyntheticMissingFont-357", tabWidth: 8)
    XCTAssertNil(NSFont(name: fallback.fontName, size: fallback.fontSize))
    f.first.applySettings(fallback)
    assertTypography(model, settings: fallback)
    XCTAssertEqual(
      model.appliedTypography?.resolvedFontName,
      NSFont.monospacedSystemFont(ofSize: 17, weight: .regular).fontName)
    let signature = model.appliedTypography
    AppliedSettingsProbe.fontWrites = 0
    f.first.applySettings(fallback)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
    XCTAssertEqual(model.appliedTypography, signature)
    let changed = EditorSettings(fontSize: 21, tabWidth: 2)
    f.first.applySettings(changed)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 2)
    assertTypography(model, settings: changed)
    XCTAssertNotEqual(model.appliedTypography, signature)
  }
  func testManualWrapResetsOnThemeOnlyApplicationWithoutTypographyWrites() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic wrap")
    _ = try model.makePane()
    try f.project()
    f.first.appliedTestToggleWrap()
    XCTAssertEqual(model.appliedWrap, false)
    XCTAssertTrue(
      model.panePool.allSatisfy {
        $0.editor.isHorizontallyResizable && !$0.textContainer.widthTracksTextView
      })
    AppliedSettingsProbe.fontWrites = 0
    f.first.applySettings(EditorSettings(theme: .dark))
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
    XCTAssertEqual(model.appliedWrap, true)
    XCTAssertTrue(
      model.panePool.allSatisfy {
        !$0.editor.isHorizontallyResizable && $0.textContainer.widthTracksTextView
      })
  }
  func testTransferPreservesSourceStyleThenUnchangedDestinationPolicyReconciles() async throws {
    let f = try AppliedSettingsFixture()
    let moved = try await f.add(f.source, text: "synthetic moved")
    _ = try await f.add(f.target, text: "synthetic target")
    try f.project()
    let sourceStyle = EditorSettings(fontSize: 17, wrap: false, tabWidth: 8)
    f.first.applySettings(sourceStyle)
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    AppliedSettingsProbe.fontWrites = 0
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snap, receipt: left)
    try f.second.applyTransferProjection(snap, receipt: right)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
    assertTypography(moved, settings: sourceStyle)
    XCTAssertEqual(moved.appliedWrap, false)
    try f.registry.completeTransfer(lease, willNotify: {})
    f.second.applySettings(.defaults)
    assertTypography(moved, settings: .defaults)
    XCTAssertEqual(moved.appliedWrap, true)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 1)
    AppliedSettingsProbe.fontWrites = 0
    f.second.applySettings(.defaults)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
  }
  func testStaleOuterCallbackCannotPublishOrClearReplacementToken() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic replacement")
    try f.project()
    var replacement: UUID?
    AppliedSettingsProbe.beforeFont = { _ in
      guard replacement == nil, let old = model.nativeConfigurationToken else { return }
      model.endNativeConfiguration(old)
      replacement = try! model.beginNativeConfiguration()
    }
    f.first.applySettings(EditorSettings(fontSize: 17))
    XCTAssertNotNil(replacement)
    XCTAssertEqual(model.nativeConfigurationToken, replacement)
    XCTAssertNil(model.appliedTypography)
    XCTAssertFalse(model.settingsApplied)
    model.endNativeConfiguration(try XCTUnwrap(replacement))
    AppliedSettingsProbe.beforeFont = nil
    f.first.applySettings(EditorSettings(fontSize: 17))
    assertTypography(model, settings: EditorSettings(fontSize: 17))
  }
  func testBlockedThenReadyAndLateSettingsReachExistingDocument() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic startup")
    try f.project()
    f.userReady = false
    f.first.applySettings(EditorSettings(fontSize: 17))
    XCTAssertEqual(model.editor.font?.pointSize, 13)
    f.userReady = true
    f.first.applySettings(EditorSettings(fontSize: 17))
    assertTypography(model, settings: EditorSettings(fontSize: 17))
    f.first.applySettings(EditorSettings(fontSize: 21))
    assertTypography(model, settings: EditorSettings(fontSize: 21))
  }
  func testCloseGenerationTracksInactiveAppliedStateAndTokenRefusesNestedWork() async throws {
    let model = EditorDocument()
    let generation = model.closeMutationGeneration
    model.appliedWrap = false
    XCTAssertNotEqual(model.closeMutationGeneration, generation)
    let token = try model.beginNativeConfiguration()
    XCTAssertThrowsError(try model.beginNativeConfiguration())
    XCTAssertThrowsError(try model.makePane())
    XCTAssertThrowsError(try model.captureCloseState())
    var undoRan = false
    model.undoManager.registerUndo(withTarget: model) { _ in undoRan = true }
    model.undoManager.undo()
    XCTAssertFalse(undoRan)
    model.endNativeConfiguration(UUID())
    XCTAssertEqual(model.nativeConfigurationToken, token)
    model.endNativeConfiguration(token)
    XCTAssertNil(model.nativeConfigurationToken)
  }

  func testBothGeometryReconstructionsAndReplacementKeepOriginalProof() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic receipt")
    try f.project()
    f.first.applySettings(EditorSettings(fontSize: 17, wrap: false))
    let view = try model.captureTransferView(preparation: f.idle)
    model.appliedTypography = ResolvedDocumentTypography(.defaults).signature
    model.appliedWrap = true
    for reconstructed in [
      f.first.appliedTestLiveOrigins(view, model: model),
      f.first.appliedTestConstrained(view, model: model),
    ] {
      XCTAssertEqual(reconstructed.appliedTypography, view.appliedTypography)
      XCTAssertEqual(reconstructed.appliedWrap, view.appliedWrap)
      XCTAssertThrowsError(
        try model.validateTransferView(
          reconstructed, expectedState: view.state,
          preparation: f.idle))
    }
    f.first.applySettings(EditorSettings(fontSize: 17, wrap: false))
    let lease = try f.reserve(model)
    let snapshot = try f.registry.validateTransferSnapshot(lease)
    let right = try f.second.captureTransferEndpoint(snapshot, endpointID: f.targetID)
    f.second.applySettings(EditorSettings(theme: .dark))
    try f.second.validateTransferEndpoint(snapshot, receipt: right)
    f.second.applySettings(EditorSettings(fontSize: 21))
    let replacement = f.second.appliedTestReplacement(right)
    XCTAssertEqual(replacement.presentationPolicy, right.presentationPolicy)
    XCTAssertThrowsError(
      try f.second.reconcileTransferEndpoint(snapshot, receipt: right, endpointID: f.targetID))
    try f.registry.cancelUnstagedTransfer(lease)
  }
  func testCompositionRefusesSettingsWithoutLosingExistingProof() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic composing")
    try f.project()
    model.editor.setMarkedText(
      "marked", selectedRange: NSRange(location: 0, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(model.editor.hasMarkedText())
    let proof = model.appliedTypography
    AppliedSettingsProbe.fontWrites = 0
    f.first.applySettings(EditorSettings(fontSize: 17))
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 0)
    XCTAssertEqual(model.appliedTypography, proof)
    XCTAssertNil(model.nativeConfigurationToken)
    model.editor.unmarkText()
    f.first.applySettings(EditorSettings(fontSize: 17))
    assertTypography(model, settings: EditorSettings(fontSize: 17))
  }

  func testSplitAndSavedSplitReuseKeepAppliedStyleAndWrap() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic split\nsecond line")
    try f.project()
    let style = EditorSettings(fontSize: 17, wrap: false, tabWidth: 8)
    f.first.applySettings(style)
    XCTAssertTrue(f.first.window!.makeFirstResponder(model.editor))
    try f.first.splitCurrent(.sideBySide)
    assertTypography(model, settings: style)
    XCTAssertEqual(model.appliedWrap, false)
    let second = model.panePool[1]
    try f.first.collapseToFocusedPane()
    XCTAssertFalse(second.isAttached)
    try f.first.appliedTestInstall(
      .init(
        axis: .stacked,
        panes: [
          .init(selection: NSRange(location: 1, length: 0), scrollOrigin: .init(x: 0, y: 0)),
          .init(selection: NSRange(location: 3, length: 0), scrollOrigin: .init(x: 0, y: 0)),
        ], focusedPaneIndex: 0), document: model)
    XCTAssertTrue(model.panePool[1] === second)
    XCTAssertTrue(second.isAttached)
    assertTypography(model, settings: style)
    XCTAssertEqual(model.appliedWrap, false)
    XCTAssertTrue(model.panePool.allSatisfy { $0.editor.isHorizontallyResizable })
  }
  func testNewPaneNativeInitializationRefusesTextReentryAndReusedAttachIsFenced() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic construction")
    try f.project()
    let original = model.storage.string
    var calls = 0
    AppliedSettingsProbe.beforeFont = { editor in
      calls += 1
      XCTAssertNotNil(model.nativeConfigurationToken)
      editor.insertText("forbidden", replacementRange: NSRange(location: 0, length: 0))
    }
    let second = try model.makePane()
    XCTAssertGreaterThan(calls, 0)
    XCTAssertEqual(model.storage.string, original)
    second.detach()
    _ = try model.makePane()
    XCTAssertTrue(second.isAttached)
    XCTAssertEqual(model.storage.string, original)
    XCTAssertNil(model.nativeConfigurationToken)
  }

  func testTransferSetterMutationOutsideEditRevisionCannotRetainProof() async throws {
    let f = try AppliedSettingsFixture()
    let moved = try await f.add(f.source, text: "synthetic transfer mutation")
    try f.project()
    let lease = try f.reserve(moved)
    var snap = try f.registry.validateTransferSnapshot(lease)
    let left = try f.first.captureTransferEndpoint(snap, endpointID: f.sourceID)
    let right = try f.second.captureTransferEndpoint(snap, endpointID: f.targetID)
    try f.registry.stageTransfer(lease)
    snap = try f.registry.validateTransferSnapshot(lease)
    try f.first.applyTransferProjection(snap, receipt: left)
    let revision = moved.editRevision
    let ownership = moved.ownershipGeneration
    var fired = false
    AppliedSettingsProbe.beforeWrap = { editor in
      guard editor === moved.editor, !fired else { return }
      fired = true
      moved.manualLanguage.toggle()
    }
    XCTAssertThrowsError(try f.second.applyTransferProjection(snap, receipt: right))
    XCTAssertTrue(fired)
    XCTAssertEqual(moved.editRevision, revision)
    XCTAssertEqual(moved.ownershipGeneration, ownership)
    XCTAssertNil(moved.appliedTypography)
    XCTAssertNil(moved.appliedWrap)
  }

  func testOrdinarySetterMutationAndInheritanceAuthorityReentryLeaveProofUnknown() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic authority")
    try f.project()
    var fired = false
    AppliedSettingsProbe.beforeFont = { _ in
      guard !fired else { return }
      fired = true
      model.manualLanguage.toggle()
    }
    f.first.applySettings(EditorSettings(fontSize: 17))
    XCTAssertTrue(fired)
    XCTAssertNil(model.appliedTypography)
    AppliedSettingsProbe.beforeFont = nil
    f.first.applySettings(EditorSettings(fontSize: 17))
    var checks = 0
    XCTAssertThrowsError(
      try model.makePane(authorizedBy: {
        checks += 1
        if checks == 2 { model.advanceOwnershipGeneration() }
        return true
      }))
    XCTAssertNil(model.appliedTypography)
    XCTAssertNil(model.nativeConfigurationToken)
  }

  func testNamedFontAndTabOnlyChangesUseEffectiveResolvedValues() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic named font")
    try f.project()
    let named = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 17))
    f.first.applySettings(EditorSettings(fontSize: 17, fontName: named.fontName, tabWidth: 2))
    XCTAssertEqual(model.editor.font?.fontName, named.fontName)
    let previous = try XCTUnwrap(model.editor.defaultParagraphStyle?.defaultTabInterval)
    AppliedSettingsProbe.fontWrites = 0
    let changed = EditorSettings(fontSize: 17, fontName: named.fontName, tabWidth: 8)
    f.first.applySettings(changed)
    assertTypography(model, settings: changed)
    XCTAssertEqual(model.editor.defaultParagraphStyle?.defaultTabInterval, previous * 4)
    XCTAssertEqual(AppliedSettingsProbe.fontWrites, 1)
  }
  func testEndpointAndPaneChangesInsideNativeSetterCannotPublishProof() async throws {
    for changeEndpoint in [true, false] {
      let f = try AppliedSettingsFixture()
      let model = try await f.add(f.source, text: "synthetic endpoint")
      try f.project()
      var fired = false
      AppliedSettingsProbe.beforeFont = { _ in
        guard !fired else { return }
        fired = true
        if changeEndpoint {
          f.sourceCheck = { throw DocumentTransferError.stale }
        } else {
          model.panePool[0].detach()
        }
      }
      f.first.applySettings(EditorSettings(fontSize: 17))
      XCTAssertTrue(fired)
      XCTAssertNil(model.appliedTypography)
      XCTAssertNil(model.appliedWrap)
      XCTAssertNil(model.nativeConfigurationToken)
      AppliedSettingsProbe.beforeFont = nil
      f.sourceCheck = nil
    }
  }
  func testInteractionAdmissionCallbackCannotStartConfigurationThenContinueEdit() throws {
    let model = EditorDocument()
    model.storage.mutableString.setString("synthetic admission")
    var token: UUID?
    model.editor.canMutate = {
      token = try! model.beginNativeConfiguration()
      return true
    }
    model.editor.insertText("forbidden", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(model.storage.string, "synthetic admission")
    model.endNativeConfiguration(try XCTUnwrap(token))
    let selection = model.editor.selectedRange()
    model.editor.canChangeSelection = {
      token = try! model.beginNativeConfiguration()
      return true
    }
    model.editor.setSelectedRange(NSRange(location: 3, length: 0))
    XCTAssertEqual(model.editor.selectedRange(), selection)
    model.endNativeConfiguration(try XCTUnwrap(token))
  }

  func testUndoOwnerCallbackCannotAcquireConfigurationThenReplay() throws {
    let model = EditorDocument()
    var undoRan = false
    model.undoManager.registerUndo(withTarget: model) { _ in undoRan = true }
    XCTAssertTrue(model.undoManager.canUndo)
    var token: UUID?
    model.canUndoRedo = {
      if token == nil { token = try! model.beginNativeConfiguration() }
      return true
    }
    model.undoManager.undo()
    XCTAssertNotNil(token)
    XCTAssertFalse(undoRan)
    XCTAssertTrue(model.undoManager.canUndo)
    model.endNativeConfiguration(try XCTUnwrap(token))
    model.canUndoRedo = nil
    model.undoManager.undo()
    XCTAssertTrue(undoRan)
  }
  func testEndpointAdmissionCallbackCannotAcquireConfigurationThenAdmitDelegateEdit() async throws {
    let f = try AppliedSettingsFixture()
    let model = try await f.add(f.source, text: "synthetic delegate")
    try f.project()
    var token: UUID?
    f.sourceCheck = {
      if token == nil { token = try model.beginNativeConfiguration() }
    }
    XCTAssertFalse(
      f.first.textView(
        model.editor, shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "forbidden"))
    XCTAssertNotNil(token)
    XCTAssertNil(model.pendingBookmarks)
    XCTAssertEqual(model.storage.string, "synthetic delegate")
    f.sourceCheck = nil
    model.endNativeConfiguration(try XCTUnwrap(token))
    XCTAssertTrue(
      f.first.textView(
        model.editor, shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementString: "allowed"))
  }

  func testNestedUndoOwnerCallbackCannotAcquireConfigurationThenReplay() throws {
    let model = EditorDocument()
    model.undoManager.groupsByEvent = false
    model.undoManager.beginUndoGrouping()
    var undoRan = false
    model.undoManager.registerUndo(withTarget: model) { _ in undoRan = true }
    model.undoManager.endUndoGrouping()
    XCTAssertEqual(model.undoManager.groupingLevel, 0)
    XCTAssertTrue(model.undoManager.canUndo)
    var token: UUID?
    model.canUndoRedo = {
      if token == nil { token = try! model.beginNativeConfiguration() }
      return true
    }
    model.undoManager.undoNestedGroup()
    XCTAssertNotNil(token)
    XCTAssertFalse(undoRan)
    XCTAssertTrue(model.undoManager.canUndo)
    model.endNativeConfiguration(try XCTUnwrap(token))
    model.canUndoRedo = nil
    model.undoManager.undoNestedGroup()
    XCTAssertTrue(undoRan)
  }

}
