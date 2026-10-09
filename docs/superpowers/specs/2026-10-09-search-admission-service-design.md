# Fixed admission service composition

Status: PLANNED implementation. The design, public adoption and implementation
plan have independent specification/quality approval. No facade code,
compiler contract, fixed-service helper run or native routing is implemented by
this record. Existing joined-terminal component is locally committed at `42513c0`
with full993/0 and separately verified native10/0. Source authoring proceeds under the
reviewed public spec/plan. Concrete process-observation harness approval remains
a separate prerequisite for actual helper acceptance.

## Goal and boundary

Add `SearchAdmissionService<Context>` in SearchExecution as a fixed composition
facade over the existing actual parent, production accounting, production retry
scheduler and generic admission controller. A package consumer obtains consumer,
job and lease capabilities and the existing typed joined result. It cannot select
the controller's legacy terminal mode through this facade.

The facade establishes one exclusively owned controller/parent chain per service
instance. It establishes neither a process singleton nor an aggregate process
budget. Choosing and distributing one application-lifetime instance belongs to
the subsequent native-owner design. Context remains caller-supplied generic
authority metadata; this slice does not choose document/folder context contents,
retain a native document, copy input during construction or create an application
dependency on SearchExecution.

Application/native activation, AppDelegate changes, editor search routing,
per-panel adapters, pane/selection/revision/marked-text/undo/close validity,
asynchronous file reservation-before-read, multiple-file replacement durability,
quit veto/restoration, packaging/release changes and memory acceptance are outside
this composition slice. It must be useful and verifiable before those changes.

## Approach decision

| Approach | Concrete benefit | Constraint |
| --- | --- | --- |
| Controller convenience `init(applicationBundle:)` | Smallest change; directly fixes existing defaults | Returns a controller with both legacy and joined terminal APIs; consumer code can select the wrong terminal mode and expose the raw controller to another owner |
| Fixed generic service facade | Makes joined-only terminal authority the normal consumer interface; owns the actual existing chain and forwards existing DTOs | Adds one thin type; still needs a later explicit app owner to distribute and retain a single instance |
| Parent/controller per window or panel | Local construction and simple panel lifetime | Duplicates child, ledger and terminal owners; independent logical limits cannot be called a process budget |

Recommend the fixed generic facade. Its purpose is the terminal-capability and
construction boundary. It must not become another scheduling abstraction or
duplicate admission state. No new generic service protocol, driver protocol,
DTO, policy provider or global registry is needed. Name it SearchAdmissionService
to avoid confusion with the existing synchronous in-process PadCore.SearchService.

## Concrete package interface

The proposed new production file is
`Sources/SearchExecution/SearchAdmissionService.swift`. Existing production
files remain unchanged. The following declarations specify the entire package
surface of the facade; bodies are direct forwarding except the fixed constructor:

```swift
import Foundation
import PadCore

@MainActor package final class SearchAdmissionService<Context> {
  package convenience init(applicationBundle: URL) throws

  package func register() -> SearchConsumerID
  package func submit(
    consumer: SearchConsumerID, descriptor: SearchAdmissionDescriptor,
    capture: @escaping @MainActor () throws -> SearchAdmissionCapture<Context>,
    completion: @escaping @MainActor (SearchAdmissionDelivery) -> Void
  ) throws -> SearchJobID
  package func cancel(_ id: SearchJobID)
  package func unregister(_ consumer: SearchConsumerID)
  package func release(_ id: SearchResultLeaseID)
  package func withResult(
    _ id: SearchResultLeaseID,
    _ body: (Context, String, SearchExecutionOutput) -> Void
  ) -> Bool
  package func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult
}
```

All operations retain existing MainActor isolation. Context needs no new Sendable
constraint: the existing controller owns and borrows it on MainActor. withResult
is the existing synchronous borrow operation and its Bool means the lease was
accepted for that borrow; it is not a terminal success predicate. Do not change
its scope or convert the body into escaping/asynchronous work.

