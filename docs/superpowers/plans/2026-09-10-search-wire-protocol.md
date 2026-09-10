# Search wire protocol implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans, with TDD and independent review. Commands for outstanding tasks are proposed; completed-task verification is recorded in `docs/verification/search-wire.md`.

**Goal:** Implement a bounded, incremental, view-free wire codec for one sequential search connection, without launching processes or changing search semantics.

**Architecture:** A small SearchExecution module depends on PadCore. A fixed header and small frames carry full-text UTF-16LE streams. Connection readers enforce exact request identity and phases and push validated chunks to caller-owned sinks; they never accumulate an array of all frames or a full encoded document.

**Tech stack:** Foundation, Swift 5 language mode, macOS 14, existing SwiftPM. No dependency or generated build plugin.

**Spec:** `docs/superpowers/specs/2026-09-10-supervised-search.md`; prerequisite `docs/superpowers/plans/2026-09-10-search-single-enumeration.md`; the reviewed protocol constraints below.

**Status:** Task1 framing implemented and independently approved at aa3aa82 (19 focused tests pass). Task2 UTF-16 is independently approved at10c4dd4 (20 focused tests,19 framing regressions pass); Tasks3A/3B/4 remain planned; see `docs/verification/search-wire.md`. Semantic prerequisite28e2a9f is independently approved.

## Global Constraints

- Preserve existing Foundation/ICU query and replacement semantics; the codec does not compile regex.
- Swift 5 language mode, macOS 14, no new dependency, shell, network or document file writes.
- Universal frame payload cap 65,536 bytes; header 32 bytes; full original UTF-16 coordinates.
- Protocol version 1 and semantic version 1 are compatibility constants, not executable authentication.
- No partial response may become successful results.
- No process, queue, RSS, native or packaged-runtime acceptance is implied by codec tests.
- Use synthetic fixtures; keep raw evidence private. Routine design/execution approvals are waived by BUILD_PROMPT.

## Scope and ownership

Create only `Sources/SearchExecution/{SearchWireTypes,SearchWireFrameCodec,SearchWireUTF16,SearchWireRequestCodec,SearchWireResponseCodec}.swift` and corresponding `Tests/SearchExecutionTests/{SearchWireFrameTests,SearchWireUTF16Tests,SearchWireRequestTests,SearchWireResponseTests,SearchWireSemanticTests}.swift`. Modify Package.swift to add `.target(name: "SearchExecution", dependencies: ["PadCore"])` and `.testTarget(name: "SearchExecutionTests", dependencies: ["SearchExecution", "PadCore"])`. No new library product is required for in-package app/helper dependencies. Do not add the app dependency until native routing is implemented.

Do not modify the active worker's SearchService/FolderSearch/native files. Start semantic integration tests only after the reviewed public PadCore `SearchExecutionOperation` and `SearchExecutionOutput` exist. No helper executable, spawn/kill/wait, timers, queue/reservations, native UI, filesystem access, package signing, or protocol fallback in this task. Implementing the codec establishes none of those runtime properties.

## Frozen v1 byte format

All multibyte integers are unsigned little-endian, decoded bytewise without assuming aligned memory. UUIDs are 16 RFC-4122/network-order bytes (`UUID.uuid` tuple order), not platform struct bytes or UTF-8 UUID strings. No BOM is stripped from text: U+FEFF is ordinary content. Universal frame payload cap **65,536 bytes**, header **32 bytes**:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | magic bytes `50 53 52 58` (PSRX) |
| 4 | 2 | protocol version = 1 |
| 6 | 2 | kind, defined below |
| 8 | 8 | payload byte count, checked against cap before allocation |
| 16 | 16 | request UUID; all zero only for hello frames |

| Kind | Code | Payload and direction |
| --- | --- | --- |
| parentHello | 1 | parent to child: generation UUID16 + semanticVersion UInt32 (=1) + reserved UInt32 (=0); 24 bytes |
| childHello | 2 | child to parent: exact same 24-byte payload; no implicit negotiation |
| requestStart | 16 | parent to child: 64-byte metadata followed by small UTF-16LE pattern/template blobs |
| inputChunk | 17 | parent to child: nonempty even-sized raw UTF-16LE, up to 65,536 bytes |
| execute | 18 | parent to child: empty payload; only after exact input length/validity |
| responseStart | 32 | child to parent: 32-byte result metadata |
| rangeChunk | 33 | child to parent: nonempty multiple of 16 bytes; each pair is location UInt64, length UInt64 |
| replacementChunk | 34 | child to parent: nonempty even-sized UTF-16LE |
| terminal | 35 | child to parent: ordinal UInt64 + status UInt16 + six reserved zero bytes; 16 bytes |

No other message kinds, progress frame, captures, arbitrary text diagnostics, paths, JSON or object archives. Process cancellation uses the future supervisor, not a cooperative cancel message that a blocked engine cannot consume. Adding progress later requires an explicit reviewed compatibility change.

Handshake uses **protocolVersion=1 and semanticVersion=1**, ordinary source constants shared by both targets through this module. No source/build digest exists or is implied. Semantic version identifies the agreed one-enumeration/flags/replacement contract and must change for incompatible behavior. Echoing a generation/version is correlation, not authentication or proof of executable provenance. Each connection is constructed with its expected generation, and every delivered request/response identity includes it even though it is not repeated in each frame.

