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

## Corrected v4 deep-origin request batch — actual execution

The separately frozen `ascii256-deep-p1` adapter ran the original twelve-case batch with requested origin(2048,20000), the same262144-unit fixtures and binaries, one pane and one sample per case/variant. All workers were explicitly command-idle; all12 native receipts, records and input inventories passed independent root validation. The interval ended and workers resumed.

| Shape / wrap | Baseline origin ms | Candidate origin ms | Candidate actual origin | Largest peak MiB in pair |
| --- | ---: | ---: | --- | ---: |
| Dense / off | 0.096709 | 0.121334 | (-68,20000) clamped | 57.563 |
| Dense / on | 0.041083 | 0.062708 | (0,20000) clamped | 57.547 |
| Long line / off | 0.103166 | 0.149000 | (-68,20000) clamped | 68.031 |
| Long line / on | 0.056959 | 0.081875 | (0,20000) clamped | 67.922 |
| Mixed / off | 0.098667 | 0.111167 | (-68,20000) clamped | 57.703 |
| Mixed / on | 0.044667 | 0.066042 | (0,20000) clamped | 57.641 |

Every baseline also clamped to the coordinates shown for its candidate. Setup ranged98.258–149.490ms. No process reached the100ms call/sum or512MiB expansion stop; no timeout, interruption or truncation occurred.

These fast results do **not** establish the cost of laying out deep visible text. Source inspection shows the candidate sends the requested horizontal coordinate to the layout rectangle before constraining scrolling. The horizontal request2048 can lie beyond a wrapped container, but the nowrap fixture assigns an effectively unlimited container width. Clamped scroll coordinates alone therefore do not prove container exclusion. The single unwrapped long line also does not populate the requested vertical region. No glyph/layout instrumentation was added to identify the actual work. A separate vertical-only deep request, useful first-line control and remaining two-pane/Unicode/repeated cases are required before selecting production eligibility. Accepted receipt validation does not imply exact restoration or useful layout work.

Private evidence: `.local/pane-layout-cost/typography-matrix-next/batch-ascii256-deep-p1-20260910-123434/`, including `root-verified-summary.json` and retained adapter hashes. Own manifest SHA256: `d82035640c0722b92260f62516cafa7509a1b83a3ad75d72234f9ee2bf176e30`; selected batch SHA256: `b42784afaa151ea1d486befe6a099616bee2e7d74ca0c76e7c6dd168131f7ea8`. The accepted v4 execution manifest and binaries are unchanged.

Five pure adapter tests passed before execution, including actual temporary-file config drift before admission and input/manifest drift between dispatches. The adapter pins the accepted v4 manifest, checks its own captured manifest/config bytes at each boundary, and rejects deferred batches. The original insufficient local-freeze draft remains preserved.

## Corrected v4 two-pane low-origin batch — actual execution

The exact `ascii256-low-p2` batch completed twelve processes with two independent layout managers sharing one document, requested origin(0,240), verified13pt nominal typography and262144 UTF16 units. Root independently validated all records,12 strict receipts, selected ordering and the unchanged v4/adapter input inventories. Workers were command-idle during the interval and resumed afterward.

| Shape / wrap | Baseline combined origin ms | Candidate combined origin ms | Candidate pane calls ms | Largest peak MiB in pair |
| --- | ---: | ---: | --- | ---: |
| Dense / off | 0.153500 | 0.909500 | 0.481625 + 0.427875 | 57.797 |
| Dense / on | 0.048417 | 1.136541 | 0.612458 + 0.524083 | 57.766 |
| Long line / off | 0.165583 | 21.665750 | 10.999958 + 10.665792 | 70.344 |
| Long line / on | 0.072167 | 49.743750 | 24.229667 + 25.514083 | 71.234 |
| Mixed / off | 0.163458 | 0.934083 | 0.491250 + 0.442833 | 57.938 |
| Mixed / on | 0.049708 | 1.156626 | 0.610792 + 0.545834 | 57.984 |

Both candidate panes reached(0,240) except long-nowrap, where both clamped to(0,0). Both nowrap baseline panes clamped to(-68,240); wrapped baselines reached(0,240). Setup ranged101.126–179.594ms. All call/summed-call100ms and observed512MiB stops remained below threshold, with no timeout, truncation or interruption. The two-pane long-wrapped call total already approaches50ms at this size; one observation establishes neither p95 nor a safe production ceiling. Empty-region, implicit-layout and nominal-font limitations still apply.

