# Shared-pane adapter benchmark — initial matrix

Completed execution; incomplete acceptance. Six of18 cases completed20 samples. Twelve failed strict visibility admission/state checks, including two with partial completed samples. No case hit its120-second watchdog. Runner exit0 means enumeration completed, not that all cases passed. No reruns after this initial matrix.

## Provenance and method

- Production commit: `c062ff4c7aed07462d0f8442c994ef53170c6935`.
- Frozen native content SHA256 (sorted filename + NUL + bytes): `13847333f6598b7c3701911757033e7801cd5d1e74463c8531f523afca9f4c1a`.
- Final harness SHA256: `31aae0d192e2c3a7a6bee82667351dd0e741cb4eddaccc097141782229b4f878`.
- Machine: Mac16,7, Apple M4 Pro,48GiB physical RAM; Version 26.6.2 (Build 25G83).
- Toolchain: Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101); Target: arm64-apple-macosx26.0; native benchmark compiled `-O -swift-version 5`.
- Raw ignored artifacts: `.local/shared-pane-performance/run.JSjhyW` (source snapshots/hashes, toolchain, smoke chronology, matrix, per-case JSON and partial stderr).
- Invocation: `bash .local/shared-pane-performance/run.sh` built and ran smoke. `bash .local/shared-pane-performance/recompile.sh .local/shared-pane-performance/run.JSjhyW` rebuilt only the frozen-native harness after activation fixes. `python3 .local/shared-pane-performance/run-matrix.py .local/shared-pane-performance/run.JSjhyW smoke` passed all3 admission fixtures. Final matrix: same Python command without `smoke`.
- Matrix duration approximately503seconds (8m23s), derived from archived-smoke directory mtime immediately before invocation to final matrix write; launch/tool overhead is included approximately. Individual child wall durations were not recorded;120-second per-child watchdog was configured. This is not a startup latency measurement.
- Each fixture/mode ran in a fresh process. Twenty samples per completed case; focused pane alternated for two-pane cases. Same storage, exact native edit/undo checks, displayed window/end caret, resize and wrap on/off. All visibility and exactness gates remain enabled.
- Initial standalone launches failed inactive-app admission. Adding native finishLaunching and bounded activation handling improved but did not eliminate failures. Final code waits at most5seconds for200ms continuously active/key state before each sample; checks afterward can still fail. Earlier failed smoke is preserved. No specific cause of remaining inactivity/occlusion is proven.

## All18 outcomes

| Case (decimal bytes, fixture, layouts, axis) | Outcome | Complete samples | Failure |
|---|---|---:|---|
| 1000000-multiline-1-sideBySide | passed | 20/20 | — |
| 1000000-multiline-2-sideBySide | passed | 20/20 | — |
| 1000000-multiline-2-stacked | passed | 20/20 | — |
| 1000000-longline-1-sideBySide | failed | 0/20 | stage=before-edit reason=application inactive |
| 1000000-longline-2-sideBySide | failed | 0/20 | stage=before-edit reason=application inactive |
| 1000000-longline-2-stacked | passed | 20/20 | — |
| 10000000-multiline-1-sideBySide | passed | 20/20 | — |
| 10000000-multiline-2-sideBySide | failed | 0/20 | stage=before-edit reason=application inactive |
| 10000000-multiline-2-stacked | failed | 0/20 | stage=before-edit reason=application inactive |
| 10000000-longline-1-sideBySide | failed | 0/20 | stage=before-edit reason=application inactive |
| 10000000-longline-2-sideBySide | failed | 0/20 | stage=before-edit reason=window occluded |
| 10000000-longline-2-stacked | failed | 0/20 | stage=before-edit reason=application inactive |
| 100000000-multiline-1-sideBySide | passed | 20/20 | — |
| 100000000-multiline-2-sideBySide | failed | 8/20 | stage=after-undo reason=window occluded |
| 100000000-multiline-2-stacked | failed | 18/20 | stage=after-resize reason=window occluded |
| 100000000-longline-1-sideBySide | failed | 0/20 | stage=after-wrap-disabled reason=window occluded |
| 100000000-longline-2-sideBySide | failed | 0/20 | stage=after-edit reason=window occluded |
| 100000000-longline-2-stacked | failed | 0/20 | stage=after-wrap-enabled reason=window occluded |

## Completed cases only

Values are milliseconds, median / empirical nearest-rank p95 (19th sorted observation out of20). These are descriptive observations without population confidence or acceptance claims. RSS is process high-water inMiB (1MiB=1,048,576bytes); Darwin ru_maxrss raw values are bytes.

