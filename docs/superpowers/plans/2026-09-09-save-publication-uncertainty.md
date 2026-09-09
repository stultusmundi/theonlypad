# Save publication uncertainty and destination identity plan

Status: planned after bounded source/test review; no production implementation, new test execution, actual disk exhaustion, or crash test is claimed. Preserve concurrent editor/checkpoint work and obtain the root source handoff before changes.

## Confirmed behavior and scope

`AtomicFileStore.save` ignores the final directory `fsync` result after rename. The native save path then adopts destination/originalBytes/savedText/encoding, marks the document clean, and schedules recovery, which can clear its recovery snapshot. A post-publication I/O failure therefore becomes indistinguishable from acknowledged success. Do not change this into the equally incorrect claim that the original file was untouched.

`SessionStoreError.committedButNotSynced` already distinguishes this state for Session.json. The checkpoint candidate additionally blocks publication until readback and requires a fresh successful save for a receipt. Reuse that distinction, while keeping document-save retry state separate from session/checkpoint state.

A second destination-identity gap exists: the file store resolves and pins the parent directory once, then uses descriptor-relative operations without verifying that the requested pathname still resolves to that directory. Renaming/replacing the parent or retargeting a parent symlink can make the save succeed in an old directory while the editor retains a different visible pathname. Existing ordinary-writer last-check/rename races remain a documented limitation; this plan does not promise a cross-process compare-and-swap.

## Existing evidence and limitations

- DocumentFileStoreTests covers static stale expected bytes, existing create-only destinations, empty files, mode0640, static leaf symlink/read-only refusal, sparse-file growth, and injected before-write/after-write/before-replace/ENOSPC failures. It checks original bytes and temporary cleanup.
- Injected ENOSPC happens before any payload write. There is no injected partial-write, file-sync, final directory-sync, parent-retarget, or abrupt-process-exit save test. Existing tests must not be described as real full-disk/power-loss evidence.
- NativeUIHarness verifies successful encoded save and exact prior-byte backup capture. BackupStoreTests cover private-store integrity and quota refusal, but no native save-failure integration assertion currently verifies dirty state, URL adoption, recovery retention, or backup-failure propagation.
- Native backup creation occurs before AtomicFileStore checks the destination and captures the previously loaded expected bytes. It protects that known baseline; it cannot recover an independent writer's raced-in bytes. Backup quota/failure already throws before touching the destination. ACLs, xattrs/Finder tags and hard-link relationships remain separate known preservation limits.

## 1. Establish failing deterministic core regressions

Add a narrow injected filesystem-operation seam or extend SaveFault with explicit partial-write, pre-replace synchronization, post-rename directory-sync, and parent-change boundaries. No real disk exhaustion or global filesystem modification is required.

- Partial payload write then ENOSPC, and temporary-file sync failure: expected original bytes remain exact; temporary is removed on ordinary unwinding; no publication result.
- Rename succeeds, directory sync reports EIO: destination may contain all new bytes, but the API must report publication uncertainty, never clean success or untouched-original failure.
- Existing and new-file cases both cover uncertainty; create-only rename must still reject a raced-in destination.
- After initial check, move the synthetic parent aside and replace it; separately retarget a synthetic parent symlink. Assert pre-publication refusal or, if publication already occurred, explicit uncertainty. Neither case may report acknowledged save at an unrelated requested path.
- Keep the existing tests unchanged. A later owned child-process termination test at pre/post-rename barriers should assert each visible file is a complete old or complete new payload, and explicitly document possible orphan temporary files after SIGKILL. This is not power-loss durability proof.

## 2. Represent publication explicitly and validate destination identity

Introduce an explicit `FileStoreError.committedButNotSynced` (or a structured save outcome with equivalent meaning). Check directory fsync and classify failure after successful rename separately. Preserve the existing thrown pre-publication errors.

Capture parent device/inode from the opened directory. Re-resolve the requested parent and validate its identity before replacement; verify again before acknowledging success. Retain static parent-symlink support only with an explicit definition that it must still resolve to the pinned parent. Reject leaf symlinks as today. A failed post-replacement identity check must be treated as uncertain publication because bytes may already have been written to the pinned directory. Do not promise the final validation removes every race with a noncooperating external process.

## 3. Preserve native buffer and retry state

The affected block is `EditorWindowController.save`: detached encoding/backup/atomic-write and the subsequent adoption of destination, originalBytes, savedText, savedEncoding and savedHasBOM.

Introduce per-document pending-publication state containing the attempted destination, immutable attempted bytes/text/encoding, prior expected bytes, and any identity receipt required for checked readback. Do not conflate it with ordinary dirty comparison or overwrite originalBytes with an unverified guess. On uncertainty:

- Restore editability, surface an actionable message that new bytes may already be present, and keep the buffer eligible for recovery even when its text equals a previously saved baseline. Ordinary saved-baseline adoption must not clear this state.
- Save As must not silently adopt its new URL merely because rename may have happened; keep the pending destination separately until validated/acknowledged. Preserve native text/undo and the prior document URL state.
- Closing/discarding must be explicit; quit must retain uncertain text in recovery or veto if recovery fails. Carry pending-save uncertainty into the new periodic checkpoint policy; do not let a clean-file clear erase the only reliable current text.
- Explicit Retry reads the attempted path off-main with bounded regular-file/no-follow and identity checks. If bytes exactly equal the attempted payload and identity is acceptable, retry publication using those observed bytes as `expected`; for a new destination this is an explicitly verified retry of this pending operation, not a general Save As overwrite permission.
- If the destination differs, disappears, changes identity, or cannot be validated, preserve the buffer and report a conflict with Save As to a new path. Never accept arbitrary current bytes as the expected overwrite baseline.
- Only a fresh successful acknowledged save clears pending uncertainty and adopts the corresponding snapshot as saved. If editing continued during uncertainty, the newly acknowledged older snapshot must not mark newer text clean.

Retain backups before the original replacement. Retry need not create unlimited duplicate backups of identical attempted content; any deduplication must not delete the original prior-byte backup or hide backup failures. Backup storage errors must leave original bytes and native saved state untouched.

## 4. Retained native acceptance and review

Inject a save-service result into an isolated native harness rather than forcing real machine disk failure. Test normal save, pre-publication error, post-publication uncertainty, checked successful retry, externally changed retry, Save As uncertainty, edits after uncertain publication, backup refusal, and quit/recovery behavior. Assert exact bytes, saved URL, dirty/pending status, native undo availability, and retained recovery disposition independently.

Source review must check that all result branches restore controls, no late save result applies to a different/closed document, and a retry cannot authorize overwrite of unrelated bytes. Run targeted core/native checks first, then the coordinated complete suites. Update verification docs with exact executed results. Physical disk-full, APFS/network-volume behavior, sudden power loss, metadata preservation and elimination of noncooperating-writer races remain unclaimed until separately tested or implemented.
