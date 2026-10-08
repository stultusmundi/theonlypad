# Production parent response accumulator design

Status: planned architectural component; independent specification/quality design review approves it. Base: verified helper checkpoint `7e63d4d`. No collector implementation or tests have run. Root owns future RED/GREEN and runtime. Fixed parent policy, admission accounting/retry and native routing remain separate tasks.

## Placement and scope

Recommend a focused accumulator in `SearchExecution`, which already owns the sink protocol, request/response validation and codec thread. Moving a shared collector from the accepted worker into SearchExecution would expand worker source/API/regression scope. Depending on PadSearchWorkerRuntime to reuse its collector creates a target cycle: that runtime already depends on SearchExecution. Keep the existing worker unchanged.

Create `Sources/SearchExecution/SearchParentResponseAccumulator.swift` and focused unit/codec tests. No changes to wire format, reader, codec, bridge, driver, worker, launch policy, Package dependencies or native owner are required. The future production factory closure is `{ SearchParentResponseAccumulator(request: $0) }`; this slice supplies the conformer, not default driver composition.

Proposed exact package interface:

```swift
package enum SearchParentResponseAccumulatorError: Error, Equatable {
  case wrongLane, invalidPhase, identityMismatch, invalidMetadata
  case invalidRange, lengthMismatch, invalidChunk, poisoned
}

package final class SearchParentResponseAccumulator:
  SearchParentWireResponseAccumulator, @unchecked Sendable
{
  package init(request: SearchWireRequest)
  package func helloAccepted(generation: UUID) throws
  package func begin(_ response: SearchWireResponse) throws
  package func appendRanges(_ ranges: [NSRange]) throws
  package func appendReplacementUTF8(_ bytes: Data) throws
  package func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws
  package func takeTerminal(for identity: SearchWireIdentity) throws
    -> (terminal: SearchWireTerminal, output: SearchExecutionOutput?)
  package func discard()
}
```

The initializer is nonthrowing: SearchWireRequest and its limits already have validated immutable constructors. Retain only creating `Thread.current`, expected identity, inputUTF16, optional scope, find/replace flag and relevant match/output ceilings. Do not retain the request, pattern/template or source text. Keep advertised response/count metadata, ranges, private replacement Data and counters only while required. No custom callbacks, hooks, public counters, locks, queues or test-only deinitializer are needed.

## Ownership, states and exact errors

Every throwing operation first checks `Thread.current === owner`; mismatch throws `.wrongLane` without reading/mutating other mutable state. This is a checked misuse rejection for sequential calls, not concurrent-use authorization. The codec creates and exclusively uses the accumulator on one retained codec thread. Tests may construct/use on their same test thread; the class need not prohibit the main thread independently. `@unchecked Sendable` permits transport of the handle, not concurrent calls.

`discard()` is nonthrowing and owner-thread-only. It uses `precondition(Thread.current === owner)` before any mutable access, idempotently replaces payload collections with empty storage and clears advertised/counter/terminal metadata. Calling it from another thread is a programmer contract violation, not silently accepted cleanup and not a recoverable wire error. No synthetic wrong-lane-discard test should deliberately crash the ordinary suite; throwing wrong-lane operations are directly tested with deterministic sequential handoff and actual thread return. Production codec's current discard callbacks satisfy the owner requirement. Deallocation has ordinary Swift ownership and no caller-visible thread callback.

States are awaitingBegin, receiving, terminal, taken, discarded and failed. On an owner-thread error other than `.poisoned`, clear payload/advertised/terminal metadata immediately and enter failed. Subsequent throwing owner-thread calls return `.poisoned`; discard in failed clears again but preserves failed, so it cannot revive a poisoned instance. Discard from any other state enters discarded. Taken/discarded calls initially fail `.invalidPhase`, then enter failed. No method resets an instance for another request. Error precedence is owner, failed, permitted state, operation identity/shape/bounds in the order stated below.

| Operation | Allowed phase | Result |
|---|---|---|
| begin | awaitingBegin | receiving |
| appendRanges | receiving before replacement started | receiving |
| appendReplacementUTF8 | receiving for replace, after all advertised ranges | receiving |
| complete success | receiving | terminal on exact completeness |
| complete failure | awaitingBegin or receiving | clear partial payload immediately, retain failure terminal only |
| takeTerminal | terminal | taken, clear all retained payload/terminal metadata before return |
| discard | any, owner only | discarded except failed stays failed; payload cleared |

`helloAccepted` always throws `.invalidPhase` and poisons: the codec consumes hello itself before constructing a request accumulator and never forwards it to this sink. Duplicate begin/complete/take and callbacks before begin or after terminal/take/discard are phase errors. A mismatched expected identity in legal begin/complete/take is `.identityMismatch` (generation, request UUID and ordinal all included); it clears partial or completed data and prevents a later correct-identity take.

