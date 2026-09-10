# Search wire codec verification

## Framing — 2026-09-10

Task1 source `d3c7d294a816bb04b5549363a2bbe85fabb27169`, corrected by `aa3aa821250f74b7ef339d06b051169c3e74c39e`, adds SearchExecution as an unintegrated SwiftPM module. It implements identities and fixed 32-byte headers, bounded frame encoding/decoding, and callback/EOF failure handling. Payloads are capped at65,536 bytes and direct transport calls at65,568. Header integers are decoded bytewise; oversized declared payloads are rejected before body allocation.

Final focused tests pass **19/0**. Fixed byte fixtures cover every header split, bytewise body feeds, coalesced frames, magic/version/kind/UUID refusal, maximum and oversized payloads, UInt64.max length, partial EOF, sink failure, repeated finish, post-finish rejection, and reentry. Target build and scoped strict formatting/public-source/whitespace checks pass. Source hashes were checked against the implementation report.

```sh
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireFrameTests
scripts/swift.sh build --scratch-path .build/search-wire --target SearchExecution
xcrun swift-format lint --strict --recursive Sources/SearchExecution Tests/SearchExecutionTests Package.swift
```

Initial missing-API compilation and temporary no-op seams were recorded separately from behavior tests; they do not demonstrate a previous production defect. Initial green was18 tests. Independent review found that a callback catching reentry and subsequently throwing an arbitrary error incorrectly reported sinkRejected. A new regression failed with that exact error, then passed after failed-state classification was moved ahead of error-type classification. It also proves no later coalesced frame is delivered and subsequent calls remain poisoned. Independent scoped re-review approved specification and quality without remaining findings.

Final codec SHA256: `333e99202bda205e60b502fb9caefdc27a9d38313f22cbedc0d543d215ae5837`. Final frame-test SHA256: `a356a20951ca09142197312d65b73127b2193fa61aa03c19d467205748d31806`.

Request/response phases, real helper execution, deadline/reap containment, memory accounting and native/folder routing remain outstanding. Framing tests do not validate those properties or desktop/packaged behavior. No dependency was added; the app does not yet depend on SearchExecution. Current local distributable artifacts still contain source55a7b1b.


## UTF-16 streaming and boundary index — 2026-09-10

Source `280dada0e76fd3af514d21ef904434118c4cbc66`, corrected by `10c4dd4a66e50c5f1a1113ef63a9ec2ad25cd016`, implements the incremental UTF-16LE encoder, strict UTF-16-to-UTF-8 decoder and packed scalar-boundary index. Each constructor enforces0...100,000,000 units; decoder/index calls enforce nonempty, even, at-most65,536-byte chunks. Encoder uses one iterator; decoder emits complete scalars in bounded chunks without normalization. Index lookups use subtraction-safe arithmetic and packed endpoint bits.

Final focused UTF-16 tests pass **20/0**, with framing regressions **19/0**. The module build and scoped formatting/public-source/whitespace checks pass. Literal fixtures preserve NUL, U+FEFF, Euro, split emoji pairs and decomposed Unicode bytes. Tests cover malformed surrogates, length/cap/EOF precedence, callback failures/reentry, stable encoder completion and index lifecycle.100,000 distributed legal range queries and invalid interior/scope queries use a12,501-byte index fixture; this is correctness/storage evidence, not performance or RSS evidence.

```sh
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireUTF16Tests
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireFrameTests
```

Independent review found that a premature validate query incorrectly poisoned an unfinished index. The continued-construction regression failed because append saw poisoned, then passed after the query became nonmutating. Invalid pre-finish queries still return invalidPhase; failed append/finish remain poisoning. Additional coverage proves a callback that catches reentry and returns normally cannot emit a second chunk; that case passed immediately and was not a reproduced defect. Scoped re-review approved both findings with no new issues.

Root verified final source SHA256 `9020acf3edc9ec5e9806054b7da4a8ef83b3b6e3bd85761df961f381d6e289ff` and test SHA256 `3f97d979e485f238cec209dffe46312aae9641f3c10816bf6de990d786b0e7e5`. Missing-API setup failures and the corrected no-op-seam behavioral red are recorded separately in private evidence; an initial test trap from indexing an absent chunk was corrected to XCTUnwrap before retaining behavioral-red evidence.

