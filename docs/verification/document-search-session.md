# Document search session component — 2026-10-14

## Implemented

`Sources/TheOnlyPad/DocumentSearchSession.swift` adapts the actual application
document-search consumer into presentation state. It retains opaque request and
result identities, bounded counts, a navigation index and an approval token.
Captured document text, match arrays and replacement output stay with the owner.

Synchronous delivery is buffered until the returned request is adopted. A thrown
submission takes precedence over its buffered delivery. Cancellation, close,
new requests and callbacks fence earlier state with fresh intent identities.
Navigation borrows the actual owner result. Replacement approval can return
later; the owner revalidates the source before applying it. Foreign or consumed
approval tokens cannot mutate a result. Reentrant newer requests survive cleanup
and presentation callbacks.

The existing search panel is unchanged and still uses its previous execution
route. This component is a prerequisite for supervised panel integration.

## Reproduction and tested evidence

On the verified ARM64 macOS host:

```sh
scripts/test-document-search-session.sh
scripts/test-application-search-owner.sh
```

Both commands accept no arguments, freeze actual sources and invoke the checked-in
owned-process watchdog directly. Do not wrap either in another process-group
watchdog. Synthetic raw captures remain in ignored local evidence directories.

The new fixed public command passes all 21 tests, with no failures or skips. It
verifies queued capture, synchronous delivery, submission refusal, late leases,
navigation, held approval, independent source credentials, missing results,
cancellation reentry, foreign tokens and an independently credentialed sibling
consumer that remains usable after session close. Backend and source boundaries
are scripted through the actual owner. The replacement-observer test changes a
counter; it does not establish native text editing or rollback.

The unchanged owner command separately passes its original 16 tests. Public
commands compile warning-free in Swift 5 mode with a macOS 14 target; they do not
request warnings as errors. The private component GREEN run does request warnings
as errors and passes the same 21 cases. Its 99 inputs, 97 mapped and linked objects,
133 artifacts and complete cleanup receipts were independently reviewed.

The declaration-only baseline reached and failed all 21 cases with 44 failure
records, including 16 missing-fixture throws. These establish initial absent
behavior; downstream assertions were not all reached then. Static test revisions
preserve earlier packets and fix access, reentry, sibling and unsafe-index issues.
No compiler failure or undiscovered test is counted as behavioral RED.

A fresh full public package passes all 1,203 default tests and builds the actual
app and helper warning-free with warnings as errors. The frozen inventory has
585 inputs, 304 compiler objects and 366 artifacts. Independent review confirms
the same default test identities and outcomes as the preceding preview build,
with only the four new component files added. The standalone 21 and 16 tests are
separate selections. Repository strict formatting, public-source checks and
staged whitespace checks pass.

CI now invokes both proven component commands directly. The workflow change was
reviewed locally; no remote CI run or publication was performed for this change.

The tested host is ARM64 macOS 26.6.2 with Swift 6.3.3 in Swift 5 mode. The macOS 14
deployment target is a compiler setting; minimum-OS and Intel runtime acceptance
remain unperformed. Original MIT code; no dependency or asset was added.

## Planned and blocked state

Native source validity, revision exhaustion acceptance, actual panel and application
lifecycle wiring remain outstanding. The component tests do not establish helper
execution, hard regex containment, RSS, performance, native nonmodal approval,
physical input, accessibility or packaged desktop acceptance. No external blocker
prevents the next implementation step. Distribution artifacts were unchanged;
no remote push, merge or publication occurred.
