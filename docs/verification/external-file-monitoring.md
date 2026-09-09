# External file monitoring: component verification

Status: the bounded file probe and pure conflict-state reducer are implemented in PadCore and tested. The watcher service, document integration, conflict controls, rename/Locate transactions and packaged desktop workflows are outstanding. A-07/A-08 are not complete. No original-file autosave or automatic reload is introduced.

## Probe

`Sources/PadCore/ExternalFileProbe.swift` observes local regular files without writing them, compares exact bytes in bounded chunks, refuses oversized/unsafe targets, revalidates file and parent identities, and provides an admitted read against a previously offered observation. Cancellation and the two-second deadline are cooperative between syscalls; they do not interrupt a blocked kernel operation. The content cap is100,000,000 bytes.

The first isolated real same-size atomic replacement test failed two intended observation assertions while confirming disk bytes remained intact. Further reds caught missing admitted-read bytes and unsafe reuse of a previous matching observation against different expected bytes. The latter optimization was removed. `forceContents=false` currently still compares bytes (or uses a conclusive length mismatch); metadata-only polling is not implemented and must not be advertised by the later service.

Independent review found signed Darwin device identifiers could trap during conversion to UInt64. The retained boundary test reproduced signal5, then passed after preserving the32-bit identifier pattern. Root review also found revalidation permission failures misclassified as file/parent changes. Real owned-parent mode revocation at entry validation and parent reopen reproduced two inaccessible-state failures; syscall-error classification now preserves EACCES/EPERM without accepting mismatched metadata or identities.

The final isolated suite passed30 tests with no failures/skips in0.058seconds. It covers same/changed bytes, atomic and in-place replacement, exact100MB observe/read, oversized refusal, missing/FIFO/final symlink, parent retarget/recreation, read-only and revoked access, restored timestamps, partial/EINTR/EIO reads and descriptor cleanup, cancellation/deadline, and injected unsupported-volume refusal. Injection is distinguished from real filesystem cases in test names/source. No physical network-volume or kernel-stall cancellation guarantee was demonstrated.

Private raw chronology is retained under `.local/external-file-monitoring`: first replacement red `run.8olval6u`, read red `run.sho5pu9g`, unsafe reuse red `run.mempro_z`, signed-device crash `run.ev8mre7o`, permission reds `run.hwk523y9`, final isolated green `run.0xwp3sua`. These are local references, not public diagnostic exports.

## Conflict-state reducer

`Sources/PadCore/ExternalFileState.swift` accepts only the live latest-issued document/epoch/baseline/sequence token and rejects duplicates. It keeps permissions separate from content and takes dirty/pending-publication status from the caller; it cannot clear either authority. Its action table refuses unsafe/incomplete reads and enforces save/composition/recording/close/quit guards. Notice deduplication compares metadata/facets, not the identity of differing bytes.

The initial compiling seam failed the current changed/read-only observation test with five assertions. Implementation then passed21 cases. Review replaced sequence-only dismissal with full-token dismissal: stale-epoch and stale-baseline regressions failed before the fix, and the expanded24-case suite passed. A stale notice action cannot dismiss a newer observation merely because its sequence number is reused. The native service still must supply the actual live token at acceptance; passing an old callback token as both arguments defeats that caller contract.

Private reducer evidence remains in `.local/external-file-state` (`red.log`, `green.log`, `dismiss-red.log`, `dismiss-green.log`). No service event or native action callback is claimed from these pure tests.

## Production integration

Root copied the independently reviewed components and54 tests, formatted them, and changed the probe's preparation-only comment. `scripts/swift.sh test --scratch-path .build/external-file-integration` exited0 in session60659:258 tests, zero failures,8.787seconds case time. The application target also compiled. No compiler warnings/errors were found in the retained log. Repository Swift-format, public-source patterns and diff checks passed. The AppKit sources were unchanged, so this checkpoint did not repeat the native or packaged desktop suites.

Focused reproduction after building the integrated checkout:

```sh
scripts/swift.sh test --filter ExternalFileProbeTests
scripts/swift.sh test --filter ExternalFileStateTests
```

These are component tests, not proactive monitoring acceptance. The local distribution still predates this component integration. Desktop automation continues to require macOS user authentication; no security settings or credentials were changed.


## External reload decoder (component verified; UI integration pending)

`ExternalDocumentDecoder` is a separate BOM-first interpretation policy for forthcoming reload and disk-copy actions. Supported UTF-8/UTF-16 BOMs override the saved encoding; BOM-less bytes use the saved encoding. Four-byte UTF-32 signatures are refused before shorter UTF-16 detection, including ambiguous UTF-16 BOM plus initial NUL prefixes. Explicit Reopen with Encoding still uses the unchanged `DocumentCodec` policy.

The isolated forwarding seam produced five tests with 28 expected assertion failures. The implementation then passed all five tests, including exact LE/BE and legacy-to-UTF-8 BOM round trips, BOM-less fallback, malformed marked Unicode refusal and unchanged explicit interpretation. A private-helper access compile error was corrected without exposing or changing the existing codec API. Independent review found no material issue and requested clearer ambiguous-prefix wording plus specific error assertions; those refinements and the source/tests are integrated. Full production core session 48984 passed 263 tests with zero failures in 9.062 seconds. Repository formatting and public-source checks passed; formatter sandbox access initially failed before native execution succeeded. The native reload/disk-copy call sites are not wired yet. Raw evidence remains in `.local/external-decoder`.


