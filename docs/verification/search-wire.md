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

UTF-16 streaming, request/response phases, real helper execution, deadline/reap containment, memory accounting and native/folder routing remain outstanding. Framing tests do not validate those properties or desktop/packaged behavior. No dependency was added; the app does not yet depend on SearchExecution. Current local distributable artifacts still contain source55a7b1b.
