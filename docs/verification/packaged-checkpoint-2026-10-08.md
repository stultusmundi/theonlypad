# Local package checkpoint — 2026-10-08

Commit `4c00a2954166eb56ede0b139b00c111c52937d46` passed fresh core checks and local release packaging. The selected packaged desktop workflows remain **blocked**: the Xcode UI runner failed to initialize, and none of the five selected test methods executed. This checkpoint does not establish product completeness or new desktop acceptance.

The recorded host was ARM64 macOS 26.6.2 with Swift 6.3.3. The package uses Swift 5 language mode and a macOS 14 deployment target. A deployment target is not evidence of a run on that minimum OS; Intel and minimum-OS runtime validation remain outstanding.

## States and verification

| State | Recorded scope |
| --- | --- |
| Planned | Retry the five packaged desktop workflows after the user completes macOS UI Automation authentication and Root confirms readiness. |
| Implemented | A reviewed correction to two shutdown test files, plus one deterministic held-read regression. Production source and shutdown semantics were unchanged. |
| Tested | Corrected focused selection: 98 tests, 0 failures. Fresh full suite: 848 tests, 0 failures. Release app build, strict formatting lint, public-source pattern check, ad-hoc packaging and standalone package validation passed. |
| Blocked | Current packaged desktop acceptance: 0 selected methods executed, 0 passed, one runner-initialization failure, `xcodebuild` exit 65. User-owned macOS authentication is pending. |

All 723 reviewed source input hashes were checked after the corrected tests and again for the package. The retained test and package captures include complete owned-process watchdog receipts. Their elapsed times are verification durations, not application latency measurements.

## Preserved failure and test correction

The initial full run executed 847 tests with one failure in `SearchAdmissionDriverIntegrationTests/testHealthyActualDriverPublishesExactBorrowedLease`: the test expected `settled(admissionClosed: true)` but observed `pending`. An unchanged focused retry passed 1 test with 0 failures. That retry did not fix or erase the first failure.

Independent source review identified a test observation race. The legacy shutdown operation can complete child cleanup while the independent parent read scope is still returning. The corrected healthy test waits for the actual generation-qualified `sessionReleased` event before reinspecting settlement. It preserves the original final settlement and accounting assertions and checks that the historical shutdown receipt is unchanged.

The added `testHealthyShutdownStaysPendingUntilActualIdleReadScopeExits` holds the cancelled read return while child stop and channel close complete. It requires truthful pending settlement, retained parent ownership, an active read and no session-release event while held. Releasing the gate allows the actual event and final settled checks. This verifies the distinction between child cleanup and parent read-scope exit; it does not change production behavior or establish physical allocation, kernel-channel or RSS guarantees.

Commit `4c00a29` changes only `Tests/SearchExecutionTests/SearchAdmissionDriverIntegrationTests.swift` and `Tests/SearchExecutionTests/SearchParentWireDriverTestHarness.swift`. The new held-read case accounts for the full-suite increase from 847 to 848 tests. The original failure, unchanged retry and independent review remain retained alongside the corrected results.

## Local artifacts

The release build and package validator passed for a six-file application bundle. Signing is **local ad-hoc**; there is no Developer ID signing, notarization, release publication or remote promotion claim.

| Artifact, relative to the tested checkout | SHA-256 |
| --- | --- |
| `dist/TheOnlyPad.app/Contents/MacOS/TheOnlyPad` | `f6b369ef997343903ce96067ede495505c623924d702120d10f688c7d9af3f04` |
| `dist/TheOnlyPad-0.1.0-dev-arm64.zip` | `ecd7c414fedfffe0b5fd0264a554c45f5082ca75c8c3658dbbbf035c866694b8` |
| `dist/TheOnlyPad.sbom.json` | `739e68c02e7510c1a4a42ca6e830e23f2749a30b407367d341ce4c79b311a2e6` |

The desktop attempt used an isolated copy of this packaged executable; its bytes remained unchanged. These artifacts belong to the tested checkpoint checkout. Later branch changes are not covered by their hashes. In particular, the ongoing H-09 Help and shortcut-reference work is not part of this tested package.

