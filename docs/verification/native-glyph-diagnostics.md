# Invalid glyph diagnostics: controlled native-history comparison

Used systematic debugging: preserve failure, isolate the exact API sequence, compare unchanged model and candidate without modifying layout behavior or suppressing logs. No timing measurements or production edits.

NativeHistoryProbe.swift extracts the identical100×200 native history grammar/RNG/pool from DirtyDifferentialHarness. It includes the real native undo/redo text-stack oracle and full UTF16 dirty oracle, but no candidate proof API, stubs or fake assertions. Both variants use identical copied native dependencies; control EditorDocument.swift is an unchanged production copy, candidate is the reviewed ignored model. Source hashes retained per run. Unbuffered markers identify seed/step/API and synthetic inserted code units.

Both full runs passed20,000 exact native-history checks: control.oig8ob33 and candidate.ox4i8oca. Each emitted16 invalid-glyph diagnostics before AppKit's own suppression message. All logged seed/step/action/glyph-index sequences matched exactly. The probe itself did not suppress logging.

First trigger: seed21 step141, native redo, before length71, after length74; glyph indices59 and40. Running seed21 alone reproduced exactly those two diagnostics in both models, each passing200 exact-history checks (control.gtaj_xly and candidate.67ea2m37). Second full-run trigger: seed23 step75, native insertText CR at UTF16offset25, followed by further index21 diagnostics. These are synthetic rich Unicode/control/newline histories, not user documents.

All four children exited0 and were reaped under60s owned watchdogs. First comparison compile and both variants ran successfully. Unique build output/runs preserved. Commands: `bash .local/controller-latency-review/history-control/compile.sh control` and candidate; `python3 .local/controller-latency-review/history-control/run.py control` and candidate; repeat with argument21 for isolated seed.

Conclusion: the warning is reproducible with unchanged production model and identical native history; the dirty optimization is not needed to trigger it. This isolates attribution, not the internal AppKit root cause or visual consequences. Native text/history assertions pass, but hidden-history rendering is not verified. Do not call the diagnostics harmless or claim they are fixed. A separate rendering investigation may use isolated seed21; this bounded comparison does not justify changing layout or weakening the exact dirty tests.

## Visible follow-up: admission failed

The ignored visible-history fixture compiled successfully (session6600), then its sole final-observation run `final.36pztpqa` terminated at the initial key-window gate after three seconds. No seed operations, text/history assertions, glyph geometry checks, or snapshots ran. This provides no additional rendering evidence. The child was reaped; no each-step retry ran.

A later read-only console-session check returned `kCGSSessionOnConsoleKey=true`, `kCGSessionLoginDoneKey=true`, and `CGSSessionScreenIsLocked=true`. Only these boolean fields were recorded. This establishes the current access blocker, not the cause of all historical failures. User unlock and automation authorization remain pending; no credentials or security settings were changed.

Source comparison with the successful controller latency fixture found missing `finishLaunching` and native event dispatch during activation. The ignored fixture now includes those initialization steps and logs gate state within the existing three-second admission limit. No gates or history operations changed. The corrected fixture has not been compiled or run. These corrections are plausible setup improvements, not a demonstrated fix for the failed admission or glyph warnings.
