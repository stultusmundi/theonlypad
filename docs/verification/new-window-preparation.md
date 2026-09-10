# New-window preparation — 2026-09-10

Implementation commit: `f5b27f14cc530423da28c651435490db15b6fea1`. Independent specification/code review requires a fix: waiters can report cancellation intent as completed cancellation even when cleanup retains the operation. That result contract is under correction; the 21-test source below does not cover it. This internal foundation prepares an empty destination; it does not yet move a document or expose a New Window chooser action.

## Implemented

The owner retains one preparation operation, its captured source identity, exact provisional window/endpoint and additional checkpoint pause. Admission counts the union of live and unresolved windows against 32, without rejecting zero document growth at 128 existing document IDs. No factory or adoption operation creates another document. Source/capacity revisions are revalidated after drain and configuration callbacks. Settings/callback configuration is separated from showing a window.

Cancellation removes only the original empty unannounced destination. Trusted registry hooks record completed registration/removal before public callbacks; a recreated window survives old cleanup. Changed workspace revisions conservatively retain cleanup and veto quit rather than guessing which window is safe to remove. Cancellation of an observing task does not abandon operation ownership. Review exposed an additional gap: a request accepted while preparation blocked destination selection was discarded as refused. Same-request retry retention is under correction; explicit re-enqueue is not accepted as evidence of preserved intent.

## Tested

`scripts/test-native-new-window-transfer.sh` passed 21 tests with no failures, using actual hidden AppKit controllers and synthetic temporary recovery/session files. Coverage includes 31/32/over-limit capacity, overlap and unresolved-only windows, zero document growth, existing-window transfer at exhausted capacity, source selection/ownership changes, corrupt session preservation, pending recovery removal, callback reentry, cancellation during drain, exact pause ownership and cleanup replacement.

A compiling initial implementation produced five behavioral failures. A later cancellation regression produced one assertion failure in 17 tests; post-await cancellation validation fixed it. Fixture compilation and teardown failures were preserved separately and are not described as behavioral reds.

The actual application target built with `scripts/swift.sh build --scratch-path .build/new-window-preparation`. Scoped strict Swift formatting, runner shell syntax, public-source patterns and whitespace checks passed. Existing transfer (11), chooser (3), and registry (62) tests passed against the immediately preceding source snapshot; those runs precede one extra post-drain validation and are not exact final-source compatibility evidence. The final 21-test suite includes that validation. Full core testing was not repeated for this slice.

Private provenance: `.local/new-window-task1-evidence.json`; final test run `.local/native-new-window-transfer-tests/run.YBQDqK2N`; application build `.local/new-window-production-build.log`. Raw logs and fixtures remain ignored.

## Outstanding and blocked

The next task must hand this operation to the existing transfer coordinator, retain both pause leases through settlement, distinguish generic-operation admission from native cleanup admission, and preserve later edits. The following task adds the typed chooser and final generation-fenced presentation. Groups, streaming transfer and other F-02 clauses remain outstanding.

The console remains locked. No visible app, physical keyboard, XCUITest, packaged-runtime acceptance, accessibility or desktop-focus test was performed. Current local package remains the separately verified existing-window source `324a3de`; this preparation commit is not packaged or released.
