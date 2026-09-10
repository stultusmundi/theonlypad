# Native application ownership integration

Status: implemented composition under hidden integration testing; AppDelegate activation remains outstanding.

The native process owner composes the real document registry, recovery actor, intake adapter,
close adapter, endpoint binding store, and managed paired checkpoint publisher. Endpoint records
contain presentation identity rather than a second document ownership collection. Startup keeps
prepared records unresolved until managed adoption succeeds. Native history preparation creates
new model identity from a validated clean history claim on a worker.

Observed hidden native integration results:

- Initial startup seam: one test failed with `notReady`.
- Implemented startup: one test passed, including native editability and final session readback.
- Three-test expansion passed: two real temporary files retain order, pin and selected tab;
  concurrent retry while session loading is held is refused without creating a competing scratch.
- Four-test expansion passed: native Close and Reopen Closed Tab commands use actual actor
  cleanup, retained clean history, a new model/recovery authority, and a paired final checkpoint.
  Four tests completed with zero failures in 0.430 seconds.

Each test uses synthetic files and an isolated session/recovery directory. Private runner output
contains source hashes and raw logs; these paths and machine diagnostics are not public artifacts.
A fresh five-test full-native snapshot passed with zero failures in 0.624 seconds after the review
fixes and public owner APIs. The fifth test restores a previously missing real temporary file
through managed session intake, creates another native scratch window, and reads back all three
windows from the same final paired publisher. Quit now awaits an already-issued intake result
before checking settlement.

Independent review identified startup retry concurrency, scratch intake retention, stale endpoint
retry, post-activation admission refresh, aggregate resource budgeting, and empty-window metadata
notification issues. Changes address these findings; not every failure branch has dedicated runtime
fault injection yet. Native forced close repair is being tested separately.

These checks instantiate real AppKit controllers without displaying windows. They do not establish
GUI, accessibility, IME, packaged application, or performance acceptance. The running application
still uses its legacy composition until the process owner and launch/session-panel routing are
integrated and reviewed.

## External queue and capacity integration

Six actual-owner tests passed with queued-before-startup opens and exact positions in two different
native documents. Further review identified window admission ignoring unresolved reservations.
The real 32-reserved-window case failed with five assertions before the fix, including an extra
endpoint and a failed final checkpoint. Endpoint creation now preflights the combined window set;
startup reuses a reserved window when all 32 slots are occupied. New scratch windows also preflight
the combined document count.

The final eight-test run passed in 0.749 seconds. It adds the 32-window regression and a full
128-unresolved-document case: no extra scratch or endpoint is allocated, the capacity notice is
explicit, and final session readback preserves all original records. Independent rereview found no
remaining material issue in these changes. Imported-position retry now reselects the exact owned
document; its switched-tab branch remains source-reviewed rather than independently fault-injected.

This run used a frozen native package from before the concurrent AppDelegate migration, with
hashed owner/test overlays. It includes real native controllers, registry, recovery actor and
publisher, but does not validate the new AppDelegate source. AppDelegate and complete frozen
application verification follow separately.
