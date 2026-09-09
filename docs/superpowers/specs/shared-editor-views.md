# Shared native editor views: architecture spike

Date: 2026-09-09. Status: executable local feasibility spike; production adoption and F-01/F-02 acceptance remain planned.

## Decision

A shared TextKit 1 document with two independent layout managers is a viable next adapter step. The spike demonstrates synchronized native text edits and shared undo without copying text between views or implementing another text engine. It does not resolve the separately recorded multicursor, rectangular-selection, accessibility, IME, or large-file engine gates. Keep the engine provisional.

Apple describes text storage as the model and layout managers, text containers, and text views as separately configurable objects, including multiple views of one storage. This supports splitting the current ownership model rather than replacing the document/persistence layer. See [Apple's Text System Architecture](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextSystemArchitecture/ArchitectureOverview.html) and [NSTextStorage.addLayoutManager](https://developer.apple.com/documentation/appkit/nstextstorage/addlayoutmanager(_:)).

## Actual experiment

The ignored local source is `.local/spikes/shared-editor/probe.swift`. No production code or dependencies changed. On the available macOS Apple Silicon host, the probe constructed one NSTextStorage, two NSLayoutManagers, one container/view/scroll view per manager, a shared UndoManager, and a native NSSplitView inside an NSWindow. It used synthetic ASCII, decomposed accents, emoji, and 200 repeated lines. All AppKit operations ran on the main actor. Native insertText calls were grouped explicitly, with undo coalescing broken at transaction boundaries.

Commands executed successfully:

```sh
swiftc -module-cache-path .local/spikes/module-cache -parse-as-library \
  .local/spikes/shared-editor/probe.swift -o .local/spikes/shared-editor/probe
.local/spikes/shared-editor/probe
```

The source is intentionally ignored; these commands reproduce the local experiment only where that source exists. This is not a retained CI test. The final build produced no diagnostics and the process exited zero.

| Exercised behavior | Observed result |
| --- | --- |
| Different selections in each pane | Left `{2,1}` and right `{8,2}` retained independently before edits. |
| Native emoji insertion in left pane | Both views immediately exposed exactly equal UTF-16 text. Right selection rebased to `{10,2}`. |
| Native edit notifications | One shouldChangeText callback, one textDidChange callback, and one storage character-edit callback for that insertion. Selection-change notifications were more numerous. |
| Undo/redo through the other pane's manager | Restored original exact UTF-16 text, then restored insertion. |
| Native replacement from right pane | Left reflected replacement; undo/redo through left's manager restored both states. |
| Independent scroll positions | Left scrolled to y=400 while right stayed at zero; right then scrolled to y=150 without moving left. |
| Layout-manager temporary attributes | A red foreground attribute on the left manager was absent on the right. |
| Native responder-chain undo | With a window delegate returning the shared manager, right.tryToPerform(undo:) changed shared text; redo restored the exact preceding state. |
| Detach originating pane | Removed its scroll view and layout manager after an edit; remaining pane still undid and redid that edit. Original view was still retained by the probe. |
| Accessibility capability | AXIsProcessTrusted returned false. No external accessibility workflow was verified. |

The window was constructed but not shown as a user-operated key window. These are in-process native API assertions, not physical typing, menu-shortcut, screenshot, assistive-technology, or IME tests. Detach success does not establish that the originating view can be deallocated safely while its undo history remains.

### Undo routing finding

Sharing overridden NSTextView.undoManager properties was sufficient for direct manager undo/redo. It was insufficient in this particular responder-chain probe: tryToPerform(undo:) returned true while text remained unchanged. Setting NSWindowDelegate.windowWillReturnUndoManager to return the shared manager changed that same probe to perform the edit reversal. NSTextView itself did not report responding directly to undo:; targeting the view directly is not an appropriate substitute for responder-chain routing.

For adoption, both view.undoManager and the window's undo-manager delegate must resolve the focused document's manager. Add an actual application menu/keyboard test; this experiment alone is not a finding against current production menus.

## Current coupling and incremental interface

EditorDocument currently owns one DocumentTextView and one NSScrollView. Storage and layout are created inside its initializer, while the undo manager belongs to DocumentTextView. Dirty state, save snapshots, commands, recovery, and language updates obtain text through that one view. NativeSyntaxHighlighter holds a single view and updates its layout manager's temporary attributes. Delegate lookups identify a document using editor object identity.

Proposed ownership:

```text
EditorDocument (one logical buffer)
  id, NSTextStorage, UndoManager, revision
  URL, original bytes, encoding, saved baseline, save/recovery state
  language, bookmarks, cached highlighting result
  attached panes

EditorPane (one presentation of a buffer)
  id, document reference
  NSLayoutManager -> NSTextContainer -> NSTextView -> NSScrollView
  selection, scroll position, wrap/layout state, ruler, find presentation

EditorWindowController
  document tabs, split arrangement, focused pane ID
  resolve commands and window undo manager through focused pane
```

A transitional computed `editor`/`scroll` accessor for the active pane can reduce the first refactor's call-site churn. Data operations should migrate to `document.storage.string` and document metadata, so changing focus cannot accidentally change the persistence target. Two panes of different documents retain separate storage and undo managers. Two panes of one document share both.

Implement the adapter in these steps:

1. Extract EditorPane construction and inject document-owned storage/undo. Preserve the current one-pane behavior first, with native regressions unchanged.
2. Add pane-to-document identity lookup and first-responder focus reporting. Resolve command selection, status, find, navigation, and undo through the focused pane. Keep bookmark offsets, dirty state, revision, recovery, and file ownership at document scope.
3. Add a second pane in NSSplitView. Attach another layout manager to the same storage. Apply settings/rulers and cached highlighting to every attached pane; parse language tokens once per document and distribute them to managers.
4. Treat a mutation as one document transaction. Capture pending bookmark and macro data before native edits, then update document observers once for the completed character mutation. Do not infer text changes from selection notifications. A storage delegate is a useful common observation point, but requires verified handling of batched replacements, undo, and composition before replacing the existing delegate path.
5. For asynchronous commands, capture document identity/revision and originating pane identity/selection. Reject stale completion or route it according to an explicit focus policy. Freeze all attached panes during save/quit, not just the active one. Flush one recovery snapshot per document.
6. Closing a pane must not close its document or discard shared undo/recovery. Prompt only when the logical document loses its final presentation according to the app's document lifecycle. Explicitly test undo targets and memory release before choosing whether detached panes remain retained until history is cleared.

## Remaining gates and risks

- Physical marked-text composition with Japanese/Chinese input, switching panes mid-composition, committing/cancelling composition, and undo after composition are unverified. Shared text does not imply two independent concurrent compositions are safe. Do not introduce mutation through another pane while a composition policy is undefined.
- Test actual key-window Cmd-Z/Shift-Cmd-Z with focus switching and two documents. Test native undo selection restoration in both panes, event-loop coalescing, macro transactions, bookmarks, and pending asynchronous operations.
- Observer counts above cover one native insertion only. Do not assume every native edit or composition sends exactly one identical callback sequence. Keep AppKit delegates/storage main-actor confined; the probe uses an explicit preconcurrency storage-delegate conformance for its synchronous callbacks.
- Each layout manager adds layout/glyph memory and work. No large-document, long-line, resize, wrap, or highlighting performance claim follows from a roughly 3 KB fixture. Benchmark supported size limits before enabling extra panes without a guard.
- This experiment does not implement dragging documents between windows, tab groups, split persistence, linked scrolling, multicursor, rectangular selection, or a new engine. Those require separate acceptance tests.
- Accessibility navigation, pane labels/focus order, VoiceOver, screenshots, and physical pointer/keyboard interaction remain unverified.

The next implementation can therefore be a contained document/pane ownership refactor with a shared TextKit adapter. There is no evidence here requiring a wholesale rewrite, and no evidence that the full editor feature scope is complete.


## Integration correction after checkpoint/save changes — planned

The production checkpoint and pending-save safeguards added after this spike must survive the pane extraction. This section is a design correction, not new runtime evidence or an implemented pane feature.

Document ownership includes pending-publication evidence/attempted bytes and its forced dirty disposition, so text returned to its old baseline remains recoverable. Uncertain Save As retains the prior logical URL. A checkpoint emits one recovery item/live ID per logical document, regardless of attached presentations, and retains the synchronous pending-close guards even for zero-window application capture.

Distinguish **editRevision** (text mutation identity for stale pane commands) from **recoveryRevision** (the existing immutable capture issuance counter). Capturing unchanged text still advances recoveryRevision. Do not test or implement recovery revisions as one-per-keystroke counters. One document-owned character observer notifies the single application checkpoint scheduler; the second pane must not create another recovery timer/writer.

Quit selection state is per presentation: preserve each pane's prior isSelectable, disable editability/selectability across all panes, guard tab/popup/ruler callbacks while frozen, and restore prior values on veto, including repeated cancellation. Retain bounded detached views for shared native undo; this remains a lifecycle policy to validate, not proof that undo targets can be deallocated.

The first implementation gate is behavioral: two current DocumentTextViews share one NSTextStorage but allocate separate UndoManagers. Insert through view A, invoke undo through view B, and assert exact mixed-ending/emoji UTF16 restoration. Expect this to fail before document-owned manager injection; a missing-type compiler error is insufficient evidence for that behavior. The executable probe, proposed injected-manager interface, ownership boundaries and subsequent native/desktop gates are in [the shared-pane implementation plan](../plans/2026-09-09-shared-document-panes.md). No code, build, GUI run or engine migration was performed for this amendment.
