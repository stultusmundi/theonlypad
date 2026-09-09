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
