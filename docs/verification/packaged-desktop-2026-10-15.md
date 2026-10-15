# Packaged desktop selection — 2026-10-15

The local ad-hoc package contains storage-cache source `9313bf6`. Its executable, fixed helper, archive and SBOM remain byte-identical to the accepted package. A broader selection planned eighteen of the nineteen checked-in desktop tests in six serial three-case batches; the separate direct AXPress test was excluded. Execution stopped on the first failed batch. This is a partial result, not a complete desktop acceptance run.

Four batches executed twelve cases: eleven passed, one failed, zero skipped or expected failures. Three complete batches passed open/edit/save/relaunch, scratch recovery, undo/tab isolation/appearance reset, multiple-window/pinned restoration, recent files, shortcut persistence/reset, effective-shortcut Help, modifier-held File New and session-write-failure quit veto. The fourth batch passed dirty external-file cancel/disk-copy handling and clean external-file reload/restoration.

`testLocateMovedFilePreservesDirtyUndoAndSavesToChosenLocation` failed because its first expected open panel was absent after Resolve → Locate. The missing-file notice and dirty-text prerequisites passed. Retained actual accessibility state contains: “The document or file status changed. Check the file again before choosing an action.” Source maps this to the initial Locate admission/freshness guard, but the exact failed operand is unknown. The test never reached cancellation, rechoice, adoption, undo or save. Its teardown waited fifteen seconds for Command-Q, then used XCTest termination fallback; no graceful quit acceptance follows from this case. No protection or test oracle has been weakened.

All four direct owned-watchdog stages completed naturally with complete captures and native exit codes 0, 0, 0 and 65. Root verified thirteen frozen app/test inputs, 195 production source/package bindings, four distribution artifacts and empty exact-owned process postflight. The screen was unlocked at each batch admission. Independent actual-run review accepts the partial result (GO f7cfbc89). Raw synthetic evidence remains ignored locally.

The six unentered planned workflows comprise four pane workflows and two managed-search workflows. The two search workflows passed in an earlier separate selection on this same package (GO 60ac1d2f); those passes are not added to this twelve-case result. Earlier source `faa02f5` desktop results and the historical five-workflow selection also remain separate evidence. Physical keyboard/IME, VoiceOver, direct AXPress, repeated reliability, large-file responsiveness and full desktop acceptance remain outstanding. No release was published.


## Separate private Locate diagnostics

The first qualified diagnostic failure identifies initial guard04, `bridge.isCurrent(context)`, as false. Its unchanged case failed at the chooser assertion after59.743 seconds without hitting the120-second XCTest maximum. The specific changed field remained unknown.

A later private package, with initial-guard and context-comparison observation overlays, passed the same unchanged case1/0 in86.328 seconds. Both direct stages completed naturally with full capture. Independent actual review accepts194 compiled sources/objects, five modules,248 artifacts,13 app/test files and unchanged pre/post bindings; exact-owned process postflight was empty. Both fixed refusal marker files were absent in its new synthetic fixture, so the context field and cause remain unknown. Xcode emitted a signed-framework stripping warning during the GUI build; the selected test still passed. The package recipe did not enable warnings-as-errors.

These are separate private diagnostic results. The broader production selection remains11 passes and one failure; six planned cases and AXPress remain unentered. No semantic fix, production-package Locate acceptance, repeated reliability or root cause is established. Historical failed and incomplete runs remain preserved locally.
