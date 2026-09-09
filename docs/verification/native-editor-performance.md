# Native editor performance: bounded baseline

Date: 2026-09-09. Status: measured development snapshot, significant target misses; performance acceptance is not complete. Production sources were not changed by this probe.

## Reference and method

Reference host: Apple M4 Pro, 48 GiB installed RAM, macOS 26.6.2, arm64, Apple Swift 6.3.3. Core and native sources were copied into ignored `.local/spikes/native-performance/Sources`, then compiled independently with `swiftc -O`. No main build modules were shared. Baseline EditorWindowController SHA-256: `22691929d9e6f6ad3282f6a30f70ca65f426136d63f6c1f71ad6cc57c68869f9`. The full source-hash manifest and raw synthetic logs remain ignored.

Each measurement was a fresh owned child process with a separate synthetic recovery directory and a 60-second supervisor timeout. A native EditorWindowController showed its window with a 900 × 650 point content area. Timing began immediately before its real `open(url,onOpened:)` API call and ended at the callback. The controller's normal parsing, settings, document construction, layout/display calls, and delegates remained enabled. No bookmarks were added. Fixtures were ASCII `.txt` files: decimal 1,000,000 / 10,000,000 / 100,000,000 bytes of repeated ordinary 69-byte text lines, plus one 10,000,000-byte line with no terminator. Each ordinary fixture was truncated to the exact size, so its last line may be partial.

Each of three runs per fixture performed 20 native `insertText` operations. The sequence cycled append-at-end, insert-at-start, insert-at-middle. The first append therefore exercised the clean document's full unchanged prefix. Before each edit, a separate timer measured `setSelectedRange`, `scrollRangeToVisible`, and display. The edit timer measured `insertText` through `layoutSubtreeIfNeeded` and `window.displayIfNeeded`. Every edit asserted that UTF-16 length increased by one and the requested offset contained the inserted `z`. Results include the first operation; no warm-up was discarded. Peak resident size came from the child's Darwin `getrusage` high-water mark; the supervisor also sampled only that child's RSS.

This measures synchronous AppKit API completion. It does not measure physical keyboard-to-photon latency, compositor completion, cold application launch, disk-cold opens, packaged LaunchServices startup, or sustained user editing. OS caches were not cleared and other system activity was not controlled. Default wrapping stayed enabled. Plain-text highlighting has no token work; current production behavior disables rulers above 2 million UTF-16 units and uses a reduced offset-only status above 1 million. The first edit to the exact 1 MB fixture crosses that status threshold. These reduced features are part of this baseline, not proof of full-feature performance.

## Results

All 12 final baseline child runs completed successfully within 60 seconds. There were no assertion failures or timeout kills. Decimal MB is used below, including RSS.

| Fixture | Open callback, three runs (ms) | First clean append + display, three runs (ms) | 60-edit pooled p95 / maximum (ms) | Peak RSS range (MB) |
| --- | --- | --- | --- | --- |
| Ordinary 1 MB | 350.27 / 345.62 / 338.44 | 44.30 / 42.12 / 41.12 | 2.22 / 44.30 | 116.46–116.62 |
| Ordinary 10 MB | 354.83 / 344.19 / 350.15 | 300.48 / 317.98 / 307.71 | 2.13 / 317.98 | 152.67–152.78 |
| Ordinary 100 MB | 3120.64 / 3051.58 / 3113.27 | 2920.70 / 2997.47 / 2999.63 | 2.33 / 2999.63 | 506.72–507.30 |
| Single 10 MB line | 5047.23 / 5142.80 / 4993.19 | 337.27 / 346.30 / 335.13 | 1090.49 / 1123.20 | 658.33–716.10 |

P95 uses the nearest-rank definition over 60 samples. For the ordinary fixtures, the three expensive first appends are exactly the largest 5% of samples and therefore excluded by that percentile. Reporting only this pooled p95 would conceal the clean-buffer latency problem. It cannot justify claiming that ordinary editing meets the 50 ms target.

| Fixture | Selection/navigation/display p95 (ms) | Maximum (ms) |
| --- | --- | --- |
| Ordinary 1 MB | 7.34 | 137.75 |
| Ordinary 10 MB | 58.74 | 59.29 |
| Ordinary 100 MB | 589.87 | 595.03 |
| Single 10 MB line | 1.17 | 2.57 |

The insertion timer excludes these preceding navigation costs. An initial experiment which inserted at the beginning first produced much lower subsequent ordinary-file edit times. The final sequence above deliberately removes that misleading favorable first edit and checks actual text mutation.

## Findings against unchanged targets

- Ordinary 100 MB open callbacks were below the provisional five-second target, but the first append took about three seconds and navigation approached 600 ms. This does not establish a generally usable 100 MB editing experience.
- The pathological 10 MB line opened around five seconds and repeatedly took about a second for edits near its beginning. This clearly misses the provisional under-50 ms editing target. Changing the target or quietly claiming a smaller supported scope would not address it.
- Dirty state currently compares exact UTF-16 against the saved baseline, and refresh requests dirty state multiple times. The large difference between the clean append and edits after a change at offset zero is consistent with full-prefix work. The instrumentation section below measures that attribution.
- No cold-launch-to-editable-buffer result was measured. The two-second launch target remains unverified here. No 1 GB viewer/search benchmark, memory-pressure test, IME input measurement, language-highlighting benchmark, save/recovery durability test, or split-pane benchmark is implied.

