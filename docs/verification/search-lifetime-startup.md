# Checked parent-lifetime startup — 2026-10-08

## Implemented component

`SearchParentLifetime.start` creates a detached pthread with checked attribute,
creation and cleanup results. Negative descriptors refuse before setup. Creation
failure releases the retained context once; success transfers it to the C entry,
including callbacks that finish before `pthread_create` returns. The entry ends
context ownership before invoking the existing blocking lifetime reader, whose
production body terminates the process without running Swift destructors.

The worker Program now accepts a throwing startup callback and returns exit70
on startup failure, before request reads, accumulator construction or engine work.
Bootstrap, descriptor/channel refusal and existing runtime exit mappings remain.
The lifetime descriptor is borrowed and must be the launcher's distinct blocking
control read end; this starter neither closes it nor retries thread creation.

## Tests executed

On ARM64 macOS26.6.2 with Swift6.3.3 in Swift5 mode and macOS14 deployment target:

- Missing interfaces/throwing-signature mismatch: compiler refusal, zero test methods.
- First attempted behavior run: compiler refusal because the imported pthread
  callback takes a nonoptional context pointer. The corrected alias preserves
  the ownership contract; no assertions are attributed to this setup failure.
- Corrected minimal compiling omission controls:26 methods,54 expected assertions,
  zero unexpected failures. All12 original Program methods pass. These controls
  are explicitly incomplete components, not a historical production baseline.
- Implemented starter/Program:26 methods, zero failures.
- Formatted worker/starter selection:133 methods, zero failures.
- Full app/core suite:895 methods, zero failures; actual app built.
- Pure harness/watchdog suite:56 methods, zero failures after two intended RED
  failures for omitted required test input and missing-input admission.

The focused and broad SwiftPM runs use the checked-in owned-process watchdog;
exact commands, unchanged compiler inventories and complete cleanup/capture
receipts are retained under ignored `.local/`. Commands:

```sh
scripts/swift.sh test --scratch-path .build/lifetime-startup --filter 'SearchParentLifetimeStarterTests|SearchWorker'
scripts/swift.sh test --scratch-path .build/lifetime-startup
python3 -m unittest discover -s Tests/SearchChildIntegration -p 'test_*.py'
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
```

Run broad tests under `scripts/run-owned-search-tests.py`; the search-child
coordinator owns its watchdog directly and must not be nested in another.

## Actual process integration

Independent specification and quality review approve the implementation and
frozen input wiring. The existing synthetic busy-main fixture now calls the
fixed package starter; its old Foundation thread/semaphore startup is removed.
All other fixture modes and bounded readiness metadata remain unchanged.

The frozen deterministic lifecycle/launcher/timer/starter selection passes104
methods. Separately selected actual process cases each pass1/0 against that
same source/fixture/peer/test-bundle binding:

- Busy main announces its entered loop, then parent control close produces the
  exact generation-qualified consuming reap with exit0 and closed channels.
- An unrelated Foundation process remains alive through lifetime EOF, exact
  child reap and channel closure, demonstrating the existing spawn gate's
  inheritance regression with the changed fixture inventory.

All stage commands have complete direct-watchdog wait/capture/cleanup receipts.
The first private actual-selection setup refused before dispatch because its
bundle-path guess used the wrong package name; the exact observed bundle name
was corrected. That setup failure is not an executed test failure.

Reproduction through the public coordinator (each owns its watchdog):

```sh
scripts/test-search-child-lifecycle.sh --filter 'SearchParentLifetimeStarterTests|SearchChildLifecycleTests|SearchChildLauncherStateTests|SearchChildLifetimeStateTests|SearchChildDispatchTimerTests|SearchChildSpawnInheritanceFixtureTests'
scripts/test-search-child-lifecycle.sh --filter SearchChildLifetimeProcessTests
scripts/test-search-child-lifecycle.sh --filter SearchChildSpawnInheritanceTests
```

## Remaining scope

Deterministic operations test the real context and C entry but do not create a
thread; the separately selected process checks above do. No production helper
executable, editor search routing,
hard regex cancellation, memory/performance, GUI, Intel or macOS14 runtime
acceptance follows. Desktop UI Automation authentication remains pending.
No external dependency or asset was added; original code remains MIT licensed.