No package `shutdown()`, raw controller/parent/accounting/retry accessor,
accountingSnapshot, driver-level submit/wait/discard/settlement entry, terminal
success Bool, isClosed convenience, executable/path/search argument, environment
override, driver/accounting/retry override, observer or preparation override is
offered. Existing DTOs remain package-visible as they are today; the new facade
does not re-export a legacy terminal operation. Consumers can still independently
construct other package types; the facade's guarantee applies to its own
capability, not a prohibition across the entire module.

## Actual construction and ownership

The only package factory is the throwing initializer with an explicit
applicationBundle URL. There is no implicit Bundle.main default in this slice;
the later owner must pass the application's selected bundle, while tests pass
isolated synthetic bundle roots. The URL selects a bundle root, not a caller
executable. The fixed helper location remains `Contents/Helpers/PadSearchWorker`.

The construction body is exactly this composition, with ordinary local names:

```swift
let parent = try SearchParentWireDriver(applicationBundle: applicationBundle)
let accounting = SearchAdmissionProductionAccounting()
let retry = SearchAdmissionDispatchRetryScheduler()
let controller = try SearchAdmissionController<Context>(
  driver: parent, accounting: accounting, retry: retry)
self.init(controller: controller)
```

The facade has only `private let controller: SearchAdmissionController<Context>`.
This strong ownership transitively retains the actual parent, accounting value
and retry object through the existing controller. Redundant facade fields are
unnecessary. The package constructor creates its parent itself and never shares
that parent's submit/wait/cancel/terminal authority. Every facade method delegates
to this same controller. It creates no Task, receipt cache, mode flag, ledger,
callback wrapper or alternate completion/cleanup owner.

Use one internal designated initializer for source-bound forwarding tests:

```swift
init(controller: SearchAdmissionController<Context>) {
  self.controller = controller
}
```

It is module-internal, not package/public, and accessible to the matching
SearchExecution test target via @testable import. Ordinary sibling/native package
consumers cannot inject a driver through it. Tests construct an actual controller
with existing collaborators and retain fixture cleanup before passing it in;
their deliberate controller alias must not be mistaken for production exclusive
ownership. This seam introduces no observer/state getter, fake factory, release
waiter or production lifecycle hook.

No automatic async deinit shutdown is added. The existing parent/lifecycle have
their own abandonment behavior, which is not a joined receipt or a success
guarantee. An accepted controller joined command retains its genuine owner while
draining, even if a particular facade caller is cancelled or its reference drops.
The application must eventually choose and retain an explicit lifetime owner;
facade deallocation is not a substitute for that design.

## Default policy stays unchanged

Construction uses the existing parent package initializer, which internally uses
SearchChildLauncher, DispatchTime uptime and SearchChildDispatchTimer. It selects
the current SearchParentResponseAccumulator and existing child/lane mechanics.
The facade does not choose a new collector, memory budget or worker policy.

Exact existing constants remain:

- Child operation 10_000_000_000ns; reap grace 2_000_000_000ns; idle 10_000_000_000ns;
  maximumRequestsPerChild8.
- Maximum completed wire bytes per child268_435_456: a stream retirement threshold,
  not an RSS or payload limit.
- Admission activeLimit1_610_612_736, retainedLimit1_342_177_280, resident1_048_576.
  Existing descriptor charge formulas are unchanged. Resident charge lasts for
  the ledger lifetime, including after terminal close.
- Actual admission at most8 jobs and at most one queued/active job per consumer;
  existing lease/cancel semantics remain authoritative.
- Dispatch retry delay25_000_000ns and actual weak token/action fencing unchanged.
- Public deployment macOS14, Swift6 toolchain in Swift5 language mode, no new
  external runtime dependency. No Task.immediate is introduced into this facade.

These are conservative logical content reservations per instance. Context,
callback aliases, native text storage, undo history, allocations, shared memory,
child RSS, launcher quarantine and multiple service instances are outside those
limits. No whole-memory or process-budget predicate is introduced.

