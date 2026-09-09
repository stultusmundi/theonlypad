# Checkpoint cost measurements

Measured on Apple M4 Pro, 48 GiB RAM, macOS26.6.2 (25G83), arm64, Swift6.3.3. Release PadCore and optimized native harness. Command: `scripts/benchmark-checkpoints.sh`. Three serial samples per size, fresh process per size, short-line ASCII, exact decimal byte sizes. Raw local run: `.local/checkpoint-benchmarks/run.thh6Wr` (ignored).

| UTF-8 bytes | MainActor capture ms, runs1/2/3 | Awaited actor publication ms, runs1/2/3 | Process peak RSS bytes at last sample |
| --- | --- | --- | --- |
| 1,000,000 | 0.034 / 0.005 / 0.006 | 52.713 / 43.346 / 42.667 | 117,194,752 |
| 10,000,000 | 0.027 / 0.009 / 0.006 | 428.166 / 421.006 / 431.673 | 226,246,656 |
| 100,000,000 | 0.030 / 0.008 / 0.007 | 4202.195 / 4278.234 / 4256.245 | 1,237,008,384 |

Every size completed all three captures/publications. The final recovery text matched exactly and the synthetic original file was unchanged. The first publication creates files; subsequent publications replace them. No filesystem-cache flush or privileged system change was performed.

Capture timing includes synchronous window text/metadata capture and immutable payload assembly. Normal edit refresh warmed dirty-state information first; native edit/setup costs are excluded. Swift/AppKit value sharing means these tiny capture times must not be interpreted as copying a 100 MB buffer for free or as measurements of the next edit's cost. Publication timing includes actor scheduling, validation, encoding, checksum work and filesystem waits; this run does not isolate those phases. RSS is process cumulative high-water including setup and previous samples, not incremental memory or a capture-only peak.

The approximately4.2-second 100 MB publication and1.24 GB process high-water require investigation. This does not change the original input-latency/open-time targets, and no performance requirement is marked complete. Three samples do not establish p95, statistical confidence, cold-launch, UI responsiveness, physical typing, long-line, Unicode, many-document, sustained-edit or packaged desktop performance. Existing 100 MB native editing latency misses remain outstanding.

Source inspection suggests where to profile next; it does not establish a dominant cause. RecoveryStore encodes checksum input and its envelope separately, hashes the first encoding, then writes and synchronizes the envelope and directory. Replacing an existing record also reads the previous envelope in RecoveryStore and at both AtomicFileStore comparison boundaries. The first100 MB publication avoids those old-record reads yet still takes4.202seconds, so those reads alone do not explain the result. Successful samples did not perform uncertainty readback, and final reload verification was outside the interval. Next isolate recovery versus session saves with the existing injection closures, then time encoding/hash/read/write/sync phases in an ignored instrumentation copy while preserving validation. Allocation profiling is needed before attributing the RSS high-water to any phase.