## Dataless-materialization guard (component verified; call sites pending)

The local-volume assumption was reviewed before watcher integration. A new synchronous thread-scoped guard is now in `Sources/PadCore/FileMaterializationGuard.swift`; it is not yet wired into the production probe or watcher. No cloud account, credentials, provider files or process-wide policy change was used.

The compiling forwarding seam failed seven tests with eleven intended assertions. Implementation passed those tests; two additional tests verified an exact synthetic-file read under the disabled policy and unchanged process policy. All nine isolated tests passed. Independent review found no material defect in the synchronous contract; it explicitly retained restoration-failure and partial-resource cleanup limitations. Full production core session 39762 then passed 272 tests with zero failures in 8.841 seconds. Raw evidence remains ignored in `.local/dataless-policy`.

The guard handles nested calls, successful and throwing work, failed policy lookup/setup, and restoration failure with disposal of a successfully returned resource. The watcher/probe integration still needs its own boundary, error-classification and FD-cleanup tests; no dataless-safe monitoring or real cloud-provider acceptance is claimed from this component alone.

## External action reads (component verified; scheduling and UI pending)

`ExternalFileActionReader` reads only against an admitted `DiskObservation`, under the synchronous materialization guard, and retains immutable exact bytes, decoded content, original URL and observation. It applies the separate external BOM policy. Confirmation revalidation reads that same source against the original identity/metadata and requires exact byte equality with the retained snapshot. No method writes a file or changes a document. Cancellation is checked around read and decode; decoding and individual kernel calls are not forcibly interruptible. The API must run on a bounded background worker. Shared monitor-worker admission and live native transaction guards are still outstanding.

A compiling throwing seam produced seven tests with six failures (session50644); the preceding sandbox build-file access failure was not a behavioral red. Implemented checks passed seven tests (88029). Fresh full core session27128 passed279 tests, zero failures,8.802 seconds after formatting. Independent source review found no material flaw. Public-source and diff checks passed. Raw logs are ignored `.local/external-action-reader-*.log`; builds used a separate scratch directory without modifying agents' shared link artifacts.

Real temporary files cover exact UTF-16BE bytes/BOM overriding legacy encoding, BOM-less legacy decoding, changed inode after observation, invalid bytes, explicit cancellation, and a second change before confirmation. The second-change test rejects through metadata; it does not separately exercise byte inequality with perfectly preserved metadata. Cancellation during decoding and UI confirmation are not tested here. These seven tests do not prove integrated reload, disk-copy, thread admission, or desktop behavior.

## Monitor service integration into PadCore

The frozen isolated service, guarded probe and41 tests were copied into PadCore with module imports adapted and repository formatting applied. The existing guard implementation was retained. Fresh full core36313 passed320 tests, zero failures in14.563 seconds, with no compiler warnings. Initial formatting lint found nine test-only `forEach` style violations; these were converted to equivalent loops and focused run68928 then passed all41 monitor tests, zero failures in5.377 seconds. Final strict repository formatting passed. This integrates the service implementation, not its application ownership, native UI, or packaged behavior.

The service caps registrations at128, shares two filesystem workers and at most16 manual requests, coalesces registered deliveries, and retains manual admission until queued callbacks drain. Watch/prepared/retired/borrowed descriptors are counted; close-only cleanup stays worker-owned and unconditional. Vnode events, debounce, periodic exact-byte reconciliation, watch replacement, conservative rename hints, explicit one-shot checks, and cancellation have synthetic real-file and injected scheduling coverage. Periodic checks still compare bytes, not a metadata cache. A blocked syscall can occupy a worker indefinitely; no hard cancellation deadline is claimed.

The final isolated run `run.3ozoauto` passed41 tests with no warnings. Preserved reds include watch-startup races, concurrent cancel/rebind, callback backlog, duplicate manual completion ownership, cancelled callback retention, manual parent continuity, policy boundaries, immediate stop fencing, and atomic first-binding transfer. The latest continuity red `run.5_wlqi_z` failed two assertions before the fix: losing a parent binding before first callback, and allowing equal bytes under a retargeted parent on Retry Monitoring.

`cancelAndSnapshot` atomically freezes registration context and its retained identity. The receipt includes document, epoch and baseline revision even before a token exists. A retry can explicitly carry that identity into registration. Rebind resets it only with the replacement context; failed rebind leaves the old revision distinguishable. Stop immediately fences both registration snapshots and manual result admission independently of a delayed control queue. Callbacks already admitted before stop cannot be recalled.

The public probe now guards standalone observe/read calls, propagates typed policy failures, and reports materialization refusal as not-downloaded. Registered worker transactions do not install prepared watch resources before successful policy restoration; restoration failure disposes them. Tests cover nested failures and borrowed-FD cleanup. No real cloud provider, ACL matrix, physical desktop, or all-platform acceptance is implied.

Raw service evidence remains ignored in `.local/file-monitor-service`; production integration logs are `.local/file-monitor-production-*.log`. The original frozen hashes and exact staged evidence are retained locally. No dependency, telemetry, original-file write, automatic reload, signing or publication was added by this integration.