## Constructor and request error behavior traced from actual source

SearchParentWireDriver+Production calls
`SearchWorkerBundleResolver.candidate(in:)`, then constructs a lifecycle and
driver. candidate validates local absolute file URL structure, lexically
normalizes dot/dot-dot components and appends the fixed helper location. It does
not stat a bundle/helper, require an .app suffix, inspect a signature or launch.
An absent syntactically valid bundle can therefore construct successfully.

Malformed/nonlocal/non-file/relative-base/query/fragment/decoded-NUL inputs are
rejected by the resolver as `SearchWorkerBundleResolverError.invalidURL`.
The facade propagates that error unchanged. It adds no preflight check,
filesystem error wrapper, fallback or new facade error. The current fixed policy
and ledger constants satisfy their existing constructor validations; any future
throw from those existing constructors is also propagated unchanged.

First accepted submit only enqueues the job and advisory inspection; the existing
controller subsequently calls production accounting, reserves credit, captures
the source, validates it on the existing async preparation lane, creates the
actual parent job and consumes its sole wait. Construction never invokes a
capture/completion, reads a document or launches a child. Register alone also
does not request a launch. The controller's actual acceptance/callback timing is
preserved; the facade must not make submit async or add a scheduling hop.

At an actual first launch, SearchChildLauncher queues perform on its retained
spawn lane. DarwinLaunchOperations.validateExecutable calls resolver
validateForLaunch before pipe creation/spawn. This uses lstat for a regular,
executable final entry and access(X_OK); final symlinks/nonregular/nonexecutable
entries are rejected. It does not certify ancestor trust or a filesystem snapshot.
Absent fixed helper yields filesystem(ENOENT), mapped through LaunchError to
SearchChildFailure.launchFailed(ENOENT). The actual lifecycle/parent return their
failure; the controller reports `SearchAdmissionDelivery.failed(
.child(.launchFailed(ENOENT)))` in a fresh, nonquarantined fixture where launch
validation wins before cancellation/deadline. This is asynchronous delivery,
not a constructor or synchronous submit throw. The harness must control those
conditions and preserve any competing real outcome as a failure to reach the
intended test, never rewrite it.

Earlier process launcher quarantine is checked before validation and can return
its own launchFailed errno. Deadline, cancel and native shutdown can win according
to existing first-outcome rules. Do not advertise ENOENT for every context in
which a helper happens to be missing. Descriptor/submission errors preserve the
existing exact throws; arbitrary capture errors preserve controller captureRefused;
source validation preserves sourceChanged; semantic errors remain .semantic.
No PadCore.SearchService fallback is allowed after any refusal or child failure.

## Typed joined termination is unchanged

The facade's implementation is solely:

```swift
package func shutdownJoined() async -> SearchAdmissionJoinedShutdownResult {
  await controller.shutdownJoined()
}
```

Forward the exact outer callerRefused or observed result. In particular, do not
translate parent callerRefused into the outer enum or interpret observed as clean
termination. Preserve the immutable raw parent result, independently refreshed
driver settlement, active job/lease counts and all three charges. Do not suppress
unsupportedDriver/legacyModeSelected in scripted injection tests because they
are unusual under a healthy fixed production constructor.

Actual capture/accounting/delivery/observation/retry scopes may return outer
synchronousCallbackActive without terminal mutation. After that real outer
return, an outside caller may retry joined entry. Matching callers share the
controller's one actual command and cannot cancel it by cancelling a caller.
Late handle/cancellation/sole-wait ownership, current query coalescing and actual
retirement ordering remain solely the controller's existing contract.

Joined observation inside a live withResult borrow returns real residual lease
and charge rather than awaiting its own destructor. Outside the true outer
return a later observation can show fewer residuals, while earlier values and
the first parent result remain immutable. Refused parent ownership, failed lane
stop, uncertain child cleanup or pending settlement never become fabricated
success. The facade does not add terminal callbacks, retries, deadline shortcuts,
raw result synthesis or a convenient Boolean success predicate.

