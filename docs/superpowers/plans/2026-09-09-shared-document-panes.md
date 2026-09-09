# Shared Document Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add horizontal and vertical presentations of one logical document with shared text/undo and independent carets, without duplicating save or recovery ownership.

**Architecture:** Retain the current TextKit 1 adapter. Extract document-owned storage and undo from presentation-owned layout/view/scroll objects, preserve single-pane behavior first, then add a two-pane split for the selected document. File operations address the logical document; selection-sensitive commands address the originating pane and reject stale completion.

**Tech Stack:** Existing Swift/AppKit, NSTextStorage, NSLayoutManager, NSTextContainer, NSTextView, NSSplitView, PadCore services; no new dependency.

**Spec:** [shared-editor-views.md](../specs/shared-editor-views.md), [architecture design](../specs/2026-09-09-architecture-design.md), [requirements matrix](../../requirements-matrix.md) F-01 and pane coverage in T-05.

## Global Constraints

- “Core functionality must work offline without accounts, subscriptions, telemetry, or cloud services.”
- “Keep README status honest: planned features are not shipped features.”
- “Use synthetic fixtures, relative paths, and placeholders in examples.”
- “Do not introduce mutation through another pane while a composition policy is undefined.”
- Preserve current exact UTF16 dirty comparisons, encoding/BOM, original bytes, backup, atomic-save, recovery, bookmark and macro contracts.
- This plan changes no engine-selection decision. F-02 inter-window/document transfer, split session persistence, linked scrolling, minimap and comparison remain separate requirements, not implied acceptance.
- Scope first implementation to two presentations of the selected tab, with either split axis and independent scrolling. “Synchronized” means shared document edits/undo, not forcing both scroll positions together.
- No production changes are authorized by this planning task. Execution uses isolated green-before-copy work and coordinated GUI/CPU slots. Local checkpoint commits remain optional until the root coordinator's integration checkpoint.

## Current evidence and integration hazards

The local feasibility probe uses one storage, two layout managers and one undo manager. It verifies exact edits, selection rebasing, independent scrolling, manager-local temporary attributes and responder-chain undo. Its detached originating view remained retained: **deallocation with live undo history was not proven**. Physical IME and accessibility remain unverified.

Production currently makes `EditorDocument` private inside EditorWindowController, owns one `editor` and `scroll`, and places UndoManager on DocumentTextView. `display` removes every host subview and reinstalls one scroll view. Delegate lookups identify documents using `document.editor === textView`. Dirty state, persistence, language work and most commands obtain text via that one view. NativeSyntaxHighlighter applies temporary colors to only one layout manager. SessionTab holds one selection, not presentation state. Every coupling below must be addressed before enabling the split commands.

The working document model must have one storage character-edit observer, one revision, one save baseline, one recovery identity and one shared manager regardless of the number of attached panes. Never mirror string contents by assigning a second view's `.string`: it creates duplicate transaction/undo paths and may destroy composition or selection state.

## Ownership and interfaces

One integration owner owns EditorWindowController and the extraction from that file. Other workers must not concurrently edit it. New adapter files can be prepared independently only after agreeing the signatures below. The highlighter owner may edit only NativeSyntaxHighlighter and its harness; script/registry/DesktopUI modifications belong to the integration owner. No worker reverts another worker's source.

Create `Sources/TheOnlyPad/DocumentTextView.swift` by moving the existing subclass unchanged first. Its injected manager replaces the current internally allocated manager:

```swift
@MainActor final class DocumentTextView: NSTextView {
  let documentUndo: UndoManager
  init(frame: NSRect, textContainer: NSTextContainer, undoManager: UndoManager)
  override var undoManager: UndoManager? { documentUndo }
  var onFocus: (() -> Void)?
  // Preserve every current marked-text/typing callback and override.
}
```

Create `Sources/TheOnlyPad/EditorDocument.swift`, moving existing metadata and dirty/savepoint logic rather than recreating it. Create `Sources/TheOnlyPad/EditorPane.swift` for presentation construction and settings. Proposed final interfaces:

