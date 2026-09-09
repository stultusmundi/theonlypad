# Integration review — 2026-09-09

Independent agents reviewed storage/UI boundaries, editing, search, language tools, macros and packaging. This is a development review, not final product acceptance.

Material findings addressed with regressions:

- Canonical Swift String equality missed normalization-only dirty edits: exact UTF16 comparison now protects close/recovery.
- Save As could infer consent for a raced-in destination: different existing paths are now refused; safe overwrite UX remains outstanding.
- Dedup changed surviving line endings and collapsed byte-distinct Unicode: exact UTF8 identities retain separators.
- Shortcut modifier permutations bypassed collisions: normalized modifiers; native modifier mapping corrected.
- Palette/main-window dispatch could target another editor: main-window lookup; large viewer commands separately guarded.
- JSON reserialization rounded numbers and removed duplicate keys: validation followed by scalar-based lexeme-preserving whitespace formatting, with an8MB output budget. Regression includes a leading combining scalar inside a string.
- Unterminated comments caused quadratic regex highlighting: replaced with bounded linear lexical scanning and worker cancellation.
- Capture-heavy search exceeded practical memory bounds: aggregate capture-range slots capped in addition to result count. Replacement spans are budgeted before allocation.
- Native traffic-light closure bypassed SearchPanelController.close: window delegate cancels work; replacement confirmation checks generation again.
- Macro replacement accounting ignored deleted text; final command missed cancellation: corrected budgets and final checks.
- System reopen events bypassed asynchronous quit guard: system open/reopen now refuse new work during quit flush. Closed-window cleanup is drained before termination.

Remaining material limits are explicit in README/matrix: atomic last-check/rename race with independent writers, metadata/backups, full macro/extension/commands/workspace scope, grammar completeness, unmeasured real input latency, and absent desktop acceptance. There has been no remote publication or final completion declaration.

## Additional integration review

- Command windows now remain retained individually until close. Macro/extension/palette singleton windows are closed before replacement, avoiding visible windows with deallocated targets.
- External-command shutdown now gates new Run actions before awaiting active process cancellation. An independent two-panel native probe attempted a new Run during a TERM-resistant child cancellation; no second process launched and none escaped the drain. Descendant processes remain explicitly outside the cancellation guarantee.
- Atomic save conflict checks now verify expected size and read at most expected bytes plus one, preventing unbounded reads if an external writer enlarges the file. Sparse1GB regression added; full suite rerun pending. Final rename races and metadata limitations remain documented.
- Printing clones source text into an independent view; native PDF generation passed. Pagination and actual print-dialog workflow remain unverified.
- Extension commands dispatch through the shared registry into existing edit transactions. Runtime code loading is absent; this declarative API is limited to the documented text-transform capability.

### Unsaved macro regression

Independent review identified volatile recorded commands being cleared after Stop → Cancel → Start, and not protected by window-close/app-quit checks. The native harness reproduced the lost recording (failed exact command-sequence assertion). Root added a shared pending-recording guard: save or explicitly discard before replacing the recording, closing its window, or quitting. Ordinary document recovery is independent; unsaved macro drafts are still not crash-persisted. The complete native script then passed, including the new lost-recording regression and neighboring workflows.

### Folder result consistency

Changing search roots now clears previous results and cancels/invalidate pending work. Clicked results are revalidated against the original root before callbacks; the editor independently rejects stale text/ranges. Both UI failures were reproduced in the retained native harness and the fixes passed there.
