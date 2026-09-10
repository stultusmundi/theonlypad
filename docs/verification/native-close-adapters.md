# Native close adapter verification

Root froze committed `cbf718c` plus reviewed controller/routing, async panel and native intake overlays in `.local/native-close-integrated`; `source-provenance.json` records exact hashes. The full app built in 8.83 seconds. All 404 core tests passed in 15.971 seconds, 21 hidden actual-controller tests in 1.418 seconds and six native-intake tests in 0.124 seconds. The hidden legacy monitor/save/Reload/Copy/Locate/close/quit suite also passed against that build. Logs are `.local/native-close-integrated-{build,core,controller,intake,monitor}.log`. These build timings are not launch/input benchmarks.

Controller tests cover lease/global admission, direct setters/UndoManager, chooser reentry refusing writes, clean and dirty close decisions, stale affirmative refusal, exact surviving-tab history, empty-window permit, scalar/drain checks, real directory-sync publication uncertainty, closed-user-gate capture, registry history availability and actual first responder preservation. Close projection fixtures settle registry cleanup synthetically; they do not provide actual actor deletion receipts. Separate process-close tests validate real actor flows, and full native composition remains required.

Behavioral evidence includes initial ten-test/seven-failure admission red, eleven-test/three-failure adapter red, twenty-test/two-failure callback red, one registry-history availability failure, and one real-focus failure. Narrowing the target predicate alone did not prevent AppKit resignation; the window preflight fixed the preserved assertion. Fixture compile errors and an unapplied patch attempt remain separately retained, not passing evidence. Independent review findings were reproduced and resolved. Final controller source passed strict formatting and diff checks.

No window was shown or activated. Native alert keyboard behavior, arbitrary impure focus-predicate rollback, process endpoint recreation/monitor reattachment, actual AppDelegate close/quit integration and packaged desktop acceptance are not claimed. The existing legacy initializer remains active.

## Endpoint recreation and asynchronous reopen

A subsequent hidden controller suite passed 26 tests. It covers asynchronous history preparation
before issuing a real intake ID, reattachment through the actual process binding store, explicit
intake destination reconciliation to a replacement controller, and legitimate closing of an empty
registry window. Independent review exposed a consumed reattachment receipt being retried after
later projection validation failed. Its behavioral regression failed before the fix; attachment
success is now recorded before the next external validation callback. Final 26-test run passed in
1.754 seconds. These are controller tests, not AppDelegate or visible desktop acceptance.

## Awaited managed navigation

The controller now provides awaited navigation for an exact document/endpoint. It captures the
model, pane, ownership, selection and edit state before worker calculation and installs only that
pane's selection after validation. It does not grant editing or move focus; legacy navigation is
unchanged. The suite passed 31 tests before independent review identified unfinished character
edits preceding the normal edit revision. A held text-storage batch reproduced stale-offset
acceptance (32 tests, two failing assertions). Pending character edits now refuse navigation.
The final 32-test suite passed in 2.147 seconds, including closed user admission, stale worker
results, close leases, and changing the current document without redirecting navigation.
