# Native catalog loading owner

Reviewed design, 2026-10-15. The standalone owner is planned; no production source or test acceptance is claimed. Root and independent design review accepted this contract. Fourteen tests are authored privately and have static review; execution remains unverified. An observed failing baseline must precede production implementation. Basis: local checkpoint `65ef485`; source changes require matching verification. This is a prerequisite within D-04, not feature completion.

## Purpose and boundaries

Create standalone `@MainActor NativeLanguageCatalogOwner` in the native application target. It performs an explicitly requested startup/reload read through actual `CustomLanguageStore.load()` off main, privately retains its genuine `LoadedLanguageCatalog`, and publishes immutable state for a later read-only manager. Construction performs no I/O. There is no accepted existing native owner to extend.

The owned slice has no manager command/window, mutable drafts, save/repair/import/export/reset API, pending-publication state, quit policy, document/picker/highlighter integration or AppDelegate activation. Those remain separate integrated work. No unavailable-service branches, placeholder controls or stub implementations are proposed. The complete working deliverable is this standalone read-only owner. Custom-language plan steps 6–9 and D-04 remain outstanding.

## Current facts and preservation

`CustomLanguageStore` is Sendable; its synchronous bounded `load()` explicitly requires off-UI dispatch. It supplies the only genuine `LoadedLanguageCatalog` constructor, with fileprivate exact-read destination/bytes/directory/leaf identity. Missing storage returns a genuine empty generation-0 receipt without creating the directory. Real reads retain ownership/mode/single-link/bounded-read/stable-identity/strict-schema policies. `LanguageCatalogSnapshot` is immutable/Sendable. Caller-constructed snapshots are not read receipts. Snapshot does not conform to Equatable; compare exact relevant fields or canonical encoded bytes in tests.

The private first-table `NativeLanguageProfileOwner` identifies itself as incomplete. Its conventions are references only. Its CRUD/recovery/quit APIs, confirmation-clearing-on-read-failure and unretained detached-task pattern must not be copied. `ApplicationShortcuts` supplies a terminal-callback warning, not this lifecycle contract.

All Core files, receipt access restrictions, durable publication, resolver/schema/limits/built-in behavior and old tests remain byte-exact. No dependencies or assets are adopted; new code is original MIT. Synthetic fixtures and raw diagnostics remain private.

## Alternatives

| Approach | Strength | Cost and disposition |
| --- | --- | --- |
| Standalone MainActor read-only owner with retained detached read | Small native boundary; immutable state; explicit callback/worker ownership; no Core changes | Chosen. Define real joining and synchronous callback reentry precisely. |
| Dedicated actor plus AsyncStream subscription | Serial work and several subscribers | Adds buffering/subscription lifetime and actor hops before there is a consumer; actor isolation alone does not prove blocking I/O runs off main. |
| Reuse incomplete private CRUD owner, or load inside manager | Reuses experiments or removes a type | Imports unaccepted authority/lifecycle branches, or makes catalog truth depend on window lifetime. Reject. |

## State and identities

The API section below fixes declarations. State carries active/invalidated lifetime, active request UUID, last-settled request UUID, optional current publication (publication UUID + source request UUID + immutable catalog), and optional request-specific failed-read record. All state/observation stays MainActor-confined. UUIDs fence process-local transitions; persisted generation and definition revisions remain untouched. Publication UUID is absent before first success and rotates on every successful real read, including identical bytes/generation.

The actual `LoadedLanguageCatalog` remains private. Observable values/UUIDs never grant save authority. No method accepts caller-built catalogs or exposes receipts. Failed initial read leaves current/publication nil. Failed reload preserves the exact last confirmed receipt/snapshot/publication and adds a fresh failure. The retained receipt proves the last successful read, not present disk currentness. Future writes would require Core's ordinary receipt/CAS revalidation. A retry preserves the old failure while loading; only success clears it.

## Admission and worker sequence