## Meaningful TDD and review phases

The following bounded phases describe the next plan; no phase has executed in
this draft. Root reviews/adopts the public spec/plan before source authoring and
supplies every compiler/runtime/watchdog/format result. Old tests/harnesses and
existing runners remain bytewise protected.

### Phase1 — capability/forwarding tests, then the thin facade

Proposed new test module:
`Tests/SearchExecutionTests/SearchAdmissionServiceTests.swift`; new production
file only SearchAdmissionService.swift. Use the existing actual controller and
joined test harness via the internal initializer, with finite genuine events,
independent task registration and unconditional cleanup installed before setup.
Do not test that a private field merely equals a constructor argument.

Required behavior cases:

1. Register two consumers on one facade; accept the first held request, reject a
   second same-consumer submit as consumerBusy before capture, and admit the
   other consumer into the real shared controller queue. Cancellation and
   unregister remove those exact consumers/jobs and their payload ownership;
   genuine held worker/cancel/wait gates are released and joined in cleanup.
2. Complete one tiny Unicode request and obtain its actual delivered lease.
   withResult receives the same Context object and exact source/output; release
   invalidates the lease, and repeated borrow returnsfalse without invoking the
   body. No copied result/Context alias is introduced by the facade.
3. Cancel the exact queued/active ID and unregister its actual consumer while
   a different consumer is pending. Assert capture/delivery suppression and the
   sole real cancellation/wait dispositions; no raw driver discard/second wait.
4. A real capture callback calls the facade joined entry through the same source-
   reviewed synchronous MainActor mechanism used by the accepted scope tests.
   Exact synchronousCallbackActive leaves public admission unchanged. This may
   belong in the separate macOS26 hidden native package; do not change public
   macOS14 or introduce Task.immediate into ordinary source merely for a test.
5. Forward an unusual exact parent refusal/failure observation after an actual
   controller join; later query refresh changes only current settlement/residuals.
   Compare the entire DTO and require the raw first parent value is unchanged.
6. Inside an actual result borrow, joined close returns its residual observation;
   after real borrow return, a later call preserves parent but observes retired
   credit. This requires a genuine nested native loop, so reuse accepted native
   mechanism in a new module without editing the old native tests. Do not pretend
   a pure task scheduled after borrow return exercises this branch.
7. With actual held request/cancel/query returns, two facade callers coalesce one
   controller parent join; cancelling one caller does not fabricate return or
   cancel the command. Root reviews independent cleanup before behavioral RED.

The injection seam can also prove exact outer unsupportedDriver/legacyModeSelected
forwarding using actual differently configured controllers. These are explicit
tests of forwarding under deliberate injected misuse, not production constructor
claims or permission to expose legacy capability to consumers.

Before implementation, Root obtains absent-API compiler RED from the reviewed
forwarding tests. Compiler absence is an API prerequisite failure, not a reached
behavioral RED oracle. Implement the exact fixed composition and direct methods,
then Root runs the matching focused tests. Before accepting that source, exercise
reviewed frozen incorrect-forwarding controls against the actual adopted facade
(e.g. an original parent refusal dropped or an observed result rewritten), and
require reached intended assertions with genuine fixture cleanup. Do not use a
prototype or imagined method body as actual production evidence. Then run
neighboring controller/parent/default accounting/retry regressions and obtain
source/evidence review. Broaden to full app/core checks only after the focused
failures are resolved without changing their reviewed oracles.

### Phase2 — ordinary package API compiler contract

Propose a new isolated Root-owned contract harness under
`Tests/SearchAdmissionServiceIntegration/` with direct checked-in watchdog and
pure input/receipt parser controls, plus a relative-root shell entry. Freeze actual
sources, actual public manifest, wrappers/common/watchdog and all declared new
fixtures, maintaining complete mode/hash/origin/membership before and after stages.
The minimal compiler client is a sibling target in the generated same package and
uses `import SearchExecution`, never @testable, for package access.