Private evidence: `.local/pane-layout-cost/typography-matrix-next-two-pane/batch-ascii256-low-p2-20260910-124457/`, including per-pane records and `root-verified-summary.json`. Adapter manifest SHA256: `c44f148f2f198287cd0f825c1c23e93c183cc13f6b845bcf01bd608078cff9a7`; exact selected-batch SHA256: `6131623cb48a7b4401b4ad8e8aadae7b963a9b4b339922b0913ecbcc4655f6b5`. Five pure adapter controls passed before execution. No binary was recompiled for this batch and no production layout change was made.

## Unicode batch stopped at the first process

The unchanged v4 baseline for `s262144-shaping-long-nowrap-low-p1` exceeded the unchanged 15-second watchdog limit. The coordinator stopped after one attempted process: no measurement record was produced and none of the remaining seven selected processes ran. Both captured streams were empty. The watchdog reported timeout, signaled its owned process group, completed its sole wait and captured both streams without truncation; child return was -9. Elapsed watchdog time was 15.024074 seconds. This is a failed experiment, not a usable timing or an accepted Unicode result.

Root independently verified the failure receipt, exact argv, unchanged complete input inventory and adapter hashes. Private evidence is `.local/pane-layout-cost/typography-matrix-unicode-low/batch-unicode256-low-p1-20260910-125019/root-verified-stop.json`; adapter manifest SHA256 `235430407bfac3c734b727f76798081bdba7966751965e9d214e621deff20d49`, selected-case hash `e8595d7eab22237a33259692bfef11902be473b94f8c7c55af9dbd64df216d1c`.

The original probe emits only its final record, so empty output does not identify the delayed operation. A separate private diagnostic adds fixed phase markers around existing work, preserving operation order and the 15-second deadline. An initial proposed explicit application initialization was removed during review because it would change that order. Diagnostic output cannot count as accepted performance evidence. Measurement expansion remains paused pending diagnosis.

The separately compiled phase diagnostic also timed out at the unchanged deadline (15.044305 seconds). Its ten captured markers show completed document construction, text construction/population and typography, followed by `geometry.before`; neither `geometry.after` nor `origin.before` appeared. This localizes the diagnostic delay to existing geometry setup/validation before origin restoration. It does not identify a particular setter yet or establish that the uninstrumented case spent exactly the same time there. Root verified exact argv, unchanged binary, typed timeout receipt, owned-group cleanup, completed wait and complete untruncated captures (277 stdout bytes, zero stderr). Evidence: `.local/pane-layout-cost/unicode-timeout-diagnostic/actual-baseline-phase-run/root-verified-stop.json`. Diagnostic binary SHA256 `6cdef8d3ff62b7cc29531f6f857b7a5f5ee3749b466dc0f451801d6620c321d2`.

The private v5 vertical geometry variants have compiled with209 verified inputs and complete compiler receipts, preserving their one-statement difference. No v5 runtime has occurred. Its compilation does not resolve the Unicode failure.

A second, separately frozen diagnostic brackets each existing geometry operation. It timed out at15.049045 seconds with eleven markers ending at `geometry.frame.before`; `geometry.frame.after` never appeared. Thus the existing first `pane.scroll.frame` assignment did not return within the remaining deadline. Requested no-wrap geometry had not yet been applied, and origin restoration had not begun. This corrects the untested hypothesis that the later container-size assignment was responsible. It does not prove an AppKit internal cause or a remedy. The original order and every prior result remain preserved. Root verified the exact binary/argv, typed timeout, owned-group termination, sole completed wait and complete312-byte stdout/empty stderr capture. Private evidence: `.local/pane-layout-cost/unicode-timeout-geometry-diagnostic/actual-baseline-geometry-run/root-verified-stop.json`; binary SHA256 `ee79b7fd34512735cb33d7e8238e853a8f6785e2c8cbc51399218879e878be05`. Actual application setup order is being reviewed before choosing a controlled experiment or production change.

## Current managed-controller setup control

A separate frozen harness now exercises current managed document construction, adoption and `applyRegistryProjection`, with desired settings recorded before document admission. It preserves ordinary configuration/presentation order and adds only fixed phase markers and scalar final assertions. Independent source review verified132 original/131 generated inputs, the exact transformation, and isolation from normal session/recovery storage. Root verified the compiler receipt and complete test-bundle contents. This is a hidden native **debug-build** controller diagnostic, not a packaged desktop workflow or a release performance benchmark.

With the same262144-unit shaping-long input and frozen binary, two separately selected cases produced:

| Requested wrapping | Actual result | Boundary observed |
|---|---|---|
| Enabled | Watchdog timeout at15.037139s; owned child killed and waited | Settings configuration returned; `presentation.before` appeared but presentation did not return before the deadline |
| Disabled | One test passed, zero failures; XCTest0.903s, watchdog0.974586s | All12 markers; settings proof, applied-wrap/width-tracking false and expected hosted pane identity assertions passed |

Root checked exact selected-method commands, all source/bundle hashes, typed cleanup receipts, complete untruncated captures and the positive one-test count for the passing case. The timed-out case has no completed test count and is not a pass. The15s deadline includes direct `xctest` startup. Neither result measures per-keystroke latency or supports a general nowrap guarantee.

Private evidence: `.local/pane-layout-cost/unicode-current-controller-setup/{actual-wrap-true,actual-wrap-false}/`; inventory SHA256 `1f75a0c2eecf1e1371846cfedcc7884116b55d8afd03e708d84881d48ae87721`, executable SHA256 `87a6699fd40bb50d47dff72f5136d00df7eb847d7e3ed94dc5980ffe1ac6fbb1`. Both root verification summaries and original compiler/sandbox-refusal evidence are retained.

A competing cause remains: the hidden controller's host starts with a zero frame, and `host.present` precedes the window's explicit layout pass. Transient zero/narrow wrapping geometry may contribute. The next checks compare an optimized build of the same inputs, inspect actual owner show/projection order, and instrument existing presentation substeps with scalar bounds. No engine change, default change, arbitrary content threshold or production guard has been adopted.

The same frozen current-controller probe was then built as an optimized testable control (`-c release -Xswiftc -enable-testing`). An initial release compile lacked testability and failed before runtime; that failure is retained. The corrected compile passed. The selected wrap=true case again timed out, at15.040345s, with the same ten markers ending at `presentation.before`. Exact source/bundle hashes and owned cleanup/capture were rechecked. This rules out a debug-only observation for this hidden fixture, but is neither a production-flags benchmark nor proof of an ordinary shown-window hang. Source inspection shows ordinary window creation calls `showWindow` before populated projection; provisional transfer routes can project while hidden. A separate trace-only subphase probe is being compiled to locate the presentation operation and observe existing scalar host bounds.

On2026-09-30 the unchanged compiled subphase probe first timed out after15.002508s with no test output; cleanup completed, and the execution phase is unknown. Xcode test-tool lookup separately passed. A clearly labeled60-second diagnostic allowance then completed the one selected wrapping-enabled test (38.964s XCTest,40.181293s process), all22 phase markers and four scalar geometry observations. Host bounds were1059×616 throughout with a window attached. Exact bundle/input bindings and strict capture/cleanup receipts were verified. Concurrent independent compilation makes this unsuitable as a benchmark; no responsiveness target was changed or accepted. Positive normal bounds weaken the transient-zero-geometry hypothesis for this fixture. Private evidence: `unicode-controller-presentation-phases/{actual-wrap-true,startup-followup-wrap-true-20260930}`. Next: monotonic timestamps in the existing diagnostic sinks to identify the expensive phase.


A separate immutable variant adds only monotonic elapsed timestamps to the existing phase sink. Its verified run completed all22 phases and the same four1059×616 geometry records. `host.present` took36.535095667s; initial settings reconciliation took about0.366s and subsequent explicit layout/wrap calls completed in milliseconds. This localizes the dominant delay to host presentation, before later explicit window layout and wrap refresh. Root kept agent builds idle; a read-only disk inventory was active, so this remains diagnostic localization rather than controlled/repeated performance acceptance. Exact bundle/input and strict runtime receipt checks passed. Private evidence: `unicode-controller-phase-timing-20260930/actual-wrap-true-after-cache-reclaim/`. The first attempt could not create an evidence directory because the repository volume was full; it refused125/OSError before test execution. Root reclaimed only obsolete generated compiler scratch and preserved that refusal separately. No production guard, arbitrary threshold or engine change follows from this evidence alone.

## Minimal native TextKit comparison,2026-09-30

Root prepared a separate hidden native adapter spike after the controller timing localized36.535096 seconds inside host presentation. Independent source review required live-engine checks after insertion and undo; these were added before runtime. Exact inserted UTF16 digest checks and edit/undo phase markers were also included. No production editor code changed.

The optimized Swift5 executable uses the installed native `NSTextView(usingTextLayoutManager:)` choice, common1059×616 scroll viewport,13-point system monospaced font, four-space tabs (32.14453125 points), wrap enabled, and fixed synthetic combining/bidirectional shaping paragraphs. TK1 enables noncontiguous layout; TK2 never accesses legacy layoutManager. A viewport bitmap is generated without saving screenshots. Exact text hashes, expected live engine, direct insertion and native undo are asserted; bitmap allocation does not establish correct glyph rendering. Windows remain hidden.