RequestStart fixed metadata (offsets relative to payload): ordinal U64 at0; inputUTF16 U64 at8; scopeLocation U64 at16; scopeLength U64 at24; maxTextUTF16 U64 at32; maxOutputUTF16 U64 at40; maxMatches U32 at48; cooperativeMilliseconds U32 at52; patternUTF16 U16 at56; templateUTF16 U16 at58; mode U8 at60; operation U8 at61; options U8 at62; hasScope U8 at63. Follow with exactly `2*patternUTF16` pattern bytes then `2*templateUTF16` template bytes. No trailing data. Maximum total =16,448 bytes (64+8,192+8,192).

Mode 0 literal /1 escaped /2 regex; operation0 find /1 replace; option bit0 caseSensitive, bit1 wholeWord, all others zero. hasScope is0/1; absent scope requires both scope integers zero. Find requires template length0; replace may have length0. Pattern/template length at most4,096 UTF-16 units each; never treat a16KiB cap as permission for8,192 units. Input and maxText/maxOutput at most100,000,000 units, maxMatches at most100,000; zero limits are representable. Input must not exceed maxText. cooperativeMilliseconds ranges0...60,000 for v1; zero is representable and yields existing semantic timeout, not a default override. This is a finite wire safety bound, not a measured production timeout policy. Scope arithmetic and boundaries are validated before execute; absent scope means whole text. Cumulative lengths use UInt64 comparisons before any Int conversion.

responseBody prevalidates arbitrary output ranges/count/shape before responseStart: reject negative NSRange values, NSNotFound/Int.max, and endpoints beyond the global100M-unit ceiling using subtraction-safe checks as invalidRange before UInt64 conversion. The receiver independently bounds wire UInt64 components before Int conversion and applies authoritative original-input/scope/scalar validation. Writer has no original input/scope and cannot substitute for that check.

ResponseStart metadata: ordinal U64 at0; matchCount U32 at8; reserved U32 zero at12; replacementUTF16 U64 at16; hasReplacement U8 at24; seven zero bytes at25. Count <= request.maxMatches, replacement length <=request.maxOutput; find must have flag0/length0, replace flag1 even for empty output. No ranges or text embedded here. Range chunks must finish exactly matchCount before replacement chunks. Match ranges always refer to the original input and lie within the requested scope (including zero-length at scope EOF).

Terminal status0 = success. Status1...10 map respectively to PadCore SearchError: invalidScope, invalidEscape, invalidPattern, invalidReplacement, textLimit, matchLimit, outputLimit, cancelled, timedOut, engineFailure. Those codes contain no strings. Unknown codes are fatal protocol errors. Valid error terminal may occur after execute before responseStart, or after partial response chunks: sink must discard any partial result, never return success. Success requires exact counts, complete well-formed replacement when applicable, and no pending high surrogate. Invalid IPC is not encoded as a semantic SearchError; poison the connection and let the later supervisor terminate it.

## Exact module API surface

All values below are public, Sendable; equality on value types/enums where their fields allow it. Readers/encoders are explicitly single-owner mutable reference types, not Sendable. All stored value properties are `let`; initializers validate relevant numeric bounds and throw SearchWireError. The semantic query/operation are PadCore types, not copies of their logic.

```swift
public struct SearchWireIdentity: Equatable, Sendable {
  public let generation: UUID
  public let requestID: UUID
  public let ordinal: UInt64
  public init(generation: UUID, requestID: UUID, ordinal: UInt64) throws
}
public struct SearchWireLimits: Equatable, Sendable {
  public let maxTextUTF16: Int
  public let maxOutputUTF16: Int
  public let maxMatches: Int
  public let cooperativeMilliseconds: UInt32
  public init(maxTextUTF16: Int, maxOutputUTF16: Int, maxMatches: Int,
              cooperativeMilliseconds: UInt32) throws
}
public struct SearchWireRequest: Sendable {
  public let identity: SearchWireIdentity
  public let query: SearchQuery
  public let operation: SearchExecutionOperation
  public let inputUTF16: Int
  public let scope: NSRange?
  public let limits: SearchWireLimits
  public init(identity: SearchWireIdentity, query: SearchQuery,
              operation: SearchExecutionOperation, inputUTF16: Int,
              scope: NSRange?, limits: SearchWireLimits) throws
}
public struct SearchWireResponse: Equatable, Sendable {
  public let identity: SearchWireIdentity
  public let matchCount: Int
  public let replacementUTF16: Int? // nil = find; 0 = empty replacement
  public init(identity: SearchWireIdentity, matchCount: Int, replacementUTF16: Int?) throws
}
public enum SearchWireTerminal: Equatable, Sendable {
  case success
  case failure(SearchError)
}
public enum SearchWireError: Error, Equatable {
  case invalidHeader, unsupportedVersion, unknownKind, payloadLimit
  case invalidMetadata, identityMismatch, ordinalMismatch, invalidPhase
  case truncated, lengthMismatch, malformedUTF16, invalidRange, poisoned
  case reentrantUse, sinkRejected
}
public enum SearchWireKind: UInt16, Sendable {
  case parentHello = 1, childHello = 2, requestStart = 16, inputChunk = 17, execute = 18
  case responseStart = 32, rangeChunk = 33, replacementChunk = 34, terminal = 35
}
public struct SearchWireFrame: Sendable {
  public let kind: SearchWireKind
  public let requestID: UUID
  public let payload: Data // <=65,536 bytes; a single bounded frame only
  public init(kind: SearchWireKind, requestID: UUID, payload: Data) throws
}
public final class SearchWireFrameDecoder {
  public init()
  public var bufferedByteCount: Int { get }
  public func consume(_ bytes: UnsafeRawBufferPointer,
                      onFrame: (SearchWireFrame) throws -> Void) throws
  public func finish() throws // framing EOF: rejects unfinished header/payload
}
public enum SearchWireFrameEncoder {
  public static func write(_ frame: SearchWireFrame,
                           emit: (Data) throws -> Void) throws
}
```