First compile a positive client that constructs SearchAdmissionService<String>
from an explicit local bundle URL and names register/submit/cancel/unregister/
release/withResult/typed shutdownJoined. This proves the module/package/generic
context is otherwise valid. Separately compile one negative client per forbidden
capability: `service.shutdown()`, `service.controller`, `service.driver`,
`SearchAdmissionService<String>(driver: ...)`, and
`SearchAdmissionService<String>(controller: ...)`. Require precise member/access/
initializer diagnostics at the intended fixture lines, nonzero compiler code and
strict watchdog receipts. An unrelated build/toolchain error is infrastructure,
not a passing negative check. No public app manifest is modified. Negative
clients are never linked into the ordinary passing XCTest target.

### Phase3 — actual fixed construction and missing helper

New actual-source tests in the integration harness must call the package
applicationBundle constructor, not the internal injection initializer.

- Construct/register a facade with a nonexistent synthetic absolute bundle and
  close without submitting. Constructor succeeds, root remains absent, and the
  actual typed join has no request/lease debt and resident1_048_576. Inspect the
  complete actual parent/settlement DTO. This is real default construction and
  clean current ownership; `.noChild` alone is not a history of zero launches.
- Invalid URL fixtures (HTTPS, remote file host, relative reference with base,
  query, fragment and encodedNUL) must synchronously throw the exact resolver
  invalidURL before any consumer/capture/input/child work. No new error enum.
- Construct a fresh synthetic .app directory with no fixed helper, then submit a
  tiny valid descriptor/source through the actual default controller/parent.
  Require actual asynchronous `.failed(.child(.launchFailed(ENOENT)))` and no
  completion lease. Neighbor/build/PATH executable markers must never replace
  the absent fixed helper; use inert synthetic marker bytes and preserve exact
  paths/modes. Start from verified nonquarantined/reapable fresh host state;
  quarantine/permission/deadline failures are retained infrastructure failures.
- Construction and registration must not inspect or execute a helper or read
  application input. Combine complete uninstrumented source review of the fixed
  constructor chain with actual constructor tests above and a Root-reviewed
  finite launch-observation fixture. It observes the existing launcher seam
  through the already-internal actual parent ctor(system:now:schedule:), records
  zero actual launch entries before lifecycle begin, and discriminates an eager-
  launch mutant. This lower-seam injected proof is explicitly complementary to
  the public factory tests, not falsely described as public constructor process
  history. No test state getter or new production seam is needed.

Constructor/API/compiler checks do not prove helper execution. Phase3 uses only
the real missing-path launch failure and no spawned search helper.

### Phase4 — separate actual public-helper proof

Root owns a separate matching run that builds the actual public PadSearchWorker
target from unmodified PadSearchWorkerMain, PadSearchWorkerRuntime, PadCore and
SearchExecution sources. Build the new facade test/harness against the identical
frozen source inventory; preserve actual public Package.swift as provenance and
generated test-manifest bytes/modes explicitly. Do not use pilot A/B/C accumulators,
the echo fixture, a script worker or a test-replaced engine as the search helper.

Copy the exact built worker executable into an isolated synthetic bundle at
Contents/Helpers/PadSearchWorker, recording original/built/copied executable
SHA256, mode, target/toolchain/build receipts and complete source binding. Freeze
and bind the compiled test bundle to the same project sources/build receipts.
Separately bind the actual OS XCTest HOST executable's exact path, bytes, mode
and platform provenance; it may be the platform xctest host rather than the
bundle Mach-O. Do not require a platform host to be built from project source,
equate its proc_pidpath with the bundle payload, or permit an arbitrary executable
override. Missing or unclassified host identity refuses the case. The runtime
service is created
by its uninstrumented package applicationBundle constructor; no executable,
driver, timer, collector or engine override is passed to that constructor.

