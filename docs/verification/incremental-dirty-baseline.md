# Current actual-controller baseline results

Executed2026-09-09. Instrument-only copies of current production native sources (source-hashes.json), compiled Swift-O against current shared PadCore objects. Apple M4 Pro48GiB, macOS26.6.2, Swift6.3.3. No candidate optimization or production changes. The application checkpoint callback was a no-op for this attribution; no checkpoint-enabled performance claim.

## Chronology and admission

Initial sandbox compile wrapper failed its /dev/fd tee setup before compiling. Preserved under builds/compile.XNtQyShY/setup-error.log. Authorized escalated compile builds/compile.iF0SPmsr exited0 with no warnings. Unchanged100MB work-bound run runs/20260909T163822.379569Z-d2c15337 passed all functional/visibility assertions, printed its first edit record and then failed the sole following span assertion (100,000,000 submitted units >4,096). Optimized precondition trap exit-5 did not print its message; code/log order distinguishes this intended behavioral red from earlier setup/admission failures. First edit total457.93ms; comparator443.55ms.

Three fresh100MB and three fresh10MB measurement children then all exited0,108operation samples total, no timeout or admission failures.100MB processes32.3s each,10MB7.6s each. Each owned child had a60s watchdog and was reaped. Unique directories in summary.json preserve full outputs. Build/GUI slot released after final child completion.

Strict gates required active/key/visible/nonminiaturized window, visible occlusion flag, correct focused pane/responder, stable native resulting selection, full target/selection geometry within viewport and screen, and target glyph intersection. Activation settled before each operation outside timers. Native operation, target ensureLayout, sizeToFit, scroll, layout/display, bounded event drain, geometry capture and dirty query were inside edit timing. Assertions afterward did not repair layout or selection. Navigation beforehand was timed separately. Append targeted newly inserted unit. Full exact Unicode oracle was outside reported timing/counters. This is native geometry/API evidence, not physical keyboard-to-photon, pixel capture, proof against partial occlusion, cold launch, supported minimum hardware or all macOS versions.

## Results

Each operation has9samples per size (3cycles ×3processes). Median total/comparator and maximum total below; p95 equals maximum with nine samples. Units submitted counts comparator input length, not internally examined Foundation code units. Nested stage durations are NOT additive.

| MB | Operation | Median edit+display ms | Median comparator ms | Maximum ms |
|---|---|---:|---:|---:|
| 100 | replace | 452.98 | 441.21 | 465.59 |
| 100 | undo | 454.20 | 442.96 | 459.69 |
| 100 | redo | 432.80 | 425.32 | 452.97 |
| 100 | restore | 456.23 | 446.63 | 457.95 |
| 100 | append | 16.75 | 0.00 | 22.43 |
| 100 | undoAppend | 450.72 | 441.51 | 464.06 |
| 10 | replace | 71.47 | 60.79 | 76.74 |
| 10 | undo | 68.53 | 59.07 | 75.81 |
| 10 | redo | 52.27 | 44.86 | 56.63 |
| 10 | restore | 68.94 | 60.65 | 70.80 |
| 10 | append | 16.63 | 0.00 | 18.48 |
| 10 | undoAppend | 72.02 | 63.29 | 75.58 |

Same-length operations and every undo-to-baseline submitted one full buffer to the comparator (100M/10M units); append submitted zero thanks to native-length preflight. Other getters reused cache.100MB peakRSS533,757,952bytes;10MB166,182,912bytes. These process high-water figures include setup, assertions and native state, not isolated copy allocations. Maximum pre-operation navigation totals22.87/23.06ms, including bounded native drain; these EOF-only checks do not characterize arbitrary navigation or pathological paragraphs.

Measured secondary stages are small: across100MB samples status bridge max0.0054ms, status total0.109ms, language detection0.2765ms, temporary-color removal0.3551ms, storage observer0.0106ms.10MB maxima also below0.3ms each. They do not explain the hundreds of milliseconds in current ordinary same-length edits. The prior string-bridge/highlighter-clear hypotheses are not supported as material bottlenecks in this workload. Repeated UI refresh includes the comparator as a nested stage; do not misattribute all refresh duration to tab reconstruction.

The under50ms editing target remains missed for same-length100MB operations and these10MB medians, including undo/restoration. Append medians around17ms do not establish general editing acceptance. Next useful work is the reviewed deterministic interval/suffix dirty proof, subject to actual differential native history/invariant testing and safe fallback. No probabilistic equality or always-dirty state proposed. Pathological long lines, bookmarks, actual checkpoint competition and physical IME are separate workloads.
