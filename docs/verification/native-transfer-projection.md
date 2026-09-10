# Hidden native transfer projection candidate

Implemented: exact existing-window registry-lease projection sharing ordinary projection logic; conservative monitor context; no ordinary refresh/dirty classification during the lease; max-two model view receipts per endpoint; exact scalar/presentation checks; retained partial projection retry and rollback.

Five tests passed, zero failures, 0.647 seconds in `.local/editor-transfer-projection-tests/run.GnfVz9Lf`. Command: `scripts/test-editor-transfer-projection.sh`. Full native and PadCore source snapshot hashes are in the run directory. No windows shown or activation attempted. This is semantic evidence, not desktop or timing acceptance.

Behavioral reds: refusal seam two failures (`editor-transfer-projection-red-stages.log`); persistent endpoint callback refusal stranded retry (`editor-transfer-projection-retry-persistent-red.log`); real clip-bounds notification did not invalidate interaction (two failed assertions in `editor-transfer-projection-scroll-red-compiled.log`). Setup/compiler errors and geometry refinement attempts are separately retained and are not the intended red evidence.

Native first presentation of a zero-sized neighbor viewport can center its origin at negative x. During the exact lease-owned reparent only, restore the original origin constrained to current native bounds after checking every scalar, selection, pending presentation, and interaction token. Native layout notifications are scoped; a real reentrant scroll notification outside that scope changes the interaction token and refuses restoration. This is bounded best-effort presentation restoration, not native coordinate identity or pixel acceptance.

Independent source review found no material issue. A separate frozen integration snapshot passed the five projection tests again (0.647 seconds) and all 71 existing managed lifecycle tests (7.086 seconds). Its base and overlay hashes are retained in `.local/native-transfer-controller-integrated/source-provenance.json`; the copied projection runner changes only root-directory resolution for archive execution. Logs: `.local/native-transfer-controller-frozen.log` and `.local/native-transfer-managed-compatibility.log`.

Outstanding: explicit active-lease endpoint replacement reconciliation and terminal cleanup endpoint replacement preserving current edits. The underlying owner has separate scratch/file transfer evidence; public command access and desktop acceptance remain incomplete.