Use tiny bounded exact cases: literal find `😀` in `A😀B😀` gives UTF16 ranges
(1,2)/(4,2); literal replacement `😀` to `Ω` gives `AΩBΩ`; malformed regex `(`
returns the exact semantic invalidPattern error through real worker framing.
Validate captured/source/output units and exact lease lifecycle, then typed joined
close and all current parent/ledger facts. Each test retains unconditional service
and fixture task cleanup before its first potentially suspending operation.

#### Task4 observer supplement — source contract, pending adoption and prototype gates

For these three ordinary-factory cases, this supplement replaces the earlier
witnessed-child-birth requirement with a narrower sampled live-identity and
nonconsuming-exit requirement. Preserve the previous spec/design as history;
these claims are not equivalent. No observer implementation or runtime is
accepted by this supplement. Tasks1–3 acceptance precedes real-helper execution.

Select one bounded test-only libproc/sysctl identity observer and acknowledged
child kqueue exit registration. Require exact live parent/child PID and
kernel-start identities, child PPID, helper path and declared argv generation,
with matching live identity samples
bracketing accepted registration, followed by one nonconsuming exit observation,
genuine original facade join and current post-join absence. Initial no-child
baseline plus one unique discovery is a fail-closed fixture policy; no repeated
discovery or convenient candidate substitution is allowed. Registration
acknowledgment is distinct from the exit event. No second wait/reaper, observer
signal authority or production observation seam is authorized.

This proves identity at fixed samples, not witnessed spawning, all launch history,
continuous liveness or an independent consuming wait. A preflight empty queue
and last live sample do not eliminate the timing gap before actual async join
entry; kevent has no exact exit timestamp here. Reject observed early exit but do
not claim no exit was possible in that gap or that join caused termination.
Associate the submitted case through exact source/output and the single retained
public owner's actual protocol chain. Opaque consumer/job/lease IDs do not expose
the private wire request UUID; OS argv generation does not recover that UUID.

If separately recorded spawn/consuming-reap evidence is needed, review a distinct
transparent actual-default-launcher operations companion. It forwards each call
and raw result exactly once, preserving the sole consuming wait. Its helper,
generation and receipts remain separate; they cannot fill a missing observation
for the public factory's different process. A final noChild/absence alone cannot
prove unseen birth/exit or consuming-reap history. No raw status is inferred from
signal submission, request success or clean join; neither exit0 nor signal9 is
an assumed accepted observation.

After actual request/lease/borrow retirement, require activeCharge == 1_048_576,
retainedCharge == 0, reservedRetainedCharge == 0, retainedActiveJobs == 0,
retainedLeases == 0 and retainedParentLanes == 0, with genuine
admitted/acknowledged/closed/settled returned
facts. Preserve original immutable raw parent/child.cleanup and refreshed
settlement separately; do not synthesize generation or reap history. Clean kernel
exit cannot replace genuine facade join; clean join cannot replace observer proof.
Production accounting, formulas and policy remain unchanged.

Choose original test-only C source at
`Tests/SearchAdmissionServiceProcessIntegration/ProcessObserverBridge/include/ProcessObserverBridge.h`
and `Tests/SearchAdmissionServiceProcessIntegration/ProcessObserverBridge/ProcessObserverBridge.c`,
with a separate
`ProcessObserver.swift` in that integration directory. First prepare the same
bridge names in private `task-4-observer-api-prototype-drafts/`, with generated
C target ProcessObserverBridge and executable ObserverABIProbe. No production or
public app manifest/platform edit follows. Before observer implementation or real
helper execution, separately review the exact prototype source/manifest/selection
and prove installed declarations, explicit feature macros, import/link/ABI widths,
alignment, count-versus-byte returns, captured errno/absence classifications,
path/argv bounds, registration/exit flags, raw-status conversion and actual XCTest
host/bundle launch selection. Missing APIs, permission or unclassified status is
failure without skips, guessed constants or retry-to-pass. Installed headers and
compile-only proof do not establish actual syscall/status/selection behavior;
controlled process probes need their own reviewed sources and finite cleanup.