FrameDecoder consumes at most65,568 bytes per call (caller splits larger read buffers without copying). It processes arbitrarily split headers/payloads, including bytewise feeds; multiple complete frames in one call are delivered sequentially. It keeps at most one header+payload under construction. Do not append the entire supplied transport buffer before parsing the header. Reject oversized input calls with payloadLimit before copying. Encoder emits bounded header then payload (neither an unbounded list nor full-message Data). `onFrame` is synchronous, nonescaping; callback failure throws sinkRejected and poisons decoder. No localized callback error is sent to a peer. Reentry sets poison before throwing reentrantUse; an outer call must observe poison even if a callback catches the nested error. After any first error, subsequent use throws poisoned; the original error is returned once.

### Uniform mutable-codec lifecycle

Every mutable codec is confined to one caller lane and enforces active/finished/failed lifecycle behavior. Codecs with caller callbacks also guard inCall; callback-free encoder/index methods need no redundant inCall state because cross-thread use is forbidden. Set inCall before any callback. A nested mutating call, including finish/acknowledge/expect/nextChunk, returns reentrantUse and permanently fails that codec; the outer operation must recheck failure after each callback, even if the callback swallowed the nested error. Read-only properties may be observed inside callbacks. No reset/reuse of a failed or finished codec is permitted, except the explicitly idempotent successful finish/end operations below. First ordinary validation failure reports its precise SearchWireError; later calls report poisoned. A callback error maps to sinkRejected unless a reentry already failed the codec. These classes are not thread-safe; simultaneous cross-thread access is forbidden by contract, not “detected” using an unsynchronized flag.

- FrameDecoder.finish: success only between complete frames, then closed; repeated finish succeeds, subsequent consume throws invalidPhase and fails the decoder. Partial header/payload throws truncated and fails it. FrameDecoder does not decide whether a request was semantically complete; readers add that check.
- UTF16Encoder, UTF16Decoder and BoundaryIndex constructors accept expectedUTF16 only in0...100,000,000; otherwise invalidMetadata, before allocation or traversal. Empty input has a valid completed boundary at0.
- UTF16Decoder.consume and BoundaryIndex.append: require a nonempty, even-sized Data of at most65,536 bytes on **every direct call**, before processing or copying. Zero/odd payload throws lengthMismatch; oversized payload throws payloadLimit. Empty input is represented by no append calls followed by finish. Both check cumulative declared lengths, pending surrogate state and integer bounds. Finish with a short declared length throws lengthMismatch; a pending high surrogate at otherwise exact length throws malformedUTF16. Successful finish is idempotent and immutable; later consume/append throws invalidPhase and fails the object.
- BoundaryIndex.validate: permitted only after successful finish, performs no mutation/callback, and can be called repeatedly. An invalid queried range returns invalidRange without corrupting a finished index (the calling response reader still fails its connection). Calling validate before finish returns invalidPhase without changing the still-buildable index; append/finish may then complete normally. Validate is nonmutating in every state. An already failed index still returns poisoned. Its identity/storageByteCount are immutable observations. Construction/append/finish failures leave validate throwing poisoned.
- UTF16Encoder.nextChunk: successful verified end transitions to finished; repeated calls return nil. A wrong expected length or any encoding failure poisons it; later calls throw poisoned. It has no callback or separate finish. Constructor checks numeric bounds only; it must not materialize a complete encoded copy. Each nextChunk incrementally advances its single owned text traversal.
- RequestReader/ResponseReader.finish: allowed only outside an active call; successful EOF requires their ready state after handshake (no request awaiting input/execution/terminal), then closed. Repeated finish succeeds; any other mutating call afterward returns invalidPhase and fails the reader. EOF in another connection phase throws truncated and poisons it. A subcodec failure poisons its containing reader.
- Writer static functions have no persistent lifecycle to reset. They stop at first validation/emit failure and never emit a later execute/success terminal. Their synchronous sink must not recursively use the same transport writer; the future transport owner must guard that separate shared resource. No static codec function claims to police arbitrary independent writers.

