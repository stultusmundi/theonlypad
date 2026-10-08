# Production parent response accumulator implementation plan

> Use superpowers:subagent-driven-development for source ownership and independent
> specification/quality review. Root owns every compiler, helper and GUI run.

**Goal:** Supply the production response collector behind the existing codec sink.

**Architecture:** One owner-thread SearchExecution class retains compact request
metadata, bounded ranges and strictly validated UTF8 replacement bytes. The
existing reader authenticates source scalar boundaries; the collector validates
its receiving state and returns one detached terminal/output. Default driver,
admission and UI composition remain separate.

**Tech stack:** Swift5 mode, macOS14, Foundation/standard Swift; no new dependency.

**Spec:** docs/superpowers/specs/2026-10-08-parent-response-accumulator-design.md.

## Global constraints

- Current isolated workspace remains in use; preserve unrelated changes.
- Original MIT, synthetic fixtures, ignored raw evidence only.
- Root exclusively owns serial tests/builds/helper execution; no nested watchdog.
- Request ceilings remain 100,000 matches and 100,000,000 UTF16 units; a chunk is
  at most65,536 bytes and retained replacement content at most3*N bytes.
- No eager reserve, source/pattern/template retention or allocation/RSS claim.
- Throwing foreign-thread calls reject before mutable access; discard is
  idempotent and requires its creating thread. No crash test for foreign discard.
- Existing worker/wire/codec/driver source and regression assertions remain intact.

## Task1: Direct collector behavior

Create Sources/SearchExecution/SearchParentResponseAccumulator.swift and
Tests/SearchExecutionTests/SearchParentResponseAccumulatorTests.swift and
Tests/SearchExecutionTests/SearchParentResponseCodecTests.swift.

Consumes validated SearchWireRequest/Response and SearchWireResponseSink;
produces the spec's exact package class/error API and protocol conformance.

- [ ] Independent design review approves the owner/state/error/bounds contract;
  qualify empty signals before outcome credit, with owned shutdown signals kept.
- [ ] A separate test author writes independent direct and genuine codec tests
  before implementation. Codec tests use the actual lane/session/bridge and
  response writer/reader with the proposed factory. Direct tests cover every spec case.
  A small representative oracle is:

```swift
let accumulator = SearchParentResponseAccumulator(request: request)
try accumulator.begin(response)
try accumulator.appendRanges([NSRange(location: 1, length: 2)])
try accumulator.complete(request.identity, terminal: .success)
let result = try accumulator.takeTerminal(for: request.identity)
XCTAssertEqual(result.terminal, .success)
XCTAssertEqual(result.output?.matches, [NSRange(location: 1, length: 2)])
XCTAssertNil(result.output?.replacement)
accumulator.discard()
XCTAssertEqual(result.output?.matches, [NSRange(location: 1, length: 2)])
```

  Test helpers construct request inputUTF16=4, pattern="😀", find, expected
  response count1/nil replacement. Exact error/Unicode/range/phase cases follow
  the adopted spec; no production counters or hooks are added.
- [ ] Root freezes actual sources/tests and first records absent-API compiler
  failure. In a separate ignored minimal package, add only a conforming naive
  collector shell: accept all callbacks, store ranges/Data, return one nominal
  output with String(decoding:as:), and discard storage. Root records actual
  behavioral assertions failing for absent validation/state handling. Never
  check in this shell or count compiler failure as behavioral RED.
- [ ] Source implementer writes the specified class after RED. Sequence methods:
  owner guard; failed/phase guard; identity/shape check; subtractive bounds and
  strict transcode; append only fully validated batch. Errors clear payload and
  enter failed; no wrong-lane mutation. Failure terminal bypasses completeness
  and clears partial output. Successful take validates whole bytes, constructs
  output, detaches storage and enters taken. Keep whole-data validation separate
  from the per-chunk cap.
- [ ] Root runs focused GREEN against exact frozen sources, then independent
  source reviewer verifies complete class/test conformance and resolves findings.

Proposed focused invocation, executed directly by the existing watchdog:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/parent-response-focused -- scripts/swift.sh test --scratch-path .build/parent-response --filter SearchParentResponseAccumulatorTests
```

Frozen behavioral RED adds absolute --package-path/--scratch-path selecting its
ignored minimal package; record exact command and input membership per stage.

## Task2: Genuine codec and helper factory

The codec test file is authored before implementation in Task1. Modify
only the factory binding in Tests/SearchWorkerIntegration/RealSearchWorkerTests.swift
and remove the superseded test-only collector after direct/codec GREEN.

- [ ] Independently review the already authored tests using actual
  SearchParentCodecLane/session, bridge,
  request writer/boundary index and response reader/writer with the new factory.
  Capture no source outside the established job/upload scope. Assert exact
  provisional output/identity for fragmented surrogate wire, nil find/empty
  replacement, semantic failure before begin/after partial body, invalid source
  scalar endpoints, trailing terminal junk and a fresh next-ordinal collector.
  Retain original instrumented codec tests unchanged.
- [ ] Root verifies the genuine codec cases against the frozen RED shell from
  Task1, then the actual production class. Record any already-passing baseline
  controls honestly; never alter an oracle to manufacture RED. GREEN selection:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/parent-response-codec -- scripts/swift.sh test --scratch-path .build/parent-response --filter 'SearchParentResponse|SearchParentWireCodecSessionTests|SearchWire'
```

- [ ] Reviewer checks codec/helper test source delta and original literal result,
  identity, reuse, pre-outcome signal/reap and strict joined cleanup assertions.
- [ ] Root runs scripts/test-search-worker.sh with the production factory. The
  coordinator owns its watchdog; do not wrap it. Record current helper/test
  artifact hashes, actual five methods and all stage/cleanup receipts. This is
  production response collection acceptance, not UI routing or memory proof.

## Task3: Integrated component checkpoint

Update dated verification, AGENTS, continuation and spec/plan states.

- [ ] Root runs full current app/core through the direct600s watchdog, strict
  format, public-source and scoped diff checks. Actual full command:

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/parent-response-integrated -- scripts/swift.sh test --scratch-path .build/parent-response-integrated
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
```

- [ ] Independent final review matches actual receipts/pins and all planned,
  implemented/tested/blocked states. Make a scoped local commit after checks;
  no remote merge/push/release. Continue fixed parent policy/composition,
  production admission accounting/retry and native owner routing.