## Response metadata and range collection

At begin require expected identity, matchCount <= request.limits.maxMatches and response replacement shape matching the request: find has nil replacementUTF16; replace has nonnil replacementUTF16 <= request.limits.maxOutputUTF16. Inconsistent shape or request ceilings produce `.invalidMetadata`. The typed response constructor already enforces global nonnegative/100,000-match/100,000,000-UTF16 limits. Begin records small metadata but never reserves capacity for its advertised maxima.

Append ranges only before replacement collection. Empty ranges are a no-op in that legal phase. Reject an incoming array count exceeding `advertisedCount - retainedCount` with `.lengthMismatch`; then validate every range before appending any. Arithmetic/scope/order errors are `.invalidRange`: location/length >= 0, location <= inputUTF16, length <= inputUTF16 - location; when scope is present, location >= scope.location, location <= scope end and length <= scope end - location. Scope comes from the validated request. No unchecked end or count additions precede these guards. Adjacent ranges and zero-length matches follow the reader's rule: next.location >= previousEnd, and after a zero-length prior range next.location must be strictly greater. Validate order against the last retained range and each preceding incoming range. A malformed incoming array poisons and clears the earlier payload too.

The accumulator cannot validate source scalar boundaries because it intentionally lacks source text/boundary index. `SearchWireResponseReader.acceptRanges` already validates each source boundary/scope/order before invoking the sink. Preserve that trust boundary; direct collector tests cover arithmetic/scope/order, and real codec tests cover invalid supplementary-scalar boundaries. Do not claim collector-only source boundary authentication.

## Replacement collection and completion

The sink receives scalar-complete UTF-8 from `SearchWireUTF16Decoder`, not raw UTF-16LE. Direct input must still validate strictly, so replacing the sink with caller bytes cannot silently repair malformed data. Each legal append accepts 0...65,536 bytes; too-large chunks or malformed, overlong, surrogate-encoded, out-of-range or truncated UTF-8 throw `.invalidChunk`. Direct splits inside a scalar are refused; the wire decoder's legitimate UTF-16 split-surrogate carry remains supported upstream. Check phase/range completeness before chunk checks. Empty Data is a legal no-op only in that phase; even it establishes replacement-started ordering. Find replacement append is `.invalidPhase`.

Use `transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true, into: ...)`; its true result denotes decoding error. Count units without String materialization or repair. Let `N` be advertised replacementUTF16. After strict chunk validation, require new units <= `N - receivedUTF16` and new bytes <= `3*N - storedBytes`; overrun throws `.lengthMismatch`. N <= 100,000,000 makes 3*N safe on the supported 64-bit platform, but comparisons still use subtraction with maintained nonnegative counters. Do not eager reserve N/3N. Data slices with nonzero startIndex must work: iterator/withUnsafeBytes access must avoid zero-index assumptions.

Successful complete requires exact retained match count and, for replace, exact received UTF-16 count N; find has no replacement storage. Incomplete success throws `.lengthMismatch`. Successful terminal records no output String yet. Failure complete accepts every SearchWireTerminal.failure case in awaitingBegin or receiving, including incomplete counts/partial replacement; discard those payloads at once and retain only that exact failure. No partial output is ever delivered. Complete after terminal is `.invalidPhase` regardless of nominal success/failure.

Take requires expected identity and a recorded terminal. Failure returns `(failure, nil)` once. Success revalidates the entire private Data strictly and exact UTF-16 count before constructing `String(decoding: storage, as: UTF8.self)`; malformed bytes are `.invalidChunk`, count disagreement `.lengthMismatch`. Find returns replacement nil; replace returns String even when N=0 (empty String, not nil). Build SearchExecutionOutput with exact ranges and replacement; then detach/clear accumulator collections and metadata, enter taken and return. The codec's subsequent discard is legal/idempotent and cannot erase the independently returned value. No retained output property or extra source copy is introduced.

Preserve U+FEFF at initial/interior positions, NUL, supplementary/decomposed text and CR/LF/CRLF byte/text sequence. No NSString encoding initializer that treats leading FEFF as removable BOM. UTF-8 storage is bounded content; range arrays are bounded by request match ceilings. Spare capacity, temporary Data/String overlap, source ownership, Foundation/engine allocation and RSS remain unmeasured; no memory peak or universal fit claim follows.

## Direct and real-codec acceptance plan

