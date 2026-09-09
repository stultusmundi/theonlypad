# Keyboard shortcut component verification

Status: partial. Core/profile/store/import/export and native recorder components exist; application ownership and the preferences editor are being integrated. No physical keyboard, active-window interception or current packaged acceptance is claimed.

## Core and persistence

Local commit `4e22b6b` contains the typed key grammar, strict version1 profile, whole-registry composition and exact-receipt private store. Twenty profile/core tests and thirteen store tests cover normalization, inherited/disabled assignments, swaps, protected/reserved chords, unavailable commands, duplicate JSON keys, permission/symlink restrictions, external changes, parent identity and publication uncertainty. Independent review preceded integration.

`scripts/swift.sh test --scratch-path .build/shortcut-store-integration` passed361 tests with zero failures in14.334 seconds and no compiler warnings. The subsequent ShortcutTransfer addition passed368 tests in14.647 seconds under `.build/shortcut-transfer-integration`, with no compiler warnings. Transfer tests cover strict local-file import, size admission before content allocation, cancellation, same-byte inode replacement, no-materialization policy denial, create-only export and exact uncertain-publication evidence. These helpers must run off the UI thread. Export never replaces an existing destination.

Raw isolated reds and integration logs remain ignored under `.local/shortcut-store`, `.local/shortcut-transfer` and `.local/shortcut-core`. Strict scoped formatting and diff checks passed. These results do not validate native dialogs or actual preference application.

## Native recorder

`scripts/test-shortcut-recorder.sh .build/shortcut-transfer-integration/arm64-apple-macosx/debug` passed47 checks in `.local/shortcut-recorder-retained/run.Ewxxj0CI`, compile/runtime exit0. The runner freezes and hashes source copies, uses the declared Swift5 language mode and kills/reaps its own child after30 seconds if necessary.

Seven unposted CGEvent-derived NSEvents exercised actual capture and `NSMenu.performKeyEquivalent`: Command-N, Shift-Z, Shift-right-bracket, Shift-equals, Option-slash, Option-Up and Option-Down. These use the machine's current keyboard layout. They establish those synthetic menu conversions, not physical key delivery or other layouts. Earlier manual NSEvent constructors produced different Shift character fields and failed menu matching; those setup results remain retained under `.local/shortcut-key-events`.

Recorder lifecycle checks inject monitor admission/event ownership: consume captured commands, refuse bare/repeated/dead/multiscalar/unsupported keys, consume invalid Return, cancel Escape, propagate Tab, ignore other windows, retire on focus loss, reject stale callbacks and remove observers/monitors on close/removal/destruction. A real hidden non-key window refuses recording. The suite does not post events, activate the app or show windows. In particular, its Command-Q handler check is not proof of actual application-menu interception.

Independent review found no material defect in this bounded recorder. Physical capture, native editor/field-editor routing, keyboard-only preferences navigation, VoiceOver and layout variants remain acceptance gates.

## Application owner review in progress

The isolated owner initially passed17 tests. Independent review then found a validate-to-read receipt race during uncertain-save retry: replacing a parent directory with identical bytes could give a new receipt authority over the replacement. A real regression and identity revalidation fix are required before production adoption. Existing passing tests did not cover that race. Pending evidence and the current runtime profile must survive refusal.

Current GUI access is blocked. Do not infer desktop success from these hidden or core checks. The requirements matrix retains H-01 as partial.
