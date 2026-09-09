# Shared document pane verification

Status: shared ownership and the native layout container are implemented; visible split commands and integrated pane routing remain outstanding. F-01 is not complete.

Task1 moved storage, dirty state, saved bytes and undo ownership into EditorDocument. Each retained EditorPane owns its layout manager, container, text view, scroll view and quit-selection state. The pool is bounded to two presentations; detach preserves native undo targets and history. Recovery capture revisions and character-edit revisions are separate. Temporary first-pane accessors remain until the routing implementation replaces them.

The initial two-view probe failed exact cross-view undo with the old separate managers. The retained ownership harness passed shared edits/undo/redo, Unicode and normalization-sensitive dirty state, one character observer, separate revisions, detached-origin undo,100 reuse cycles, uncertain-save state and eventual release. An immediate weak-release assertion initially ran before AppKit deferred cleanup; the same bounded run-loop drain passed with and without speculative cleanup. No new disposal cleanup or actor/runtime requirement was adopted.

Task1 was independently reviewed and committed as5f8121c. Full core/native50290 passed199 core tests (8.567seconds) and all native harnesses, including both process-kill recovery cases. An earlier sandboxed DirtyState failure also occurred on the preceding sources; AppKit service access was blocked. The unchanged harness passed with authorized native execution. No test or product behavior was weakened.

The highlighter initially failed to color the second layout manager. Its storage-owned implementation passed SharedHighlightHarness21565 and the full suite: both managers receive/clear temporary colors without changing text or independent selections. Cached-token attachment and full pane metadata fan-out remain later integration work.

EditorPaneHost uses existing scroll views and never allocates document storage or implicitly detaches/collapses panes on resize. The reviewed host candidate passed hidden geometry, both axes, resize/small-bound behavior, invalid-input refusal without mutation, divider-key event handling, focus transfer, labels and ownership checks. Its copied/formatted production source passed EditorPaneHostHarness51449. Text views retain the established “Document text” label. These are in-process event/focus checks, not physical keyboard/mouse, VoiceOver or packaged desktop acceptance.

The routing candidate is still ignored. Its real composition regression demonstrated another pane changing provisional marked text. Initial corrected routing tests now cover shared undo/recovery, a focus change during a suspended transform, composition exclusion and quit/veto state. Existing compatibility runs and independent review are underway; no production routing or visible split controls are claimed.

Current packaged desktop automation requires macOS user authentication. The distribution artifact remains the earlier checkpoint build. Shared-pane packaged workflows, physical IME, accessibility and performance acceptance remain unverified.