Follow installed TDD/writing-good-tests with independent literal data. First tests against an absent API establish compiler RED; a temporary ignored minimal conforming shell can establish behavioral RED without passing via missing declarations alone. Root retains both histories, freezes exact sources and runs its accepted direct watchdog. Do not check in the shell or weaken existing assertions. Implement the focused class only after Root confirms intended behavioral failures, then run focused GREEN and unchanged core/wire/codec regressions. Commands and receipts follow Root's existing frozen package/toolchain conventions; this note does not invent a new runner.

Direct controls (roughly 18–24 concise methods, group parallel malformed byte variants):

1. Find with literal ordered ranges, adjacent ranges and zero-length match; nil replacement and exact one-time terminal/output.
2. Zero-match find and replace; replace with N=0 returns exact empty String. Empty legal appends leave counts intact.
3. Literal `[EF BB BF, 41, F0 9F 98 80, 65 CC 81, 00, 0D 0A, 0D, 0A, EF BB BF]` represents `FEFF A 😀 e + combining acute NUL CRLF CR LF FEFF`, exactly 12 UTF-16 units/19 UTF-8 bytes. Assert independent exact units/bytes and the returned text. Initial and interior FEFF need explicit assertions.
4. Append 65,536 ASCII bytes at declared length 65,536 succeeds; 65,537 refuses `.invalidChunk` then `.poisoned`. A tiny append under declared 100,000,000 is valid but early successful complete is `.lengthMismatch`; this is not allocation measurement.
5. Nonzero-startIndex Data slice containing a supplementary scalar succeeds exactly. Split-scalar chunks and literal malformed/overlong/surrogate/out-of-range/truncated sequences fail `.invalidChunk` and poison.
6. Exact declared UTF-16 overrun, incomplete success, extra advertised ranges and duplicate begin/complete/take fail exact errors. More incoming bytes than 3N cannot be admitted; valid UTF-8 UTF-16 counting already implies the 3N content inequality, so do not manufacture impossible independently valid data just to trigger that redundant guard.
7. Negative/overflowing/beyond-input/out-of-scope/overlapping/decreasing/duplicate zero ranges fail `.invalidRange`; validate a second incoming bad range without retaining its first good element. Genuine source-scalar-boundary rejection belongs to codec tests.
8. Response identity mismatch separately mutates generation/requestID/ordinal; complete/take mismatch prevents subsequent correct take. Response find/replace shape and request count/output ceiling mismatches fail `.invalidMetadata`.
9. Semantic failure before begin and after partial ranges/replacement returns that failure with nil output once; no incomplete-count rejection overrides it. Cover all ten semantic statuses through a data-driven literal list.
10. Discard in receiving/terminal/taken is idempotent; late operations refuse. Poison remains poisoned after discard. A returned success survives later discard and accumulator reference release, with no private-state access.
11. Deterministic actual second-thread invocation returns `.wrongLane` for a throwing operation, waits for that thread's scope exit, then proves the correct owner can finish unchanged. Do not invoke foreign-thread discard or create concurrent access recipes.
12. hello callback, append before begin, find replacement, replacement before all ranges, and ranges after replacement started all fail `.invalidPhase`.

Real-codec tests use `SearchParentCodecLane`, actual SearchParentWireCodecSession, upload bridge and real response writer/reader with the production factory, without a native child. Preserve the actual source boundary index built during request upload. Exercise fragmented wire data/split UTF-16 surrogate, exact find/replace outputs surviving codec cleanup, semantic terminal without responseStart and after partial valid body, invalid source supplementary boundary, trailing terminal junk and next ordinal with a fresh factory instance. Assertions inspect returned output/identity and subsequent legal codec transitions, not fabricated codec receipts or new production spy hooks. Existing instrumented factory-before-emission/unwound-take/reentry tests remain unchanged.

After component and real-codec GREEN plus independent review, Root may separately switch genuine real-helper integration to the production factory and run its representative cases. Preserve actual artifact/PID/generation/ordinal/source fidelity, sole consuming reaper, empty signal history before protocol outcome credit and qualified shutdown/session-release evidence (including actual owned SIGKILL records). This demonstrates real parent collection with the product helper; it still does not implement native search routing, a default policy or allocation/RSS acceptance.

## Review checklist and limits

- [x] Different design reviewer validates thread/discard API and state/error precedence against complete current sink/codec contracts.
- [ ] Different test author derives literal expectations, including Unicode fixture counts, and retains original regression assertions.
- [ ] Root obtains compiler and behavioral RED, focused GREEN, unchanged codec/wire/core checks and source review.
- [ ] Root separately verifies real helper with the production factory before default composition/native owner tasks.

This design scopes only the collector. It neither grants runtime authority nor changes accepted packaging/worker sources. Nonthrowing owner-only discard and bounded content rather than measured memory are explicit acceptance limits, not hidden assumptions.
