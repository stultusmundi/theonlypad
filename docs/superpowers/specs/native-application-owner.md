# Native application document owner

The process owns one registry, recovery actor, managed intake, native close adapter and paired
checkpoint publisher. The registry retains documents independently of windows. A separate endpoint
table retains each native window incarnation and assignment; the binding store retains detached
monitor continuity without retaining window controllers.

Startup holds publication before reading session state. Prepared tabs remain unresolved until
managed adoption and native projection complete. Each import has a real recovery adoption receipt.
A retained failure keeps its model, intake ID and remaining prepared startup records. Recreating a
lost endpoint explicitly reconciles that same intake; it never creates a replacement document to
make an import appear successful. Scratch startup uses this same transaction path.

User admission and endpoint identity are separate predicates. An accepted operation can finish
while quit prevents new user work. Managed navigation installs only the requested selection in its
captured pane after validating model, ownership, edits and endpoint; it does not acquire general
editing or focus permission. Native close uses the existing actor transaction and immutable repair
expectations. Reopening clean history prepares a new identity and consumes the exact history claim
only after active adoption.

The external-open FIFO holds at most 128 requests including the current request. It waits for
startup, prepares at most one bounded file at a time off the main thread, awaits intake and exact
line/column positioning, and retains the same identity when retrying an adopted document. Existing
file selection is projected through the registry. Large-file viewing is an explicit application
callback; unsupported positioning must be reported rather than silently ignored.

Quit gates external and user admission, drains accepted work, and refuses unsettled or queued work.
A veto resumes the existing queue and publication gates. Success requires actual native window
freeze, exact projection/resource validation and one final paired checkpoint receipt. A separate
legacy publisher is not permitted in the integrated AppDelegate.

Review has identified and corrected concurrency, endpoint retry, receipt-consumption, scalar-budget
and callback-notification risks in the component implementations. The implementation plan and
verification records track the tested paths separately. AppDelegate activation and visible desktop
acceptance remain outstanding until their own integration checks pass.