```swift
public final class SearchWireBoundaryIndex {
  public let identity: SearchWireIdentity
  public init(identity: SearchWireIdentity, expectedUTF16: Int) throws
  public var storageByteCount: Int { get }
  public func append(_ utf16LE: Data) throws
  public func finish() throws
  public func validate(_ range: NSRange, within scope: NSRange?) throws
}
public final class SearchWireUTF16Decoder {
  public init(expectedUTF16: Int) throws
  public func consume(_ utf16LE: Data, emitUTF8: (Data) throws -> Void) throws
  public func finish() throws
}
public final class SearchWireUTF16Encoder {
  public init(text: String, expectedUTF16: Int) throws
  public func nextChunk() throws -> Data? // <=65,536 bytes; nil only at exact verified end
}
public protocol SearchWireRequestSink: AnyObject {
  func helloAccepted(generation: UUID) throws
  func begin(_ request: SearchWireRequest) throws
  func appendInputUTF8(_ bytes: Data) throws
  func execute(_ identity: SearchWireIdentity) throws
}
public protocol SearchWireResponseSink: AnyObject {
  func helloAccepted(generation: UUID) throws
  func begin(_ response: SearchWireResponse) throws
  func appendRanges(_ ranges: [NSRange]) throws
  func appendReplacementUTF8(_ bytes: Data) throws
  func complete(_ identity: SearchWireIdentity, terminal: SearchWireTerminal) throws
}
public final class SearchWireRequestReader {
  public init(generation: UUID) throws
  public func consume(_ bytes: UnsafeRawBufferPointer, sink: SearchWireRequestSink) throws
  public func finish() throws
  public func acknowledgeTerminal(_ identity: SearchWireIdentity) throws
}
public final class SearchWireResponseReader {
  public init(generation: UUID) throws
  public func expect(_ request: SearchWireRequest, boundaries: SearchWireBoundaryIndex) throws
  public func consume(_ bytes: UnsafeRawBufferPointer, sink: SearchWireResponseSink) throws
  public func finish() throws
}
public enum SearchWireWriter {
  public static func hello(generation: UUID, fromChild: Bool,
                           emit: (Data) throws -> Void) throws
  public static func request(_ request: SearchWireRequest, text: String,
                             emit: (Data) throws -> Void) throws -> SearchWireBoundaryIndex
  public static func responseBody(_ response: SearchWireResponse,
                                  output: SearchExecutionOutput,
                                  emit: (Data) throws -> Void) throws
  public static func terminal(_ identity: SearchWireIdentity,
                              result: SearchWireTerminal,
                              emit: (Data) throws -> Void) throws
}
```

No additional undefined output/limit types are needed. These convenience writers stream frames through a synchronous sink; they do not own process scheduling or perform I/O. A production transport can implement a bounded synchronous sink on its dedicated codec lane; it must stop upstream production when credits are unavailable rather than enqueue an unbounded list. Tests may collect small fixture bytes only. Writers stop on the first emit failure; the transport connection is then unusable. `request` constructs an identity-bound BoundaryIndex, appends each exact Encoder.nextChunk payload used for inputChunk, finishes the index and validates optional scope before emitting execute, and returns that completed index only after execute emission succeeds. The return is deliberately not @discardableResult. Encoding/index/scope or earlier emission failure prevents attempting execute and returns no index. An execute-emission failure also returns no index and permits no subsequent sink call, but its bytes may already have escaped before the sink threw; no rollback is implied. The connection is unusable and the future lifecycle must stop/reap the owned child. Do not parse outgoing wire or traverse the full source again just to recover boundaries. It emits start, encoder chunks, execute; `responseBody` emits metadata, bounded range chunks and output chunks, **never terminal**. It checks response counts/lengths against actual output using incremental counting, without a second matching operation. Parent response reader applies authoritative expected-request limits.

### Local semantic refusal versus malformed IPC

The later async executor has an explicit **bounded admission contract before helper launch**, distinct from direct SearchService error priority. For a live, uncancelled request with valid execution policy, check input text bound first (SearchError.textLimit), pattern bound second (over4,096 UTF-16 units -> invalidPattern), and replacement-template bound third (over4,096 units -> outputLimit). Find has no template. Reject without compiling regex, launching a child or writing request bytes. Scope checks then return invalidScope for negative/out-of-bounds/surrogate-splitting endpoints. Cancellation/policy admission belongs to the executor and must not be inferred from a wire parser error. For requests within these admission bounds, preserve the reviewed core parsing/enumeration/template error precedence and first terminal failure.

This deliberately changes only priority when a request is outside the async bounds: an oversized template plus invalid regex returns **outputLimit from async admission**, while direct SearchService still searches/validates its query first and returns **invalidPattern**. Do not change the direct service or the active single-enumeration plan. Do not send overflow flags, substitute a synthetic small template, or compile regex in the parent to imitate multi-invalid-input ordering. Valid-sized query/template semantics, capture expansion, scopes, match ranges, replacement output and runtime output-limit behavior are unchanged. A valid-sized template whose expansion exceeds the output cap is still evaluated by the semantic primitive and fails there.

Wire constructors use SearchWireError for invalid metadata and are **not** a replacement public semantic executor. Do not broadly translate invalidMetadata or invalidRange into SearchError at an arbitrary catch site. Local semantic validation must be explicit and tied to the original request; if a constructor still fails after preflight, that is a local protocol/programming failure.

