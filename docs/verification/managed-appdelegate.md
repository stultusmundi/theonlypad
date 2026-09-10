# Managed AppDelegate integration

## Implemented

AppDelegate uses the process-owned `NativeApplicationDocuments` for startup, window creation, session repair intake, external open admission and final checkpoint/quit preparation. Editor enumeration reads the owner's windows; AppDelegate has no independent editor array or checkpoint publisher. Window callbacks decorate existing endpoints without constructing or registering documents. Settings are applied again after startup activation.

Command-line and Finder/URL requests enter the same bounded process FIFO. Overflow and quit refusal are reported. Recent Files retains its explicit target and awaits the controller's actual intake completion. Commands requiring a document refuse an unready scratch rather than silently executing against no selection. Large-file viewers remain separately owned; nondefault line/column requests are explicitly unsupported.

Session repair completion uses the exact originating panel and request identity for subsequent UI notifications and cleanup. Closing/replacing a panel cannot undo an accepted import, display its stale adjustment warning, or erase a newer request. Quit retains shortcut veto, monitoring and recent-panel suspension, repair-panel invalidation, and external-command shutdown around the owner's confirmed final receipt.

## Tested

Run the retained hidden native suite:

```sh
scripts/test-appdelegate-documents.sh
```

The runner freezes current PadCore and native sources, excluding only the application entry point, into a private Swift 5/macOS 14 package. Explicit test-access extensions are appended unchanged with source hashes. A 180-second watchdog owns only its child process group. Native presentation and termination reply callbacks are captured in tests; no windows are shown and the application is not activated.

Nine tests passed with no compiler warnings:

- Actual managed scratch ownership and persisted final session.
- Two queued pre-startup files with exact ordered line/column positions.
- Shared Finder/launch queue capacity and quit refusal.
- Settings after activation and refusal of an unready document command.
- Actual termination delegate success after a real final receipt.
- Failed final write veto, monitoring resumption, then successful retry.
- Large-viewer position refusal before presentation.
- Real repaired-file intake with a superseding panel, preserving the imported model and newer request.
- Real repaired-file intake with a newer request in the same panel, suppressing the stale warning.

Behavioral red evidence preceded implementation: the initial compiling seam failed two tests; the panel-replacement regression failed two assertions; the same-panel request regression failed one. A malformed fixture initializer was a setup failure, not behavioral evidence. Explicit MainActor annotations removed warnings from the native callback defaults before the final run.

## Outstanding acceptance

These are hidden semantic tests, not desktop acceptance. Real launch/Finder delivery, native menus and choosers, visible focus, large-file display, and quit/relaunch require desktop testing. Full application/package verification remains a separate integration gate. Transfer between independent document groups and streaming-document transfer remain outside this migration.

## Frozen integrated verification

A single recorded source snapshot, based on the committed process owner plus reviewed AppDelegate
and lost-endpoint overlays, passed the full application build and 404 core tests (16.066 seconds).
The combined `scripts/test-managed-documents.sh` runner then passed all 71 tests in one process
(5.750 seconds): AppDelegate 9, process owner 9, controller routing 32, native intake 6, external
opens 10 and close/repair 5. The runner appends the existing, hashed same-file test access
extensions; it does not change production behavior or substitute actor publication receipts.

The frozen monitor compatibility harness also passed compilation and execution: suspended open/save,
conflict actions, exact reload/copy, Locate, uncertain publication, split/tab identity, undo,
close/reopen and quit-veto behavior. Formatting, public-source patterns, shell syntax and diff checks
passed. CI now includes the combined managed suite. No visible desktop or current packaged runtime
acceptance is implied by these results.
