# Fixed production parent driver composition

Status: implemented, tested and independently evidence-reviewed wiring step;
scoped local commit approved. Based on verified collector commit
`ab5360f` (927 app/core tests and five final-nested helper methods passed).
Root selects the first approach and the explicit operational defaults below.
Independent specification/quality design review approves this contract and its
executable plan; source tests/RED preceded code.
BUILD_PROMPT authorizes routine design choices and replaces repeated human
approval ceremony with documented independent review.

## Smallest coherent slice

Add a package convenience initializer to SearchParentWireDriver that accepts only an application-bundle URL and assembles the existing real launcher, monotonic timers, lifecycle, production accumulator factory and explicit child/wire policy. Keep the injected driver/lifecycle APIs and their regression tests intact. No application dependency change or editor activation occurs here. A future application process owner will supply `Bundle.main.bundleURL`, not a helper executable path.

Three choices:

1. A SearchParentWireDriver convenience initializer plus a small internal policy recipe and collaborator overload. Recommended: returns the existing concrete driver, preserves joined shutdown, has one construction recipe and no additional retained owner.
2. A package SearchParentProduction factory enum returning the same concrete driver. Equally feasible, but adds a public package namespace without improving ownership; worthwhile only if more independent constructors are adopted.
3. A new production service holding driver, lifecycle, admission controller/accounting and native consumers. Too broad now: accounting/retry and UI lease contracts need their own reviewed task. Do not hide absent production accounting behind test values or implicit unlimited budgets.

## Exact proposed APIs and files

Create `Sources/SearchExecution/SearchParentWireDriver+Production.swift`, importing Foundation and Dispatch. It contains:

```swift
extension SearchParentWireDriver {
  package convenience init(applicationBundle: URL) throws

  // Same recipe with the existing real collaborator contracts; internal only.
  convenience init(
    applicationBundle: URL,
    system: any SearchChildSystem,
    now: @escaping @Sendable () -> UInt64,
    schedule: @escaping @Sendable (
      UInt64, @escaping @Sendable () -> Void
    ) -> any SearchChildTimer,
    observe: (@Sendable (SearchParentDriverEvent) -> Void)? = nil
  ) throws
}

enum SearchParentProductionPolicy {
  static func childPolicy() throws -> SearchChildPolicy
  static let maximumWireBytesPerChild: UInt64
}
```

The internal overload is ordinary constructor composition over already existing system/clock/scheduler/observer APIs, not a new spy/counter/hook or an executable override. It always resolves the supplied bundle, uses the same explicit policy and the production SearchParentResponseAccumulator. It creates SearchChildLifecycle with those collaborators, then delegates to the unchanged injected driver initializer. Both constructors share this overload; no second copy of the recipe in tests. Keep the current injected initializer available for reduced policies and deliberate factory failures in existing tests.

The package initializer supplies `SearchChildLauncher()` with empty arguments, `DispatchTime.now().uptimeNanoseconds`, and a retained serial DispatchQueue labelled `TheOnlyPad.search-parent.timers`. Its scheduler closure creates `SearchChildDispatchTimer(deadline:queue:action:)` on that queue. Capture the queue directly in the stored closure, not the driver or a new reference cycle. The lifecycle retains its system/scheduler; driver state retains the lifecycle; existing timer and actor/lane cleanup continue to own their scopes. There is no need to expose lifecycle/PID/observer diagnostics in the package API or widen SearchChildSystem visibility.

Do not add `Bundle.main` as a default argument: Foundation command-line/unit hosts have different main bundles, while the actual app owner can explicitly bind its genuine bundle when activated. The production initializer accepts bundle URL only: never env/PATH/shell/filechooser/executable parameters or worker fixture flags. Existing resolver normalization/URL refusal is preserved. Missing helper entries remain startup failures at launch; construction does not preflight the filesystem or hash an executable on the main thread.

Production edits are confined to the new composition file. New unit tests may live in `Tests/SearchExecutionTests/SearchParentProductionTests.swift`; package-access coverage uses a normal non-@testable import in its own small test file. Existing joined-completion and parent-shutdown fields are package-accessible, and child-shutdown fields are public: this file can inspect actual logical shutdown/ownership/lane facts without widening any API. These fields expose no PID/signal/consuming-reap instrumentation. Existing helper integration test/runner changes are a separate Root-owned verification task, with original assertions retained. No wire/collector/worker/launcher/lifecycle/admission/native source changes are proposed.

## Selected operational defaults

| Setting | Exact value | Meaning |
|---|---:|---|
| operationNanoseconds | 10,000,000,000 | Hard operation deadline from admitted begin, including launch/handshake/upload/engine/response |
| reapGraceNanoseconds | 2,000,000,000 | Grace before truthful stop-unconfirmed handling; not permission for a second waiter |
| idleNanoseconds | 10,000,000,000 | Healthy child idle lifetime |
| maximumRequestsPerChild | 8 | Recycle when completed count reaches eight before admitting next request |
| maximumWireBytesPerChild | 268,435,456 | 256 MiB cumulative completed stream I/O bytes, including handshake; healthy retirement after current request |