| Case | Edit/display | Undo/display | Resize/display | Wrap on+off/display | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| 1000000-multiline-1-sideBySide | 28.58 / 33.03 | 20.93 / 21.94 | 20.60 / 21.67 | 48.40 / 51.42 | 107.1 |
| 1000000-multiline-2-sideBySide | 25.58 / 33.86 | 20.82 / 22.50 | 38.88 / 40.64 | 95.78 / 97.87 | 115.9 |
| 1000000-multiline-2-stacked | 33.53 / 50.78 | 23.38 / 39.07 | 38.30 / 40.89 | 83.84 / 91.44 | 108.9 |
| 1000000-longline-2-stacked | 814.63 / 847.13 | 806.08 / 852.39 | 80.77 / 84.47 | 1028.08 / 1078.07 | 2663.4 |
| 10000000-multiline-1-sideBySide | 3.69 / 4.61 | 2.58 / 2.87 | 3.33 / 3.49 | 17.36 / 18.08 | 135.9 |
| 100000000-multiline-1-sideBySide | 15.99 / 19.59 | 10.57 / 11.23 | 3.35 / 5.74 | 50.28 / 53.20 | 396.8 |

## Incomplete samples and constraints

- 100MB multiline/two-side preserved8 complete samples before after-undo occlusion; two-stacked preserved18 before after-resize occlusion. They do not receive completed-case percentile summaries. Other failures preserved0 complete samples; several failed mid-operation, so0 does not mean no work occurred.
- The 1MB longline/two-stacked case peaked at2,792,800,256bytes (~2.60GiB). During100MB longline stress, exact owned-process ps snapshots observed about4.23–4.30GiB resident memory. Those snapshots are not process peak RSS measurements; failed cases without completed samples have no final high-water reading. No unsafe growth or watchdog kill was observed; no memory ceiling is proven.
- Two-pane10/100MB cases bypass the app's initial2M UTF16 split cap for adapter stress only. They are not supported app behavior. No100MB two-pane case completed the matrix. Longline10/100MB completed no cases; visibility failures prevent useful comparative conclusions.
- **1GB was not covered.** Cold launch,100MB time-to-usable, actual app input latency, physical input-to-photon latency, search, file opening, controller dirty/recovery/highlighting/command overhead, physical IME and VoiceOver were not measured.
- BUILD_PROMPT provisional ordinary input p95 target is under50ms. The measured edit/display proxy exceeded50ms at1MB multiline/two-stacked (50.78ms) and1MB longline/two-stacked (847.13ms). The latter is a clear expensive adapter path. This proxy is not actual input latency: it includes synchronous layout/display plus an event drain that may return early or wait up to20ms. Lower proxy numbers do not prove input-latency acceptance, and anomalous size scaling must not be interpreted as a performance improvement.
- Exact text validation occurs outside operation intervals but affects later allocation/cache state. Wrap total sums on/off intervals excluding intermediate visibility validation. Initial creation/layout excluded from samples but inside child watchdog. Window/server timing, display drain and partial occlusion limitations remain; geometry/native window state is not pixel capture.
- Preserve targets and existing split guard. Next assessment should diagnose intermittent native activation/occlusion and instrument costly longline layout/memory under a reviewed resource budget. Do not infer a safe larger split limit from the completed small/multiline cases.

## Retained runner verification

The benchmark harness and runners are now retained as `Tests/NativeIntegration/SharedPanePerformanceHarness.swift`, `scripts/benchmark-panes.sh` and `scripts/benchmark-panes.py`. Default invocation runs three 1 MB multiline smoke cases; `--full` requests the 18-case matrix. Use an exclusive build/GUI slot. Output goes to a new private `.local/pane-benchmarks/run.*` directory with frozen sources and hashes. The retained runner measures child elapsed time and returns nonzero for any failed/timeout case; these reporting improvements do not retroactively change initial matrix evidence above.

`scripts/benchmark-panes.sh` compiled and ran in session8975. The release build passed in21.52seconds; standalone harness compilation emitted a deprecated activation-option warning. The three child cases took23.365seconds in total: one-pane failed before-edit foreground admission, side-by-side and stacked each completed20 samples. The wrapper correctly exited1. Raw evidence is `.local/pane-benchmarks/run.bvsCLR`. This validates runner execution/failure reporting, not a successful smoke acceptance or replacement for the initial matrix.

The retained harness was then formatted and its deprecated, documented no-effect `NSRunningApplication.activateIgnoringOtherApps` option removed. Comparing formatted sources showed no other behavioral change; `.activateAllWindows` and every visibility gate remain. Retained source SHA256 is `00c4e5269d47c25ae0be753ce48359b87dd318c2c04bfda7a8f6820b0c3481bf`, distinct from the measured original hash above. Its standalone optimized compile passed in session79613 with an empty diagnostic log. Repository Swift formatting, Python/shell syntax, public-source patterns and diff checks passed. The full matrix was not rerun after this formatting/no-effect option change.