Received malformed lengths, invalid UTF-16, illegal scope metadata, unknown tags, identity mismatch, bad range endpoints or unexpected EOF are peer/protocol failures and poison the connection. They are never interpreted as valid engine errors or successful empty results. Only an exact recognized failure terminal for the current request carries a SearchError from the helper. A corrupt response cannot be rescued by locally clipping ranges or rerunning in-process. This wire-only task defines/tests the distinction; the executor task must implement the documented admission priority, not universal equivalence to direct-service invalid-input ordering.

Required executor-stage regression: `.regex` pattern `(` and `.replace(template: String(repeating: "x", count: 4097))` returns SearchError.outputLimit with launch count0 and no request bytes; direct `SearchService.execute` on the same benign invalid request returns SearchError.invalidPattern. A4096-unit template with the same invalid regex is admitted by size and returns invalidPattern from the helper. A4097-unit literal-mode replacement is also refused as outputLimit before launch. Add both valid-sized semantic parity controls and malformed-response tests that remain SearchWireError. These tests belong to the later executor stage because this module intentionally has no executor/launcher; current wire constructor tests assert invalidMetadata for out-of-cap blobs rather than pretending to prove launch refusal.

Constructor error mapping is fixed: zero generation/request identities use identityMismatch; ordinal0 uses ordinalMismatch; out-of-cap or negative limits/counts and structurally invalid request/scope/response metadata use invalidMetadata. Frame UUID is zero only for hello kinds; violating that relation uses identityMismatch. Per-request response limits are enforced by the reader against its expected request, not inferred from global constructor caps. Scalar endpoints are checked after the index is complete and fail invalidRange. These are protocol errors; the explicit local semantic preflight above runs first for user requests.

## Connection phases and correlation

The parent transport must gate response parsing: after childHello, do not pass subsequent response bytes to ResponseReader.consume until Writer.request returns its completed index and ResponseReader.expect accepts it. Child response bytes may already be buffered after execute; retain only bounded transport buffering during this gate. No always-consuming read loop may bypass expect. If a later transport design requires one, revise the API with independent review rather than weakening reader phases.

Readers preserve their own first validation error when it crosses the FrameDecoder callback boundary. FrameDecoder intentionally maps callback failures to sinkRejected; that must not erase a reader's already-recorded invalid metadata/phase/range error. Ordinary external sink rejection remains sinkRejected. Keep FrameDecoder's reviewed contract unchanged and test exact outer errors plus subsequent poison.


The future owned launcher supplies the expected generation to the helper as the bounded nonsecret bootstrap argument `--generation <UUID>`. The helper validates exactly that argument before constructing RequestReader; no document text, pattern or document path is placed in argv. This protocol-only task consumes the supplied generation and does not implement launch parsing. It must not decode an unchecked hello merely to invent its own expected identity.

RequestReader starts awaiting parentHello, checks exact generation/nonzero UUID and semantic version, then enters ready before calling sink.helloAccepted. That callback lets the future helper emit childHello without inspecting raw bytes or assuming handshake acceptance. Request ordinal begins1, must increase by exactly1 after acknowledgeTerminal; no wrap. UInt64.max may complete once, then further requests fail ordinalMismatch and caller must establish a new generation. Represent exhaustion separately (for example nil expected ordinal); checked successor must not throw during completion of max, and idle EOF remains valid after exhaustion. A bounded internal successor test may exercise max without widening public admission. Ready accepts only requestStart with nonzero request UUID; input phase accepts only inputChunk and then execute. Empty input has no chunks. Execute validates count/surrogates/scope before calling sink.execute, then enters executing **before** that callback. Any next request before exact acknowledgeTerminal is invalidPhase. Acknowledgement accepts the same full identity only, changes to ready before external callbacks (none in this API), and never accepts twice. Repeated request UUID with a later ordinal is a different full identity; replay of any earlier ordinal is rejected without storing unbounded UUID history. The supervisor must still issue its own unique job IDs.

ResponseReader begins awaiting childHello, enters ready before sink.helloAccepted and permits later request admission only after that callback returns. `expect` validates matching generation and next ordinal, requires a finished boundary index with the **same full identity** and exactly inputUTF16, and retains the exact request. Trusted encoding ownership must also ensure that this index was produced from that identity's immutable input; no hash or length is substituted for that association. It then accepts responseStart or error terminal for that request UUID. All subsequent frames must match the same UUID; responseStart/terminal ordinal must match too. After success/error terminal, reader transitions ready before invoking complete and clears heavyweight request/index references; the sink has separately reserved any retained results. A later old terminal/frame is invalidPhase, even if a new request has not started. `expect` cannot reenter from an active callback; caller schedules it after callback returns. First protocol/sink error poisons the entire connection; no parser reset API.

EOF after complete hello while ready is normal connection closure. EOF before hello, mid-frame, receiving input, executing, waiting response, or before terminal is truncated; no complete callback. EOF does not make a partial replacement successful. The future supervisor decides whether idle EOF means healthy recycling or unexpected exit.

`terminal.success` is a **peer claim**, not proof of process quiescence. The future helper must call responseBody inside the scope owning decoded input, compiled expression/checking results/output/autoreleasepool; exit that scope, then write terminal. A function-local result kept alive while sending terminal violates that runtime obligation. Error terminal follows the same release rule. RequestReader.acknowledgeTerminal is called only after terminal write has succeeded. This codec task tests ordering/correlation, not actual heap release, readiness, termination, or reap.