```swift
@MainActor final class EditorDocument {
  let id: UUID
  let storage: NSTextStorage
  let undoManager: UndoManager
  private(set) var revision: UInt64
  private(set) var panePool: [EditorPane] // At most two, retained for document lifetime.
  var composingPaneID: UUID?
  func makePane() throws -> EditorPane
  // Existing encoding, originalBytes, savedText, language, bookmarks, saving,
  // cachedTextDirty and recovery metadata remain on this object.
}
@MainActor final class EditorPane {
  let id: UUID
  unowned let document: EditorDocument
  let layoutManager: NSLayoutManager
  let textContainer: NSTextContainer
  let editor: DocumentTextView
  let scroll: NSScrollView
  private(set) var isAttached: Bool
  func attach()
  func detach()
}
enum PaneAxis { case sideBySide, stacked }
struct PaneCommandContext {
  let documentID: UUID
  let paneID: UUID
  let revision: UInt64
  let selection: NSRange
}
```

Document owns panes; panes reference their owner without a retain cycle. A closed presentation's view stays in the bounded two-entry pool so native undo targets remain alive. Detach removes its layout manager from storage; attach reconnects that same manager/container/view. Reopening a split reuses the detached pane and explicitly initializes its caret from the focused pane; do not allocate an unbounded sequence of hidden undo targets. The final document close releases its entire pool/history using the existing document-close lifecycle. If retained-target tests fail, stop integration and revise the lifecycle design rather than clearing undo to hide failure.

EditorWindowController adds internal testable methods/properties:

```swift
var focusedPane: EditorPane? { get }
var visiblePanes: [EditorPane] { get }
func splitCurrent(_ axis: PaneAxis) throws
func collapseToFocusedPane() throws
func focusPane(id: UUID) throws
func paneContext() -> PaneCommandContext?
func accepts(_ context: PaneCommandContext) -> Bool
```

`accepts` requires matching selected document, attached originating pane, unchanged revision and exact selection, focused originating pane, and neither saving, composing nor quitting/closed state. Async commands conservatively reject changed focus rather than apply to the newly focused selection. Saving is different: retain its existing document-bound snapshot/commit semantics; changing pane focus must not change the saved document.

## Task 1: Extract ownership with unchanged single-pane behavior

**Files:** create DocumentTextView.swift, EditorDocument.swift, EditorPane.swift; modify EditorWindowController.swift; create Tests/NativeIntegration/SharedPaneOwnershipHarness.swift; modify scripts/test-native-integration.sh compilation source arrays.

- [ ] Write a native harness constructing one document and two presentations; first assert shared storage/manager identity and independent initial selection. Add exact shared edit and cross-pane undo assertions:

```swift
let document = EditorDocument()
let left = try document.makePane()
let right = try document.makePane()
left.attach(); right.attach()
document.storage.mutableString.setString("a😀e\u{301}\r\nz")
left.editor.setSelectedRange(NSRange(location: 1, length: 0))
right.editor.setSelectedRange(NSRange(location: 7, length: 0))
precondition(left.editor.textStorage === right.editor.textStorage)
precondition(left.editor.undoManager === right.editor.undoManager)
let before = Array(document.storage.string.utf16)
document.undoManager.beginUndoGrouping()
left.editor.insertText("X", replacementRange: NSRange(location: 1, length: 0))
document.undoManager.endUndoGrouping()
right.editor.undoManager!.undo()
precondition(Array(document.storage.string.utf16) == before)
```

- [ ] Compile that harness against the isolated adapter source, capture the expected unavailable-interface red result, and preserve the current full native baseline before extraction.
- [ ] Move the existing subclass and model methods verbatim first; inject manager/storage and move construction into EditorPane. Change model dirty/save/recovery text reads to `storage.string` / `storage.mutableString` and model undo registrations to `undoManager`.
- [ ] Preserve one visible pane while converting every document lookup from editor identity to a lookup across `panePool`. A temporary accessor is allowed during isolated refactoring; remove ambiguous `document.editor` / `document.scroll` access before enabling splits.
- [ ] Run the ownership harness and existing native suite. Exact encoding/dirty, programmatic editing, bookmark composition undo, save/backup/recovery and session restoration harnesses must remain green.
- [ ] Review diff for one storage observer per document, no new file-path writes and no discarded undo history. Copy green files in the coordinated integration gap; checkpoint this ownership change independently of visible splits.

## Task 2: Route focused-pane editing and one document transaction

**Files:** modify EditorWindowController.swift, EditorPane.swift, DocumentTextView.swift; create Tests/NativeIntegration/SharedPaneCommandsHarness.swift.

