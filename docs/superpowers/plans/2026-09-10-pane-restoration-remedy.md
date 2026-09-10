# Pane restoration remedy implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement and review each task. Routine human checkpoints are waived by BUILD_PROMPT; independent review and actual verification remain required.

**Goal:** Preserve restored pane positions and preferred-editor input while keeping document typography, wrap, transfer and close receipts coherent.

**Architecture:** Native document state records applied typography and wrap separately from the window's desired settings. A synchronous document token excludes reentrant edits and ownership changes during native configuration. Origin layout eligibility is selected from measured cost evidence; the small private candidate is not a production implementation.

**Tech stack:** Swift5 language mode, macOS14+, AppKit/TextKit1; no new dependency.

**Spec:** [Reviewed design](../specs/2026-09-10-pane-restoration-remedy.md).

**Requirement coverage:** A-06 session restoration, A-10 preservation of edits, F-01 shared splits, F-02 transfer, F-06 themes/settings, H-08 preferences, I-01/I-05/I-06 responsiveness and measurement, T-05/T-07/T-08 desktop/Unicode/performance validation. These aggregate IDs remain partial after this scoped remedy unless every other clause is independently accepted.

## Constraints and interfaces

Preserve the existing shared NSTextStorage, undo and recovery authorities. Preserve source styling during transfer; reconcile to destination settings on the next accepted applySettings. Manual wrap follows existing policy. Never use document-wide attribute comparison to decide whether settings are already applied. No private tracing enters the package. Root owns all visible UI and measurement intervals; parallel workers can modify disjoint files only.

New native value types belong in `Sources/TheOnlyPad/DocumentAppliedSettings.swift`: an Equatable scalar typography signature and a resolved plan retaining font/paragraph objects. `EditorDocument` owns optional applied typography/wrap and an exact configuration token. `settingsApplied` becomes derived. Applied-state changes rotate close-mutation generation. These are internal native implementation details, not public PadCore API or new persisted preferences.

## Task 0: Native regression runner prerequisite

Files: `scripts/test-native-document-transfer.sh`, `scripts/test-editor-transfer-projection.sh`, `scripts/test-native-close-model.sh`; a shared coordinator under `Tests/NativeIntegration/` if useful; corresponding pure coordinator tests. Own these files explicitly before parallel implementation.

- [ ] Preserve each runner's exact source transformations, build prerequisites and assertions while replacing its legacy session-owning Popen/wait cleanup with the accepted frozen watchdog imported and called by the same coordinator process. Do not wrap the old runner in a second session owner.
- [ ] Freeze all required native sources, test-only access extensions and build inputs; include `DocumentAppliedSettings.swift` when introduced. Selective source-list runners must not accidentally omit it. Recheck hashes after execution and retain complete wait/capture receipts plus positive test counts.
- [ ] Add pure failure cases for failed/missing receipts, source changes and zero-test success. Run the unchanged transfer/projection/close suites through the migrated coordinators; document built-product prerequisites exactly. Review this independently before using the runners for Task1/2.

## Task 1: Applied state, configuration admission and settings reconciliation

Files: new `DocumentAppliedSettings.swift`; `EditorDocument.swift`, `EditorWindowController.swift`, `EditorDocumentCloseAdapter.swift`, `EditorDocumentTransferAdapter.swift`; new `Tests/NativeIntegration/DocumentAppliedSettingsTests.swift` and `scripts/test-document-applied-settings.sh`; update `Tests/NativeIntegration/EditorDocumentTransferTests.swift`, whose writable settingsApplied assumption must migrate atomically. Include only exact required native sources in the frozen test harness. Transfer receipt reconstruction in the controller changes atomically with the new receipt fields so each commit compiles.

