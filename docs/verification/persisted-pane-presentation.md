# Persisted pane presentation verification

Status: core metadata, session flow and native restoration are implemented and tested. Desktop restart, physical input, accessibility and performance acceptance remain outstanding. This record does not establish complete F-01 acceptance or document transfer in F-02.

Session version 2 stores one or two pane selections, bounded document-coordinate scroll origins, axis and focused slot per logical document. Version 1 is checked against its exact original canonical schema before migration in memory. Loading does not rewrite it. Version 0 and unsupported future versions remain refused and unchanged. Existing atomic publication, private storage permissions, document limits and recovery ownership remain in place. Scroll coordinates are best effort across changed font, wrapping and window geometry; they do not promise restoration of the same logical top line.

## Core evidence

The frozen core suite passed **386 tests, zero failures in 15.927 seconds**, with no compiler warnings. Targeted session tests cover both pane orders/axes/focus, exact v1 migration and optional-field distinctions, no load-time writes, pre-publication failure preservation, invalid direct values, nested malformed schema, version refusal and one recovery identity. Eight new resolver tests cover both ranges, scalar boundaries, bookmarks, shortened text and native UTF-16 size limits; these and the five existing resolver tests separately passed in 3.316 seconds.

Behavioral failures were retained before implementation: a version publication test failed once, and eight corrected presentation tests failed 118 assertions. An earlier synthetic Unicode path needed canonical spelling to match the unchanged path policy. A temporary full-suite package initially omitted the repository's Examples directory; copying those existing fixtures fixed the test setup without changing production behavior or weakening assertions.

Private evidence: `.local/pane-persistence-core/` and `.local/pane-persistence-resolver/`. These contain source hashes and raw red/green logs. They are excluded from public artifacts.

After the native design revision, the extracted NSString helper and legacy/full resolver tests passed20tests. Six new tests first failed20assertions against a compiling pass-through seam. CountingNSString verifies one length query and at most four endpoint character reads without allocating its reported100M units; malformed input is refused before text access, and exact scalar/EOF/combining/mixed-ending semantics remain. The full frozen core suite then passed 392tests with zero failures in15.820seconds and no warnings. Root matched all92core/test source files against that frozen package before local commit `5ad963d`. Evidence: `.local/restored-selection/`.

## Session-flow evidence

`scripts/test-session-presentation-flow.sh` snapshots PadCore and the actual SessionCoordinator, SessionRestorationController and RecoveryCoordinator sources into an isolated Swift 5 package. It records source hashes, enforces a 180-second watchdog for its own process group, and propagates the actual test exit status. It never shows a window.

Nine tests passed, zero failures in 0.019 seconds after a 9.62-second build. They exercise real synthetic file reads, both-pane validation against the loaded text, startup/retry recovery as scratch, unresolved metadata preservation through real session storage, Locate, canceled startup, nonfocused-pane adjustment warnings and refusal of legacy reader payloads that would lose saved layout metadata.

The first seven-test run failed eleven assertions before payload wiring and the new store were integrated. Independent review then identified that accepting a range-only payload for any single pane could drop a nonzero saved scroll position. A new test reproduced three failures; the compatibility guard now permits missing presentation only for the exact former default single-pane layout. The full eight-test suite then passed. An additional actual checkpoint-owner test confirms recovery publication precedes session metadata, an injected beforeReplace failure preserves exact v1 bytes, and a fresh capture retry publishes the v2 split plus one recovery record. Its first fixture reused a recovery revision and was correctly refused as superseded; the corrected fixture uses fresh revisions as required by the existing protocol. No production checkpoint behavior was changed to accommodate it.

Private flow evidence: `.local/session-presentation-flow-tests/` and `.local/session-presentation-flow-{red,green,review-red,review-green,checkpoint,checkpoint-green}.log`. The runner does not compile AppDelegate or exercise its import/focus routing; those remain subject to native integration verification.

## Native integration evidence

The reviewed synchronous candidate built the actual application and passed all 392 core tests in 16.113 seconds. Root ran its complete pane and real-save suites concurrently: 24 modes/199 assertions and 26 save assertions passed, with empty compiler logs. The existing hidden monitor/open/save/Reload/Copy/Locate/quit suite also passed. Independent review found no material issues in this scope.

This first final candidate deliberately used the previously reviewed registry while the separate close-state component was being developed. Its source provenance is retained in `.local/pane-candidate.2o9eg75i/source-provenance.json`. All other core/native source and pane/save test files were matched against the working tree. The current application, including the later reviewed close-registry addition, subsequently built in 3.45 seconds; that separate component passed 30 tests and remains unwired to native close behavior. Final integrated reruns also passed: all 24 pane scenarios and 199 assertions in `.local/pane-session/run.LFh2hY7D`, plus 26 real-save assertions in `.local/pane-save/run.Kd90NmLF`. Both compiled and exited successfully against the current application build.

The pane tests retain the original successful deferred-restore assertion, now requiring completion when the action returns. They cover actual NSTextView replacement, exact Unicode, both axes/ranges/preferred slots, shared undo/redo through both panes, deferred live-slot capture, operation/composition/close/quit refusal, and real notification callback reentry. Recursive restore, file-save admission, secondary detachment and secondary selection changes cannot leave a committed stale split. Refusal removes additional attachments, preserves deferred metadata and retains newer edits/selections. Later scrolling and selection changes do not trigger saved-origin replay.

The real-save harness performs an actual synthetic atomic save and checks exact disk bytes, acknowledged baseline, clean state, one recovery identity, save-active restore refusal, explicit restore after completion, and native undo independently from saved disk contents. Two synthetic commands use explicit native undo groups; an earlier fixture incorrectly expected separate groups from two unposted calls. Production undo behavior was not changed to accommodate that fixture. Reusing a detached pane from a collapsed second-slot view also exposed and fixed an attachment-order assumption.