## Desktop initialization failure

The selected methods were:

- `GUIProbe/GUIProbe/testOpenEditSaveQuitRelaunch`
- `GUIProbe/GUIProbe/testScratchRecoveryAfterCommandQuit`
- `GUIProbe/GUIProbe/testCustomShortcutRecordingPersistenceAndRestoreDefaults`
- `GUIProbe/GUIProbe/testOptionHeldFileNewMenuClickAddsExactlyOneTab`
- `GUIProbe/SharedPanesTests/testSharedEditsUndoOrientationCollapseSaveAndRestart`

The result bundle reports one failed **runner record**, not one executed application workflow. The runner timed out while enabling UI automation; the diagnostic records a macOS **Enable UI Automation** authentication request. No selected method began. The outer watchdog did not time out: it captured the completed `xcodebuild` exit 65 and complete streams.

User-owned macOS authentication remains pending. No privacy or system security setting was changed, and neither authentication grant nor screen-unlocked state was inferred. A new desktop attempt requires actual readiness; repeating the failed initialization is not acceptance evidence.

The five passing packaged desktop workflows at source `f4d9207` remain [historical evidence from 2026-09-30](packaged-desktop-2026-09-30.md). They do not transfer a desktop pass to `4c00a29`. This checkpoint also adds no physical IME, VoiceOver, broader GUI, large-file performance, memory/RSS or app-routed search-helper acceptance.

## Reproduction

Use the tested commit in an isolated checkout. The following commands retain the verified test selections and direct owned-watchdog arrangement. Choose fresh ignored output directories; the watchdog refuses to overwrite an existing output directory. The 600-second limits are safety guards, not product performance targets.

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 \
  --output .local/checkpoint/reproduce-focused -- \
  scripts/swift.sh test --filter \
  'SearchAdmissionDriverIntegrationTests|SearchParentWireDriverTests|SearchParentJoinedShutdownTests|SearchAdmissionControllerTests|SearchAdmissionLedgerTests'

# Run after the matching test build above.
python3 scripts/run-owned-search-tests.py --timeout 600 \
  --output .local/checkpoint/reproduce-full -- \
  scripts/swift.sh test --skip-build

xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py

python3 scripts/run-owned-search-tests.py --timeout 600 \
  --output .local/checkpoint/reproduce-package -- \
  scripts/package.sh --ad-hoc-sign

python3 scripts/check-package.py dist/TheOnlyPad.app \
  dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

The broad Swift suite contains adversarial regex cases and needs the direct owned watchdog. Native integration coordinators that already own their watchdog must not be wrapped in another one. Toolchain invocations require the environment's appropriate filesystem permissions; do not skip tests to disguise a permission failure.

After UI Automation authentication is available, Root owns exclusive serial desktop execution against an isolated package copy. The retained `issued-command.json` specifies the exact five-method `xcodebuild test` selection, disabled parallel testing, and per-test time allowances of 90 seconds by default and 120 seconds maximum. Use fresh ignored result and derived-data locations and an isolated app path. `scripts/test-desktop-ui.sh` selects the broader suite and is not an equivalent reproduction of these five methods. No desktop command in this note has a passing result for this checkpoint.

## Evidence retention

Raw logs, result bundles and system diagnostics remain ignored and must not be published wholesale. Paths below are relative to the isolated checkpoint checkout:

- `.local/checkpoint/core-first-failure-and-unchanged-retry.json`
- `.local/checkpoint/independent-shutdown-test-review.json`
- `.local/checkpoint/corrected-shutdown-tests-verification.json`
- `.local/checkpoint/root-package-verification.json`
- `.local/desktop-ui/checkpoint-4c00a29-c3wm6nui/root-initialization-failure.json`
- `.local/desktop-ui/checkpoint-4c00a29-c3wm6nui/xcresult-summary.json`

The earlier records' pending-state flags describe their creation time. Later corrected tests and package verification do not rewrite those records or convert the desktop initialization failure into a pass.
