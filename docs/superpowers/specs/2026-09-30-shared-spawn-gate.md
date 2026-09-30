# Shared process spawn inheritance gate — design only

Status: root-reviewed architectural design; no implementation, test changes, child launches,
or runtime evidence. Scope is the transient inheritance exposure of search-owned
raw pipe descriptors across the two current application process launch sites.
Production search routing/public lifecycle construction remains a separate gate.

## Source facts

`Sources/SearchExecution/SearchChildLauncher.swift` obtains each pair with Darwin
pipe, adopts both descriptor integers, then separately sets and verifies FD_CLOEXEC
on each. Search launches are serialized by SearchLaunchCoordinator, but that
queue cannot exclude `Sources/PadCore/ExternalCommand.swift`'s Foundation
Process.run. The gap before both successful verifications is observable by an
unrelated spawn. In particular, an inherited lifetime writer could delay helper
EOF after the real parent closes its copy.

The launcher already preserves exact descriptor ownership, consumes close
authority before its single close syscall, and retains uncertain closure in a
search-wide quarantine. That quarantine alone does not stop Foundation launches.
POSIX_SPAWN_CLOEXEC_DEFAULT protects the search child's own descriptor selection;
it does not close the parent-side race with another concurrent launch.

The launcher creates /dev/null using O_CLOEXEC and normalizes low descriptors with
F_DUPFD_CLOEXEC; these creation operations are atomically protected by their
contracts. The vulnerable creation primitive is raw pipe. Source search found
only these two application process launch sites. This is not a claim about
arbitrary frameworks, plugins, or code that bypasses the approved launch sites.

## Recommendation and alternatives

Use a short process-wide gate around each raw pipe creation through protection or
settled failure, plus the same gate around each actual spawn syscall/API call.
All other search setup stays on its existing spawn lane. Do not hold the gate
over channel construction, ownership publication, engine work, transport I/O,
wait/reap, sleeps, completion callbacks, or asynchronous cleanup.

Three alternatives were considered:

1. **Recommended per-pipe protection and per-spawn admission.** A critical region
   starts before pipe and ends only when both descriptors are known protected or
   synchronously closed, or unsafe uncertainty has permanently poisoned the
   shared gate. Once both are protected, unrelated spawns are safe throughout
   normalization and later setup. This preserves current PID/adoption/cleanup
   structure and keeps Foundation excluded only for short syscall sequences.
2. **One larger search transaction.** Hold from first pipe through spawn and
   synchronous ancillary cleanup. This has fewer admission points but excludes
   unrelated work during all flags, file-action setup and argument allocation.
   Existing adopt is a collaborator and must move outside the gate; a typed
   raw-spawned result must retain PID and parent descriptor ownership until
   adoption. This increases the change surface around already accepted cleanup.
   Validation should still remain outside the gate. It is viable, but not the
   minimal change for this race.
3. **Rely on Foundation inheritance behavior or search-only CLOEXEC_DEFAULT.**
   Rejected. Neither coordinates the transient parent descriptor state with the
   other launch site. Do not assume an unproved Darwin pipe2 availability or
   globally ignore a failed flag/close operation.

## Minimal package interface

Add `Sources/PadCore/ProcessSpawnGate.swift`, using Foundation's existing NSLock.
PadCore owns the primitive because SearchExecution already depends on PadCore.
No new public product or dependency is needed.

Proposed package surface, with names finalized during implementation:

```swift
package enum ProcessSpawnGateError: Error {
  case quarantined(Int32)
}

package final class ProcessSpawnGate: @unchecked Sendable {
  package static let process: ProcessSpawnGate
  package init() // Fresh, healthy test scope; production defaults use .process.
  package func withCriticalRegion<T>(
    _ body: (inout ProcessSpawnPermit) throws -> T
  ) throws -> T
  @discardableResult
  package func run(_ process: Process, unlessCancelled: () -> Bool = { false }) throws -> Bool
}

package struct ProcessSpawnPermit {
  // Construction and stored state fileprivate to the gate file.
  package mutating func quarantine(_ error: Int32)
}
```

The gate checks its own stored poison after acquiring the lock, before invoking
body. The permit records only a first nonzero error; no reset/unpoison operation
exists. A defer copies any permit poison into the gate BEFORE unlocking, even
when body throws. The closure is synchronous/nonescaping and its inout permit
must not escape. The gate has no descriptor ownership or retry authority and
does not store descriptor integers. It records refusal state, not a proof that
the process has been cleaned up. The existing launcher quarantine retains its
separate ownership evidence.