No helper, process containment, allocation ledger, native routing or packaged runtime acceptance is implemented by this stage.


## Committed-source integration

A clean detached snapshot at `05cab519c138da94bd20acaec9864f81906dc850` records598 tracked-file SHA256 values and passes the complete **464-test suite with0 failures**. XCTest elapsed16.023 seconds; guarded build/test command28.169 seconds, no timeout. An explicit actual application build on the same scratch source passes (incremental command0.475 seconds, no timeout). These command durations are verification timings, not launch or editing benchmarks.

Commands inside that source snapshot:

```sh
scripts/swift.sh test --scratch-path .build/integrated
scripts/swift.sh build --scratch-path .build/integrated
```

The full test command was supervised by a private owned-process watchdog because it includes adversarial regex. Source provenance and raw watchdog results remain ignored locally. This does not establish an in-app regex deadline or substitute for the planned checked-in helper lifecycle harness. Request/response implementation, desktop acceptance and the packaged helper remain outstanding. No package was promoted during this verification.

## Sequential request path — 2026-09-10

Task3A source `f59522219c5698c66ec53045343bb8eef8a51e2c`, corrected by `2a7616829180bd55d437f57f245a459639343d30`, implements bounded request metadata, hello/request writing and the sequential request reader. Independent specification/quality re-review approved the correction with no remaining findings. The writer builds and returns the exact identity-bound index from its emitted UTF-16 chunks, validates scope before execute, and returns only after execute emission succeeds. The reader validates identity/ordinal, metadata, UTF-16, scope and acknowledgement phases before accepting another request.

Initial checks pass: **28 request tests,19 framing regressions and20 UTF-16 regressions**, all with0 failures. The SearchExecution target build, strict scoped formatting, public-source pattern and whitespace checks pass. Root independently checked all three final source hashes against the implementation report.

```sh
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireRequestTests
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireFrameTests
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireUTF16Tests
scripts/swift.sh build --scratch-path .build/search-wire --target SearchExecution
```

Tests cover independent metadata bytes, bounded chunk writes, wrong lengths, malformed text, scalar scope, replayed/skipped ordinals, exact acknowledgement, callback failures/reentry and partial EOF. The principal short-input behavioral regression first returned invalidPhase at the compiling seam, then passed with lengthMismatch and no execute callback. An expanded fixture caught an external sink error incorrectly escaping as reader validation; that classification was corrected. A later regression proved that execute followed by a partial next header could return success and drive provisional work. The correction rejects those same-consume suffixes with invalidPhase and poisoned acknowledgement; all31 partial-header lengths now invoke no simulated engine. Later-arriving bytes cannot undo work scheduled after an earlier successful consume. A write-then-throw execute sink returns no index and receives no later call; no byte rollback is claimed.

Final SHA256 values:

- Types: `e7be9b26c5fa3d110d45d623529392acd6038815d6587bad2af975f1893757f8`.
- Request codec: `c7132e4740ecc00b5ddc390bc04284ae488685a067e768434d95b3480177477a`.
- Request tests: `d2c9529b9a41d15661321f44715b116921e1386dfca669b257947ecec7f8e081`.

Missing-API compilation was recorded separately from behavioral red. Raw check output remains in tool transcripts; no separate logfiles were retained for this task. Response/terminal codecs, helper execution, containment, allocation policy, native/folder routing and packaged acceptance remain outstanding. The earlier464-test integration snapshot does not include this request implementation.

Independent review found that input callbacks reentering the request reader could be normalized by the UTF16 decoder to sinkRejected, which incorrectly took precedence over the reader’s own failed state. Two new regressions first failed with exactly that mismatch, then passed after the containing failed state was checked first. Final request suite: **30 tests,0 failures**; strict scoped formatting/public-source/whitespace checks pass. Unchanged framing/UTF16 suites were not repeated for this ordering-only fix. Root verified final source and retained red/green log hashes and inspected their result summaries. The correction logs remain ignored locally, and scoped re-review approved I1 with no new findings.


