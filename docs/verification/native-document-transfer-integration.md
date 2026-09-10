# Existing-window transfer integration

Implementation: one selected editable document moves between existing native windows through the canonical `file.moveToWindow` command and a captured destination chooser. The process registry retains the same document/storage/undo/recovery authority. Destination ownership and endpoint identities are checked again when Move is confirmed. Cancel performs no move. New-window destinations, independent groups, streaming transfer and visible desktop acceptance remain outstanding.

## Evidence under integration

- `bash scripts/test-document-move-destination.sh`: three hidden cases passed through the actual AppDelegate, including Cancel and Move. Independent source review found no material issue.
- `bash scripts/test-native-application-document-transfer.sh`: original scratch and UTF-16/BOM file workflows passed, including stale ownership choices after moving away/back, real external-write detection after closing the old source window, and recovery-store readback.
- Five additional endpoint-loss cases initially failed with stale endpoint errors. Explicit source/target recreation and receipt reconciliation made all seven cases pass. Exact endpoint incarnations are reconciled without recapturing the original rollback geometry.
- Expanded post-settlement editing exposed an early refresh abort: a missing peer prevented the live editor becoming editable. Refresh now attempts both projections and live admission before retaining the first failure. The real edit/undo/recovery regression passes.
- Expanded file-backed terminal replacement exposed closed-context filtering that prevented monitor detachment. The correction passed the actual file-backed terminal retry, preserving the same bridge and detecting a later real external write. A source-close-before-reservation variant then exposed a competing ordinary detachment receipt; exact transaction-owned suspension fixes that race. Pre-stage cancellation now projects both originals before monitor restoration.
- The process's exact idle retry-state accessor passes the existing process suite with added in-flight/foreign/expired token and settled-cleanup assertions (`.local/transfer-process-retry-state.log`). Identity-only lease queries do not authorize projection; strict registry validation still does.

All native tests use hidden windows, synthetic data and isolated state. Raw source hashes, red and green results stay in ignored `.local` run directories. These results do not establish physical keyboard, VoiceOver, IME, visible focus, packaged desktop behavior or performance acceptance. The locked console still blocks those checks.

The expanded native owner run passed 11 tests with zero failures in 1.924 seconds (`.local/native-transfer-all-phases-green.log`). A subsequent independent process validation regression passes in the separate 15-test frozen suite; full final native rerun is still pending the last AppDelegate focus guard review.

## Frozen integration

Snapshot `.local/native-transfer-reviewed-integrated/source-provenance.json` records all public source hashes and the two archive-only runner root-resolution adjustments. App/core build completed in 10.86 seconds. All 404 core tests passed (15.923 seconds), all 71 managed lifecycle tests passed (5.881 seconds), and all 11 real native transfer cases passed (3.343 seconds). Logs: `.local/transfer-reviewed-core.log`, `.local/transfer-reviewed-managed.log`, `.local/transfer-reviewed-owner.log`. No compiler warnings were found in those logs.

The final AppDelegate superseding-action correction is included in this snapshot: newer chooser entry and quit entry invalidate prior presentation completions, including after quit veto. Independent review cleared the final controller, bindings, process, owner and command changes. Separate frozen projection/chooser/binding reruns and local packaging are recorded below when complete.

Final frozen follow-up: projection 9/0 (1.168s), chooser/presentation 3/0 (0.404s), and all 44 native binding checks passed. Legacy native monitor lifecycle compatibility also passed, covering suspended open/save, disk actions, reload/copy, uncertain reload, Locate, save rebind, undo, close/reopen and late close (`.local/transfer-reviewed-monitor-lifecycle.log`). Source formatting, public-source pattern checks and git diff checks passed. All 364 code/test/runner inputs match the final frozen manifest. Local packaging is recorded separately; no desktop acceptance is implied.
