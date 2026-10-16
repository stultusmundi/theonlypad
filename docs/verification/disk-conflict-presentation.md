# Disk conflict presentation and Locate context

## Implemented

The installed conflict panel now retains the document's file-state binding and
observation token. Accepted monitoring changes reconcile that installed panel
even when another tab is selected. A changed binding or token revokes its
captured file actions, disables their buttons and explains how to obtain current
actions. Check Again, Retry Monitoring, Use Manual Checks and Close remain
available. Reopening Resolve captures a fresh context; existing action-time
validation remains required.

Panel replacement and close use exact instance checks. A successor installed by
a close notification survives the older call's return. Captured handlers are
retired before AppKit setters can call out, with their previous captures retained
until the mutation has finished.

## Tested

On ARM64 macOS 26.6.2 with Swift 6.3.3, the retained command completes its five
direct watchdog stages with natural exit zero:

```sh
scripts/test-disk-conflict-presentation.sh
```

The original two token-characterization tests and two presentation tests pass,
with no failures or skips. They exercise unchanged-token Locate cancellation,
retained-token refusal before and after held monitor delivery, a changed token
while another tab is selected, fresh-panel cancellation and close-notification
reentry. Managed undo/redo, close, checkpoint readback and synthetic-file cleanup
are asserted by the native tests. No windows or actual file chooser are shown.

The runner freezes current sources from the three application modules, excludes
only the application entry point and appends seven explicit test access tails.
It binds one five-module compiler graph and four test-bundle leaves before
running either selection. It retains exact command, receipt, stream, input and
artifact identities through final postflight. Do not nest this command under
another session-owning watchdog.

The separately reviewed formatted runner passes twelve pure contracts. These
use synthetic compiler files and replace the child boundary; they do not compile
or launch native code. The first thirty-second attempt timed out after ten
completed tests. The unchanged input passed all twelve under an upfront
120-second outer budget. This is verification infrastructure evidence, not an
application performance measurement. Original inert-runner failures, the held
first implementation and formatting derivatives remain recorded locally.

A separate matching panel-only compatibility run passes thirteen checks. Strict
repository formatting and public-source checks pass. Current-source default
verification separately passes all 1,203 tests, with no failures, skips or
compiler warnings, and builds the actual app and helper. All 555 recorded
source/test/support input facts match before and after that run. NativeIntegration
Python discovery separately passes 125 tests with no failures or errors. Its
synthetic child/graph controls do not establish native or desktop acceptance.

The original neighboring `scripts/test-native-monitor-lifecycle.sh` attempt
stopped at compilation before any test ran: its direct compiler command omitted
the package identity needed for current package-scoped search types and linked
only Core objects. That failure is retained. A narrow repair now reuses the
unchanged shared artifact/package validator, captures both Core and Search
objects/modules and compiles in Swift 5 mode with their actual package identity.
The native harness, test access tails, assertions and existing timeout runner
remain unchanged.

The matching-debug-path retake compiles and completes the existing hidden
harness. Its seven named completion summaries cover suspended open/save,
conflict actions, reload/copy, uncertain reload, Locate and monitor lifecycle.
These are summaries from one process, not seven XCTest cases or an assertion
count. All 384 manifest hashes still match: 190 live originals/control files,
93 augmented native sources and 101 dependency artifacts. This older harness
does not retain the new runner's strict twenty-field receipts, complete compiler
argument record or temporal artifact identities. Independent actual review accepts this
limited scope; no desktop or packaged acceptance follows.

## Outstanding

This correction does not identify the changing field in the historical packaged
Locate failure or establish that its original desktop test now passes. The
previous broader desktop result remains eleven passes and one Locate failure,
with six planned cases and separate AXPress acceptance unentered. A matching
package and actual desktop retake remain required. Physical keyboard, IME,
VoiceOver, performance and older-platform acceptance remain separate work.

Raw synthetic inputs, compiler products and captures remain ignored under
`.local/disk-conflict-presentation-integration/`. No package or release was
published by this checkpoint.
