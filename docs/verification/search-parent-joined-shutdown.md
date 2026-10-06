# Joined parent-driver shutdown

The reviewed additive terminal API owns one shutdown task and joins the actual
parent reader/codec scopes plus the existing lane-stop acknowledgment. It retains
the result of its original child shutdown invocation, including a pending result.
It closes submission before scheduling cleanup and commits one compact completion
before returning it to callers. Caller cancellation does not cancel that owner.

Legacy-first use permanently refuses joined mode. Joined-first use makes later
legacy calls join the same completion. Legacy-only calls preserve their existing
snapshot behavior. Payload receipt consumption and external result release remain
separate responsibilities. Joined abandonment delivers to an installed observer
through the existing cancellation arbitration before dropping unclaimed data.
There are no added timers, signals, reapers, polling or production test hooks.

## Private component evidence, 2026-10-06

The compiling initial RED executes59 tests with four explicit failures and zero
unexpected failures; all54 existing driver controls pass. The minimal GREEN
passes the same59 tests. Advanced and final snapshots each pass78 tests:24 new
joined cases and54 unchanged controls, with no warnings, failures or skips.
Final inputs contain183 records and nine SDK pins (eight headers plus settings).
Final manifest:
`dd991fe89f4bd69dc2623183068b82c1d93510fa1f46a83f78a7b71b428e51e3`.

Held cases separately exercise owner startup, reader exit, codec body, completion
return, lane-loop acknowledgment, close acknowledgment and consuming reap. They
also cover first-call ownership refusals, cancellation, mixed legacy calls and
preservation of the original pending child result after later cleanup completes.
Frozen instrumentation is disclosed and absent from production candidate bytes.

Six focused mutants each run one unchanged test. Removing mode exclusion, alias
ownership, original-child preservation, the final reader wake, lane-stop wait or
existing-observer publication produces respectively1,3,3,1,1,3 explicit assertions
with zero unexpected failures. Fixture rescue follows the discriminating assertion
and joins retained tasks; no watchdog timeout is treated as a behavioral failure.
Each mutation has186 input records with an exact single replacement from the
accepted baseline.

Root checked complete frozen membership, original dependency/test bytes, exact
transform and mutation relationships, SDK pins, command/wait/capture/group receipts
and post-run executable hashes. Independent source review approved the component
and its audited evidence. Unexecuted preparation packets and an initial failed
read-only audit attempt remain preserved separately. The corrected independent
root audit completes both advanced and final snapshots.

These are injected ownership tests using actual driver/lifecycle/codec components.
They establish no real helper process, GUI, allocator release, memory budget,
campaign eligibility or user-facing supervised search. Matching public integration is recorded below. Raw evidence stays
under ignored `.local/search-parent-joined-shutdown-20261006/`.

## Public integration

The original driver and harness controls remain byte-identical. Five ordinary
joined cases live in `Tests/SearchExecutionTests`;19 held cases compile only
through the existing frozen driver runner. It pins and recomputes the exact
original-to-derived driver, lifecycle and codec-lane relations. Its wrapper changes
only the frozen directory depth; the canonical SDK and nine selected inputs are
pinned. Complete compiler/runner/original/SDK membership is checked before and
after execution. No transformed hook or rescue API ships in production source.

Proven commands:

```sh
python3 -B -m unittest discover -s Tests/SearchParentDriverIntegration -p 'test_*.py'
scripts/test-search-parent-driver.sh
```

The pure suite passes31 contracts. The public runner passes all78 named cases
with zero failures/unexpected failures/skips and complete direct owned-watchdog
receipts. Its98-record manifest is
`acfef13c68c0f7f6f229eff55ca3b9740c60b45fdd8a5a3d68ac0b480f4a097a`.
Do not wrap this coordinator in another session-owning watchdog.

A separately frozen240-input application snapshot passes847 tests with zero
failures/skips and builds the app without warnings under the accepted owned
watchdog. Manifest:
`14f686261d49719c02849be7cf56566187e317583e94c24fe2ef4058c1bc7ded`.
Root verified live source equality, exact adoption after formatting, complete
named execution and process receipts. Strict Swift formatting and public-source
checks pass. Independent public diff review found no blocker.

The first pure run had30 methods/14 setup errors: its synthetic wrapper lacked
the new required directory anchor. Only the synthetic fixture was corrected;
production derivation checks remain strict. A separate read-only full-suite audit
initially mistook “Skipped” in a passing test name for a skipped event. Its predicate
was corrected to actual XCTest skip events, with no source edit or test rerun.
These attempts remain preserved. Integration evidence is ignored under
`.local/joined-shutdown-integration-20261006/` and the existing parent-driver
integration evidence directory. The tested desktop package remains `f4d9207`.
