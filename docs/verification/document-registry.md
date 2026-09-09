# Document registry and capacity verification

Status: the initial view-free ownership subset and pure session-capacity seam are implemented and tested. Registry close-state handling is also implemented and tested. Native document ownership and close enforcement, window/group transfer, streaming ownership and desktop acceptance remain outstanding. These components are not yet wired into application behavior.

## Implemented and tested

`ApplicationDocuments` retains one handle per UUID and object identity, with one window/group assignment. It owns initial pin metadata, stable pin ordering, selection/focus/reorder, group axis and empty group/window removal. Invalid/stale/reentrant mutations leave state unchanged; no-op operations do not publish a new revision. Change notifications run after stable commit and may reenter without older cleanup overwriting the new operation. Current32window/128handle checks count live records only.

The first seven behavioral tests failed36assertions before implementation. Independent root review found that one object could be registered under a changed UUID; a regression failed4assertions before object-identity admission was added. The full retained suite now passes13tests. Root independently reran it with zero failures in0.005seconds; independent code review found no material issues within this subset.

`SessionCoordinator.transferCapacity` reads live/unresolved window and document IDs without invoking file services or changing state. Incomplete startup, preserved startup errors and pending cleanup refuse the read. A separate revision changes before capacity-relevant state/callbacks. It returns truthful sets even above32windows/128documents; the future registry adapter must enforce admission and unresolved-ID collision policy.

Four initial capacity tests failed18assertions. The expanded seven-test suite passes, including actual corrupt-file preservation, successful file restoration, unresolved-only windows, held startup/cleanup, failed/successful cleanup, callback-visible revision changes, no snapshot I/O/notifications and recent-path independence. Root independently reran7tests with zero failures in0.007seconds.

## Reproduction

```sh
scripts/test-application-documents.sh
scripts/test-session-capacity.sh
```

Both scripts freeze actual sources into ignored local packages, retain hashes/results, enforce process watchdogs and propagate nonzero statuses. They do not create native windows. Root evidence is in `.local/registry-root-verification.log` and `.local/capacity-root-verification.log`; initial failures and agent runs remain in their respective ignored evidence directories. These are test timings, not performance benchmarks.

## Remaining work

The complete interface and staged work are in [the reviewed design](../superpowers/specs/document-transfer.md) and [implementation plan](../superpowers/plans/2026-09-10-document-transfer.md). Move services/endpoints, native mutation guards, monitor relays, transfer rollback, independent document groups and streaming handles remain planned. Registry close tickets and correlated repair states are implemented, but the required native and recovery actor adapters are not. Fake handle tests do not establish real editor/undo/save/close safety. Current public package predates this work; no GUI, remote CI, signing or release validation is claimed here.

## Close-state extension

The expanded registry suite passed 30 tests (the original 13 plus 17 close cases), with zero failures in the root run. Independent review found no material issues in this limited scope. Affected-group and per-document admission generations reject reused confirmations even after selection, order, pin or axis changes return to their old values. Closing retains strong model ownership; failed or uncertain cleanup cannot silently dispose of changed state. Retired document UUIDs stay reserved, retained history objects cannot be re-registered, and history remains bounded.

Repair results correlate the exact attempt, document and mutation state. Tests use synthetic receipts: they do not prove filesystem durability or authorize resetting a real recovery tombstone. Current RecoveryCoordinator.close permanently retires its UUID even if removal fails; it must not be wired directly to the new safe-failure path. A reviewed recovery close/repair service and real native mutation guards remain required dependencies. No new close UI is exposed by this component.

Code is local commit `11d2a25`; root evidence is `.local/document-close-root-verification.log`. The current native application including these types also built successfully. A passing build is not native close acceptance.
