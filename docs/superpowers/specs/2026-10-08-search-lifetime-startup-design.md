# Checked search parent-lifetime startup design

Status: independently reviewed; implementation and runtime evidence pending. Base: accumulator checkpoint1ca5f1f.

## Authority and boundaries

Architectural slice under BUILD's autonomous design/testing/local-commit authorization. Add one checked, dedicated watcher startup and activate it only in the existing busy-main fixture. Worker Program reports startup failure before request work; no helper product, editor routing, memory/performance or desktop acceptance yet. macOS14, Swift6 toolchain/Swift5 mode, original MIT code, Darwin only; no external package/assets or security-setting changes. Root owns serial real-process/GUI execution.

## Alternatives and choice

Select pthread attributes configured detached before one pthread_create. It returns explicit failure codes and establishes a separately schedulable dedicated thread without an unbounded readiness wait. Create-then-detach adds a post-create failure with an unsafe join/cancel/borrowed-FD cleanup obligation. Foundation Thread lacks the checked creation-result API needed here. No dispatch pool, Swift Task, semaphore, startup polling, stack/scheduling tuning or retry.

## API

Create `Sources/SearchExecution/SearchParentLifetimeStarter.swift` with:

```swift
package struct SearchParentLifetimeStartError: Error, Equatable {
  package enum Stage: Equatable {
    case invalidDescriptor, attributeInitialization, detachedState, creation, attributeDestruction
  }
  package let stage: Stage
  package let code: Int32
  package let attributeCleanupCode: Int32?
  package let threadCreated: Bool
}
extension SearchParentLifetime {
  package static func start(controlFD: Int32) throws
}
```

Internal-only operations allow deterministic syscall-boundary tests:

```swift
typealias SearchParentLifetimeThreadEntry = @convention(c)
  (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
final class SearchParentLifetimeThreadContext {
  let controlFD: Int32
  let run: (Int32) -> Void
  init(controlFD: Int32, run: @escaping (Int32) -> Void)
}
struct SearchParentLifetimeThreadOperations {
  let initializeAttributes: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  let setDetached: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  let create: (UnsafeMutablePointer<pthread_t?>, UnsafePointer<pthread_attr_t>,
    SearchParentLifetimeThreadEntry, UnsafeMutableRawPointer) -> Int32
  let destroyAttributes: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  static let darwin: SearchParentLifetimeThreadOperations
}
```

An internal overload `SearchParentLifetime.start(controlFD: Int32, operations: SearchParentLifetimeThreadOperations, run: @escaping (Int32) -> Void) throws` is the production implementation boundary. The package entry uses fixed Darwin operations and existing `SearchParentLifetime.run`; no caller-selected watcher body enters production composition. Concrete Swift-imported pointer spellings must compile at the current deployment floor; a compiler correction may adjust spelling while retaining these ownership contracts.

## Startup and ownership

The borrowed descriptor is the launcher's verified blocking lifetime-pipe read end, distinct from request/response descriptors. Reject negativeFD with invalidDescriptor/EINVAL before any operation. Do not duplicate/close it, change process signals, add a reaper, or accept arbitrary descriptor ownership.

Initialize attributes. Failure: report its returned pthread code, no destruction/context/create. Set PTHREAD_CREATE_DETACHED. Failure: destroy initialized attributes once, report detachedState as primary and nonzero cleanup code separately; no context/create. After valid attrs, retain one immutable context containing fd/body before create. Call create once. Returned errors are pthread result codes, not errno; do not retry.

Failed create guarantees no callback: release retained context once, destroy attrs once and report creation as primary, cleanup code separately, threadCreated=false. Successful create transfers context irrevocably to the C trampoline even if the callback finishes before create returns. Destroy attrs once and never reclaim transferred context or detach/join/cancel the returned thread. If destruction fails after successful create, throw attributeDestruction with that code/threadCreated=true/no secondary code. The helper caller treats any startup error as fatal and exits promptly; it cannot retry or proceed as a longer-lived host.

The C trampoline consumes the retained context once. An internal helper extracts fd/body and explicitly ends the box's strong ownership before calling body; production body is Never/_exit and will not run defers. The returning injected body is only an internal test boundary. It preserves actual context/trampoline ownership, including synchronous-before-create-return and deferred-after-return schedules. Null context is a trusted-contract violation that fails closed with _exit70. No mutable stack address is passed to the thread.

Success proves a thread was created, not that its first read already ran. Lifetime EOF remains readable when scheduled. Startup must return without a readiness semaphore. Existing actual busy-main acceptance proves independent process termination while main is occupied.

## Program admission

Change `SearchWorkerProgram.run`'s starter parameter to `(Int32) throws -> Void`. After channel creation, catch any startup error and return70 before constructing/running reader, writes, accumulator factory or engine. Preserve bootstrap64, invalid/aliased descriptor and channel failure74, existing sequential order and runtime exit mapping. Nonthrowing existing injected closures remain compatible. Startup errors typed as SearchError are still fatal setup errors, never semantic search terminals. Future fixed entry must promptly exit the returned code; this slice does not add an entrypoint.

## Tests and actual fixture

Deterministic tests exercise actual context/trampoline with injected operations: negative descriptor, each initialization/detach/create/destroy error, primary+cleanup precedence, destroy once/no destroy on failed init, no retries, actual weak context alive during transfer and absent before body, one body invocation/exactFD, callback-before-create-return and callback-after-return, creation failure reclaim, and destruction failure after transfer in both callback schedules. Test collaborators never model creation failure plus a callback, which violates pthread semantics. No test-only deinit hooks or production test methods.

Add Program tests with pending valid wire input and throwing starter: exact70, one channel/start, exact controlFD, zero reads/writes/factory work. Keep all prior Program tests unchanged. A behavior control using an ignored throwing error type without changing the production signature may demonstrate original missing fail-closed handling if possible; compiler RED and semantic RED are recorded separately.

Replace only the busy-main fixture Thread/semaphore block with checked package start/catch -> existing refusal. The fixture retains its existing mode, readiness metadata and busy loop; no protocol selector is added to production. New SearchExecution source is discovered automatically by the current frozen harness. Add exact new deterministic test path to its FIXED input set and the synthetic inventory controls; generated targets stay unchanged.

Root selects the existing real lifetime occupied-main test under the harness-owned direct watchdog. Require exact source/fixture/test-bundle bindings, real generation-qualified consuming reap exited0, channel closure and failure cleanup. Preserve the existing shared-spawn peer regression and original timer/lifetime/launcher controls. This demonstrates the concrete startup/lifetime slice, not helper wire execution, regex deadlines or editor cancellation.

## Acceptance and remaining work

Fresh deterministic/Program/neighboring suites, pure harness checks, actual busy-main child, source review and full app/core build/test must pass before local checkpoint. Use direct watchdog ownership; never nest a coordinator or infer cleanup from global PID absence. Raw synthetic logs remain ignored. Desktop auth is independently pending. Next: fixed helper product, entrypoint and nested packaging/real parent execution; then production parent binding/editor routing and adversarial/memory/desktop acceptance.