Evidence: `.local/pane-synchronous-final-build-corrected.log`, `.local/pane-synchronous-final-native.log`, `.local/pane-synchronous-final-save.log`, `.local/pane-synchronous-monitor-compat.log`, and their retained candidate subdirectories. The initial candidate-wrapper invocation failed before building because its relative package path was resolved twice; the corrected root-wrapper command built the same frozen source. These setup failures are retained separately from product assertions.

## Diagnosed race and reviewed design revision

The first implementation asynchronously revalidated the two selections and canceled on any viewport change. Repeated full-sequence runs failed the original deferred-restore assertion. Traces showed that only the interaction guard changed: TextKit usage recalculation resized the document view and revealed the caret after capture. The same failure occurred through normal editor input. A content-view layout flush and a private visible-rectangle layout experiment both failed to resolve it. Apple documents that [rectangle layout may extend to larger ranges](https://developer.apple.com/documentation/appkit/nslayoutmanager/ensurelayout%28forboundingrect%3Ain%3A%29); it cannot establish a hard work bound.

Review found that native installation consumed only the two selection results, not the worker's bookmark validation. The replacement validates those endpoints directly against existing NSMutableString storage, then installs synchronously. At most eight character queries are needed for two ranges; no native validation worker, source String copy, bookmark pass, full-glyph layout, geometry polling or automatic retry remains. Full startup/file/recovery and bookmark validation stays off-main. Native callback reentry still has explicit admission and post-callback authority guards.

Worker-only hold/drain assertions were retired only after this suspension was removed. Their safety requirements now have synchronous refusal/reentry and post-return no-replay tests; the original positive assertions remain. Historical failures and unsuccessful hypotheses are retained in `.local/native-pane-persistence/SYNCHRONOUS-MIGRATION.md` and the referenced raw runs. They were not relabeled as passes or hidden by disabling tests.

## Remaining verification

At the earlier native checkpoint, the two desktop restart tests compiled but could not execute on the locked console. GUI access is now available and the later packaged failures below supersede that blocker. Physical IME, VoiceOver and performance acceptance remain outstanding.

Strict source formatting, public-source checks, diff checks and runner syntax passed. CI includes the retained tests but hosted CI has not run. The existing verified package still predates this work until local packaging is completed and recorded separately. F-02 transfer, linked scrolling and broader workspace/performance scope remain outstanding.

## Current packaged desktop failures — 2026-09-10

The source55a7b1b package was exercised with actual XCUITest keyboard/menu actions. The first complete suite found side-by-side restored slot-zero scroll0 instead of240 (tolerance2). Its stacked layout assertion was a harness error: sorting scrolling document text frames reversed correctly adjacent fixed pane containers. Independent review approved sorting the fixed containers while retaining all UUID, positive-size, hittability and adjacency assertions.

A fresh run with that corrected ordering passed the stacked geometry checks, then exposed restored scroll102 instead of240. The final quit persisted the wrong origin. This is a production restoration failure, not a passing pane acceptance result; tolerances and requested values remain unchanged. Both shared-pane content/undo/restart tests passed separately within that run, as recorded in [shared-pane verification](shared-document-panes.md).

Private geometry traces now prove the new pane clamps 240 to zero before TextKit has established its document height. A private viewport-layout candidate preserves that initial origin, but a second failure remains: after both origins are installed, the post-start font/paragraph settings pass changes the peer's origin. The inert trace records 940 before that pass and 1026 afterward, retained at quit capture. Its 102 geometry-only records remain below the 512-record cap and avoid the earlier reentrant font/layout probes.

The individual typography setter and appropriate idempotent-settings remedy remain under investigation. No private candidate, speculative delayed replay or instrumentation has been promoted into production. Raw synthetic evidence and source manifests remain ignored under `.local/desktop-ui/`, including `pane-origin-inert-hq9u8uei/`. Native and packaged regressions must pass before restoration acceptance is claimed.

## Private desktop repair evidence — 2026-09-10

The private combined candidate resolves the observed restoration sequence: establish needed small-document layout before constraining an origin; avoid redundant typography setters; and request restored focus through the existing exact projection admission. Hidden managed-startup regressions went from 12 tests with two actual-responder failures to 12 passing tests, including exact insertion after startup for either saved split slot.

The first combined desktop run exceeded the original 120-second allowance for both layouts without a preceding content assertion failure. Review identified repeated predicate waits even when a fresh accessibility query already satisfied the exact condition. `PaneSessionTests` now uses the previously reviewed `SharedPanesTests` pattern: check current existence/count/UTF-8 bytes first, retaining every original fallback timeout, content assertion, geometry check and fixture action.

With that harness correction, the unchanged complete workflows passed: side-by-side in 93.629 seconds and stacked in 95.167 seconds. They verify independent saved origins and selections, preferred-pane typing after restart without a click, shared content, both undo operations, switching focus and native quit. Private binary SHA256: `1c717c742c3c2dbc95aa68eea886db5cd6c1aa9dd1db4c16f9c2c10499c49613`; source/test hashes and synthetic evidence remain in `.local/pane-scoped-focus-build/` and `.local/desktop-ui/pane-scoped-focus-59pj4cfr/`.

Only the test wait correction is promoted here. The production pane fix remains outstanding: the private settings delta must be replaced with document-specific applied-state validation across transfers, and eager layout must pass large-file/long-line cost review before adoption. Small-fixture desktop success does not establish those properties or full product acceptance.
