# Native editing approval regressions

This record documents the bounded nonXML native editing correction and its maintained regression gate. Results below cover the completed source snapshot; the broader application remains incomplete.

## Behavior

A native text-change approval belongs to its original editor, document, revision and recording context. A nested callback may perform its own real edit, refuse an edit or invalidate that context. The caller records only changes that actually happened and refuses a stale parent replacement. A lawful parent may proceed after an unchanged refused child. Caret refusal preserves genuine seeded undo or redo history.

The bounded transaction handling is implemented in `EditorWindowController.swift` and `DocumentTextView.swift`. Search replacements, nested explicit-range string insertion and caret insertion preserve their respective admission rules. Core search and file APIs remain unchanged. No runtime dependency or productive permission hook is added.

## Coverage and reproduction

Run the pure contracts and the native command serially:

```sh
python3 -B -m unittest discover -s Tests/NativeApprovalIntegration -p 'test_*.py'
scripts/test-native-approval-regressions.sh
```

The pure command passes 35 Python tests: 20 inherited capture-parser controls and 15 runner contracts. They cover fixed selections, clean archive discovery and freeze, symlinks, destination collisions, replaced or added inputs, provider order, source projection inverses, changed frozen bytes, malformed receipt shape and retained state. Synthetic pure captures do not establish native behavior.

The fixed native selection contains 68 distinct methods: 32 existing search replacements, 19 existing macro cases, eight nested-string cases, seven refusal/handoff controls and two caret-history cases. The Unicode positive runs first and overlaps the search class, producing 69 executions in nine stages. Only that positive is a mandatory stop. Later ordinary assertion failures remain failures and permit later cohorts to enter. Missing prerequisites, malformed receipts, unexpected errors or retained fixture custody produce incomplete exit 125. Static source assertion counts are not runtime assertion counts.

Readable Swift provider clients are concatenated with the processed original search tests in one frozen Swift file because the real fixtures have private file scope. Existing Search access regions and macro tails remain unchanged. Two additional passive tails observe existing state; they do not grant approval or fabricate a native result. Seven established declaring-file Test projections have complete byte inverses and protected gaps. Productive source and Test access are tracked separately.

The runner derives its repository from the wrapper and captures current source and Test membership without Git, donor packets or an existing build cache. It accepts no suite, source-root or build-path override. A fresh build is bound to its actual source/object/module/output-map/link/Test-bundle graph before XCTest. Each stage invokes the accepted owned-process watchdog directly and verifies full capture, input identity, artifact and state custody. Do not add an outer process-group watchdog. Each cohort uses separate synthetic state; native commands execute serially under one owner.

## Retained verification

The final maintained-command execution used a clean 1,022-file public-layout snapshot containing the matching productive files, unchanged runner and final canonical providers. It required neither Git nor ignored inputs and began without a build cache. All nine stages exited naturally with zero; all 68 unique methods and 69 executions passed with zero ordinary or unexpected failures, verified postflight and nine empty synthetic-state roots. All 1,022 input bytes and modes remained exact afterward. The public pure command passed all 35 tests, and strict recursive Swift formatting passed without diagnostics. This final rerun includes the two comment-position corrections; the earlier provider run is predecessor evidence.

The matching formatted productive source separately passed an actual warning-free application build, all 1,228 default-package tests, the original Search 32 and macro 19 commands, managed documents 73, managed admission 4, transfer projection 20 and applied settings 24. These results do not expand the selected scope of this command.

The cold no-argument close-model command failed setup before its harness because its temporary package omitted the `PadSearchWorkerRuntimeTests` target directory. That failure is retained and is not a passed cold build. The supported prebuilt invocation using the verified matching actual app/Core build passed 106 close checks, 198 factory checks and one shared-pane ownership control. Source/compiler/object binding was checked; frozen artifact hashes alone are insufficient.

The original public baseline remains incomplete overall with exit 125. Its three complete cohorts comprise 59 unique methods: 50 pass, nine fail and 16 ordinary assertions fail with zero unexpected errors in those complete cohorts. Seven nested cases stop at support premises, so their deeper controls are unentered. The later negative cohort retains fixture custody and encounters unexpected errors; the caret cohort is unentered. This is not a complete 68-method ordinary RED. The reviewed exception authorized only a private two-file experiment. The unchanged full candidate coverage and required neighbors are retained above; the baseline itself is not full68 RED.

## Limits

Hidden native checks do not establish packaged desktop, physical keyboard, IME, VoiceOver, performance, Intel or older-OS acceptance. They do not resolve separate XML undo-history, transfer-focus or strict ARC lifetime investigations. The local packaged desktop checkpoint remains distinct. The recorded scope is the listed hidden checks on their matching source snapshot.