Root selects these fixed operational defaults for this composition slice; they are not measured performance/RSS bounds. The first four already appear in current benign actual-helper tests; that does not establish suitability for every 100M-unit document. `childPolicy()` calls the existing throwing SearchChildPolicy constructor with explicit literals, without try! or caller-controlled fallback. The static wire constant feeds the existing driver guard/counter. Direct policy tests compare literal values from this actual production recipe; deterministic lifecycle/driver tests use its returned policy rather than a separately copied policy.

The wire threshold is not a response payload limit and can be exceeded by one admitted operation. The existing saturating counter requests retirement after completion; do not kill a valid active operation at 256 MiB or advertise an allocation/RSS cap. Per-job SearchWireLimits stay mandatory and explicit in SearchParentWireJob. This slice does not silently select editor maxText/maxOutput/maxMatches/cooperative duration or replace admission budgets with policy numbers.

## Creation versus admission and start

Resolver `candidate(in:)` validates and normalizes only the local absolute bundle URL; it performs no filesystem work. Invalid URL construction throws the existing SearchWorkerBundleResolverError before delegation to driver initialization. Creating a valid driver does start its existing retained SearchParentCodecLane thread immediately, even before the first request. Queue/system/lifecycle creation must not launch, open helper descriptors, signal, poll or schedule an operation timer. A nonexistent bundle is therefore constructible; its first admitted request can fail with launchFailed(errno) at the real preparation lane.

`SearchChildLifecycle.begin` establishes identity, publishes operation and arms the absolute operation deadline before submitting launch. The unchanged launcher performs fixed final regular/executable checks and descriptor/spawn work on its retained shared spawn lane, using the process-wide spawn gate and sole lifecycle wait authority. The resolver's final-entry check does not authenticate immutable ancestors/signatures; package validation remains separate. Never pull validateForLaunch/read/hash into the construction or control lane just to make constructor tests pass.

One driver has one parent lane and at most one active operation/child session; constructing several drivers does not enforce a process-wide active search limit. The later process-owned admission service must coordinate consumers. Explicit shutdown is still required: deinit's detached abandonment does not provide a synchronous scope-exit receipt. Legacy shutdown may truthfully return pending parent/session scopes; joined shutdown is a distinct terminal mode, rejects incompatible ownership, joins logical scopes/lane stop, and preserves its original child cleanup receipt rather than upgrading an uncertain child. Neither certifies launcher pre-adoption quarantine release, Swift Task deallocation or physical allocator release.

## Finite TDD and verification tasks

1. Independent design review approves the narrow accessible API and exact defaults. Separate test author writes tests before implementation; Root records missing-API compiler RED separately. An ignored minimal constructor that uses wrong policy or eagerly refuses nonexistent bundle can establish intended behavioral RED with existing injection contracts. Root freezes this generated extension separately from actual sources; no class initializer, source/collector or original assertion may be altered in production to manufacture the baseline. Do not execute syscall collaborators in this drafting task or copy a temporary stub into production.

2. Direct composition controls through the internal overload: validate all five literal policy values; malformed/nonlocal/query/fragment/NUL bundle URLs fail before driver lane creation/launch/schedule; a nonexistent synthetic bundle constructs without launch/timer/filesystem preflight and joined shutdown before submission yields an actual absent-child/lane-stop receipt; on submit, an existing injected system records the exact normalized fixed candidate and generation after the first operation timer is armed. Drive a synthetic ordinary response through the real codec to prove the production collector supplies exact output. Assert concrete request UUID/generation/ordinal/source/output and genuine phase errors; no test-only production getters.

3. Drive policy behavior with existing fake system/clock/timer fixtures and the actual production policy: exact first operation deadline; timeout before success; grace/maintenance boundary handling; ten-second idle expiry; eight completed requests then ninth-generation restart; threshold accounting from completed byte events and retirement after completion. Do not allocate 256 MiB solely to hit a default: test the actual policy constant and reuse existing reduced-threshold byte-counter/driver controls for mechanics, explicitly separating those proofs. Existing failed-launch/quarantine and no-retry/reap ownership assertions remain unchanged.

4. Add ordinary-package-access checks that instantiate `SearchParentWireDriver(applicationBundle:)` with no @testable import, then terminate using the genuine joined shutdown command. No normal unit test posts input or starts a helper merely to check access. A broken package visibility/default binding must be a compiler or behavioral failure; never freeze a private test extension that makes an otherwise inaccessible API appear available.

5. Root runs focused composition plus existing resolver/launcher/lifecycle/driver/codec/admission regressions against exact frozen sources with direct owned watchdog, then different independent source review. No new helper arguments, reaper, replacement runner or nested watchdog.