## Sequential response path — 2026-09-10

Task3B source `869de1f7e26190f8d70baa128f501dffa41c2a94` implements response/terminal values, bounded response writing and sequential response reading. Independent specification and quality review approved this scope with no confirmed implementation findings. The reader validates request/index identity, ordinal, scalar/scope/range ordering, body shape, replacement UTF-16 and terminal status. It defers completion until its enclosing frame consume succeeds without trailing bytes. The writer validates signed ranges and body shape before responseStart, writes bounded batches, and emits terminal separately. Shared binary helpers moved to Types; request-codec changes are scoped to mechanical helper use.

The implementation report records **28 response,30 request,19 frame and20 UTF-16 tests, all with0 failures**, plus the SearchExecution target build, strict scoped formatting, public-source and whitespace checks. Raw command output remains in the private execution transcript; separate raw logs were not retained. Root verified the four source SHA256 values:

- Types: `2e4371b215fec840a498ab3686afde485bd1f30689743414b1ba05beb204674d`.
- Request codec: `c69e5a559deea4824f8c2f8e3d8166c5a88dbc01c180d56763efd980c1392cac`.
- Response codec: `c5f75540fd1b847111fbc37d57938709669607edcea7ccbf5dc087cbff38e49d`.
- Response tests: `64b0a246f2275d67bec12e6c0c4b058738b94b54ec5d020d6c62033677b337fb`.

```sh
scripts/swift.sh test --scratch-path .build/search-wire --filter SearchWireResponseTests
```

Tests include fixed ABI bytes, all semantic terminal statuses, partial-body failure discard, signed writer preflight, scalar/range/scope validation, UTF-16 errors, callback refusal/reentry, ordinal reuse/exhaustion, and ready-phase partial trailing frames. Four benign Foundation zero-length controls returned the exact planned range order. No sorting or relaxed comparison was introduced.

Process limitation: the initial red was missing-API compilation. After implementation, the sole initial failure was an incorrect test expectation (malformedUTF16 instead of required lengthMismatch for short replacement on early success). Correcting that oracle was not a production fix. No compiling behavioral red preceded implementation; the report preserves that gap without manufactured history.

Semantic wire integration, real helper execution, cancellation/deadline containment, memory measurements, native/folder routing and packaged desktop acceptance remain outstanding. The earlier464-test committed-source run predates both request and response implementations. Current distributable artifacts remain source55a7b1b.


## Semantic handoff and integrated source — 2026-09-10

Task4 `e04f4660719927c4ed81f2c8bf05c6495e171e61` adds nine benign semantic integration tests. Independent specification/quality review approved without findings. The real request writer/reader, returned boundary index, one actual SearchService.execute/Framework enumeration, response writer/reader and separate terminal/ack sequence preserve fixed capture/literal/escaped/scoped/zero-length/surrogate/Unicode results. Tests distinguish nil and empty replacement and verify semantic error followed by same-generation ordinal reuse. The first run was green over approved APIs; no production defect or fabricated red is claimed.

Focused semantic9/0 and all-wire106/0 pass, along with target build, strict recursive formatting, public-source and whitespace checks. Root verified source SHA256 `ddbb1171b6d9f0b1cd5644a9888682f26034f23db1702adb829906967f411131`, retained raw-log hashes and actual summaries. An initial formatter invocation lacked --recursive and exited64; the corrected invocation passed without diagnostics.

A clean detached snapshot at that commit records605 tracked-file hashes. Its complete **531-test suite passed with0 failures** (15.731 seconds XCTest,29.544 seconds guarded command, no timeout). The actual application build also passed on that snapshot (incremental0.508 seconds, no timeout). Commands were `scripts/swift.sh test --scratch-path .build/integrated` and `scripts/swift.sh build --scratch-path .build/integrated`, supervised by the existing private owned-process harness. Timings describe verification, not UI or performance benchmarks.

Raw provenance and results remain ignored locally. This completes the bounded wire plan; it does not implement the helper lifecycle/runtime, memory policy, hard cancellation, native/folder routing or a packaged helper. Existing packaged desktop verification concerns source55a7b1b, which predates the search changes.