Scheduling is explicit: sink.execute only records the validated identity/work item for the helper's single execution lane; it does not call SearchService or acknowledgeTerminal while consume is on the stack. After consume returns, the helper executes once, streams the body, leaves its heavyweight/autorelease scope, successfully writes terminal, then calls acknowledgeTerminal outside every reader callback. The same rule applies to semantic errors. No next request is consumed until this exact acknowledgement succeeds. A helloAccepted or response-complete callback similarly records follow-up work; expect/consume/finish on that same reader must wait until the callback and outer consume return. Tests must prove that reentrant acknowledgement fails and a scheduled exact acknowledgement succeeds, without loosening the guard to support the helper.

## Unicode/range validation and ownership

UTF16 decoder holds only a possible high surrogate and current bounded output chunk. Frame payloads have even byte counts; transport may split at any byte. A high surrogate at the end of one frame is retained until the next frame; require low surrogate next. Reject standalone low, high followed by ordinary scalar, and high at finish. Convert scalars incrementally to UTF-8, output chunks <=65,536 bytes (flush before adding a scalar that exceeds cap); do not construct `[UInt16]` for the whole input or `String(data: fullWireData)`.

BoundaryIndex holds `ceil((expectedUTF16+1)/8)` bytes, <=12,500,001 at100M units, plus counters and one pending high surrogate. One input pass marks valid boundaries; finish rejects wrong counts or a dangling surrogate. It is immutable after finish, and validate uses subtraction-safe bounds then two indexed bit lookups. Neither validate nor range decoding traverses Swift text from its start. Scope endpoints use the same index. At most100,000 response ranges, each must start at or after the previous end; after a zero-length match the next location must advance (no duplicate zero-length result). Before implementing that predicate, retain exact benign Foundation controls: regex `a*` over `b` yields `(0,0),(1,0)`; regex `(?=a)` over `aa` yields `(0,0),(1,0)`; regex `$` over `a` yields `(1,0)`; regex `a*` over `a` yields `(0,1),(1,0)`. The latter permits a zero-length result at the previous nonempty end. If any control differs on the supported Foundation runtime, stop and report the discrepancy for review; do not sort, relax or silently rewrite the oracle. Range callbacks contain at most4,096 elements and sink metadata asserts cumulative expected count.

Parent builds its index while encoding the immutable original input on the bounded codec lane; helper RequestReader builds a temporary index while decoding for scope validation, releases it before engine execution, and retains only its decoded text in its caller-owned sink. Same algorithms are reusable; do not allocate a second full wire buffer. RequestReader must finish its index before sink.execute, so no engine is entered with malformed text/scope.

Text sinks own incremental construction of the one final String and their exact allocation credits; this wire stage exposes bytes and does not hide a whole-text accumulator. Test sinks may use bounded synthetic accumulation. App/helper String building, growth and bridging require the later measured codec allocation task: the earlier640MB active candidate has been superseded by the reviewed allocation preflight, and768MB retained remains a candidate covering up to600MB original+replacement UTF-8 payload before additional charges. Neither is implemented by this codec. Temporary frames/chunks/range arrays and boundary bits must be included in those ledgers, and a sink retaining callback Data must account for that lifetime. No arbitrary text diagnostics or full capture arrays escape.

## Task 1 — Module, frame bounds and poison semantics

Files: SearchWireTypes.swift, SearchWireFrameCodec.swift, SearchWireFrameTests.swift, Package.swift. This task implements SearchWireIdentity, SearchWireError, SearchWireKind, SearchWireFrame and frame encoder/decoder only. Limits/request/response/terminal values are added with Task3, not committed as unused stubs here.

- [x] Add the listed target/test declarations and compiling type/method seams. Do not misreport missing-module compilation as a behavioral red.
- [x] Write fixed-byte header fixtures by hand (magic/version/kind/count/UUID), not only encoder/decoder round trips. Principal behavioral fixture: declared payload65,537 must reject before body or sink invocation.

```swift
let decoder = SearchWireFrameDecoder()
var emitted = 0
let bad = Data([0x50,0x53,0x52,0x58, 1,0, 17,0,
                1,0,1,0,0,0,0,0] + Array(repeating: 1, count: 16))
XCTAssertThrowsError(try bad.withUnsafeBytes {
  try decoder.consume($0) { _ in emitted += 1 }
}) { XCTAssertEqual($0 as? SearchWireError, .payloadLimit) }
XCTAssertEqual(emitted, 0)
XCTAssertLessThanOrEqual(decoder.bufferedByteCount, 32)
```