- [ ] Add observable red tests: identical/theme-only settings preserve both pane origins and avoid native typography writes; changed typography applies to every pane; manual wrap resets on the next settings application; a transferred differently styled document reconciles even when destination settings are unchanged.
- [ ] Add resolver tests for unavailable named-font fallback, resolved identity, tab width and size changes. Assert effective native font/paragraph values, not only cache fields.
- [ ] Add a deterministic native-setter reentry seam in the test adapter. While the exact token is active, native insertion/marked-text/undo, selection/focus/pane commands, transfer capture and close capture must refuse; a stale callback cannot publish proof or clear another token.
- [ ] Implement per-document reconciliation and exact token admission across those paths. Keep component proof unknown after incomplete application. Preserve AppDelegate's ready-time and late-load settings delivery.
- [ ] Extend transfer receipts and both controller reconstruction helpers to retain original applied state. Include desired policy for both source and destination in endpoint capture/validation, including an empty destination whose settings change during transfer. Preserve captured endpoint policy in `replacementTransferReceipt`; do not refresh it from a potentially changed controller.
- [ ] Exercise new/reused pane inheritance; construction can affect shared storage, so token/proof must cover it. Keep semantic wrap distinct from host-size geometry.
- [ ] Run the new harness under the accepted same-process watchdog with meaningful test count, source hashes and complete receipts. Run existing native transfer/close/projection regressions against the candidate. Review and resolve findings before a local commit.

Proposed new command, not yet proven: `scripts/test-document-applied-settings.sh`. After Task0 migration, existing commands to run with their documented built-product prerequisites: `scripts/test-native-document-transfer.sh`, `scripts/test-editor-transfer-projection.sh`, `scripts/test-native-close-model.sh`. Do not nest independently session-owning watchdogs.

## Task 2: Preferred responder restoration

Files: `EditorWindowController.swift`; `Tests/NativeIntegration/EditorTransferProjectionTests.swift` and its existing runner. Reference private candidate `.local/pane-origin-diagnostic`; copy only reviewed behavior, never diagnostic hooks.

- [ ] Reproduce the startup responder loss with actual native insertion for single pane and both split orientations, plus the existing projection cases.
- [ ] Make projected focus return acceptance; require exact actual first responder before committing and after origin callbacks. Installation outside a projection uses ordinary focus; installation inside a projection uses only its scoped helper.
- [ ] Inject responder refusal and verify existing rollback preserves ownership, panes and session state. Keep general admission intact.
- [ ] Run the focused regression and existing projection/transfer controls, then independent review and local commit.

Existing runner: `scripts/test-editor-transfer-projection.sh`. Passing hidden native tests does not establish real desktop input.

## Task 3: Measured origin-layout eligibility

Files: `DocumentPanePresentation.swift`; corresponding native presentation tests; sanitized cost evidence. Depends on reviewed measured eligibility, not an assumed viewport cost bound.

- [ ] Complete the reviewed individual v2 layout risk batches, stopping on any failure,100ms per-call/summed-call or512MiB observed limit. Retain all receipts, including failures. Follow with separately selected combining-cluster and typography probes, then repeated exact-case measurements before selecting eligibility.
- [ ] Select/document a total UTF16 ceiling no greater than2M and any typography eligibility restriction justified by results. A requested viewport rectangle is not a work bound. Record remaining implicit AppKit work even when eager layout is skipped. If no tested input/typography class meets the budget, keep eager layout unpromoted, retain existing constrain/scroll behavior with honest clamped/unavailable results, and leave this requirement outstanding; do not choose a ceiling solely to finish the plan.
- [ ] Add red tests for finite geometry, eligibility boundaries, attached pane/layout manager, skipped eager calls above the ceiling, and correct clamped/applied outcomes below it.
- [ ] Implement the one viewport ensureLayout request only for admitted inputs before origin constraint. Do not introduce full layout or diagnostic glyph queries.
- [ ] Verify neighboring pane selection/history/resize and transfer behavior, review, and commit. Do not describe post-return measurements as hard100ms cancellation.

The v2 runner remains private until its source/receipt review completes. No unproven runner command is added to AGENTS.

## Task 4: Integrated desktop and package acceptance

- [ ] Build a clean committed checkout with exact source hashes and package/archive/SBOM checks.
- [ ] Root runs both original complete persisted-pane desktop orientations through third launch, preferred-pane typing, shared content, undo, other-pane typing and undo. Preserve assertions and120s allowance; no retry to hide failure.
- [ ] Exercise cross-window transfer between differing settings, subsequent unchanged destination settings, new/reused panes, theme-only change and actual changed typography in the desktop app. Include save/quit/reopen and close rollback neighbors.
- [ ] Measure actual changed-typography cost separately; removing redundant setters does not resolve changed-settings latency.
- [ ] Resolve material reviews, rerun only affected tests, sanitize evidence, update requirements A/F/H/I/T and continuation. Promote verified local artifacts only after acceptance. Full BUILD_PROMPT remains outstanding beyond this remedy.
