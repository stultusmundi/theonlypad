# Recovery resource bounds

Implemented 2026-09-09. Existing same-user/private-directory, no-follow regular-file checks, checksums, atomic save behavior, revisions and close tombstones remain. No network or extra dependency was added.

## Defect and change

Previously `readIfPresent` used unbounded `readToEnd` for load, save's previous version, and even removal. Directory loading collected and sorted every entry, and the coordinator listed the directory again to count old quarantine files. A synthetic sparse 64 MiB malformed JSON file increased peak RSS by 67,321,856 bytes before quarantine.

Reads now reject a file above the serialized limit using `fstat`, then read chunks of at most 1 MiB with a cumulative limit and one-byte growth probe. No giant preallocation. Directory inventory uses bounded `readdir`, retains only capped candidate metadata, and sorts that bounded set. Startup also bounds cumulative bytes read and decoded text retained. Metadata-only removal avoids content reads. Only new corruption is counted in `loadReport`; the coordinator no longer performs a second unbounded inventory.

Oversized valid data and unprocessed later files stay at their original paths. Resource exhaustion throws an actionable error, not a corruption classification. Invalid schema/UUID/checksum or malformed data still moves to a unique `.corrupt` name. Aggregate overflow aborts the startup claim; original valid snapshots remain on disk and a retry remains possible.

## Default limits and tradeoff

- Per snapshot: 100,000,000 UTF-16 units; original-path metadata at most 4,096 UTF-16 units.
- Encoded envelope and cumulative startup input: 600,032,768 bytes.
- Restored text/session quota: 100,000,000 UTF-16 units total.
- At most 128 JSON candidates and 4,096 total directory entries.

The text limit accommodates a 100 MB ASCII/legacy document and UTF-16 decoding within that code-unit budget. JSON can escape one control character into six ASCII bytes; the serialized cap includes that worst case and bounded path/envelope metadata. This deliberately high but finite ceiling is not a low-memory guarantee: decoding and checksum encoding can still require large transient allocations. No 600 MB peak-memory benchmark was performed. Many large unsaved buffers can exceed the session quota; the application must require ordinary saves rather than claim all can be recovered.

## Preventing an unrestorable successful quit

The shared serial coordinator initializes size accounting from bounded recovery loading. Before persistence it checks total decoded text and snapshot count, subtracting the replaced snapshot's previous size. The store checks candidate count, available directory-entry slots, and total serialized bytes from file metadata before the atomic save. Failed saves do not update quotas or revision state; clears/closes release quota. Errors propagate through the existing recovery flush/quit-veto path.

Decoded aggregate accounting assumes the application's single serial coordinator owns writes. Independent processes modifying the same recovery directory can invalidate cached accounting; this is not an interprocess locking implementation. Existing app launch design avoids creating a second instance with shared state. Standalone RecoveryStore callers receive file/count/serialized limits, while the coordinator adds the decoded session quota.

## Verification

First isolated tests failed on missing bounds APIs. Five new RecoveryBoundsTests then passed alongside eight existing DocumentFileStoreTests: 13 tests, zero failures. Cumulative-read regression failed with that guard removed and passed restored. Source/tests were copied into the main package only after isolated green; no main build was run by this task during the root compile window.

The retained native RecoveryHarness passed against the isolated coordinator/core. It verifies ordering and tombstones, new-only quarantine reporting, preservation of a sparse file one byte beyond the default envelope cap, retry after removing that fixture, aggregate save rejection, replacement quota subtraction, count rejection, quota release on close, and a fresh coordinator restoring the accepted state. Removing the coordinator quota guard made the aggregate assertion fail; guarded code passed. Fixtures are synthetic and cleaned up.

Root reruns the combined build/native suite after this handoff. Tests use injectable smaller RecoveryLimits for most boundaries. The large sparse-file test exercises early metadata rejection, not a full-size allocation. No physical crash, large accepted-payload performance run, filesystem race stress, or interprocess coordination claim is made by these new tests.

## Follow-up: quota ordering across a batch

A native probe reproduced a quota-ordering stall: persisted A=60/B=40 under a 100-unit quota, followed by current A=80/B=20, failed forever if A was attempted first and the caller aborted before shrinking B. Final content fit, but its intermediate order did not.

`RecoveryCoordinator.persistBatch([(UUID, UInt64, RecoverySnapshot?)])` now accepts at most 4,096 entries, coalesces each UUID to its highest revision (last input wins equal revisions), ignores stale/tombstoned entries, completes all clears first, then attempts text-size shrinks before growth. Other writes continue after a failure. Quota failures receive one bounded retry after successful progress, since escaped JSON size and decoded text size can move in opposite directions. Unresolved errors propagate; there is no silent discard or unbounded retry loop. Invalid UUID/payload pairs report errors while other cleanup proceeds.

The retained native recovery harness first failed on the missing API, then passed order correction, cleanup despite an oversized write, revision coalescing, and a serialized-byte retry scenario. Existing ordering/tombstone/oversize/quota assertions remain. Root owns batching all frozen windows together at quit; independent per-window short-circuiting would not resolve cross-window quota dependencies. Multidimensional cyclic quota swaps may still fail conservatively rather than temporarily violating durable limits. This is ordered persistence, not an atomic multi-file transaction.
