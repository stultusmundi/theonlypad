# Native session integration

Status: planned. Core storage and merge planning are implemented and pass the combined 184-test suite; native session restoration is outstanding.

Design: `docs/superpowers/specs/session-restoration.md`. Preserve all unresolved records and recovery content. No file path authorizes overwriting the file.

## Interfaces and order

1. Add a native restoration coordinator owning the startup task, unresolved entries and metadata persistence revision. Inject SessionStore and RecoveryCoordinator locations in native tests. The coordinator loads metadata off-main, claims recovery exactly once, and calls SessionRestoration.plan. Do not let each new editor window race to claim startup recovery.
2. Give editor windows stable UUIDs and an initializer that can suppress automatic scratch creation/recovery claiming. Add explicit import of a RestorationTab and capture of SessionWindow. Imports preserve tab IDs, pin order, language override and validated selections/bookmarks. Clean file imports use bounded existing decoding; recovered imports always remain scratch buffers. Native tests must cover supplementary scalars and selections beyond changed on-disk text.
3. Restore windows in recorded order and tabs in recorded order, independent of file I/O completion. Treat user-created windows/documents as separate ownership, so delayed restoration never replaces them. Keep missing/unreadable/oversized-file entries in the coordinator with original metadata. Build a functioning Retry/Locate/Remove panel; Remove must be explicit and Locate must read and validate before changing metadata. Never put error text into a user buffer.
4. Add session capture after the existing global quit freeze, pending-close drain and recovery batch. Persist metadata off-main only after content persistence succeeds. A metadata failure vetoes quit and unfreezes all windows. Capture unresolved entries too. Never silently trim records to fit SessionStore limits.
5. Serialize debounced session writes for tab order/pin/selection/bookmark/window changes and recent paths. Prevent older captures from overwriting newer ones and prevent startup errors from overwriting the preserved unreadable session. Recovery writes and metadata revisions must not race close/discard operations.
6. Wire recent-file commands through the existing command registry, with bounded persisted paths and actionable errors for unavailable entries. Opening a file or restored workspace must not run external commands or extension code.

## Required verification

- Start with failing native tests for two-window order, selection, pinned tabs, scratch plus dirty saved-file recovery, and clean saved-file reopen. Confirm stable IDs and exact content after another capture/load cycle.
- Exercise missing recovery, missing path, malformed/future session data, Locate failure/success, explicit removal, and interrupted metadata saves. Originals must remain readable and errors must leave unresolved records intact.
- Exercise a late restore result after user input/window close, metadata quota overflow and quit veto after recovery succeeded. No hidden document, dropped record or stale overwrite is acceptable.
- Run `scripts/swift.sh test` and `scripts/test-native-integration.sh` after integration. Add the native session harness to the latter only once its executable command works.
- Use the real packaged app and available XCUITest harness for open/edit/save/quit/reopen. Record exact observed window/tab content and remaining unverified platform behavior. An in-process harness alone does not establish packaged restoration.

## Current evidence and blockers

SessionStore has nine temporary-file/privacy/fault tests. SessionRestoration has six merge, identity, orphan, missing-record and capacity tests. All 184 core tests passed together on 2026-09-09. This does not establish any native session acceptance criterion. Integration is sequenced after the current native bookmark/IME undo correction and dirty-state cache regression checks to avoid concurrent edits to EditorWindowController.

## Startup and quit integration slice (implemented 2026-09-09)

Implemented in AppDelegate and injectable SessionCoordinator: session/recovery are claimed once; ordered windows are prepared through serial bounded reads and imported into dedicated windows. Early user opens use separate windows. Recovery text always imports as scratch, including Retry of an unresolved recovery-backed tab. Saved file bytes accompany decoding for future conflict checks. Position validation runs off-main. Missing records remain in the coordinator and are merged back into quit metadata in their original order. Failed/corrupt/future metadata blocks writes; otherwise-valid orphan recovery is still surfaced. Confirmed Remove drains recovery deletion before dropping metadata and before quit capture; failure retains metadata. Locate of recovery-backed text requires explicit replacement confirmation. File → Unresolved Session Tabs reopens the panel.

Quit waits for startup, freezes editors and drains existing close/recovery operations, persists the global recovery batch, then persists session metadata. Session errors enter the existing quit-veto/unfreeze path. Pending repair callbacks are invalidated before capture. A repaired target closed during its read is rejected rather than silently reopened. Explicit repair started without an existing window creates a dedicated window. Repaired tabs use their original position and selected-tab preference.

Capacity: startup admission checks 100 million UTF-16 units and a 400 MB retained text-plus-original-byte estimate; single 100 MB ASCII files remain eligible. A serial in-flight read can add approximately 300 MB to that estimate. These are allocation bounds, not measured RSS limits: AppKit storage, retained unresolved recovery, allocator overhead and copy-on-write behavior add memory. Successfully imported recovery snapshots are released from the Retry map; failed snapshots remain bounded by RecoveryCoordinator limits. Repairs recalculate admission from currently open windows, so closing documents releases capacity. Excess records remain unresolved.

Tested: expected missing types/command and the older-disk recovery Retry bug were reproduced before fixes. Final isolated all-native-source compile passed. SessionIntegrationHarness passed two-window ordering, pinned/saved and scratch imports, missing-path retention across persistence, exact recovery Retry, invalid metadata preserving valid orphan recovery, recovery deletion failure/success, canceled late startup, write-failure propagation, and capacity arithmetic including a single 100 MB ASCII file without allocating that fixture. SessionRestorationHarness passed native Locate/Remove sheets, recovered-text replacement confirmation and confirmed deletion completion after panel close. No original files were written by recovery restoration tests.

Remaining: debounced session autosave and recent-file commands are not implemented in this slice. Packaged restart, real application termination reply/quit-veto UI and early external-open event sequences still require parent integration checks. The coordinator write-failure test establishes error propagation; it does not by itself prove the AppDelegate termination reply. Corrupt/future session protection currently requires external repair/restart before metadata can be persisted; no reset/overwrite UI is claimed.
