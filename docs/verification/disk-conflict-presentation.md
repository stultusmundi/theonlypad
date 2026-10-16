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

The neighboring legacy `scripts/test-native-monitor-lifecycle.sh` attempt stops
at compilation before any test runs. Its direct compiler command omits the
package identity needed for current package-scoped search types and links only
Core objects. The failure is retained; migrate the harness to matched current
dependencies without changing assertions before claiming compatibility. The
passing four-case retained runner does not replace that unperformed selection.

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
