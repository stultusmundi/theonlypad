# Document bookmarks implementation plan

**Goal:** Provide tested native-editor bookmark state, navigation and source-range operations without introducing another text engine.

**Architecture:** Value-semantic sorted UTF-16 line-start anchors remapped using checked TextEdits. Sparse line lookup scans text without allocating a record for every unmarked line. Limit source/result to 100 MB UTF-8 and bookmark count to 10,000. Mixed line endings remain exact in range/export APIs.

**Anchor contract:** Insertions at a bookmarked line start follow the original content. Partial edits retain the bookmark on the surviving original line content; entirely removed logical lines lose their bookmark. Removing a separator may merge bookmarks. CRLF is one separator. The final empty line is bookmarkable. Navigation excludes the current logical line until wrapping. Copy the whole value before an edit and restore that snapshot with native undo/redo: inverse remapping alone cannot recreate deleted/merged bookmark state. A rejected edit never mutates bookmark state.

- [x] Isolated TDD: toggles, mixed-ending ranges/export, wrapping navigation, scalar checks, partial/whole-line edits, insert/delete joins, exact undo snapshots and budgets.
- [x] Implement bounded sparse lookup/remapping and obtain green tests before copying into the root package.
- [x] Document editor integration: ordered successful edits only, explicit bookmark snapshot restoration alongside native undo, no persistence or UI claims.

## Delivered API and verification

`DocumentBookmarks()` starts empty. Bulk construction uses `init(offsets:in:)`, validates checked scalar/line-start positions, sorts and deduplicates. `toggle(atUTF16Offset:in:)`, `removeAll()`, `destination(from:direction:in:)`, `ranges(in:)` and `export(from:)` support native navigation and marked-line operations. `remap(through:in:)` accepts one existing `TextEdit` and the exact pre-edit string; its only mutation occurs after successful validation and mapping. `offsets` is readable, not externally mutable.

Nine isolated tests passed after initial missing-type red. An added exact-no-op replacement regression reproduced deletion of all anchors; byte-exact no-op detection fixed it and the nine-test suite passed again. Cases include mixed CRLF/CR/LF, emoji surrogate refusal, final empty lines, wraparound navigation, partial edits, complete line deletion, join deduplication, before/after value snapshots, stale non-line-start anchors, 200,001 unmarked lines without dense line indexing, 10,000 bookmark capacity, and 100 MB UTF-8 limits. Source and tests were strictly formatted and linted before copying into the shared package.

Commands:

```sh
scripts/swift.sh test --package-path .local/bookmark-core
scripts/swift.sh test --filter DocumentBookmarksTests
```

The first command used an ignored isolated package containing the unchanged existing TextEdits source and the new subsystem; the retained tests live in `Tests/PadCoreTests/DocumentBookmarksTests.swift`. The implementation lives in `Sources/PadCore/DocumentBookmarks.swift`.

## Native integration obligations and unresolved behavior

- Root must associate each state with its document and pass edits in exact order with matching pre-edit text. Structural anchor validation detects invalid positions, not arbitrary stale text that happens to have identical line starts.
- Compute on a value copy before changing native text; commit the new state only after a successful edit. Rejected editor changes leave the prior state intact.
- Capture both pre/post bookmark values alongside the native undo transaction. Text-edit inverse mapping cannot restore deleted/merged bookmarks; toggles and marked-line operations need their own explicit metadata undo policy.
- Entire-document replacements drop bookmarks on entirely replaced logical lines. Exact no-ops preserve them. Sort/format/move commands require explicit semantic remapping or narrower edits if they should retain anchors; this core does not infer correspondence from arbitrary replacement text.
- Sparse metadata is bounded by bookmark count. Lookup/remapping can scan text and construct a checked replacement string; this is not a constant-time editing engine or a measured 100 MB typing-latency guarantee.
- Native controls, gutter rendering, persisted bookmarks, and actual native undo acceptance remain root integration work. This is core behavior evidence, not B-06 end-to-end completion.

