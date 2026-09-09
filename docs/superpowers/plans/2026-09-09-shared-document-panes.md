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
- The initial planning task made no production changes. Execution is now proceeding under the original autonomous build authorization, with coordinated source ownership and GUI/CPU slots. Local checkpoint commits remain optional until the root coordinator's integration checkpoint.

## Current evidence and integration hazards

The local feasibility probe uses one storage, two layout managers and one undo manager. It verifies exact edits, selection rebasing, independent scrolling, manager-local temporary attributes and responder-chain undo. Its detached originating view remained retained: **deallocation with live undo history was not proven**. Physical IME and accessibility remain unverified.

Production currently makes `EditorDocument` private inside EditorWindowController, owns one `editor` and `scroll`, and places UndoManager on DocumentTextView. `display` removes every host subview and reinstalls one scroll view. Delegate lookups identify documents using `document.editor === textView`. Dirty state, persistence, language work and most commands obtain text via that one view. NativeSyntaxHighlighter applies temporary colors to only one layout manager. SessionTab holds one selection, not presentation state. Every coupling below must be addressed before enabling the split commands.

The working document model must have one storage character-edit observer, distinct edit and capture revisions, one save baseline, one recovery identity and one shared manager regardless of the number of attached panes. Never mirror string contents by assigning a second view's `.string`: it creates duplicate transaction/undo paths and may destroy composition or selection state.

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
  private(set) var editRevision: UInt64
  var recoveryRevision: UInt64 // Existing capture issuance counter; never repurpose as edit count.
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
  var selectableBeforeQuit: Bool?
  func attach()
  func detach()
}
enum PaneAxis { case sideBySide, stacked }
struct PaneCommandContext {
  let documentID: UUID
  let paneID: UUID
  let editRevision: UInt64
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

`accepts` requires matching selected document, attached originating pane, unchanged editRevision and exact selection, focused originating pane, and neither saving, composing nor quitting/closed state. Async commands conservatively reject changed focus rather than apply to the newly focused selection. Saving is different: retain its existing document-bound snapshot/commit semantics; changing pane focus must not change the saved document.

## Current integration corrections (planned requirements)

The checkpoint/save changes landed after the original pane plan. Preserve them during extraction:

- `recoveryRevision` counts immutable capture issuance. Two captures of unchanged text must have fresh capture revisions. Add a distinct `editRevision` for PaneCommandContext; do not use capture issuance as evidence that text changed.
- `pendingPublication` stays document-owned and forces dirty/recovery eligibility even if text returns exactly to savedText. Moving its type out of the currently private controller file requires internal module visibility, not public API. Capture both panes as one logical live ID/recovery item and retain the previous URL during uncertain Save As.
- `selectableBeforeQuit` becomes presentation-owned. Freeze editability and selectability in every pane; restore each original selectability on veto, including repeated cancellation. Preserve the new tab/popup/ruler lifecycle guards.
- Keep both application-level and per-window synchronous `assertNoPendingCloses` checks immediately before capture, with no suspension inside the paired text/metadata capture. One document observer notifies the application scheduler; adding a second pane must not re-enable legacy per-window recovery timers or create a second writer.
- Retain all existing save-failure, WindowCheckpointHarness and capture harness assertions through the ownership refactor. Add pending-save baseline-return and pending Save As paired-capture cases to the pane harness.

## Task 1: Extract ownership with unchanged single-pane behavior

**Files:** create DocumentTextView.swift, EditorDocument.swift, EditorPane.swift; modify EditorWindowController.swift; create Tests/NativeIntegration/SharedPaneOwnershipHarness.swift; modify scripts/test-native-integration.sh compilation source arrays.

- [ ] First retain an ignored copy of the current EditorWindowController source and append the following main-actor probe in that same file, so its existing private DocumentTextView is exercised without weakening production access control. Compile it using the existing native harness dependency list, replacing the normal harness entry point with this probe. No window or GUI interaction is required. The expected red is exact undo restoration through the other view, because the current subclass allocates separate managers:

```swift
@main struct SharedUndoRedProbe {
  @MainActor static func main() {
    _ = NSApplication.shared
    let storage = NSTextStorage(string: "a😀e\u{301}\r\nz")
    func presentation() -> DocumentTextView {
      let layout = NSLayoutManager()
      let container = NSTextContainer(size: NSSize(width: 600, height: 600))
      storage.addLayoutManager(layout)
      layout.addTextContainer(container)
      let view = DocumentTextView(frame: .zero, textContainer: container)
      view.isRichText = false
      view.allowsUndo = true
      return view
    }
    let left = presentation(), right = presentation()
    let before = Array(storage.string.utf16)
    left.undoManager!.beginUndoGrouping()
    left.insertText("X", replacementRange: NSRange(location: 1, length: 0))
    left.undoManager!.endUndoGrouping()
    precondition(left.textStorage === right.textStorage)
    precondition(Array(right.string.utf16) != before)
    right.undoManager!.undo()
    precondition(Array(storage.string.utf16) == before,
                 "Undo from the other presentation must restore exact shared text")
  }
}
```

The first implementation interface is injected document-owned UndoManager in DocumentTextView, with one independent layout manager/container per presentation. After extraction, retain the equivalent shared-manager regression in SharedPaneOwnershipHarness rather than keeping a second application entry point in production.

- [ ] Write the native ownership harness constructing one document and two presentations; assert shared storage/manager identity and independent initial selection. Add exact shared edit and cross-pane undo assertions:

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

- [ ] Run the behavioral red probe below against an ignored copy of the current source before extraction. Preserve its exact failed undo assertion and the current native baseline. Then compile the proposed ownership-interface harness above after introducing those interfaces; missing API compilation alone is not the behavioral regression evidence.
- [ ] Move the existing subclass and model methods verbatim first; inject manager/storage and move construction into EditorPane. Change model dirty/save/recovery text reads to `storage.string` / `storage.mutableString` and model undo registrations to `undoManager`.
- [ ] Preserve one visible pane while converting every document lookup from editor identity to a lookup across `panePool`. A temporary accessor is allowed during isolated refactoring; remove ambiguous `document.editor` / `document.scroll` access before enabling splits.
- [ ] Run the ownership harness and existing native suite. Exact encoding/dirty, programmatic editing, bookmark composition undo, save/backup/recovery and session restoration harnesses must remain green.
- [ ] Review diff for one storage observer per document, no new file-path writes and no discarded undo history. Copy green files in the coordinated integration gap; checkpoint this ownership change independently of visible splits.

## Task 2: Route focused-pane editing and one document transaction

**Files:** modify EditorWindowController.swift, EditorPane.swift, DocumentTextView.swift; create Tests/NativeIntegration/SharedPaneCommandsHarness.swift.

- [ ] Add failing assertions for two edits from distinct panes with one shared undo sequence, one document editRevision increment for an ordinary completed character edit and one recovery item/live ID per logical document per capture, and bookmark/macros recorded once. Capture original source pane for pre-edit bookmark computation; never infer an edit from selection notifications.
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
  func present(panes: [EditorPane], axis: PaneAxis) throws
}
```

- [ ] Add failing tests for `splitCurrent(.sideBySide)` and `.stacked`, distinct pane IDs, shared document ID, independent initial scroll/carets, and collapse preserving active pane text/selection/undo.
- [ ] Implement NSSplitView with `isVertical = (axis == .sideBySide)`. Use a 160-point preferred minimum pane extent and constrain divider movement when space permits. The controller sets an appropriate minimum window size during split presentation; the host lays out within its actual bounds and never implicitly collapses/detaches panes on resize. Keep both scroll views constrained to pane bounds. This refinement preserves the user’s chosen split during resizing.
- [ ] Register `view.splitVertical` (“Split Side by Side”), `view.splitHorizontal` (“Split Top and Bottom”), `view.closeSplit` (“Close Other Pane”), and `view.focusOtherPane` (“Focus Other Pane”) in the shared registry. Existing split changes orientation without creating a third pane. Last-pane close is not exposed; closeSplit is disabled with one pane.
- [ ] Assign actual accessibility identifiers `editor.pane.<UUID>` and `editor.text.<UUID>` while preserving the established “Document text” text-view label and distinguishing the pane containers through their own labels/IDs. Expose focus through actual responder changes. Preserve the single document tab/title/dirty indicator; selecting another tab shows that document's own presentation arrangement.
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

## Ownership extraction execution checkpoint

After checkpoint commit0b92dfe, the exact same-file behavioral probe compiled successfully against a copy of the current controller, then failed the cross-view undo assertion with SIGTRAP. Shared storage and visible insertion had passed first. Ignored evidence is under `.local/shared-pane-ownership`; controller source SHA256546cf083d8f1dd33a5470661b075746f0ddf3da48fc477d79d8d196f5d074117. Task1 model/view/pane extraction is now in progress. No visible split or focused-pane command behavior is implemented yet.

Shared highlighter regression: two layout managers on one storage initially failed the second-view color assertion (72016). NativeSyntaxHighlighter now accepts storage ownership, parses once and applies temporary attributes to every attached layout manager; compatibility init(editor:) remains. SharedHighlightHarness passed21565, checking both color application/clearing, exact text and independent selections. This is adapter evidence, not visible split completion.

Ownership extraction reached a real disposal failure after shared undo/redo, detached-origin undo, reuse and uncertainty assertions passed: document released but a view remained retained by native undo history. Investigating document-disposal-only cleanup and executor isolation; never clear history when detaching a pane. No lifetime acceptance claim until the retained-view regression passes.

### Routing audit refinement

Selection-sensitive transformations (line/comment commands, bookmark actions and selection text utilities) must validate the captured pane ID, edit revision, exact selection, attachment and current focus. Snapshot-only statistics/external-command output reads the focused selection at invocation and does not need later focus validation. Save/recovery/encoding/whole-document formatting remain bound to one logical document; hold a stable originating presentation for native transaction calls, never dynamically reinterpret `document.editor` as the latest focused pane inside a suspended callback.

Outline/find result clicks intentionally reactivate a captured document today. Preserve that behavior by binding each panel to an originating pane and explicitly reactivating it after snapshot/range/attachment checks. A blanket current-focus requirement would break cross-tab result navigation. Detached origins must fail clearly. Add tests for stale transform focus changes, result navigation back to the captured attached pane, rejection after detach, save acknowledgements after focus changes, and cross-pane undo of formatting/macros.

Lifetime finding correction: the initial weak assertion ran before AppKit deferred release. A bounded three-second run-loop drain, matching existing NativeLifetime practice, preserved eventual-nil assertions. Both the speculative cleanup variant and the no-cleanup control passed at roughly0.9seconds. No retention cycle was established; speculative isolated-deinit/history clearing was removed. Detached panes retain undo history, and no new disposal/executor contract is introduced.

Task1 focused verification: ownership harness passed at macOS14 deployment target; hidden WindowCheckpoint passed; strict source formatting and diff checks passed. DirtyState initially failed to find the encoding sheet in the tool sandbox on both current and0b92dfe sources. Diagnostics showed AppKit service connection failure; the unchanged retained harness passed with authorized unsandboxed native execution. No product/test patch was needed. Independent frozen-source review found no material issue. The full native extraction run remains pending.

Task1 full core/native50290 passed:199 core tests in8.567seconds, all native integration harnesses including shared ownership/highlighting and both process-kill recovery cases. Independent review is clear. First-pane compatibility accessors are intentionally temporary; no visible split/routing feature is claimed.
