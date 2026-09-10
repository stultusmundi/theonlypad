# Pane origin layout cost: initial pilot

Exploratory measurements only; no production layout ceiling or performance acceptance is established.

On the recorded Apple M4 Pro/48 GiB macOS26.6.2 reference host, twelve fixed native processes measured the first explicit `DocumentPanePresentation.applyOrigin` call. Each used one pane, 65,536 UTF-16 units of synthetic ASCII and requested origin(0,240). The three shapes were dense 64-column rows, one long paragraph, and dense text around a long paragraph. Each baseline/candidate pair ran once, alternating order. There was no overlapping project build or GUI test during the pilot.

The baseline is the same frozen private candidate with only its new `ensureLayout(forBoundingRect:in:)` statement removed. It is not a pristine historical build. No window, event posting, explicit pre-layout or run-loop pumping occurred. Construction and ordinary AppKit geometry access can cause implicit layout, so this does not establish cold TextKit state or measure deferred work.

| Shape | Wrap | Baseline call (ms) | Candidate call (ms) | Candidate origin outcome |
| --- | --- | ---: | ---: | --- |
| dense | Off | 0.086 | 0.528 | clamped |
| dense | On | 0.046 | 0.434 | applied |
| long | Off | 0.085 | 3.537 | clamped |
| long | On | 0.061 | 6.775 | applied |
| mixed | Off | 0.064 | 0.445 | clamped |
| mixed | On | 0.046 | 0.415 | applied |

All twelve processes returned zero with confirmed direct-child wait and complete untruncated output; none exceeded the 100ms post-return stop threshold or 512MiB recorded RSS threshold. Observed process peak RSS was approximately61–64MiB, including setup and framework costs. Those thresholds are stopping rules, not in-call cancellation or memory limits; the separate owned watchdog imposes a15-second process timeout.

Clamped results remain clamped: several unwrapped fixtures produced a negative horizontal origin, and layout of the single unwrapped paragraph corrected its vertical extent. No literal-origin correctness claim follows from an admitted timing sample. Larger inputs, deeper/out-of-bounds positions, two panes, complex Unicode/font fallback and repeated per-case samples remain required before selecting eligibility. These results are neither p95 input latency nor100MB/1GB acceptance.

Private evidence: `.local/pane-layout-cost/pilot-20260910-104503/`. The232-input execution manifest SHA256 is `edde35ade51ff4995f190e29af56a82bb894adafffede3f911f63654559f4164`; baseline executable `6438d594ae7f90e770d2696e847af3acaa949c4b6eadca3a9db20a039eaf2fe9`; candidate executable `292ddf2a52992816eb380fb1472666869c467eb283512e73ed2d547f3a43204f`. Both compiled with optimization, Swift5 language mode and arm64/macOS14 target. Raw sources, compiler receipts, exact bytes/geometry and self-process memory results remain ignored/private.


## First256Ki batch refused before timing

The reviewed v2 coordinator's first `ascii256-low-p1` invocation stopped after its first baseline process. The native fixture returned125 (`LayoutCostNominalFont`) before any timed origin call. The owned watchdog confirmed wait125 and complete capture, without timeout, truncation, interruption or cleanup failure. No v2 measurement was accepted and no remaining case was launched.

Inspection found that fixture initialization set the editor font while storage was empty, then populated storage without reapplying the actual controller's font/paragraph configuration. The refusal does not report enough detail to distinguish nil font from wrong size or empty name. That exact distinction remains unmeasured. The earlier65,536-unit pilot used the same setup without an effective-font assertion; its retained timings remain observations of that fixture and must not be described as verified13pt typography.

The failure is retained under `.local/pane-layout-cost/v2/batch-ascii256-low-p1-20260910-112509/`. A corrected setup/diagnostic proposal is being reviewed; original inputs, binaries and results remain frozen. No automatic retry, p95 or production layout ceiling follows from this refusal.
