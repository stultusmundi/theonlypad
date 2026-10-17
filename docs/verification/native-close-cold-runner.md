# Cold native close runner — 2026-10-17

The no-argument close runner previously failed before compilation: its frozen package omitted `Tests/PadSearchWorkerRuntimeTests`, although the unchanged Swift package manifest declares that target. The supported prebuilt interface passed but did not repair the cold command.

The correction includes the worker test directory in the two cold-only inventory expressions. Recursive application-source capture, the package manifest, prebuilt and other suite behavior, native transformations, watchdog, parsers, receipts and custody checks are unchanged. Dependent runners pin the corrected helper and resulting catalog-helper bytes explicitly. No application Source or dependency changes are included.

Three new Python regressions cover the real manifest's test-target inventory, exact original/generated worker-test bytes with mutation refusal, and mutation after the authoritative read. The unchanged helper produced three ordinary failures across 53 tests, with zero errors. The corrected helper passes all 53. An earlier test hook targeted preflight rather than capture; that setup mistake and the corrected baseline remain retained separately. Existing 50 methods are unchanged.

A fresh complete source layout with the six reviewed Python overlays and no Git/cache input passes the actual no-argument command: all nine owned-process stages return zero; 106 native close checks, 198 factory checks and one shared-pane scenario pass. The matching maintained native approval command passes 68 distinct methods/69 executions, and disk-conflict presentation passes four tests. All 1,024 captured layout files remain byte/mode-identical after these runs. Runtime compiler/Python caches are separate from the pinned source inventory; no claim of an otherwise empty runtime tree is made.

At the cold-runner checkpoint, Python-only dependent suites pass catalog 15, native approval 35, CI diagnostics 81 and disk presentation 12. The CI count81 is historical: the later opt-in error-family diagnostic adds19 tests, and the current CI suite passes100 as recorded in [CI diagnostics](ci-failure-diagnostics.md). That later suite result is separate from this retained cold-runner execution; all Python counts are separate from actual native execution.

```sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
scripts/test-native-close-model.sh
scripts/test-native-approval-regressions.sh
scripts/test-disk-conflict-presentation.sh
```

These hidden synthetic checks establish the runner repair and named neighboring behaviors. They do not execute the default Core test suite or establish visible desktop, physical keyboard/IME, VoiceOver, performance or full product acceptance. Hosted CI's separate failure cause remains unknown. The original cold setup failure and historical prebuilt success are preserved; no tests or security checks were disabled.