Proposed fixed bounds are child capacity65 (saturation fails), argv16_384 bytes,
SDK-bounded path storage with hard ceiling4096, event capacity2 and one owned queue.
Parse only declared argv3/path/--generation/canonical nonzero UUID; do not decode,
retain, hash or log environment tail or raw parser prefixes. Concrete ABI/error
and status mappings remain unaccepted until the reviewed prototype establishes
them. Original bridge code uses platform declarations; no Apple implementation
code or external runtime package is adopted.

One retained serial Dispatch queue owns the blocking event operation and exact
completion acknowledgment; no Task.detached cooperative-pool blocking. Retain all
handles before scheduling. Calculate remaining timeout from the fixed absolute
join-phase deadline when the worker actually starts; missed scheduling, EINTR or
timeout fails without restarting/extension. Proposed bounds remain delivery12s,
identity/registration1s, event2.5s from publishing the join phase, cleanup owner20s
from submit and outer test60s. These do not preempt arbitrary blocked syscalls or
tasks; missing real returns fail. Disable all future producer/timer/
executor registration synchronously before cleanup's first await. Independently
retain and join the one genuine normal-or-rescue facade terminal task and every
actual event worker; no result-dependent rescue or competing terminal owner.
Consume exclusive queue ownership once only after all workers really return,
require the exact close return0 and retain close uncertainty as failure with no
retry. Descriptor numbers may be reused by other threads: no guaranteed nonreuse
or post-close F_GETFD authority, retry or foreign descriptor action. Omit that
sample from release acceptance. Outer watchdog termination is infrastructure
containment, never successful inner worker/queue/helper cleanup.

The concrete observer, fixture, pure discriminators and runner receive separate
source/finite-failure-cleanup review before execution. No checkbox or command is
runtime-accepted by this source-only supplement.

Invoke the checked-in owned-process watchdog directly in the harness process for
each build/test/run stage; never wrap the coordinator in another process-group
watchdog. Strict receipt/source/artifact/origin checks, actual positive unique
test count, zero skips/compiler warnings, complete captures and genuine owned
cleanup are mandatory. No timeout/emergency release counts as a passed behavior.
Missing-helper/fallback controls retain exact failure diagnostics. This phase's
matching evidence is separate from scripted facade forwarding and construction.

This phase proves a tiny actual fixed facade/worker protocol slice on the tested
host. It does not prove allocation/RSS bounds, arbitrary regex containment,
packaged-editor routing, adversarial denial-of-service safety, real-file input
reservation, native mutation authority, quit correctness, GUI or macOS14/Intel
runtime. Those require their own reviewed implementation and acceptance.

## Subsequent native-owner design obligations

After this slice is reviewed and accepted, explicitly design an app-lifetime owner
that retains/distributes one facade instance and selects Context without hidden
heavy native aliases. Add the actual app dependency only as part of that native
change. Define exact per-consumer registration/job/lease cleanup and preserve
native revision/selection/pane/marked-text/undo/close revalidation on delivery.

File search needs a reservation-before-asynchronous-input producer contract:
current sync MainActor capture is not permission to synchronously read a file or
put an already decoded unreserved file into a queued closure. Distributed panels
cannot each create a ledger and then claim aggregate reservation enforcement.

Irreversible joined close cannot precede resolution of recoverable native quit
veto. Root notes suggest placement after managed prepareQuit, but an uncertain
join still needs an explicit native refusal/restoration/retained-service policy.
Do not declare the terminal facade reusable after veto, silently instantiate a
second parent/ledger, reinterpret borrowed residual charges as whole-service
release or bypass document-close/checkpoint authority. This draft deliberately
selects no quit integration behavior and implements none of these native steps.
