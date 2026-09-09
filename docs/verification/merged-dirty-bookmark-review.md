# Merged dirty-state and bookmark undo review

Date: 2026-09-09. Bounded differential review of the document/view mutation observers, bookmark undo registrations, responder routing, and NativeUIHarness/DirtyStateHarness. This is not a full repository or feature-completeness review. Production edits belonged to root/document_core; this reviewer changed only retained tests, ignored probes, and review documentation.

## Method and baseline

Used the installed differential-review workflow: inspect changed state transitions, trace ownership, inspect tests, examine relevant history, and reproduce a concrete failure before recommending a fix. The relevant tracked baseline is commit `60eaaf7`; the current bookmark and dirty-cache changes were uncommitted at review. Git blame identified the reviewed bookmark undo block as working-tree code. Eight dirty getter call sites and four controller-targeted undo registrations were traced. Existing tests cover native composition commit/cancel, undo/redo, typing coalescence, rejected edits, and a field editor's responder-chain undo.

## Material finding: closed documents retained by undo closures

**P2, addressed by root's weak-document captures; retained regression added.**

The bookmark setter, composition undo, ordinary typing undo, and encoding setter registered undo closures that strongly captured EditorDocument. The document owns its editor and undo manager, which owns the closure. That cycle can retain closed text buffers, original bytes, storage and views after their controller has released them, even after eviction from the ten-item closed-tab history.

An ignored ownership probe used the copied current EditorDocument and the exact bookmark registration pattern. Without history the document released. With the strong capture and no remaining strong external references to the document or undo manager, it remained alive. Removing undo actions through a weak manager reference released it.

Root changed all four registrations to weakly capture the document and unwrap it only during undo execution. The controller remains the undo target. Actual native controller lifetime tests establish that changing that target or clearing all native undo history is not required by the observed ownership behavior: native text undo/redo history alone released after closure, and the weak-capture version released controller, editor and window across the exercised cases.

## Retained lifetime regression

`Tests/NativeIntegration/NativeLifetimeHarness.swift` creates only synthetic documents and uses weak references to the actual controller, editor and window. It closes clean windows without discard prompts, drops all strong fixture references, and drains the run loop before asserting release. Cases include plain windows, native text undo, bookmark-only history, ordinary typing before a bookmarked later line, composition before that line, and encoding conversion followed by undo.

The three-second release deadline is a functional lifecycle guard rather than a performance target. The harness does not retain an undo manager while checking release. Its negative-control build restores only the four strong document captures in ignored copied sources. Root added this harness to the native integration script using the same compilation pattern as DirtyStateHarness.

Final isolated red/green evidence: the weak-capture binary exited zero and released controller, editor and window in all six cases. Restoring the four strong captures made the same retained harness fail (exit -5): editors remained alive in bookmark-only, bookmark-typing, bookmark-composition and encoding-undo cases. Plain and native-text-undo controls still released, and controllers/windows released in every case. Both binaries used the tightened later-line bookmark fixture. This directly identifies the strong document captures as the retained-resource cause.

## Reviewed paths without an additional material finding

- Dirty text equality remains exact UTF-16; saved-baseline assignment and character-edit notifications invalidate the cache. Reads during unfinished storage batches bypass stale cached results. Encoding and BOM remain independent comparisons. The observer captures the document weakly and is removed at deinitialization.
- Composition operation depth prevents nested setMarkedText calls inside unmarkText from finalizing early. The native harness tests provisional updates, committed undo/redo, cancellation restoring deleted anchors, and comparison with plain NSTextView behavior. This is API evidence, not physical IME acceptance.
- The window delegate supplies the selected document's undo manager. NativeUIHarness explicitly exercises responder-chain undo/redo and verifies undo inside the workspace search field leaves document text unchanged. No further first-responder isolation defect was reproduced during this bounded review.

The known large-file same-length comparison and long-line latency issues remain separately documented in `native-editor-performance.md`; they are not new findings in this review. Current combined production tests and packaging remain root's integration responsibility.
