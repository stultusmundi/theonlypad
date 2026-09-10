# Streaming core measurements — 2026-09-10

Status: measured Foundation byte-reader throughput and bounded window decoding. Desktop viewing, editor responsiveness and large-file feature acceptance remain separate and outstanding.

Run `python3 scripts/benchmark-streaming-core.py` from the checkout; `--smoke` runs one 1 MB child per shape. No dependencies beyond Python, Xcode command-line tools and the system SDK. The runner snapshots **committed HEAD** LargeFileReader.swift, not uncommitted changes, into a unique private ignored directory. It compiles that unchanged source with the retained benchmark harness using `swiftc -O -swift-version 5`. No production source changes or AppKit calls occur.

## Protocol and retained evidence

The full run used commit `da117a5bfac22b16ec82c477ba6c69b4547bd38c`; core SHA-256 `c4d15f310dfd6ead312e68105eaaa2515438893ae58332c056aee976908eb1d9`. Private evidence is `.local/streaming-core-current/run.10zuiz74`: environment/source hashes, compile status/log, fixture hashes, 24 stage-by-stage JSONL child logs, individual results and summary. Compilation exited 0 with an empty diagnostic log. A prior small smoke run passed both shapes. No failed or incomplete child occurred in this protocol.

Synthetic decimal sizes are 1 MB, 10 MB, 100 MB and 1 GB. Each size has CRLF-delimited ASCII rows and a pathological single ASCII line with no newline. Two 17-byte markers sit at the end of the file and across the 1 MiB search-chunk boundary (for 1 MB, the earlier marker is at midpoint). Fixtures are generated in bounded chunks by the supervisor, synced and SHA-256 hashed, then read by three fresh child processes each. Only the exact generated fixture is deleted after retaining its hash and all results; peak generated fixture storage is 1 GB. No system-cache purge or security setting changes occur.

Each child verifies exact 65,536-byte windows at start, midpoint and end, including a separately constructed offset-based byte oracle. It decodes only that window and verifies exact UTF-8 bytes and 65,536 UTF-16 units. Window timing includes read plus UTF-8 decoding, excludes oracle construction/comparison and JSON output. Full search timing includes the actual streaming search and excludes comparison/output; all 24 scans returned exactly the two expected offsets. Three windows per child yielded 72 exact window checks.

A cancellation closure requests cancellation on its fifth invocation; every child throws the actual cancelled error at that request. Timing from callback request to caught error measures synchronous cooperative unwind, **not** UI cancellation, asynchronous dispatch latency or interruption of a blocked kernel read. A separate search with result limit 1 verifies explicit overflow refusal. Every stage emits JSON before the next operation, and a 60-second owned-child watchdog preserves partial evidence on failure; compile has a 180-second watchdog.

## Environment and results

Apple M4 Pro, 14 reported CPUs, 51,539,607,552 bytes RAM; arm64; macOS 26.6.2; Apple Swift 6.3.3. Files are on the repository volume. Fresh generation, hashing and prior repetitions influence filesystem caches. Other agents could compile during this run; CPU/storage load was not exclusively controlled. These are neither cold-cache numbers nor a causal regression comparison with earlier reports.

| Shape | File bytes | Scan median s | Scan max s | Window + decode max ms | Child peak RSS max bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| rows | 1,000,000 | 0.000980 | 0.001003 | 0.0391 | 9,666,560 |
| rows | 10,000,000 | 0.009399 | 0.009557 | 0.0314 | 9,682,944 |
| rows | 100,000,000 | 0.092901 | 0.094695 | 0.0336 | 10,813,440 |
| rows | 1,000,000,000 | 0.933012 | 0.939659 | 0.0342 | 10,813,440 |
| longline | 1,000,000 | 0.000853 | 0.000866 | 0.0302 | 9,650,176 |
| longline | 10,000,000 | 0.007781 | 0.007873 | 0.0250 | 9,682,944 |
| longline | 100,000,000 | 0.082316 | 0.083283 | 0.0314 | 10,747,904 |
| longline | 1,000,000,000 | 0.795910 | 0.797007 | 0.0360 | 10,813,440 |

All 24 fresh children passed. Maximum service-open time was 0.1207 ms. Maximum cancellation request-to-throw time was 0.0205 ms; maximum cancellation-test duration to that deterministic request/throw was 0.2265 ms. No hard cancellation deadline follows from these observations.

RSS is Darwin `getrusage(RUSAGE_SELF).ru_maxrss` in bytes: each fresh child's high-water includes Foundation/runtime, window/oracle construction, decoded text and search allocations. It excludes Python fixture generation and preceding children, but is not a per-operation allocation delta or a universal ceiling. Maximum observed RSS was 10,813,440 bytes. Current algorithm source uses bounded windows/chunks, a pattern-sized prefix table and capped result offsets; this protocol uses a 17-byte pattern and two matches, not worst-case 1 MiB patterns or one million results.

## Limits against the brief

The earlier [large-file report](large-files.md) already covered all four sizes and single-line data with three same-process scans. This run adds fresh-child RSS, row-shaped fixtures, bounded decode checks and explicit cooperative cancellation evidence; it does not replace prior evidence.

ASCII fixture decoding does not establish arbitrary Unicode, invalid-byte, UTF-16 file or grapheme rendering behavior. Existing core unit tests separately cover overlaps, malformed inputs, mutation detection and seeded byte-search oracles; this benchmark did not rerun them. No scrolling, line indexing, native layout, UI search delivery, editor opening, editing, undo, recovery, physical input, memory-pressure simulation or packaged application was measured. The unchanged brief targets—2-second cold launch, ordinary input p95 below 50 ms, 100 MB usable editor within 5 seconds, and responsive 1 GB desktop viewing/search—are not satisfied merely by these byte-service timings. No GUI was launched while the console was locked.

## Supervisor interruption correction

Independent review identified a runner-only lifetime gap after the 24-run measurement: an exception during child waiting could leave its separately launched process group alive. `run_child` now kills and waits for its exact owned process group on unexpected exceptions, preserves the partial log, writes a sibling `.status.json` with the exception class and reaped exit state, then rethrows. Timeout cleanup also tolerates a child that already exited. This does not change measurement operations or the numerical evidence above; original runner hashes remain retained with that run.

`python3 scripts/test-streaming-supervisor.py` injects `KeyboardInterrupt` and `RuntimeError` into the wait for an actual harmless Python sleep child. Both cases first failed the assertion that the child had terminated; the test's own `finally` cleaned up those exact red-run children. Both then passed after the fix, including status-file and log-retention assertions. This is injected supervisor-exception coverage, not a physical terminal interruption or immunity to uncatchable process termination. Private evidence: `interruption-red.log` and `interruption-green.log` beneath `.local/streaming-core-current`.

Final unchanged-harness smoke `run.56zadx9e` compiled and passed both 1 MB shapes with the revised runner. No full measurement repetition was needed for this cleanup-only change; the 24-run results retain their original source provenance.
