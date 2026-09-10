# Shared document pane verification

Status: shared ownership, both visible split orientations, pane routing and cache/settings fan-out are implemented and covered by native tests. The packaged shared-edit/undo and scratch-pane restart workflows passed on2026-09-10 as recorded below. Scroll restoration has a separate failing desktop check; physical IME/accessibility and performance acceptance remain outstanding. F-01 is not complete.

Task1 moved storage, dirty state, saved bytes and undo ownership into EditorDocument. Each retained EditorPane owns its layout manager, container, text view, scroll view and quit-selection state. The pool is bounded to two presentations; detach preserves native undo targets and history. Recovery capture revisions and character-edit revisions are separate. Temporary first-pane accessors remain for compatibility; controller commands now use explicit pane routing.

The initial two-view probe failed exact cross-view undo with the old separate managers. The retained ownership harness passed shared edits/undo/redo, Unicode and normalization-sensitive dirty state, one character observer, separate revisions, detached-origin undo,100 reuse cycles, uncertain-save state and eventual release. An immediate weak-release assertion initially ran before AppKit deferred cleanup; the same bounded run-loop drain passed with and without speculative cleanup. No new disposal cleanup or actor/runtime requirement was adopted.

Task1 was independently reviewed and committed as5f8121c. Full core/native50290 passed199 core tests (8.567seconds) and all native harnesses, including both process-kill recovery cases. An earlier sandboxed DirtyState failure also occurred on the preceding sources; AppKit service access was blocked. The unchanged harness passed with authorized native execution. No test or product behavior was weakened.

The highlighter initially failed to color the second layout manager. Its storage-owned implementation passed SharedHighlightHarness21565 and the full suite: both managers receive/clear temporary colors without changing text or independent selections. Cached-token attachment and full pane metadata fan-out remain later integration work.

EditorPaneHost uses existing scroll views and never allocates document storage or implicitly detaches/collapses panes on resize. The reviewed host candidate passed hidden geometry, both axes, resize/small-bound behavior, invalid-input refusal without mutation, divider-key event handling, focus transfer, labels and ownership checks. Its copied/formatted production source passed EditorPaneHostHarness51449. Text views retain the established “Document text” label. These are in-process event/focus checks, not physical keyboard/mouse, VoiceOver or packaged desktop acceptance.

At the routing checkpoint, its real composition regression demonstrated another pane changing provisional marked text. Retained tests cover shared undo/recovery, stale focus/selection/revision/attachment/tab results, composition exclusion, all-pane save/quit protection, explicit Find/Outline source reactivation, orphan callbacks, and late close/JSON/encoding results. Each of14 modes passed in that integrated native suite. Visible controls were integrated in the later checkpoint below.

Current packaged desktop automation requires macOS user authentication. The distribution artifact now contains the visible-pane implementation; its packaged workflows have not executed. Physical IME, accessibility and performance acceptance remain unverified.

## Shared highlighting cache integration checkpoint

The ignored cache candidate compiled and passed its real-owner harness on the first execution. It was copied into production with the single invalidation call in EditorDocument's existing character observer, and passed the full integrated native run6143. There was no pre-implementation behavioral red for this addition.

The controlled parser verifies one invocation for both layouts, cached attachment without reparsing, rejection of foreign/detached layouts, invalidation after text changes away and back, and rejection of a cancelled parser that deliberately returns stale tokens. Exact Unicode/mixed-ending bytes, selections, undo availability and temporary-only attributes are preserved. Plain text and buffers above two million UTF-16 units do not parse.

Independent source review found no material issue in generation, attachment, range, cancellation or ownership checks. Pending-parser disposal and malformed injected ranges were source-reviewed, not directly exercised. Automatic cache application through visible pane attachment and packaged desktop acceptance remain outstanding.

## Integrated routing verification

