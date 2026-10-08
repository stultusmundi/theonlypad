# Production worker accumulator verification — 2026-10-08

## State and scope

Planned: a concrete, strict worker input accumulator behind the existing package protocol.
Implemented: `SearchWorkerUTF8Accumulator` stores only valid, complete-scalar UTF8, accounts for declared UTF16 units, refuses malformed/excess/incomplete input, and cannot be reused after finish or failure. It preserves initial/interior U+FEFF, NUL, decomposed text, supplementary scalars and line endings. Data ownership ends on finish/refusal; this does not establish physical reclamation or secure erasure.
Tested: the actual component plus real wire reader, collector, runtime and Foundation search adapter pass the bounded tests below. Independent specification and quality review approve the exact final source; no blocking findings.
Remaining: checked lifetime startup, helper executable/packaging, production parent defaults/response binding and editor routing. No actual helper process, hard regex cancellation, RSS/allocation, performance, desktop, Intel or macOS14 runtime acceptance follows from these tests. The editor still uses its in-process service. The prior local app package is the binary-admission checkpoint; this module slice does not create a new distribution artifact.

## Architecture and limits

The constructor accepts0...100,000,000 UTF16 units, matching existing wire limits, without reserving the declared size. Each append is at most65,536 bytes and must end on a scalar boundary. Strict standard-library transcoding counts UTF16 units before storage; valid stored content is at most three times declared units. The byte ceiling is a defensive invariant implied by strict valid UTF8 and unit accounting, not an independent heap/RSS bound. Data capacity, temporary materialization, engine/response/parent owners and total process memory are excluded.

Final bytes are strictly revalidated with exact count before native String materialization. The public runtime, collector, protocol, fixed engine and application routing are unchanged. Swift6 toolchain in Swift5 mode, macOS14 deployment floor, Foundation/Swift standard library, no external dependencies or assets. Original code remains MIT licensed.

## Actual results

| Verification | Result | Scope |
|---|---|---|
| Initial compilation | Expected missing interfaces plus an unexpected macOS15-only API finding | Zero test methods executed; retained setup failure |
| Compiling minimal component shell | 29tests/115 intended assertions/0unexpected | 20unit tests/84 assertions;9runtime tests/31 assertions; this transient shell is not an older production baseline |
| Implemented component, before formatting | 29/0 | Concrete unit and real runtime integration |
| Formatted `SearchWorker` selection | 119/0 | New29 plus existing worker/resolver neighbors, including existing tiny-pipe controls |
| Full formatted app/core suite | 881/0 | App built through SwiftPM; broad existing tests guarded by owned watchdog |
| BOM-stripping mutation | 1test/1 intended assertion/0unexpected | A frozen copy changes only final materialization to Foundation String(data:encoding:); literal expected units detect the lost initial U+FEFF |
| Strict format lint, public-source and diff checks | Pass | Source hygiene only |

The initial design used `String(validating:as:)`, which the compiler rejected at the macOS14 floor. Keep that failure in the record. The corrected binding uses strict standard-library `transcode` with `stoppingOnError:true`, then materializes only private validated bytes. Scoped independent SDK source review confirms the signature, true-on-error behavior and lack of a macOS15 availability gate. Tests compiled at the declared floor on ARM64 macOS26.6.2/Swift6.3.3; running on macOS14 remains untested. The test response sink was corrected independently without changing any literal oracle.

## Behavioral coverage and provenance

Twenty unit methods cover ordered ASCII chunks, three-byte BMP and supplementary unit counts, decomposed accents, exact U+FEFF/NUL/endings, empty documents/appends, metadata overflow, twelve malformed UTF8 rows, direct split-scalar refusal,65,536/65,537 boundaries, aggregate overrun, early/duplicate finish, poisoned/finished reuse, maximum declaration with tiny input and nonzero-index Data slices.

Nine runtime methods use the concrete factory, actual wire reader/collector/runtime and fixed Foundation engine. Unicode find ranges and capture replacement text are literal expectations. No-match replacement checks literal UTF16 units. Bad regex is a semantic terminal followed by a healthy request; empty replacement succeeds. Literal high/low surrogate payloads cross separate real wire frames. Malformed/truncated/coalesced input refuses engine invocation. Weak accumulator owners are present during response body and absent before terminal and the next read; this is object lifetime only.

Root verified unchanged membership and hashes for371 initial compiler inputs and372 inputs for each later component/regression/full invocation, with exact-command watchdog receipts, complete captures, consuming wait and owned-group cleanup. The BOM control has240 frozen package inputs and exactly one declared source mutation; the original production source is unchanged. Its failure is the literal missing initialFEFF unit, not compilation or infrastructure. All successful builds are warning-free. Raw diagnostics, sealed source reviews and synthetic mutation packages remain ignored.

## Commands

These inner SwiftPM commands were executed under the checked-in direct owned-process watchdog:

```sh
scripts/swift.sh test --scratch-path .build/worker-accumulator --filter 'SearchWorkerUTF8AccumulatorTests|SearchWorkerAccumulatorRuntimeTests'
scripts/swift.sh test --scratch-path .build/worker-accumulator --filter SearchWorker
scripts/swift.sh test --scratch-path .build/worker-accumulator
```

The broad suite uses a600-second outer guard because neighboring regex tests are adversarial. Use a fresh output directory with `scripts/run-owned-search-tests.py`; never nest it around a coordinator that already owns a watchdog. Desktop automation is separately awaiting user-owned system authentication; no grant or visible workflow result is inferred.
