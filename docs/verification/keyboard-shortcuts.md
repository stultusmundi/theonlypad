# Keyboard shortcut component verification

Status: partial. Core/profile/store/import/export and native recorder components exist; application ownership, native editor and menu wiring are integrated. No physical keyboard, active-window interception or current packaged acceptance is claimed.

## Core and persistence

Local commit `4e22b6b` contains the typed key grammar, strict version1 profile, whole-registry composition and exact-receipt private store. Twenty profile/core tests and thirteen store tests cover normalization, inherited/disabled assignments, swaps, protected/reserved chords, unavailable commands, duplicate JSON keys, permission/symlink restrictions, external changes, parent identity and publication uncertainty. Independent review preceded integration.

`scripts/swift.sh test --scratch-path .build/shortcut-store-integration` passed361 tests with zero failures in14.334 seconds and no compiler warnings. The subsequent ShortcutTransfer addition passed368 tests in14.647 seconds under `.build/shortcut-transfer-integration`, with no compiler warnings. Transfer tests cover strict local-file import, size admission before content allocation, cancellation, same-byte inode replacement, no-materialization policy denial, create-only export and exact uncertain-publication evidence. These helpers must run off the UI thread. Export never replaces an existing destination.

Raw isolated reds and integration logs remain ignored under `.local/shortcut-store`, `.local/shortcut-transfer` and `.local/shortcut-core`. Strict scoped formatting and diff checks passed. These results do not validate native dialogs or actual preference application.

## Native recorder

`scripts/test-shortcut-recorder.sh .build/shortcut-transfer-integration/arm64-apple-macosx/debug` passed47 checks in `.local/shortcut-recorder-retained/run.Ewxxj0CI`, compile/runtime exit0. The runner freezes and hashes source copies, uses the declared Swift5 language mode and kills/reaps its own child after30 seconds if necessary.

Seven unposted CGEvent-derived NSEvents exercised actual capture and `NSMenu.performKeyEquivalent`: Command-N, Shift-Z, Shift-right-bracket, Shift-equals, Option-slash, Option-Up and Option-Down. These use the machine's current keyboard layout. They establish those synthetic menu conversions, not physical key delivery or other layouts. Earlier manual NSEvent constructors produced different Shift character fields and failed menu matching; those setup results remain retained under `.local/shortcut-key-events`.

Recorder lifecycle checks inject monitor admission/event ownership: consume captured commands, refuse bare/repeated/dead/multiscalar/unsupported keys, consume invalid Return, cancel Escape, propagate Tab, ignore other windows, retire on focus loss, reject stale callbacks and remove observers/monitors on close/removal/destruction. A real hidden non-key window refuses recording. The suite does not post events, activate the app or show windows. In particular, its Command-Q handler check is not proof of actual application-menu interception.

Independent review found no material defect in this bounded recorder. Physical capture, native editor/field-editor routing, keyboard-only preferences navigation, VoiceOver and layout variants remain acceptance gates.

## Application owner

The isolated owner initially passed17 tests. Independent review then found a validate-to-read receipt race during uncertain-save retry: replacing a parent directory with identical bytes could give a new receipt authority over the replacement. A real regression failed six assertions before the fix. The owner now revalidates original publication evidence after readback and before granting the temporary retry receipt; the store checks that receipt's parent again at write time. Re-review found no remaining material issue in this scope.

`scripts/test-application-shortcuts.sh` freezes production PadCore/owner/test sources into an ignored Swift5 package. Its first retained run `.local/application-shortcuts-tests/run.sRzW59jh` passed18 tests in0.179 seconds, build9.53 seconds, no warnings. Tests cover off-main services, overlapping operations, catalog churn, reentrant publication, explicit repair/discard, pending evidence, exact retry and public revisions. The actual app subsequently compiled with this owner and the full368-test suite passed in14.599 seconds (`.local/shortcut-native-integration.log`). Application menu integration is covered in the later section.

The native editor's first29 checks missed real owner notifications during Apply: updates could invalidate the operation's own successful completion or hide a later export error. Independent review identified both cases. Further review found that ordinary import results were dropped by incidental busy-state updates. Separate semantic revision tracking now distinguishes catalog/profile changes from ancillary updates; successful own-save receipts must match the latest profile/catalog, newer owner status remains authoritative and current operation errors remain visible. Genuine stale imported results are still refused.

After retained failing regressions and independent re-review, production-copy `scripts/test-shortcut-editor.sh .build/shortcut-native-integration/arm64-apple-macosx/debug` passed38 checks in `.local/shortcut-editor-native/run.ZYC2LFey`, compile/runtime exit0. A documented test-only extension is appended to frozen controller source; original and combined hashes are retained. Tests cover actual table/buttons/search plus injected async callbacks, protected/unavailable rows, swaps/conflicts, Cancel/no-write, Apply exactly once, busy/close behavior, recovery, import/export and the notification fixes. A bounded scrollable status view and horizontal table scrolling keep controls and the last conflict/column reachable at the declared650×500 minimum content size. This is hidden geometry evidence, not physical/VoiceOver acceptance. A subsequent initial-focus regression failed before explicitly assigning the search field as the window’s initial responder. The final production-copy run `.local/shortcut-editor-native/run.SW7q5Ws4` passed39 checks, including the prior38; this verifies the native declaration, not actual focus delivery in a shown window. See the integrated application evidence below.

Current GUI access is blocked. Do not infer desktop success from these hidden or core checks. The requirements matrix retains H-01 as partial.

## Integrated application

The reviewed application wrapper, AppDelegate/catalog wiring, Settings link and shared menu adapter are now integrated. Final source review found no remaining material issue in this scope. `scripts/test-shortcut-application.sh` passed12 tests in0.472 seconds after an11.46-second build, with no warnings, using `.local/shortcut-application-tests/run.zjURmCFP`. This production snapshot includes the initial search-focus declaration.

The tests exercise actual menu construction/validation, removal of registered equivalents during catalog reconciliation while preserving native Quit, the real Import-button → draft → Apply callback path, modal-response revalidation, repair Cancel, explicit Verify/Retry versus Reload/Discard, actionable malformed import, completed interactive snapshots, retained uncertain export errors and Settings-link bounds. Only dialog responses are injected; no window is shown and no physical key dispatch is claimed. Retained failures preceded fixes for disabled completion snapshots, native Quit withdrawal, import admission after chooser close and misleading export-only recovery.

The actual application build plus368 core tests passed in14.402 seconds (`.local/shortcut-wired-integration.log`, no warnings). The existing hidden monitor lifecycle suite also passed against this build in `.local/native-monitor-lifecycle-retained/run._9gs7uny`, covering open/save/suspend, checked Reload/Copy/Locate, dirty undo and pending-publication preservation. Strict repository formatting and public-source/diff checks passed after replacing one disallowed block comment with a line comment.

CI now includes the retained shortcut owner, recorder, editor and application commands. Local execution is verified; remote CI has not been run or claimed. Native physical shortcuts, field-editor routing, customized-key macro invocation, visible dialogs and the newly compiled desktop tests remain acceptance work. The local package must be rebuilt before it contains this integration.

After the presentation-call-site fixes, the final actual native build/core suite passed368 tests in14.580 seconds without warnings. The final production application snapshot `.local/shortcut-application-tests/run.ZVGPxM6y` passed12 tests in0.473 seconds after an11.39-second build. These supersede the earlier integration snapshots for current-source verification.