- [x] Proposed command: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireFrameTests`; retain genuine red, then implement bounded header/body counters and rerun unchanged tests.
- [x] Cover every header split, coalesced small frames, invalid magic/version/kind, UInt64.max length, empty allowed frame, maximum payload, trailing partial header/body EOF, emit failure, caught callback reentry and poisoned subsequent use. Assert exact errors and no sink calls on rejected headers.
- [x] Scope-format, independently review this framing deliverable, then scoped local commit if root dispatch authorizes it. No process test or broad core suite needed for this parser task.

## Task 2 — Streaming UTF-16 and constant-time range endpoints

Files: SearchWireUTF16.swift, SearchWireUTF16Tests.swift.

- [x] Add exact-length fixtures with split surrogate pair, embedded NUL, U+FEFF, BMP three-byte UTF-8 and supplementary characters. Test literal expected UTF-8 bytes, not a second run of the same decoder.

```swift
let codec = try SearchWireUTF16Decoder(expectedUTF16: 2)
var bytes = Data()
try codec.consume(Data([0x3D,0xD8])) { bytes.append($0) }
XCTAssertTrue(bytes.isEmpty)
try codec.consume(Data([0x00,0xDE])) { bytes.append($0) }
try codec.finish()
XCTAssertEqual(bytes, Data([0xF0,0x9F,0x98,0x80]))
let identity = try SearchWireIdentity(generation: UUID(), requestID: UUID(), ordinal: 1)
let index = try SearchWireBoundaryIndex(identity: identity, expectedUTF16: 2)
try index.append(Data([0x3D,0xD8,0x00,0xDE]))
try index.finish()
XCTAssertThrowsError(try index.validate(NSRange(location: 1, length: 0), within: nil)) {
  XCTAssertEqual($0 as? SearchWireError, .invalidRange)
}
try index.validate(NSRange(location: 0, length: 2), within: nil)
```

- [x] Proposed command: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireUTF16Tests`; retain failing assertions then implement incremental scalar state/bitset and rerun.
- [x] Add odd-sized frame payload, short/long known-length input, missing low surrogate at EOF, low-first, split pair followed by wrong scalar, zero input/EOF boundary and negative/overflowed NSRange. Do not allocate a fake huge input merely to check integer rejection.
- [x] Observable large-index correctness: incrementally feed a fixed repeated mixture of ASCII, a three-byte BMP scalar and supplementary pairs, using several chunk boundaries through pairs. Validate100K predetermined legal ranges distributed across the input; reject predetermined offsets inside pairs, out-of-bounds/overflow endpoints and an invalid late-file scope. Assert exact answers, storageByteCount formula and immutable finished behavior. Do not add test-only loop/probe counters that mirror implementation. Review source explicitly for stored packed bitset, one advancing construction traversal and two constant-time indexed endpoint reads; latency/scaling benchmarking is separate and unclaimed by these correctness tests.
- [x] Encoder tests consume nextChunk until nil, assert each <=65,536/even and exact expected bytes; wrong expected length errors instead of a successful end marker. Test repeated nextChunk after successful end returns nil, while after failure throws poisoned. Review/commit scoped Unicode deliverable.

## Task 3 — Sequential request/response readers and writers

Files: SearchWireRequestCodec.swift, SearchWireResponseCodec.swift, SearchWireRequestTests.swift, SearchWireResponseTests.swift; extend SearchWireTypes.swift with SearchWireLimits, SearchWireRequest, SearchWireResponse and SearchWireTerminal. Preserve Task1 identities/framing contracts.


Execute Task3 as two independently reviewed slices to keep each compilable without unused production stubs:

- **Task3A request path:** own SearchWireTypes.swift additions for Limits/Request only, new SearchWireRequestCodec.swift and SearchWireRequestTests.swift. Define SearchWireWriter with hello/request, RequestReader and actual request metadata encoding/decoding. No Response/Terminal values or response functions yet. Return/validate the real completed boundary index.
- **Task3B response path:** after3A review, own SearchWireTypes.swift additions for Response/Terminal only, new SearchWireResponseCodec.swift and SearchWireResponseTests.swift; extend the existing SearchWireWriter with responseBody/terminal. Request code stays unchanged unless a specific integration defect needs review.

The checks below apply to the corresponding slice; run the completed earlier codec suites as affected regressions. Task4 follows both approvals.

- [ ] Test hello exact generation and semantic version before any request; all-zero request ID refusal, cross-generation object expectation, wrong/replayed/skipped ordinal, and overflow refusing wrap. Feed hardcoded control metadata with reserved bytes set and independently check no execute callback.
- [ ] Add principal request behavioral red: valid metadata declaring two units, only one unit sent, followed by execute yields lengthMismatch with execute count0. Add complete input then duplicate execute and next request before acknowledgement: invalidPhase. No regex runs in these fixtures.
- [ ] Add principal response red: start declares one match and replacement, receive a valid range/text chunk, then engineFailure terminal; sink receives failure and discards accumulated data, **never a SearchExecutionOutput success**. Companion success needs exact counts and completed surrogate state; early success gives lengthMismatch. A minimal test recording sink stores begins/chunks/terminals and builds success only inside complete(success), clearing on complete(failure).
- [ ] Test wrong UUID/ordinal, duplicate metadata/terminal, unknown status, response text for find, absent text for replace, oversized cumulative output, range split not multiple16, out-of-bounds/scalar-splitting/outside-scope/unsorted/overlapping ranges, extra chunk after expected count, partial response EOF and sink refusal. Exact fixture bytes must not depend entirely on Writer behavior.
An independent terminal-byte fixture fixes the numeric engine-error ABI (the preceding reader fixtures verify its stateful meaning):

