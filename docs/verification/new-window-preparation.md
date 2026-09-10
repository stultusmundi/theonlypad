# New-window preparation — 2026-09-10

Implementation commit: `f5b27f14cc530423da28c651435490db15b6fea1`. Independent review found cancellation-result and accepted-open retention defects. Fix commit `da8ef2ef26f6d9e53401eb146cbd235948b53574` passes the expanded tests below; focused independent re-review approved both fixes with no remaining findings. This internal foundation prepares an empty destination; it does not yet move a document or expose a New Window chooser action.

## Implemented

The owner retains one preparation operation, its captured source identity, exact provisional window/endpoint and additional checkpoint pause. Admission counts the union of live and unresolved windows against 32, without rejecting zero document growth at 128 existing document IDs. No factory or adoption operation creates another document. Source/capacity revisions are revalidated after drain and configuration callbacks. Settings/callback configuration is separated from showing a window.

Cancellation removes only the original empty unannounced destination. Trusted registry hooks record completed registration/removal before public callbacks; a recreated window survives old cleanup. Changed workspace revisions conservatively retain cleanup and veto quit rather than guessing which window is safe to remove. Cancellation of an observing task does not abandon operation ownership. A precise transient destination-admission error now retains the same accepted FIFO request for explicit retry. Permanent errors keep their existing treatment; no second queue is added.

## Tested

`scripts/test-native-new-window-transfer.sh` passed 21 tests with no failures, using actual hidden AppKit controllers and synthetic temporary recovery/session files. Coverage includes 31/32/over-limit capacity, overlap and unresolved-only windows, zero document growth, existing-window transfer at exhausted capacity, source selection/ownership changes, corrupt session preservation, pending recovery removal, callback reentry, cancellation during drain, exact pause ownership and cleanup replacement.

A compiling initial implementation produced five behavioral failures. A later cancellation regression produced one assertion failure in 17 tests; post-await cancellation validation fixed it. Fixture compilation and teardown failures were preserved separately and are not described as behavioral reds.

The actual application target built with `scripts/swift.sh build --scratch-path .build/new-window-preparation`. Scoped strict Swift formatting, runner shell syntax, public-source patterns and whitespace checks passed. Existing transfer (11), chooser (3), and registry (62) tests passed against the immediately preceding source snapshot; those runs precede one extra post-drain validation and are not exact final-source compatibility evidence. The final 21-test suite includes that validation. Full core testing was not repeated for this slice.

Private provenance: `.local/new-window-task1-evidence.json`; final test run `.local/native-new-window-transfer-tests/run.YBQDqK2N`; application build `.local/new-window-production-build.log`. Raw logs and fixtures remain ignored.

## Outstanding and blocked

The next task must hand this operation to the existing transfer coordinator, retain both pause leases through settlement, distinguish generic-operation admission from native cleanup admission, and preserve later edits. The following task adds the typed chooser and final generation-fenced presentation. Groups, streaming transfer and other F-02 clauses remain outstanding.

The console remains locked. No visible app, physical keyboard, XCUITest, packaged-runtime acceptance, accessibility or desktop-focus test was performed. Current local package remains the separately verified existing-window source `324a3de`; this preparation commit is not packaged or released.

## Review corrections

Commit `da8ef2ef26f6d9e53401eb146cbd235948b53574` separates cancellation intent from an owned cleanup task/result. Waiters await cleanup; successful settlement returns cancelled, while cleanup failure returns retained with its exact error. Cleanup awaits only raw preparation, avoiding a waiter dependency cycle. The original cancellation test produced four assertion failures in 23 tests before the fix.

The same-envelope retry regression produced two failures before transient destination admission was retained. It now exercises actual `retryExternalOpen`, preserves the original request ID and later FIFO request, and verifies one import/adoption per request with no additional endpoint.

Final combined preparation suite: 23 tests, zero failures, 2.167 seconds. Actual native open coordinator suite (`scripts/test-native-application-open.sh`): 10 tests, zero failures, same production snapshot. Application build passes (2.24 seconds); scoped formatting, shell syntax, whitespace and public-source checks pass. Private evidence: `.local/new-window-task1-review-evidence.json`, preparation `run.d3YF665I`, native-open `run.NQSuCy3k`, and `.local/new-window-review-production-build.log`. Focused independent re-review approved specification compliance and code quality with no remaining findings. No broader core rerun or new desktop/package claim is made.
