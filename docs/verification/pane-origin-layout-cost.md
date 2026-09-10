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

Inspection found that fixture initialization set the editor font while storage was empty, then populated storage without reapplying the actual controller's font/paragraph configuration. The initial refusal did not distinguish nil font from wrong size or empty name. A separate frozen single-case diagnostic subsequently observed a present Helvetica font at12pt (`wrong-size`). It read the existing font getter once and exited125 before any origin call; its complete owned-process receipt recorded0.594s with no timeout or cleanup failure. This is a fixture diagnosis, not a layout measurement. The earlier65,536-unit pilot used the same setup without an effective-font assertion; its retained timings remain observations of that fixture and must not be described as verified13pt typography.

The failure is retained under `.local/pane-layout-cost/v2/batch-ascii256-low-p1-20260910-112509/`. The diagnostic and its145-input manifest remain private under `.local/pane-layout-cost/font-diagnostic/`. A corrected post-population typography fixture is being compiled separately; original inputs, binaries and results remain frozen. No automatic retry, p95 or production layout ceiling follows from this refusal.

## Corrected typography: one256Ki pair

A separate frozen v3 fixture now applies the controller's typography sequence after content population and pane construction. It preserves the effective-font guard and records typography as a subtotal within full setup. Both native processes observed `.AppleSystemUIFontMonospaced-Regular` at13pt. No window, event, run-loop pump, attribute scan or explicit prerequisite layout was added; ordinary AppKit setters can still trigger implicit layout.

Root ran exactly one baseline and one candidate for262,144 UTF-16 units of dense ASCII, wrap off, one pane, requested origin(0,240), with all other project commands paused. Both completed the15-second owned watchdog and strict receipt/input/fixture validation without failure.

| Variant | Origin call (ms) | Full setup (ms) | Typography subtotal (ms) | Actual origin | Peak process memory (MiB) |
|---|---:|---:|---:|---|---:|
| Baseline | 0.098459 | 103.209334 | 0.413042 | (-68,240), clamped | 63.422 |
| Candidate | 0.578333 | 107.220959 | 0.449208 | (0,240), applied | 63.391 |

The new fixture is not a size-only extension of the earlier pilot: its typography setup differs. This single pair establishes neither p95 nor cold-engine behavior, long-line/Unicode/split performance, or a production ceiling. Historical refused results remain intact. No further batch was run.

Private evidence is `.local/pane-layout-cost/typography-fixture-v3/`, with246-entry review manifest `3e9d6aea0cf1f74a325da6af881271eea166f81db73fb27c173bf7c4922e58f2`. Baseline executable SHA256 `e39f80acc6b8e7513ec0bb3b332ac477f0d48de7068a0c0962e915029443e496`; candidate `bc96ebf972d6c35733ef942e70802d497b4bd6579d76a5164dfada706afd56b9`. Both final compilations and eight pure fixture-validator checks passed before execution. Raw receipts and exact input bytes remain private.

## Corrected v4 first ASCII batch — actual execution

The corrected fixture ran the exact reviewed twelve-process `ascii256-low-p1` batch on the same reference machine, with all three workers explicitly command-idle. Every process used262144 UTF16 units, one pane, requested origin(0,240), and verified13pt system-monospaced typography after text population. There is one sample per case/variant; these are not p95 measurements.

| Shape / wrap | Baseline origin ms | Candidate origin ms | Candidate actual origin | Largest observed peak MiB in pair |
| --- | ---: | ---: | --- | ---: |
| Dense / off | 0.100500 | 0.539833 | (0,240) applied | 57.563 |
| Dense / on | 0.045583 | 0.618417 | (0,240) applied | 57.641 |
| Long line / off | 0.113166 | 10.733375 | (0,0) clamped | 68.000 |
| Long line / on | 0.048917 | 24.603375 | (0,240) applied | 69.109 |
| Mixed / off | 0.088667 | 0.512833 | (0,240) applied | 57.719 |
| Mixed / on | 0.041000 | 0.620542 | (0,240) applied | 57.719 |

All nowrap baselines reported(-68,240) clamped; wrapped baselines reported(0,240) applied. The candidate long-line nowrap result remains clamped: this batch does not prove exact origin restoration for every shape. Full setup ranged97.586–154.233ms, outside the separately timed origin calls. Construction may implicitly lay out; engine-cold state is not established.

The parent coordinator exited0. Root independently revalidated all12 strict ownership/wait/capture receipts, native typography/geometry/timing/memory records, exact batch ordering, frozen hashes and complete209-entry compiler input inventory. No watchdog timeout, truncation or interruption occurred. No other native batch ran.100ms origin-call/summed-call and512MiB post-return limits were not reached; these remain expansion stops rather than in-call resource guarantees.

Private evidence: `.local/pane-layout-cost/typography-matrix-v4/batch-ascii256-low-p1-20260910-121741/`, including `root-verified-summary.json`. Execution manifest SHA256: `6b1ba9a0932ea999fef3a9683ecc7c4b56944edaf4ccc7ec3659cb5979bf63cb`. Baseline binary SHA256: `6778dfb5745620e39a3a1dafe14f305a71efebd0adb844ad8c13e03b6b75593e`; candidate: `d518ca4ee8295036a765564c1a3e8d7997b0b282d62b04d35509d20821f33f52`.

Before execution, the Python coordinator's manifest resolver, fixture hash, receipt boundary, input inventory and progress controls were corrected. The receipt validator is an exact copy of the accepted v3 implementation. Eight expanded pure tests pass, including injected coordinator traversal and12-item order, first-failure stop, input additions before/between children, typed receipt rejection and a consistent two-pane summed-duration threshold control. Original faulty Python, manifests, binaries and compile receipts remain preserved; no failed attempt was relabeled a success.

Deep origins, two panes, Unicode shaping/fallback fixtures and repeated exact cases remain unmeasured in v4. These results do not select a production ceiling or justify unbounded eager layout. In particular, the long wrapped line already costs24.603ms at this small size.