The small `run(Process)` method is the production Foundation integration point:
enter gate, check the bounded internal cancellation query, call Process.run
synchronously only if still admitted, then release. False means no child was
launched. It contains no waits or arbitrary client callbacks. It can be exercised with a real Foundation process in the isolated
integration composition, while deterministic ExternalCommandRunner tests verify
that the runner uses this same integration point. No arbitrary launch closure
or fake implementation becomes a public default.

SearchLaunchCoordinator receives a gate instance through its internal initializer;
its production singleton uses ProcessSpawnGate.process. ExternalCommandRunner's
public initializer uses the same singleton and gains an internal/package injected
initializer for a fresh gate and, if needed, a narrow Foundation launch operation
test seam. Its used/cancelled lock is never held across gate acquisition.

## Search-side protected-pipe transaction

Maintain descriptor ownership separately from inheritance safety. Each
LaunchDescriptor gains a monotonic `closeOnExecConfirmed` fact; false is the
conservative default for pipe results. Setting/verification returning successfully
makes it true. A failed verification remains false even if F_SETFD may have
actually worked. Known O_CLOEXEC and F_DUPFD_CLOEXEC creation can mark their
result protected immediately by the syscall contract; no later clearing exists.

For each new pair:

1. Acquire the gate before operations.pipe. If already poisoned, return typed
   refusal without calling pipe or any spawn operation.
2. Adopt BOTH returned descriptors before a fallible flag call, preserving the
   current invariant. A throwing pipe collaborator must mean no descriptors
   were created; it must never hide partially owned results.
3. Set and verify CLOEXEC for the read end, record its confirmed fact; then do
   the same for the write end. Only now may successful protection release gate.
4. If any step after creation fails, perform bounded synchronous cleanup while
   still holding gate. Existing close authority is consumed before syscall and
   never retried, including EINTR/EBADF. Closing both new ends is mandatory even
   if the first fails. It is safe to close the earlier, already protected cells
   here as well, but not necessary to close them before gate release.
5. If any created descriptor is BOTH unconfirmed protected AND not confirmed
   closed, poison the shared permit before unlock. Keep the search quarantine
   and original setup/close diagnostics. Throw only after this invariant holds.
6. Normalize low descriptors outside gate: originals are already CLOEXEC, and
   duplicate creation uses F_DUPFD_CLOEXEC. Later uncertain closure still poisons
   the existing search coordinator; it need not poison the shared gate if every
   uncertain descriptor was already confirmed protected.

The outer existing catch may call cleanup again, but descriptor cells prevent a
second syscall after consumed close authority. It must not defer the first
unprotected-descriptor cleanup/poison decision until AFTER gate release.
Likewise a Swift defer ordering that unlocks before committing poison is invalid.

Enter the gate again for the exact `setup.spawn` call. A new poison discovered
since the last pipe transaction refuses launch before child creation; normal
outer cleanup disposes of its already protected descriptors. No blocking dispatch
sync to the search queue occurs while gated. After a successful spawn result,
release gate BEFORE channel adoption and completion publication. Existing
irrevocable PID adoption and sole-reaper rules remain unchanged.

## Failure disposition table

| Situation at gate release | Shared gate | Existing search disposition |
| --- | --- | --- |
| pipe fails before any results | healthy | original failure |
| both ends verified CLOEXEC | healthy | proceed |
| flag/verification fails; every unprotected end closes successfully | healthy | original failure; cleanup confirmed |
| an unprotected end close is uncertain, including EINTR or EBADF | permanently poisoned | retain quarantine; refuse replacement |
| only verified-protected end close is uncertain | healthy | retain search quarantine |
| ordinary posix_spawn or Process.run error with no unsafe descriptor | healthy | original spawn failure; cleanup as before |
| gate already poisoned | body not invoked | fail before any new child |

Shared poisoning must block a new Foundation runner as well as a new search
launcher/coordinator using that same gate. Creating another facade cannot escape
it. Do not clear poison after a later fcntl probe: the descriptor integer may have
been consumed and reused. Do not retry close, scan descriptor numbers, or claim
closed from a query of a potentially reused number. Restart is the recovery for
this narrowly scoped fail-closed condition.