6. Root separately exercises the exact ordinary package initializer with the verified nested packaged helper: construct using recorded applicationBundle, submit tiny literal find/replace/semantic failure requests with explicit SearchWireLimits, assert actual output identity/source/literal ranges and semantic result, then genuine joined terminal shutdown/lane/child cleanup. The existing artifact verifier authenticates the bundle-derived fixed path and final executable/source hashes before test credit. The new unobserved constructor path exposes no PID diagnostics; its result/cleanup receipts must not be described as observed exact-PID instrumentation.

7. Preserve the current five helper methods and every exactPID/sole-consuming-reap/signal/session-release assertion through the shared internal composition overload, supplying only existing ObservedHelperSystem (which forwards to real SearchChildLauncher), monotonic clock/timer scheduler and existing event observer. For packaged mode pass the authenticated applicationBundle; never derive a fake bundle from arbitrary executable path. Built-only fixture mode can continue its existing injected lifecycle recipe or create a separately authenticated fixed bundle layout; do not silently reinterpret its Build/FrozenHelper executable as a packaged application. Explicitly label observed/shared-recipe path versus unobserved ordinary initializer path in captures. Empty signals/reaps are required before protocol outcome credit; joined shutdown records actual owned SIGKILL if used, matching PID, one consuming reap and genuine session release. No nominal event is constructed and no assertion is removed to accommodate the constructor.

The two actual paths establish distinct facts: ordinary constructor runs its concrete defaults; observed shared recipe retains exact child diagnostics. Their source correspondence is reviewed; one path's PID observations are not retroactively assigned to the other. If Root requires every ordinary-constructor run itself to carry exactPID observations, that is an explicit additional observation-boundary design, not permission to weaken current receipts or claim unobserved counters.

## Deferred accounting/native activation

SearchAdmissionController's accessible convenience initializer still requires a driver plus SearchAdmissionAccounting and SearchAdmissionRetryScheduler. It can consume this concrete driver as SearchParentWireDriving, but no production accounting formula/limits/resident budget or retry token is supplied here. The ledger measures logical reservations/leases, not measured RSS. Later work must choose reviewed charges, delayed capture, result lease retention/release and settlement before native activation. TheOnlyPad still depends only on PadCore; document/folder search defaults remain in-process. Adding this constructor cannot by itself change those routes or certify hard regex containment, allocation, large-file fit or desktop responsiveness.


## Actual fixture integration decisions

Task1 is the composition source and deterministic/package-access tests. Task2
adds actual constructor evidence without reassigning observed child diagnostics.
For packaged mode, preserve all five existing methods and every assertion while
changing the harness's driver construction to the shared internal recipe. Built
mode retains its existing injected lifecycle because its authenticated executable
is not an application bundle. Both remain explicit evidence scopes.

Add one actual `production-defaults` case selecting the ordinary package
initializer. It requires an explicit authenticated application bundle. The
runner rejects selecting this case without that bundle, before any build or
child launch. The default built selection stays the existing five cases; default
packaged selection includes all six. This is conditional case selection, with
no skips or passing substitute for an unavailable packaged artifact.

The new ordinary case runs independent literal Unicode find/replace, semantic
failure followed by healthy same-generation/next-ordinal reuse, then calls real
joined shutdown. It authenticates exact source/identity and the unchanged
artifact verifier before/after. Its accessible genuine shutdown facts include
child stopped/channels closed/noChild and parent settled/zero retained lanes.
It emits a distinct ordinary-constructor summary qualified as logical cleanup;
it exposes no PID, signal count or consuming-reap diagnostic and must not inherit
those counts from the five observed shared-recipe cases.

Extend the existing coordinator's case/output validator with explicit evidence
scope discrimination, preserving all original five method/PID/generation/signal
and receipt checks. Add meaningful pure runner RED/GREEN controls for the new
selection/refusal and unobserved receipt shape, including rejection of fake PID
credit or misclassified observed output. Never remove existing assertions, add
helper arguments/reapers, execute privacy changes or nest another watchdog.

Root alone runs serial compiler/real-helper/package checks, using current frozen
sources and actual final nested artifacts; reviewers and source owners do not.
Independent source/evidence review, a complete fresh public app/core build/test,
strict format/public/diff and local packaging finish the checkpoint. Document
planned/implemented/tested/blocked independently; continue production admission
accounting/retry and native routing afterward, with GUI access still user-owned.

## Authority and provenance

The original source-only draft is retained privately as17209 bytes,
SHA25663bf59ad6e5c7fdab5d5e2462df0db0c7913e3181e67871471f235d95c525994.
Root read it completely and verified all13 declared current source pins. Its
recorded pre-commit staged snapshot remains historical; collector commitab5360f
is now the actual base. Source callbacks and lifecycle contracts already exist;
no runtime result is inferred from this design.


## Implementation checkpoint

The fixed recipe and scoped helper-test wiring are implemented and independently
source-approved. Root records focused12/0, neighbors331/0, pure32/0, full939/0 and
six final nested-helper methods with separate observed/ordinary evidence.
Package/archive/SBOM and both signatures verify. See
[verification](../../verification/search-parent-production-composition.md).
Final independent evidence review approves the scoped local commit; admission accounting/retry and
native activation remain separate outstanding work.