Core204 tests passed10.355seconds. First native run94053 passed all14 routing modes but stalled in LaunchHarness: batched launch requests were incorrectly subject to current-focus validation. A stack sample identified navigate -> present -> modal; the owned process was terminated, so this run exited143 and is not a pass. A modal-mode watchdog then reproduced a bounded assertion failure75031. Launch requests now use captured-document navigation while interactive Go to Line retains strict focus validation; the unchanged exact path/position/batch assertions passed30675.

Full native retry6143 exited0, including all routing/cache/ownership harnesses, save failures, encoding/BOM undo, lifetime release, window/session restoration, tabs/recent files, and both process-kill recovery cases. Subsequent sibling-focus regression97984 reproduced delayed launch navigation stealing focus from the other pane. Gating the final focus request by the interactive policy fixed it; the retained15th routing mode and exact LaunchHarness both passed68373. Independent final review found no material issue. The full suite was not repeated after that narrow focus refinement; its directly affected two-pane and real launch workflows were rerun. Packaged desktop automation remains blocked on user authentication; prior package results do not apply to these sources.

## Visible controls integration

An unchanged controller failed the real split command assertion before implementation. The candidate adds both axes, collapse/focus actions, bounded pane reuse, per-document in-process orientation, shared undo/recovery, copied view settings and cached highlighting. A second behavioral red showed NSTextView construction resetting the existing shared font from18pt to13pt; capturing settings before construction fixed it. Another test required a visible explanation when large-document splitting is disabled. All four candidate modes passed, along with five compatibility harnesses and the15 routing modes. Switching a detached colored pane to plain text without editing passed unchanged; no speculative cache fix was made.

Production verification: core204 passed8.952seconds; the complete native suite32534 exited0. This includes the four visible modes, real AppDelegate/menu registry split-focus-collapse assertions, all routing cases, save/encoding/lifetime/session checks and both process-kill recovery cases. Independent source review found no material issue. The desktop target, including two new split tests, compiled with `xcodebuild build-for-testing`21390; those tests have not executed.

Adding another pane is provisionally limited to2,000,000 UTF-16 units, with a visible status explanation. Existing two-pane layouts can change orientation. That initial slice restored one presentation per logical tab. Later work added persisted pane orientation and selections; see [pane presentation](persisted-pane-presentation.md) and the current desktop evidence below. Linked scrolling remains outstanding. The initial adapter matrix completed six of 18 cases; twelve visibility failures remain incomplete measurements. See [the benchmark record](shared-pane-performance.md) for all outcomes and long-line costs. These native results do not establish physical keyboard/IME/VoiceOver behavior, packaged desktop acceptance or performance targets.

## Packaged shared-pane workflows — 2026-09-10

Against unchanged packaged source55a7b1b (executable SHA256 `f02db4960212814ea8cbf38b351f466081f310a4ec1db7135a2f6a62f70525eb`), both real desktop tests passed:

- Shared editing through both panes, grouped undo/redo, both orientations, focus routing, collapse, save with exact disk bytes, quit/restart, restored two-pane content/axis and one logical tab:61.559 seconds.
- Two unsaved scratch panes, shared content, normal quit/restart, restored two-pane content/axis and one persisted logical tab:27.681 seconds.

The tests now require the implemented two-pane restoration instead of the earlier one-pane behavior. Pane ordering uses fixed container frames because document text frames move during scrolling. Immediate accessibility probes avoid unnecessary XCTest polling delays; all fallback waits and the original120-second execution limit remain. Independent review approved these harness corrections. The long workflow previously expired while still progressing through menu actions; it now completes without raising its time limit.

Private source provenance/results: `.local/desktop-ui/pane-harness-retry-rdjm4__b/`. The same three-test run also includes a **failing** scroll-restoration test, so its overall exit is65. Earlier launch-only failures were caused by an owned app instance left running after a shortcut-test timeout; exact-instance normal termination resolved that infrastructure problem. This evidence does not close the scroll, accessibility, IME or performance requirements.
