# Actual macOS XCUITest feasibility

## Current save-fix package: authentication blocked

The ad-hoc package `a2d3e80e2bef8ac9bba9402191a31ef8b2486128fbb01539e754d686a4834a9f` passed release build/signature/inventory checks,199 core tests and full native integration before packaging. Three XCUITest launches then failed before any test started: original runner, fresh app copy and clean DerivedData (`run.ACcFbH`, `run.djaOOv`, `run.625FfD`, ignored). Each reported a timeout enabling automation mode. No product assertion ran; this is not a six-test pass.

Read-only `automationmodetool` reports Automation Mode disabled and user authentication required. Its installed man page confirms no-argument invocation is status-only. Console/login flags were true; no leftover owned test process was found between attempts. No security preference was changed and no credential was used. The user was asked to approve the native Enable UI Automation authentication prompt. Current packaged desktop verification waits on that access; the preceding six-test success below remains evidence for its own binary only.

An [Apple Developer Forums report](https://developer.apple.com/forums/thread/693850) describes the same timeout with repeated authentication prompts on older macOS. That is contextual evidence, not proof of this host’s precise cause; the local status output is the basis for requesting authentication. Advice there to change automation security preferences was not executed.

## Latest package: six workflows passed

Executable SHA-256 `0324726fcc89fbb0b54670efe713f7246ba23572ef4ae7e48c1a0f2e77a73526` first completed six tests with four passes and two failures (`.local/desktop-ui/run.5qsntP/results.xcresult`, ignored). Multiwindow restoration, scratch recovery, quit failure/veto, and undo/tab/appearance passed. Recent Files queried a Window despite the real accessibility Dialog role; the query was corrected without changing assertions. Open/edit/save wrote33bytes instead of the expected16, consistent with insertion without full selection. A bounded source review found no demonstrated selection-reset race; its cause remains unresolved.

The two focused workflows then both passed on the identical binary: zero failures,115.960seconds (`.local/desktop-ui/run.3Q960E/results.xcresult`, ignored). Recent Files exercised opening from history, clearing history, quit/relaunch persistence, disabled Open on the empty list, and unchanged original bytes. The focused pass does not erase the unexplained earlier selection failure. The save test now additionally asserts the visible17-unit selection after Command-A and exact replacement text before saving. The fresh full suite with those diagnostic assertions passed all six tests, zero failures,298.439seconds (xcodebuild exit0, `.local/desktop-ui/run.WdUWEz/results.xcresult`). This adds successful integrated coverage, but does not establish the cause of the earlier intermittent selection failure. All prior data assertions and failed diagnostic results are retained.


## Session-enabled package verification

On 2026-09-09, `scripts/test-desktop-ui.sh` passed all four actual UI tests against executable SHA-256 `4654c5fc0744d6b4e094c2f7cd35b3257656866db91f34eab3ca15cc01fe18cf`: zero failures, 181.300 seconds, xcodebuild exit 0. Local raw results remain in `.local/desktop-ui/run.3Oy70j/results.xcresult`.

The package includes session startup/quit, scrolling extent and explicit tab accessibility identifier fixes. Verified flows were native open/edit/save/Command-Q/relaunch/reopen; scratch quit/relaunch recovery; an obstructed session directory causing quit refusal followed by continued editing, removal of the synthetic obstruction and successful quit/recovery; and native menu/keyboard Undo/Redo, independent tab histories, stable tab IDs, and appearance persistence/reset with unchanged document text. The failure test used a synthetic regular file in place of the session directory, without changing system permissions.

The focused tab test previously stalled because its expected accessibility IDs were not exposed by the product. Explicit accessibility identifiers fixed that issue; count/identity assertions were retained. This extends the evidence below but does not establish the full UI matrix, physical IME/VoiceOver, minimum-OS/Intel runtime or clean-machine installation acceptance.

## Earlier retained-package verification

After the initial probe below, the portable project was retained under `Tests/DesktopUI` with `scripts/test-desktop-ui.sh`. The script passes an explicit copied app URL through the shared scheme, uses runner-container temporary fixtures and keeps all diagnostics under ignored `.local/desktop-ui`.

**Earlier packaged artifact: both actual UI tests passed, xcodebuild exit 0.** Executable SHA-256: `ac27f8ac5a5d2b7e846c7a0cb4463b62ad18ffa5f49a362531b5281368d1000d`. This run used the package regenerated after the bookmark composition/undo/cache fixes and Session core. It covered exact file bytes after edit/save, real Command-Q exit, relaunch and reopening the saved file, plus a separate unsaved scratch buffer recovered after Command-Q/relaunch. Saved-file test 60.367 seconds; scratch recovery test 31.673 seconds; two tests total 92.040 seconds, zero failures. XCTest cleanup collected termination diagnostics even though both tests passed. No crash or UI-completeness claim is inferred from those diagnostics.

Reproduce with `scripts/test-desktop-ui.sh` after packaging, or pass a local bundle path. The final passing result bundle is locally retained at `.local/desktop-ui/run.LwJRSc/results.xcresult`. Two initial retained-project runs failed before launch because test-scheme environment forwarding/macro expansion was not configured; those were fixed without production changes. The tracked harness and project contain no machine-specific paths. See `Tests/DesktopUI/README.md` for portable setup and safety boundaries.

## Initial feasibility result

**Feasible and tested on 2026-09-09.** Xcode 26.6 (17F113), macOS 26.6.2, native local macOS destination. An actual Apple UI-testing bundle built, launched the packaged application and passed one UI test: zero failures, 18.925 seconds; `xcodebuild test` exited 0 with `TEST SUCCEEDED`.

This replaces an assumption that host Accessibility trust alone determines XCTest availability. It does not establish complete GUI coverage, physical typing, assistive-technology certification, or usability on other machines. No macOS permission dialog was accepted, privacy setting changed, credential used, or security check disabled.

## Tested interaction

The runner used `XCUIApplication(url:)` to launch an exact copied app bundle, with a fresh `THEONLYPAD_STATE_DIRECTORY` in the test runner's temporary directory. The fixture contained only synthetic text. It then:

1. Waited for the application window and clicked the File menu.
2. Found its Open menu item, dismissed the menu, and invoked Command-O.
3. Used Command-Shift-G in the actual native Open dialog to enter the synthetic fixture path; clicked `app.dialogs["open-panel"].buttons["OKButton"]`.
4. Found the `Document text` text view and verified its initial value contained `synthetic before`.
5. Clicked the editor, sent Command-A, typed `synthetic after\n`, and sent Command-S.
6. Polled the fixture and asserted its exact saved bytes were `synthetic after\n`.
7. Terminated the app after the test.

The app executable SHA-256 was `4b9a46e6876b018f40662f938584fcf673848bc32ca00f2151417bd2ed724604`. This was the locally packaged artifact available at probe start, not a claim that subsequently edited sources were packaged or UI-tested.

## Retained local setup

Ignored `.local/gui-spike` contains the real `GUIProbe.swift`, `GUIProbe.xcodeproj` with shared GUIProbe scheme, copied `TheOnlyPad.app`, derived data, logs and xcresult bundles. The project is an actual `com.apple.product-type.bundle.ui-testing` target, generated Info.plist, macOS13 minimum, and local ad-hoc signing. Production app/project files were not edited. The current probe source points to this local checkout; replace that path with a test configuration input when integrating a portable runner.

The successful command, from repository root:

```sh
xcodebuild test \
  -project .local/gui-spike/GUIProbe.xcodeproj \
  -scheme GUIProbe \
  -destination 'platform=macOS' \
  -derivedDataPath .local/gui-spike/DerivedData \
  -resultBundlePath .local/gui-spike/fifth.xcresult \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 45 \
  -maximum-test-execution-time-allowance 60
```

Choose a fresh result-bundle path for another run. Copy the desired development artifact into the ignored probe app location before testing it. Fixture/state uses a fresh UUID temporary directory and never the real application support location. Unsanitized logs and xcresult bundles remain ignored because Apple diagnostics contain machine-specific paths and may attach UI snapshots. None were added to tracked documentation.

## Failures resolved during setup

- First attempt: writing the fixture into the checkout failed with NSCocoaErrorDomain513 / POSIX EPERM. Apple's generated UI runner has App Sandbox entitlements. Moving synthetic state to `FileManager.default.temporaryDirectory` resolved this without changing sandbox entitlements.
- Direct Open menu-item clicking triggered Apple's `XCPointerEventPath` assertion: `point.x != INFINITY && point.y != INFINITY`. The successful test still clicks and inspects File, then invokes Open by its normal keyboard shortcut. Direct menu-item pointer coverage remains unverified.
- Unscoped `app.buttons["Open"]` matched both the toolbar and dialog. Scoping to the actual Open dialog identifier resolved it.
- An earlier failure-diagnostic path triggered an XCUIApplication framework assertion and stalled; only the owned probe processes were terminated. Explicit test time allowances were added. The final run completed normally.

No unresolved permission blocker remained for this exact passing flow. Future GUI cases need their own meaningful assertions and robust dialog scoping; this single test does not satisfy the complete GUI acceptance matrix.

## Apple references

Apple documents using XCUIApplication to launch and control apps and describes bundle matching and its URL initializer in [XCUIApplication initialization](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init%28bundleidentifier%3A%29). The installed Xcode SDK's `XCUIApplication.h` declares `initWithURL:`; the actual Swift compile validated `XCUIApplication(url:)`. Launch isolation uses Apple's [launchEnvironment](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launchenvironment) API. Apple states that launch failures halt the test in [launch](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launch%28%29).

## Additional focused workflow: partial evidence, revised test pending

A retained `testUndoRedoTabIsolationAndAppearanceReset` was added against the frozen `ac27f8ac…8d1000d` package. Two actual attempts completed these assertions before stalling:

- Typed `synthetic first tab` and observed its exact text.
- Clicked native Edit→Undo and Edit→Redo, asserting empty/restored text respectively.
- Sent Command-Z and Shift-Command-Z and again asserted empty/restored text.

Both attempts then stalled while asking XCTest for the count of tab buttons matching an identifier prefix (`tab.select.`). The second query was scoped to the editor window and still stalled. No successful new-tab, tab-history, or preference assertion is claimed from these attempts. Ignored logs remain in `.local/desktop-ui/focused.sHqBCt` and `.local/desktop-ui/focused.CNXJUu`. The first attempt exceeded its nominal test allowance without completing; only verified owned probe processes were terminated. No unrelated app process or macOS setting was changed.

Automatic approval review rejected a proposed combined cleanup/edit because removing tab-count and identity assertions would weaken coverage under AGENTS.md. The rejected edit was not applied. Targeted cleanup was subsequently accepted as a separate safe action. The revised test **retains** one-tab/two-tab counts, captures nonempty stable identity, and verifies exact content and independent undo history. It preserves the original `tab.select.<UUID>` identifier expectations, searches any accessible element type to avoid assuming toggle-button mapping, and invokes the normal Previous/Next Tab shortcuts with additional selected-tab identity assertions. It also retains Appearance control/save/reset assertions and exact unchanged document text checks. No tests were disabled to obtain a green result.

The revised test is authored for a later coordinated run. Other agents need the GUI, so no further focused UI attempt was launched. Its source presence is not a passing result and it makes the extended desktop suite pending until verified. Preference assertions examine the selected control and persisted setting; they do not prove rendered color/contrast. The two earlier passing quit/relaunch tests remain the established suite evidence above.


Follow-up nonvisible AppKit probe found that select/close buttons have `NSView.identifier` values but return an empty `accessibilityIdentifier()`. The parent was notified to add explicit accessible identifiers and native getter assertions. The same nonshown probe returns AXUnknown for role, so it does not establish the actual XCUI toggle element type. This is a confirmed product-selector gap; the earlier query stalls must not be attributed exclusively to an Apple framework defect. The revised test keeps the original stable-ID expectations pending that product fix and an actual coordinated rerun. No window was shown or activated for the getter probe.

## Additional multiwindow regression

The same `4654c5fc0744d6b4e094c2f7cd35b3257656866db91f34eab3ca15cc01fe18cf` executable passed the new focused multiwindow/pinned-tab test: one test, zero failures,39.700 seconds, `.local/desktop-ui/run.gDhAX0/results.xcresult` (ignored). It exercised two windows and three scratch buffers, native pinning, normal quit/relaunch, exact content, stable IDs, first-window order/selection and native Window-menu focus. Harness corrections and prior failed diagnostic runs are recorded in `../superpowers/plans/2026-09-09-multiwindow-desktop-session.md`. Later source changes are not included in this historical package.

## External-file workflows added (compile-only)

Two new actual desktop workflows are retained in `Tests/DesktopUI/GUIProbe.swift`: external atomic replacement → nonmodal notice → explicit clean Reload → quit/relaunch, and dirty external change → real discard Cancel → Open Disk Copy → original-tab preservation. They use synthetic files, actual selectors and the existing native file-picker helper. `xcodebuild build-for-testing` passed; the existing traditional-headermap warning remains. Private compile log: `.local/desktop-external-compile/build.log`.

Neither workflow executed while the screen is locked and UI automation access remains pending. These sources are not desktop acceptance evidence. Real renamed-file Locate through the native chooser, permission UX, and dirty/copy relaunch coverage remain outstanding. No authentication attempt, application launch or security setting change was made for this compile-only check.