## Incremental native adapter refinement

`remap(through:inUTF16:)` reads an unchanged native `NSString` directly; the editor should pass `NSTextStorage.mutableString` to avoid converting/copying its entire buffer. The adapter validates scalar boundaries and existing line starts with random-access UTF-16 reads, shifts untouched anchors, scans removed bookmarked line spans, and normalizes at most one affected-line prefix. It compares only the replaced span for an exact no-op and never constructs a new document string. Native text is not mutated. Work is proportional to bookmark count, edited/affected line content and replacement length; a huge single affected line or full-document replacement can still require a large scan.

The native adapter bounds source/result to `maximumNativeUTF16 = 100_000_000` UTF-16 units, up to 200 MB of UTF-16 backing, so 100 MB ASCII documents remain supported. Replacement text also retains the 100 MB UTF-8 bound. This differs explicitly from the reference String API's UTF-8 source/result byte bound: exact UTF-8 size cannot be proven from arbitrary native storage without scanning it. The reference implementation remains a differential-test oracle and a standalone checked String API; use the native adapter for typing integration.

Twelve tests passed in isolation, including exhaustive scalar-boundary edits across CR/LF/CRLF/emoji/combining fixtures with six replacements and three bookmark configurations. The native and reference results matched. Additional tests verify surrogate/stale-range rejection and the 100-million-unit native boundary without mutating source storage. A synthetic `NSMutableString` with 49,999,996 UTF-16 units and two distant anchors completed 1,000 ordinary in-line remaps in approximately 0.00136 seconds with debug core objects, excluding setup. This is a narrow metadata timing probe, not editor latency or general performance acceptance.

Native undo integration remains separate: commit/register the computed metadata only after a successful native edit, inside the same UndoManager group as its text change. A recursive metadata setter can register the inverse value. During native undo/redo, ordinary remapping must not overwrite the restored snapshots. Grouped typing, IME, canceled preflight changes, programmatic edits, and marked-line operations still require real adapter tests; do not create an unmatched undo group in a preflight delegate callback that may not result in an edit.

## Root native integration evidence

Shared registry now exposes toggle/next/previous/clear/export-to-new-tab and gutter clicks. Metadata is computed against native pre-edit NSString storage, committed in didChange, and registered in the same native undo transaction. Undo/redo restore copied metadata instead of inverse-remapping it. Reload resets metadata; reopening a clean closed tab carries its anchors.

Native missing-navigation regression failed before integration, then edit/insert/delete/undo passed. A separate reviewed duplicate-line regression reproduced unrelated later bookmarks being erased by whole-buffer native replacement. TextDifference now computes a scalar-safe exact changed span off-main for document commands. Native redo and unrelated-bookmark retention now pass in the full harness. One contiguous changed span cannot preserve unchanged islands between multiple separated changes; command-aware mapping remains outstanding. Bookmarks are not yet session-persisted. Native typing/coalescing review is still pending.

### Native composition and typing undo follow-up

Implemented: provisional `setMarkedText` edits update anchors before the next input callback. Composition registers one metadata snapshot before native text undo and waits for the outermost input operation before finalizing. Restoring original replacement text restores anchors removed provisionally. One original-text snapshot is retained per bookmarked composition; ordinary caret typing uses edit-local remapping and one metadata undo snapshot per contiguous insertion run. Window responder Undo resolves the active document manager.

Tested: isolated full AppKit NativeUIHarness passed after formatting. Retained assertions cover repeated marked text, commit, restore-original/unmark behavior compared with plain NSTextView, composition Undo/Redo, contiguous three-character typing undone in one action, history clear, rejected edits, no-op edits, responder Undo/Redo, and workspace field-editor Undo isolation. The field editor retained its own native undo behavior; no additional manager was introduced.

Not claimed: physical input-method interaction, real keyboard event acceptance, or large-document composition latency. `unmarkText` commits; the cancellation fixture explicitly restores original marked text before unmarking.
