# Production worker text accumulator implementation plan

> For agentic workers: use superpowers:subagent-driven-development for bounded source work and independent review. Root exclusively owns serial runtime verification.

**Goal:** Provide a strict, bounded concrete worker text accumulator and prove its integration with the existing worker loop.

**Architecture:** One single-lane Data accumulator implements the existing package protocol. Strict scalar-aligned UTF8 append validation accounts for declared UTF16 units; successful or failed finalization discards its buffer owner.

**Tech Stack:** Swift6 toolchain in Swift5 language mode, Foundation, XCTest; no external dependencies.

**Spec:** `docs/superpowers/specs/2026-10-08-worker-text-accumulator-design.md`

## Global constraints

- macOS14 minimum; Swift5 language mode.
- Declared UTF16 range0...100_000_000; chunk bytes at most65_536; stored content at most3 times declared UTF16.
- Strict decoding; preserve U+FEFF/NUL/Unicode/line endings exactly; no normalization or replacement.
- No eager declared-size reservation, concurrency, limit changes, RSS claims, helper/editor activation or remote publication.
- Synthetic documents only; raw runtime diagnostics ignored; compiler and runtime serially owned by Root.

## Task1: Accumulator contracts

Files: create `Sources/PadSearchWorkerRuntime/SearchWorkerUTF8Accumulator.swift` and `Tests/PadSearchWorkerRuntimeTests/SearchWorkerUTF8AccumulatorTests.swift`.

Consumes: `SearchWorkerTextAccumulator.appendUTF8(_ bytes: Data) throws`, `finish() throws -> String`. Produces: `SearchWorkerUTF8Accumulator.init(declaredUTF16: Int) throws`, implementing both methods; the five error cases in the spec.

- [x] Write literal behavioral tests. An initial example is:

```swift
let value = try SearchWorkerUTF8Accumulator(declaredUTF16: 4)
try value.appendUTF8(Data([0x61, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80]))
XCTAssertEqual(try value.finish(), "a€😀")
XCTAssertThrowsError(try value.finish())
```

Include independently literal malformed byte tables and exact UTF16 declarations for all acceptance cases. Tests catch repair decoding, wrong UTF16 accounting, accepted partial data and failed state transitions. Initial missing-symbol compiler RED is recorded separately; add only a minimal compiling implementation shell after observing it, then observe genuine behavioral RED before implementing behavior.

- [x] Root runs `scripts/swift.sh test --scratch-path .build/worker-accumulator --filter SearchWorkerUTF8AccumulatorTests` through `scripts/run-owned-search-tests.py --timeout 240 --output .local/worker-accumulator-red-owned -- ...`. Existing watchdog command receives the test command following `--`; retain complete receipts and explicit failures.
- [x] Implement receiving/finished/failed states, bounded metadata, strict standard-library `transcode(bytes.makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: true, into: { _ in units += 1 })` validation/counting; only after success materialize with `String(decoding: bytes, as: UTF8.self)`, subtraction bounds, exact finish and buffer-owner discard. Any rejected append/finish enters failed state. Do not add test accessors or public factories.
- [x] Root reruns the same filter with a fresh green output directory; require zero failures and no warnings.

## Task2: Real worker integration

File: create `Tests/PadSearchWorkerRuntimeTests/SearchWorkerAccumulatorRuntimeTests.swift`. Production runtime, collector, reader, writer and engine stay unchanged.

Consumes: concrete initializer above, `SearchWorkerRuntime(generation:channel:makeAccumulator:engine:)`, `FoundationSearchWorkerEngine`, real wire writer/frame decoder. Produces: independently observable Unicode output/ranges, malformed-wire refusal, sequential ownership and semantic-error recovery tests.

- [x] Author real wire fixtures from literal UTF16 payloads where split-surrogate behavior is the subject. Use literal expected text/ranges, not decoding helpers to compute expectations. Use real fixed engine for find/replace/error behavior; a narrow engine spy is allowed only to prove malformed input never invokes execute.
- [x] Root runs the combined `SearchWorker` filter under the direct watchdog in fresh output directories. Integration tests written after the concrete component need not falsely claim prior missing-accumulator RED; use a discriminating mutation control for malformed input/ownership where meaningful.
- [x] Independent reviewer checks spec coverage, strict Unicode preservation, bounds, state poisoning, error origin, logical release scope and no altered production routing. Resolve important findings with scoped reruns.

## Task3: Evidence and local checkpoint

Files: create `docs/verification/search-worker-accumulator.md`; update `docs/continuation.md`, `AGENTS.md` and this plan with actual commands/results.

- [x] Run the fresh integrated suite through direct watchdog, strict swift-format lint, public-file check and git diff check. Use a fresh240s focused/600s integrated guard, never nesting coordinators.
- [x] Record planned/implemented/tested/remaining independently. Do not infer full feature completeness, actual helper process, memory or desktop evidence.
- [ ] Make a scoped local commit after verified source review/checks. Continue next with checked lifetime startup/helper assembly; local checkpoint is not a request to stop.

Actual verification: component29/0, formatted worker/resolver119/0, full app/core881/0. Independent SPEC and QUALITY approve exact sources with no blocking findings. Retained compiler availability failure and behavioral29/115 RED remain separate; frozen BOM mutation fails1/1. No helper/editor/RSS/desktop acceptance. Local commit is the remaining checkpoint operation.