Both65,536-unit cases completed before advancing to the predeclared262,144-unit cases. One execution per case, each under a60-second diagnostic watchdog:

| Case | Initial host/layout/raster interval | Direct insertion call | Result |
| --- | ---: | ---: | --- |
| TK1,65,536 UTF16 units | 1.899s | 2.000s | Exact content/undo checks passed;6.486s total watchdog |
| TK2,65,536 UTF16 units | 1.796s | 1.607s | Exact content/undo checks passed;3.490s total watchdog |
| TK1,262,144 UTF16 units | 29.837s | 29.506s | Timed out during undo at60.077s; incomplete |
| TK2,262,144 UTF16 units | 27.527s | 26.903s | Exact content/undo checks passed;54.544s total watchdog |

The large fixture exactly matches the previous controller seed, UTF16LE SHA256 `57d02eabe7f0b13b71cb96029c4bccb4cd74ba52b7812bb1612fad66c3637210`. All cases use the same binary/source and actual typography. Root verified the compiled source/binary hashes, exact runtime commands, capture lengths, successful receipts and timeout's exact-group kill/wait/capture receipt. No pending probe process remains. Other agents performed no builds or child runs during this serial diagnostic interval; source-only work continued.

Private evidence: `.local/textkit-comparison-20260930/{plan.md,review.md,final-hashes.json,root-verification.json}` plus four case directories. Final source SHA256 `c352df25739b12da7ea9cd8dc95b98df79ff1b8245b422cf16555b0b350e95cb`; executable SHA256 `0787fd872a351329ba1237d36b240c50cc6339ce6d12438207b251c0cdc4b40a`. Toolchain/platform are the same Swift6.3.3/macOS26.6.2 ARM64 reference as the controller investigation. The first compile and subsequent exact-insertion-check compile are both retained.

This rejects a direct TextKit2 substitution as a demonstrated remedy for this paragraph: it still spends tens of seconds in initial layout and direct insertion. It does not select a new engine or impose an arbitrary long-line policy. These single hidden cases omit production gutters/highlighting/shared models and post-edit repaint; the two engines can defer work differently. They are not p95 typing latency, a100MB benchmark, glyph/IME/accessibility validation or desktop acceptance. Future comparison must include matched paragraph-segmented controls, actual rendered/edit/undo correctness, and the previously recorded Scintilla Unicode gates before adopting any alternative.


## Matched paragraph control, 2026-09-30

A separately reviewed TK1 control replaces exactly215 existing ASCII spaces with LF at offsets1216*k−1 (k=1…215). All other scalar positions,262144 total UTF16 units/scalars, typography, wrapping, viewport and native operations remain unchanged. The resulting216 paragraphs have at most1215 content units. Native assertions verify every changed position and exact UTF16LE digest `91ae61b41e6c20a0a390a076857de3c4941098fbb3e8ba9ebb8f4097cd36ca79`. Paragraph boundaries intentionally change bidi/line-breaking context; this is not identical shaping work.

The single optimized hidden run passed content, insertion, undo and live-engine checks with a1059×616 bitmap and no visible window. All14 phase records, exact source/binary, clean compiler output and strict owned-watchdog cleanup/capture receipts were independently verified.

| Interval | Segmented control | Earlier unsegmented TK1 |
| --- | ---: | ---: |
| Host/layout/raster | 0.052827s | 29.837105s |
| Direct insertion | 0.132497s | 29.505706s |
| Undo | 0.008678s | Incomplete at watchdog timeout |

The segmented pass marker occurred at0.360975s. Do not compare that completed interval with the previous timeout as though both runs completed. This supports paragraph-scoped work as a major contributor for this fixture, without proving a particular AppKit internal cause. The132ms insertion remains a single direct-call observation, not p95 input latency or target acceptance. No production behavior, threshold or engine was changed. Physical typing, glyph/IME/accessibility, actual controller and100MB/1GB acceptance remain outstanding.

Private evidence: `.local/textkit-segmented-control/`, including the full source difference, fixture inventory, pre-run bindings and `root-verification.json`. Source SHA256 `4a4dc31b0ced9c79e0f99eddc538daa6c6cf1cca432671cd75e6b7b1698e9acb`; executable SHA256 `c3203012b47531a4767fbe56a1ed7cf96e2c3c57e6822c31d88732da06ebe9e0`. The original comparison and every timeout remain preserved. Next engine investigations must retain true long-paragraph content; inserting line breaks into user documents is not a remedy.
