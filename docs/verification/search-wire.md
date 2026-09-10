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