`requestLoad()` is synchronous MainActor admission so observer reentry is real and testable. There is one producer, no queued reload/coalescing. Busy requests return `.busy(activeRequestID:)`, perform no I/O, change no state and notify nobody. Invalidated requests return `.invalidated`. Caller task cancellation does not withdraw an admitted read.

1. Reserve request UUID, set active request and preserve previous current/failure. Deliver one immutable loading state. Reservation precedes the callback, so synchronous reentry is busy.
2. After observer return, recheck active lifetime and exact reservation. If observer invalidated, return `.invalidated` and launch nothing. `.started(requestID:)` is returned only after real producer and settlement handles are installed.
3. Capture the Sendable synchronous read closure. Launch one utility detached producer, whose production closure calls exactly `store.load()` and captures no owner/UI/observer.
4. Create one MainActor settlement task, capturing the producer and the owner weakly. It awaits that exact producer's `result`, then obtains the owner only for synchronous settlement. Do not bind a strong owner before the await. Store request UUID, producer handle and settlement handle together before requestLoad returns; no await/callback intervenes in this installation. The MainActor settlement task cannot run before this synchronous installation completes.
5. After the await, settlement first matches its exact record and retires only that record. If invalidated, drop result without notification/publication. On active success, atomically install genuine receipt/fresh publication, clear failure/active request, set last-settled request. On failure, preserve previous receipt/current exactly, replace failure/last-settled request and clear active request.
6. Deliver one terminal state only after worker retirement and complete commit. Terminal observer can synchronously start a successor. No old-frame mutation, cancellation, deferred cleanup, notification or successor launch follows that callback. Thus old completion cannot clear the successor. After delivery, the old settlement task simply returns.

One producer plus one awaiting settlement task is the bound; the settlement task performs no I/O itself. An old terminal observer may launch a successor because the old producer is already complete and its record retired. This briefly overlaps task bookkeeping, not I/O producers.

Observer delivery is synchronous, once per loading/terminal transition. No notification queue is introduced. Installing/replacing observer emits no replay; consumers read `state` initially. Capture one local observer/state for delivery. Loading callback replacement does not retroactively change its in-progress delivery. Each consumer compares captured identities with live state before later actions; a delivered state is a historical immutable value, not timeless currentness.

## Invalidation and actual join

`invalidate()` is synchronous, terminal and idempotent. It revokes admission, clears observer/private confirmed receipt and observable current/failure/active/settled facts, and exposes canonical invalidated state before returning. Observer installation afterward is ignored without retention. It emits no callback. An already-entered callback cannot be undone; its old frame is fenced after return.

Already-running producer and settlement handles remain privately retained. Do not call Task.cancel and call that cleanup: synchronous descriptor reads have no cooperative/hard cancellation contract. `invalidateAndWait()` captures the exact settlement handle synchronously, invokes invalidate without an intervening await, then awaits that settlement's value. Settlement first awaits the actual producer and retires its matching record. The join returns only when both real read and settlement are complete. Multiple callers join the same task; no successor exists after revocation. If no worker has launched, join returns immediately. Cancellation of the joining caller does not skip awaiting task.value. No semaphore/wait/synchronous join is performed on MainActor.

The weak settlement capture avoids owner→task→owner lifetime cycles across a stalled read. While alive, owner retains both handles. An explicit invalidateAndWait async frame retains the owner through its join. If a caller drops the owner without joining, the settlement task still retains/awaits its producer, then releases the result without callbacks because weak owner is absent. Deallocation is not a join or I/O cancellation guarantee. Plain invalidate returns before an ongoing read completes. Bounded bytes do not bound filesystem wall time; a stalled syscall can delay the explicit join indefinitely. No hard cancellation, timeout or application shutdown deadline is claimed.

## Acceptance and limits

Require reviewed source, legal Swift 5-mode native compilation, reached behavioral red, deterministic green controls, actual synthetic file reading with off-main proof, busy/invalidation/reentry/late-result assertions, and unchanged Core/neighbor tests on matching frozen bytes. See the [implementation plan](../plans/2026-10-15-native-language-catalog-loading.md).

