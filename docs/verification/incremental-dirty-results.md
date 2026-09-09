# Exact dirty candidate: unchanged controller protocol results

Executed 2026-09-09 against the isolated candidate. Production extraction was subsequently integrated and verified separately below. Same actual-controller harness/runner bytes as baseline: ControllerLatencyProbe SHA256 af9d675cacbd9c16f384135f5956c05672e274b6a1f7cb96b08b385b08432de6; run.py SHA25666e3ccc85d67b580cdedbe8cc6e4b3fb7e5d45cd024093d4b8ce520f202980fc. Native sources Swift-O/current linked PadCore; same reference Apple M4 Pro48GiB, macOS26.6.2, Swift6.3.3.

Compile builds/compile.30ErePMZ passed.100MB work-bound run20260909T165839.947771Z-b2b4f1c8 passed the unchanged<=4096 comparison-span assertion and all18 functional/visibility operations, exit0. First replacement submitted35units versus baseline100,000,000; total21.00ms/comparator0.0118ms. Genuine baseline red remains preserved separately.

Measurement runs20260909T165940.789588Z-6f07df0d (100MB) and20260909T170058.665985Z-45cdd7d5 (10MB) each completed three fresh child processes and54operations. All six children exited0; no watchdog, exact-oracle, history or strict admission failure. Each child reaped; exclusive slot released before summary. Controller checkpoint callback remained noop as baseline; no hidden recovery workload was introduced or removed between variants.

## Comparison

Nine samples/operation/size. Median edit+layout/display and maximum are milliseconds. With9samples nearest-rank p95 equals maximum; no first-edit samples discarded. Navigation separately measured before operations. Every post-native-operation target ensureLayout, sizeToFit, scrolling, display/event drain and geometry capture stayed inside edit timer; no selection/layout repairs after timing. Full exact oracle remained outside timing. Native resulting selections retained and checked.

| MB | Operation | Baseline median | Candidate median | Baseline max | Candidate max |
|---|---|---:|---:|---:|---:|
| 100 | replace | 452.98 | 19.24 | 465.59 | 25.13 |
| 100 | undo | 454.20 | 15.67 | 459.69 | 21.94 |
| 100 | redo | 432.80 | 7.13 | 452.97 | 8.12 |
| 100 | restore | 456.23 | 16.35 | 457.95 | 19.36 |
| 100 | append | 16.75 | 18.90 | 22.43 | 22.04 |
| 100 | undoAppend | 450.72 | 15.61 | 464.06 | 22.32 |
| 10 | replace | 71.47 | 19.75 | 76.74 | 24.72 |
| 10 | undo | 68.53 | 19.37 | 75.81 | 26.27 |
| 10 | redo | 52.27 | 10.51 | 56.63 | 13.71 |
| 10 | restore | 68.94 | 13.82 | 70.80 | 18.36 |
| 10 | append | 16.63 | 18.37 | 18.48 | 20.63 |
| 10 | undoAppend | 72.02 | 20.13 | 75.58 | 20.79 |

100MB range-comparison medians were0.0014–0.0037ms (append no comparator);10MB0.0025–0.0055ms. Actual native aggregate ranges conservatively included35UTF16units at100MB and10units at10MB, not merely the replacement scalar. Every non-append measured state used one bounded range comparison and no full-comparison fallback; append used native length precheck with zero submitted units. This is scoped evidence, not a promise all edits produce small ranges. Separate functional tests exercised baseline reset, pending batches and poison resolution using exact whole-buffer fallbacks.

PeakRSS high-water maxima: baseline/candidate100MB533,757,952/532,905,984bytes;10MB166,182,912/165,363,712bytes. Differences below1MB do not establish a memory improvement; high-water includes fixture/oracle/native overhead. Maximum separate navigation23.39ms at100MB and23.22ms at10MB, comparable to baseline22.87/23.06ms. End-to-end navigation+edit totals are not the reported edit figures.

## Decision and limits

The candidate materially removes the measured exact-dirty bottleneck for these ordinary multiline EOF changes and saved-state restorations. Every candidate measured edit total stayed below50ms in this scoped run; baseline same-length states did not. This supports reviewed production extraction with the full native semantic/lifetime/undo/save suite, not full editor performance acceptance.

Strict native active/key/visible/nonminiaturized/occlusion/focused responder and viewport/screen rectangle checks passed. They are window-state/geometry evidence, not physical keyboard-to-photon or proof against partial occlusion. No cold launch, unsupported hardware/OS, arbitrary navigation, checkpoint competition, marked-text typing, bookmarks, huge paragraphs or widely dispersed edit proof intervals were timed. Unknown or shifted ranges can widen/full-fallback intentionally. Original user targets unchanged.

Functional evidence remains separate:40,000 seeded storage/native history operations,43,226 exact checkpoints,68,675 proof invariant transitions; private introspection/instrumentation stays ignored. Hidden history glyph diagnostics reproduce identically in unchanged model and candidate, including isolated seed21; see native-glyph-diagnostics.md. Rendering implication remains unclassified, not suppressed or labeled harmless.

The measurements above precede production extraction; they are not a repeat measurement of the final source. No hashes, probabilistic equality, undo-position identity or always-dirty shortcuts used.


## Production integration verification

The reviewed algorithm is now in `Sources/TheOnlyPad/EditorDocument.swift`. Production has no timing, comparator counters, or test introspection. `scripts/prepare-dirty-harness.py` makes a private instrumented copy, checks exact insertion boundaries, records hashes and the instrumentation diff, and appends same-file test access. The retained native suite compiles that copy with the actual application dependencies. Its independent full UTF-16 oracle and proof invariants cover 40,000 seeded operations, 43,226 dirty checkpoints, 70,936 before/after proof checks and seven focused span/fallback cases.

The full `scripts/test-native-integration.sh` run (local session 37987) exited 0 after production integration. Alongside the retained differential harness, the suite passed pane routing, save/publication failure handling, native dirty/undo/marked-text APIs, lifetime, sessions and both process-termination recovery workflows. Raw diagnostics are ignored in `.local/dirty-native-integration.log`. The baseline-reproduced glyph diagnostics remain unresolved; passing exact text and undo assertions does not establish their rendering impact. The preceding unchanged PadCore integration passed all 258 tests; this optimization changes the application document model only.

The current packaged app predates this extraction. Desktop automation remains blocked by macOS user authentication; no current packaged desktop, physical IME or full performance acceptance is claimed. Checkpoint-enabled controller measurement is a separate pending investigation.