```swift
let identity = try SearchWireIdentity(generation: UUID(), requestID: UUID(), ordinal: 1)
var encoded = Data()
try SearchWireWriter.terminal(identity, result: .failure(.engineFailure)) {
  encoded.append($0)
}
XCTAssertEqual(encoded.count, 48)
XCTAssertEqual(Array(encoded.suffix(16)),
               [1,0,0,0,0,0,0,0, 10,0, 0,0,0,0,0,0])
```

- [ ] Proposed command: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireRequestTests` then `--filter SearchWireResponseTests` using the same scratch. Implement phase transitions before callbacks and exact poison behavior; rerun same fixtures.
- [ ] Request tests assert returned index identity/length/endpoints. Pre-execute failures return no index and never attempt execute; an execute sink that records bytes then throws returns no index and receives no subsequent call, without asserting rollback; response tests cover malformed signed ranges before conversion. Writers use Encoder.nextChunk and FrameEncoder.write, bounded range batches, no arrays of frames/full encoded Data. Test emitted sizes plus a sink that throws after its first chunk; no subsequent emit or terminal allowed. Body writer alone must never emit kind35.
- [ ] Review protocol offsets against independent byte fixtures and typed phase tests; scoped commit after root approval.

## Task 4 — Benign semantic handoff and module evidence

Files: SearchWireSemanticTests.swift only, unless review finds a codec defect.

- [ ] After the semantic prerequisite is reviewed, test a tiny sink that collects validated request input and records the execute identity. Only after consume returns, call `SearchService.execute` once with the decoded query/scope/operation. The codec does not compile/query itself. Feed resulting SearchExecutionOutput to responseBody, release its test-owned heavy scope, emit terminal separately, acknowledge outside consume, and assert parent receiver exact ranges/output. Use a known fixture such as `(a)` replacing `$1!` in `a a`: expected ranges(0,1),(2,1), output`a! a!`.
- [ ] Retain literal metacharacters, escaped newline/NUL, optional captures used internally in replacement, scoped whole-word boundary, zero-length EOF and emoji fixtures with fixed expected results. Include the root's bounded Foundation controls over `😀`: explicit high-surrogate pattern, low-surrogate pattern and high-surrogate class produce no ranges; dot produces `(0,2)`. Compare direct semantic output with codec-consumer output in full original UTF-16 coordinates. For Unicode replacement text assert exact UTF-16 units or fixed UTF-8 bytes; canonical Swift String equality alone cannot prove preservation of normalization form. Root evidence `.local/regex-scalar-spike/result` exited0 in0.468s under an external10s watchdog; it supports those fixtures only, not all regex scalar behavior. These planned tests add no subprocess helper in this stage; actual helper differential verification remains in its own stage. Confirm no captures appear in response bytes and find carries nil replacement. Add engineFailure typed terminal transport without calling a pathological engine.
The semantic oracle must use fixed expected values in addition to direct/codec comparison:

```swift
let output = try SearchService(timeLimit: 10).execute(
  SearchQuery(pattern: "(a)", mode: .regex), in: "a a",
  operation: .replace(template: "$1!"))
XCTAssertEqual(output.matches,
               [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
XCTAssertEqual(output.replacement, "a! a!")
```

Feed this result through the exact writer/reader/sink sequence described above and assert those same literal values on the completed receiver. The positive primitive call alone is not wire integration evidence.

- [ ] Proposed command: `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireSemanticTests`; then proposed `scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWire` for all new benign suites. No existing adversarial SearchTests are run by these filters. Any broader core test requires the approved outer watchdog, separate from this plan.
- [ ] Proposed build `scripts/swift.sh build --scratch-path .build/search-wire --target SearchExecution`, scoped `xcrun swift-format lint --strict Sources/SearchExecution Tests/SearchExecutionTests`, public-pattern check and whitespace check. Record actual final commands/hashes/results only after execution; do not add unverified commands to AGENTS.md.
- [ ] Independent specification/quality review of exact scoped diff. Freeze protocol/semantic constants and API names for the future helper/supervisor worker. Record implemented wire framing/validation separately from outstanding process, allocation, native/folder and packaged-runtime acceptance.

## Self-review outcome and unresolved implementation gates

This proposal defines the complete wire-only interfaces and binary schema; no process/native receipt is fabricated. Root review refinements are explicit: versioned hello rather than nonexistent build hash; match-only responses; complete codec lifecycle/direct-call limits; scheduled execution/acknowledgement after consume; local semantic preflight distinct from poisoned peer IPC; observable large-index correctness plus source complexity review. Exact Foundation zero-length controls precede predicate enforcement and never authorize sorting/tolerance. Memory growth of the eventual String sinks and hard child lifecycle are intentionally outside this implementation slice and must be covered before production routing.

Task1 and Task2 commands have been executed and reviewed; Task3A/3B/4 commands remain proposed. Root reviewed the private draft and lifecycle/error-boundary refinements before adopting this plan. The task split prevents committing unused codec stubs; each task retains its own meaningful tests and review gate. Task1 changed only Package.swift and the three framing source/test files; Task2 added the UTF16 source/test pair. Later protocol stages remain outstanding.