Map shared refusal explicitly to SearchChildFailure.launchFailed(error) instead
of letting the existing generic catch discard it as EIO. Foundation callers get
an actionable ExternalCommandError case such as spawnSafetyUnavailable; it must
not become a timeout/cancel/success result. Existing launch errors otherwise
retain their origin. The error should describe restart/retry safety without
publishing descriptor integers or internal paths.

## Lock order and concurrency constraints

- Search: existing serial spawn queue → shared gate → local synchronous Darwin
  setup/spawn calls. Never shared gate → search queue sync or channel/async owner.
- External runner: briefly runner-state lock, RELEASE it, then shared gate →
  Process.run. Release shared gate before pipe capture, cancellation/termination,
  process waiting or any output collection.
- Signal/reap control-lane methods do not acquire gate and cannot be delayed by a
  slow Foundation spawn through this new lock. Launch is already submitted to
  the retained spawn lane, so gate acquisition never blocks lifecycle control.
- Gate is nonrecursive. Production critical closures contain no client callback,
  engine, task wait, sleep, or nested gate admission. Test gates/observations are
  confined to injected collaborators and cannot become production hook calls.
- NSLock supplies mutual exclusion, not a bounded wait or real-time guarantee.
  Process.run/spawn may themselves take time. Deadline/cancellation ownership
  stays with lifecycle; no new promise that spawn returns within a policy time.

## Deterministic tests with isolated state

Every uncertainty/failure test constructs a fresh ProcessSpawnGate and shares it
only among that test's search coordinator and Foundation adapter/runner. Never
poison or reset `.process` in ordinary tests. Tests use scripted descriptor values
and injected operations; none passes fake numbers to Darwin or creates a child.
Concurrent tests use explicit entered/release gates, always release them in defer,
and have a bounded harness watchdog. No timing sleep is the ordering oracle.

Required behavioral controls:

1. Hold search at successful pipe return before either CLOEXEC. Submit a
   Foundation admission attempt; assert its body cannot enter. Release search,
   then assert both protections precede Foundation entry. Reverse the overlap:
   hold Foundation spawn region and show raw pipe is not created until release.
2. Fail each endpoint's F_GETFD/F_SETFD/verification stage. Confirm both ends are
   adopted before failure and each owned close attempted once. When unprotected
   closes succeed, a subsequent Foundation admission proceeds.
3. Inject uncertain close of an unprotected endpoint, for EINTR, EBADF and EIO.
   Confirm poison commits before a concurrently queued Foundation attempt can
   enter. That attempt and later fresh runner/coordinator attempts refuse without
   invoking launch bodies. The first original error remains available.
4. Distinguish protected-only uncertainty: establish both flag facts, inject a
   low-FD normalization/ancillary close failure, retain search quarantine, but
   permit a Foundation spawn body. Never turn this into a false cleanup receipt.
5. Throw from within a gate region after setting poison; assert the next entrant
   sees poison. Throw without unsafe state; assert the next entrant proceeds.
   Verify success and failure both release the lock.
6. A new poison between completed protected-pipe setup and search spawn causes
   that search transaction to close its protected descriptors and invoke no spawn
   body. Already spawned children retain their previous exact owners/reapers.
7. Test the actual ExternalCommandRunner admission integration using its narrow
   injected launch seam: refused gate invokes no launch, has correct typed error,
   and does not hold its cancel lock. Its output/cancel/wait flow remains outside
   the shared gate; ordinary existing command regressions remain required.
8. Re-run the accepted launcher ownership matrix, failed-startup/adoption,
   single-close/quarantine and deterministic lifecycle controls. A gate-removal
   mutant must violate the explicit overlap ordering test; a missing poison
   commit mutant must admit the Foundation body and fail its refusal test.

Package tests can use the gate via package access; cross-target frozen harnesses
must retain one package identity and capture the new PadCore source in inventory.
The runtime/bootstrap worker's files need no changes for this gate.

## Separately reviewed real unrelated-child EOF evidence

Root alone runs this under the accepted direct owned-process watchdog after source
review. Add a fixed synthetic unrelated peer executable supporting only
hold-until-stdin-EOF: emit one bounded readiness marker, block on its explicit
stdin control pipe, exit0 on EOF, exit70 on unexpected data/error. No shell,
arbitrary regex/command, user path, environment payload or detached process.
Freeze/hash both peer and search fixture and their exact source inventories.