## Dirty-comparison attribution

A second isolated build wrapped the existing dirty getter with a monotonic timer and call counter, preserving its exact return expression. Counters were reset immediately before insertion and sampled after display. Three additional supervised 100 MB runs completed successfully, with insertion assertions unchanged:

| Run | Dirty getter calls | Cumulative dirty getter time (ms) | Insert + display time (ms) | Attributed fraction |
| --- | --- | --- | --- | --- |
| 1 | 5 | 2947.52 | 2963.80 | 99.45% |
| 2 | 5 | 2933.91 | 2947.16 | 99.55% |
| 3 | 5 | 2961.81 | 2976.29 | 99.51% |

This is direct evidence that repeated full-prefix dirty comparison dominates the first clean append in this snapshot. Timing overhead is included in the instrumented path; its overall latency closely matches the uninstrumented baseline. It does not attribute the long-line cost or navigation cost. A native-length preflight or correctly invalidated dirty cache is a candidate optimization, not an implemented or verified fix in this task. Preserve normalization-only dirty detection, programmatic storage changes, native undo/redo, and saved-baseline transitions when changing it.

The instrumented binary/source/results are retained locally as `probe-instrumented`, `probe-instrumented.swift`, `EditorWindowController-instrumented.swift`, and `results-instrumented.json`. The ordinary `probe` binary and copied sources were restored to the measured uninstrumented baseline after this attribution run.

## Reproduction and next work

Local artifacts are intentionally ignored rather than published: `probe-baseline.swift`, copied sources, `libPadCore.a`, `probe-baseline`, `source-hashes.json`, and `results-baseline.json` under `.local/spikes/native-performance`. The core was compiled with `-O -parse-as-library -module-name PadCore -emit-module -emit-library -static`; native sources except TheOnlyPadApplication.swift were compiled with `-O -parse-as-library`, importing that isolated module and linking its static library with the probe entry point. The final baseline launcher was:

```sh
python3 .local/spikes/native-performance/run.py
```

The launcher uses a fresh state directory per fixture/run, direct file logging, a 60-second child deadline, and child-only RSS sampling. It requires permission to read those process statistics; an initial sandbox denial was followed by checking that no owned child remained, adding failure cleanup, and rerunning with that permission. These are local reproduction artifacts, not a retained CI benchmark suite.

Next work should remove repeated full-buffer document bookkeeping from ordinary keystrokes while preserving exact dirty/undo semantics, then rerun the same adverse clean-append sequence. Separately profile long-line TextKit work and navigation/layout costs. Any engine adaptation or limit must be explicit and tested against the original requirements. This report records failures rather than approving a replacement engine or claiming performance completion.

## Isolated dirty-cache candidate (not production adoption)

A subsequent ignored-only candidate caches the exact text comparison and the saved text's UTF-16 length. Character-edit notifications from NSTextStorage invalidate the cache synchronously; savedText assignment also invalidates it. The getter notices a pending character edit inside beginEditing/endEditing, so reads before the notification cannot return an old cache entry. Encoding and BOM remain independently compared. Attribute-only edits do not invalidate text equality. The notification observer weakly captures the document and is removed during deinitialization; AppKit storage remains main-actor confined.

The original implementation failed a new local performance regression: five dirty reads after a 10 MB append took 431.15 ms against a 50 ms guard. The candidate passed, measuring approximately 0.0005 ms for those cached/length-preflight reads on the final semantic run. Native fixtures also passed direct `.string` assignment, direct storage replacement, saved-baseline changes, normalization-only changes including equal-length reordered combining marks, in-progress edit batches, attribute edits, encoding/BOM changes, native insert/undo/redo, and programmatic setMarkedText/unmarkText. Programmatic marked text is not physical input-method validation.

Using the unchanged full-controller benchmark entry point with only the candidate dirty-state hunk, three additional 100 MB children completed successfully:

| Run | Open callback (ms) | First clean append + display (ms) | Peak RSS (MB) |
| --- | --- | --- | --- |
| 1 | 1202.75 | 13.93 | 519.00 |
| 2 | 1087.65 | 13.92 | 519.50 |
| 3 | 1083.04 | 11.89 | 519.75 |

This addresses the measured clean-append bottleneck in the isolated copy. A same-length change near the end still needs one full exact comparison after invalidation: five getter reads following a same-length final-character change in a 10 MB document took **86.83 ms** in the semantic probe. The first cache miss dominates that sequence. It does not establish under-50 ms same-length editing, improve long-line layout automatically, or resolve the measured navigation delays.

The minimal proposed hunk is ignored `.local/spikes/dirty-cache/dirty-cache.patch`; its candidate full file must not replace newer production edits. The standalone native regression source is `DocumentTests.swift` in that directory, derived from the same private document class and the accompanying `semantics.swift` fixtures. Optimized full-controller results are in `.local/spikes/native-performance/results-optimized.json`, with `probe-optimized` and `run-optimized.py`. No production source was modified. Integration requires review against the current document lifecycle and native application regressions after the other editor changes are handed back.