No windows or posted events are needed. Hidden tests can establish this owner contract, not startup activation, manager UI, restored-model resolution, visible warnings, menu routing, CRUD/recovery/quit, desktop/accessibility, packaging or performance. Store bounds are inherited, not new allocation/latency measurements.

## Read-only API

Reviewed declarations; production implementation and compilation remain unverified. All types have internal access in `Sources/TheOnlyPad/NativeLanguageCatalogOwner.swift`; no PadCore or Package.swift API changes.

- `enum NativeLanguageCatalogLifetime { case active, invalidated }`
- `struct NativeLanguageCatalogPublication`: immutable `id: UUID`, `requestID: UUID`, `catalog: LanguageCatalogSnapshot`.
- `struct NativeLanguageCatalogFailure`: immutable `requestID: UUID`, `underlyingError: any Error`.
- `struct NativeLanguageCatalogState`: immutable `lifetime: NativeLanguageCatalogLifetime`, `activeRequestID: UUID?`, `lastSettledRequestID: UUID?`, `current: NativeLanguageCatalogPublication?`, `failure: NativeLanguageCatalogFailure?`.
- `enum NativeLanguageCatalogAdmission { case started(requestID: UUID), busy(activeRequestID: UUID), invalidated }`.
- `@MainActor final class NativeLanguageCatalogOwner`:
  - `init(store: CustomLanguageStore)` captures `{ try store.load() }`; no immediate read.
  - `init(read: @escaping @Sendable () throws -> LoadedLanguageCatalog)` is an internal dependency seam for deterministic tests, with exactly the same worker/settlement path as production. No injected scheduler, fake catalog factory, control flag or receipt constructor.
  - `var state: NativeLanguageCatalogState { get }`.
  - `var onChange: (@MainActor (NativeLanguageCatalogState) -> Void)? { get set }`. Replacing does not replay. After invalidation setter discards the supplied observer without retaining it and getter remains nil.
  - `func requestLoad() -> NativeLanguageCatalogAdmission`.
  - `func invalidate()`.
  - `func invalidateAndWait() async`.

State is MainActor-confined, not declared Sendable merely to move arbitrary error existentials. Snapshot alone remains Sendable. The owner does not stringify/log underlying errors; later presentation must choose safe copy. There are no user document buffers in state.

Initial active state: active/settled IDs, current and failure are nil. Canonical invalidated state: lifetime invalidated, all other fields nil. An admitted request sets active ID only; previous settled/current/failure remain. A successful terminal state has active nil, lastSettled equal source request, current with fresh publication UUID, failure nil. A failed terminal state has active nil, fresh lastSettled/failure request identity and unchanged optional current. Busy/invalidated refusal changes nothing and delivers nothing.

Private implementation facts: one `confirmed: LoadedLanguageCatalog?`; one read closure; one optional worker record containing request UUID, actual detached `Task<LoadedLanguageCatalog, Error>` and awaiting MainActor `Task<Void, Never>`; one lifetime flag and immutable state facts; one observer. Receipt never appears in state/admission/getters. No method accepting expectedPublicationID, draft or save authority is introduced. State can be derived from those facts; it need not be a second independently writable authority.

`requestLoad()` only returns started after worker installation. Invalidation inside loading callback returns invalidated, with zero read invocations. Busy reentry returns the original active request UUID. Invalidation during worker execution suppresses all later publication and notification; requestLoad's earlier started remains historical admission. Terminal observer can synchronously call requestLoad and receive a successor's started; old settlement performs no work after observer return.

`invalidateAndWait()` revokes synchronously before its first suspension and joins captured real settlement. It is not a UI close veto, quit vote, cancellation deadline, disk durability acknowledgment or save receipt. The two initializers create the same fully implemented owner; the closure initializer does not permit forging LoadedLanguageCatalog because its constructor remains inaccessible outside Core.

Design review does not establish real application activation, a working manager, or measured cancellation/performance. The [parent language design](2026-10-12-custom-languages.md) retains the full product scope.