Use the real SearchChildLauncher and an actual Foundation Process passed through
the very same ProcessSpawnGate.run adapter used by ExternalCommandRunner. Give
both a fresh shared gate. A test-only LaunchOperations decorator forwards real
syscalls but gates the return of the lifetime pipe creation before CLOEXEC; record
the Foundation admission attempt outside the gate. It must not spawn until
protection is complete. Release that setup gate promptly, then wait for bounded
readiness markers from both children. Retain the unrelated peer's explicit stdin
writer to keep it alive; do not release it during the lifetime assertion.

Close the helper's real parent connection/control writer. Require the independent
helper lifetime watcher to exit0 and the SearchChildLifecycle sole reaper to
record the exact PID/generation, with channel cleanup. The unrelated Foundation
peer must still be running at that observation, so its own exit cannot account
for the helper EOF. Only then close the peer's explicit stdin writer, require
normal exit0, and use its one Foundation/test owner to wait and close its pipes.
On any failure, each already-owned child retains its exact cleanup authority;
watchdog bounds the complete test. No competing raw waitpid for Foundation's PID.

This composition proves actual unrelated Foundation spawn plus helper EOF while
that unrelated child is alive. It does not claim the entire ExternalCommandRunner
capture/timeout path was exercised; deterministic integration plus the existing
runner regression tests cover that consumer connection. Nor does it prove parent
death, malicious-child behavior, arbitrary framework launches, or real-time EOF.
An ordinary happy run without the controlled overlap is insufficient to establish
the pipe-to-CLOEXEC exclusion window. If current Foundation already closes unknown
FDs, retain that fact as platform behavior only: the deterministic gate-removal
mutation still proves the application no longer relies on it.

## Scope and adoption gates

Expected touched production files are the new PadCore gate, ExternalCommand.swift
for shared gated admission and error mapping, and SearchChildLauncher.swift for
injected gate/protection facts/scoped creation and spawn. Package target graph is
already suitable. Add focused gate/consumer tests and one reviewed real fixture
composition, with exact frozen inventories. No helper/runtime/bootstrap source
changes, broad subprocess rewrite, global signal changes or privacy changes.

Root reviewed the permit's monotonic failure semantics and per-pipe cleanup
placement on2026-09-30. The user has explicitly waived routine approval ceremony;
independent implementation review and exact execution evidence remain required. Before actual child execution require
deterministic RED/GREEN, overlap and poison mutants, matching source snapshots,
and independent source review. Record implemented, tested and remaining gates
separately; this document alone establishes no inheritance protection.


## Independent review correction: deterministic contention oracle

An outside-gate “attempt submitted” signal alone does not prove the competing lane reached admission; scheduler delay can falsely preserve ordering even with a missing gate. Before releasing the held region, the test must observe actual contention on that same lock, or unexpected early body entry. A bounded test-level wait records explicit failed assertions if neither occurs; the outer watchdog is cleanup, not the intended red oracle.

Use a narrow optional test-only contention observer on a fresh package gate: production's default nil takes the normal `NSLock.lock()` path; an observed test path first tries the same lock with `try()`, calls the observer only after a failed try, then blocks on that same lock. A successful try already owns the lock and must not acquire twice. The observer only records/signals and must not reenter, wait or mutate gate ownership. It is not part of the public app API. The held owner releases only after the fixture distinguishes confirmed contention from early body entry; gate-removal mutation produces an explicit wrong-event assertion. A missing poison-commit mutation still produces a direct incorrect-admission assertion.

Real overlapping-child fixtures use this observation too; outside submission signals remain bookkeeping, never exclusion evidence. No timing sleep becomes an ordering oracle. Preserve default-nil production behavior and test both healthy/poisoned unlock paths.


## Review correction: cancellation while awaiting admission

The preexisting external-command cancellation check occurs before gate acquisition. A command cancelled while contending must not launch when the gate eventually opens. `run(_:unlessCancelled:)` checks the runner's private cancellation state after healthy admission and immediately before `Process.run`; false maps to the existing cancelled result with no PID/exit/output. Shared poison is checked first. Admission linearizes at this query; cancellation after it may race with spawn and follows the existing termination path, not an atomic syscall-cancellation promise.

This permits exactly one short internal gate→runner-state query. Every runner-state-lock path releases before acquiring the shared gate, and the query releases that state lock before Process.run, so no inverse held-lock path exists. No client-defined callback is exposed publicly. Test holds the actual gate, observes exact lock contention, cancels, releases, then requires zero fake Process.run calls and a cancelled result. Preserve compiling RED before adding the query.