- [ ] Add failing assertions for two edits from distinct panes with one shared undo sequence, only one recovery revision per completed character change, and bookmark/macros recorded once. Capture original source pane for pre-edit bookmark computation; never infer an edit from selection notifications.
- [ ] Implement `onFocus` after successful `becomeFirstResponder`; resolve current selection, status, search, outline, ruler clicks, text utilities, line/language commands, copy/paste and `windowWillReturnUndoManager` from focusedPane. Model byte/dirty/save work remains document-bound.
- [ ] At ordinary focus handoff call `breakUndoCoalescing` on both text views. Register each explicit command as one model-owned group; keep existing bookmark metadata in that same group. Assert actual menu/keyboard undo later, not only manager calls.
- [ ] Implement context validation and add a suspended async transform test: capture left context, focus right before resuming, and assert rejection with unchanged text and actionable existing stale-result error. Repeat after detach, edit, document switch, close and quit.
- [ ] Define composition exclusivity: first marked-text operation claims document.composingPaneID. Keep other panes noneditable and reject programmatic mutation from them until the originating pane finishes/cancels composition. Reject split/collapse/tab switch while marked text remains; present “Finish text composition before changing panes.” Do not silently call discardMarkedText. Restore other panes' editability only if the document is not saving/quitting.
- [ ] Add native marked-text cancel/commit fixtures with bookmarks, assert no mutation through the other pane while composition is active, and exact undo afterward. Keep physical Japanese/Chinese/Korean input as an explicitly separate desktop/manual acceptance gate.
- [ ] Run existing macro, bookmark and async-snapshot harnesses plus SharedPaneCommandsHarness. A storage notification count by itself is not sufficient proof of exactly one user transaction.

## Task 3: Add both split axes and safe collapse lifecycle

**Files:** create Sources/TheOnlyPad/EditorPaneHost.swift; modify EditorWindowController.swift and Sources/PadCore/AppCommands.swift; extend SharedPaneCommandsHarness.

EditorPaneHost owns only arrangement and takes existing pane scroll views:

```swift
@MainActor final class EditorPaneHost: NSView {
  func show(_ panes: [EditorPane], axis: PaneAxis)
}
```

- [ ] Add failing tests for `splitCurrent(.sideBySide)` and `.stacked`, distinct pane IDs, shared document ID, independent initial scroll/carets, and collapse preserving active pane text/selection/undo.
- [ ] Implement NSSplitView with `isVertical = (axis == .sideBySide)`. Use a 160-point minimum pane extent; prevent divider dragging below that extent and shrink to a single presentation if the window cannot fit both, preserving document data and retained presentation state. Keep both scroll views constrained to their pane bounds.
- [ ] Register `view.splitVertical` (“Split Side by Side”), `view.splitHorizontal` (“Split Top and Bottom”), `view.closeSplit` (“Close Other Pane”), and `view.focusOtherPane` (“Focus Other Pane”) in the shared registry. Existing split changes orientation without creating a third pane. Last-pane close is not exposed; closeSplit is disabled with one pane.
- [ ] Assign actual accessibility identifiers `editor.pane.<UUID>` and `editor.text.<UUID>` with labels “Document text, pane 1/2”. Expose focus through actual responder changes. Preserve the single document tab/title/dirty indicator; selecting another tab shows that document's own presentation arrangement.
- [ ] Test collapse after an edit in the removed pane, then undo/redo via the remaining pane. Repeat split/collapse 100 times and assert panePool count never exceeds two, attached layout-manager count is correct, and shared history survives. Test document close discards/persists once, never once per presentation.
- [ ] Freeze every pooled/attached view during save/reload and quit. Failed operations must restore editability consistently. Assert editing the second pane cannot race an encoding reload or mutate a captured quit snapshot.
- [ ] Initially refuse extra layout allocation above 2,000,000 UTF16 units with an actionable size message, pending Task 5 measurements. This is a provisional visible guard, not F-01 full-size acceptance or a reason to omit later performance work.

## Task 4: Share highlighting and fan out document metadata

**Files:** modify NativeSyntaxHighlighter.swift, EditorDocument.swift, EditorPane.swift, EditorWindowController.swift; create Tests/NativeIntegration/SharedPaneHighlightHarness.swift.

Replace view-specific ownership with document storage and a snapshot of attached layout managers:

```swift
init(storage: NSTextStorage, layoutManagers: @escaping () -> [NSLayoutManager])
func update(language: DocumentLanguage)
func applyCachedTokens(to layoutManager: NSLayoutManager)
```

- [ ] Write a failing test that colors one token in both attached layout managers, proves no foreground color entered NSTextStorage, and proves highlighting adds no undo/recovery mutation.
- [ ] Retain one parser task per document and the current two-million-unit parse cap. Capture immutable text/language and generation; check storage text/generation before applying. Clear/apply temporary attributes across all attached managers. Newly attached panes receive the validated cache; detached managers receive no late work.
- [ ] Refresh bookmark ruler offsets in every attached presentation after edits/undo, while caret/selection status remains focused-pane-specific. Changing wrapping/settings updates every pane's layout without changing bytes or adding undo.
- [ ] Assert a delayed old-language result cannot color a newer document, detached pane or stale storage revision. Assert one parse invocation for a shared document edit, not one per pane; use an injected parser counter in the harness.
- [ ] Run highlighter, language, bookmark and pane harnesses. Review memory ownership so the layout-manager provider captures the document weakly and cannot create a document/highlighter cycle.

## Task 5: Retain full integration and desktop evidence

**Files:** modify scripts/test-native-integration.sh; create Tests/DesktopUI/SharedPanesTests.swift; modify Tests/DesktopUI/GUIProbe.xcodeproj/project.pbxproj to include that test source in the existing test target; append docs/verification/shared-document-panes.md. Only after evidence, root updates the F-01 matrix row.

- [ ] Add every new native harness to the real script source lists. The script currently lists EditorWindowController dependencies explicitly in multiple compile commands: extraction must update each command, not only the first harness.
- [ ] Run `scripts/swift.sh test` and `scripts/test-native-integration.sh` after green isolated work is integrated; save sanitized summaries and exact exit status. Do not claim a successful build proves focus/IME behavior.
- [ ] Add packaged XCUI: create synthetic text, split side by side, click pane 1 and type a distinct marker, assert both values; click pane 2, type another marker, use menu Undo then Cmd-Z/Shift-Cmd-Z and assert shared exact values. Repeat top/bottom, move each caret independently, collapse, undo from the remaining view, save once and assert exact bytes on disk.
- [ ] Add packaged close/quit tests verifying only one logical recovery/session tab is persisted for two views. Current SessionTab stores the focused pane selection only; relaunch restores a single presentation by design for this subsystem. Do not claim split arrangement persistence or F-02 transfer support.
- [ ] Run the existing `scripts/test-desktop-ui.sh` with the new test included, synthetic state directory and packaged current application; coordinate exclusive GUI ownership and independent process watchdogs. Retain logs/screenshots only in ignored paths.
- [ ] Benchmark one versus two layouts at 1 MB, 10 MB and 100 MB ordinary multiline plus long-line fixtures with actual visible end caret, edit/undo, resize and wrap. Record process memory and both p50/p95 observations where sample count supports them. Keep the initial split size guard until evidence supports raising it; do not infer performance from the small shared-storage probe or another engine.
- [ ] Run a physical IME/VoiceOver review when the environment permits it; record unavailable checks rather than reporting native synthetic callbacks as physical coverage. Outstanding physical/large-file gates keep acceptance partial.
- [ ] Independent review checks one save/recovery identity, bounded retained undo targets, composition exclusion, stale async checks, both axes and actual menu/focus routing. Update documentation separately as implemented, tested and outstanding; do not mark F-02, linked scrolling or split-session persistence complete.

## Acceptance and self-review

F-01 maps to Tasks 1–4 ownership/axes/shared edits/undo/independent selections and Task 5 real desktop evidence. Pane-specific T-05 maps to Task 5. F-02 remains untouched: no document transfer between windows or separate pane tab groups is implemented by this plan. Existing F-07 status must continue to report the focused pane. Separate engine reassessment and advanced-selection requirements are unchanged.

Every proposed cross-file interface is named above. No matrix or continuation file was edited during this planning task. New source/test paths and code blocks describe planned work only; none is claimed to exist or pass. The BUILD_PROMPT waives repeated design/handoff approval, so the coordinator may execute this plan after its normal source-ownership and test-slot coordination without asking the user to choose an execution style.
