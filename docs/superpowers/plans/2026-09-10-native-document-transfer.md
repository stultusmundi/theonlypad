# Native document transfer implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` task by task after interface review and source freeze. Delegate only when separately authorized. Track the checkboxes and retain actual red/green evidence.

**Goal:** Move one existing editable model between existing windows without losing history, monitor continuity or exclusive recovery ownership.

**Architecture:** A process-owned transfer coordinates one registry reservation, one existing publisher pause and two token-bound native projections. Failed rollback retains the same model and explicit reconciliation state. Independent groups and streaming remain separate completion stages.

**Tech stack:** Swift 5 mode, Foundation, AppKit/TextKit, existing PadCore recovery/session services; no new dependency.

**Spec:** [native-document-transfer.md](../specs/native-document-transfer.md).

Status: root design review complete; registry interface approved and independent registry, monitor and bounded native-state work assigned. Every implementation checkbox below remains pending until evidence is recorded. No transfer tests have run yet. This supplements the [existing F-02 plan](2026-09-10-document-transfer.md) and uses [native integration contracts](../specs/native-document-transfer.md). Root integration freeze and independent design review are prerequisites. Existing unrelated owner/AppDelegate/controller work is not part of this task.

## File responsibility map and execution evidence

- Registry owner: `ApplicationDocuments.swift`, `WorkspaceDocumentRegistryTypes.swift`, proposed `DocumentTransferBoundary.swift` and `ApplicationDocumentTransferTests.swift`. Keep the private record/gate mutation together; do not expose registry dictionaries.
- Process owner: proposed `ApplicationDocumentTransfer.swift` and root-owned `NativeApplicationDocuments.swift` admission/publisher/endpoint ports. Existing actor/store requires no new writer or authority API.
- Monitor owner: `DocumentFileStateController.swift`, `NativeDocumentEndpointBindings.swift` and their retained harnesses; proposed transfer-specific boundary may be a separate file. Ordinary history/endpoint-loss tests remain intact.
- Native owner: `EditorWindowController.swift` and a proposed `EditorDocumentTransferAdapter.swift`; model/pane changes only for reviewed scalar/context or callback plumbing. Proposed hidden `NativeDocumentTransferTests.swift` owns actual model/undo/projection assertions.
- Later product owner: canonical `AppCommands.swift`, AppDelegate and destination UI only after Stage 4 hidden green. Group/schema/streaming changes require separate reviewed file ownership.

For each stage, first compile a real failing behavioral test, retain unique red evidence, implement the smallest change, then run the same assertion and existing affected harnesses. Add dedicated unique-directory runners by following `scripts/test-native-application-open.sh` and registry runners; proposed transfer runners are not existing verified commands. Actual established compatibility entry points include `scripts/test-native-application-documents.sh`, `scripts/test-native-application-close.sh` and `scripts/test-native-application-open.sh`. Freeze source snapshots before those runs, compile with the package's Swift 5 mode, and retain owned-child watchdog outcomes. Perform scoped formatter/shell/diff checks and independent review before root's scoped commit; no remote publication is implied.

## 1. Freeze transaction and monitor interfaces

- [ ] Read actual final registry/process-owner/controller APIs after composition integration. Record hashes and precise owners before mutation.
- [ ] Agree opaque registry reservation plus internal projection capability; global mutation/capture/quit refusal and strong ownership must exist before callback-capable preflight.
- [ ] Agree bounded scalar transfer-state/geometry read, avoiding close dirty evaluation and all full-text operations.
- [ ] Agree dedicated monitor ownership-transition receipt and rollback phases. Ordinary same-generation detachment remains unchanged; exact binding checks are never weakened.
- [ ] Assign registry coordinator, monitor bridge/store, native endpoint and process integration files to nonoverlapping owners. Root owns final NativeApplicationDocuments/AppDelegate/checkpoint admission wiring.

## 2. View-free registry transaction red–green

- [ ] Compiling behavioral red: same handle moves from selected source to target, exactly once; storage/history are represented by stable synthetic identities.
- [ ] Add structural cases: stale workspace/ownership, wrong source selection, inactive/pending adoption, close lease, unknown/duplicate assignment, same-group refusal, streaming refusal, target index/pinned partition, duplicate standardized URL. No destructive read is allowed.
- [ ] Assert exact source-neighbor selection, empty-source state, target selection, pin preservation, one assignment and one final notification; history counts remain unchanged.
- [ ] Force reentrant register/select/pin/reorder/close/transfer/capture/quit at every supplied callback; require busy refusal before effects.
- [ ] Stage/source failure/target failure/rollback failure: exact old snapshots restored or strong retained-failed record remains. Duplicate/foreign/stale token and old-completion-after-new-transaction refuse.
- [ ] Existing registry/adoption/history/close tests remain unchanged and green.

## 3. Monitor transition red–green

- [ ] Establish actual red showing current same-generation endpoint token cannot reattach after ownership rotation; do not change that test to ignore ownership.
- [ ] New transfer API preserves exact baseline/parent continuity while changing endpoint ownership; old action and delayed delivery rejected after move and move-back.
- [ ] Use real temp-file service tests: parent retarget with equal bytes remains refused; retained replacement/deletion/manual/error state is not reset by movement.
- [ ] Force failure before token consumption, after target registration, after callback delivery, then rollback and Retry Layout. Prove no guessed token, duplicate monitor owner or retained callback cycle.
- [ ] NativeEndpointBindings and all existing bridge/service/admission/lifetime tests remain green.

## 4. Existing-window native vertical slice

- [ ] Hidden actual-controller behavioral red before move implementation: two owned windows, selected dirty source with two panes, target with its own document, no new model/factory call.
- [ ] Succeed using actual registry/actor/publisher. Assert exact EditorDocument/storage/UndoManager/layout-manager/pane identities, original recovery authority/issuance fence, normalized-distinct Unicode/CRLF bytes, encoding/BOM, bookmarks, URL/baseline, pin and settings.
- [ ] Edit from each moved pane; undo/redo after source window closes must retain exact native history and target selection independence. No source-close deletion of moved recovery.
- [ ] Preserve deferred >2M presentation including live-slot merge, dormant slot, warning and original pane IDs. Do not allocate a second layout manager to test metadata preservation.
- [ ] Capture source/target selection and constrained origins at differing window geometry. Exactly one best-effort restoration; later caret/scroll/edit causes no latent jump. No full glyph layout or benchmark claim from semantic tests.
- [ ] Inject actual callback reentry (selection/layout/endpoint lifecycle) during source/target projection and rollback. Prove no modal/file operation, recursive move, extra pane or stale async source command can act through the busy gate.
- [ ] Require refusal for composition/marked text, undo in progress, active operation/save, pending publication/text processing, macro/loading/preparation and pane-install token on either affected model. Dirty text alone must succeed.
- [ ] Actual source and target projection failure; failure of each rollback separately; both endpoint-loss orderings. Retained failure holds same model/pause and quit veto; explicit recreated-endpoint Retry Layout settles without a new reader, factory, adoption or repair epoch.

## 5. Paired publication and process integration

- [ ] Hold actual publisher before capture and after capture in separate tests; reservation/drain has no cycle. No transfer wait may be added to publisher prepareCapture.
- [ ] Existing captured old-placement checkpoint may complete. After transfer settlement, real paired checkpoint/final quit persists one UUID in target and exact recovery bytes; restart verifies one model, pin/order/selection/presentation.
- [ ] Inject metadata write failure: live assignment remains target, status/actionable retry and quit veto persist; repaired checkpoint does not re-adopt authority.
- [ ] Concurrent intake, close, history preparation, external FIFO and quit admission reject/queue according to the explicit process gate. Cancellation of a wait does not cancel the transaction or release its publisher pause.
- [ ] Notification callback can start the next admitted action; prior cleanup cannot clear newer state. A failed endpoint recreation remains explicitly retryable.
- [ ] Run root core/native compatibility suites only after all owners freeze. Report implementation, test and desktop-blocked states separately.

## 6. Product access and remaining F-02 stages

- [ ] After existing-window hidden green, add Move Document to Window command through the canonical command registry and an accessible destination chooser. Cancel/stale chooser is a no-op; visible focus failure warns without reversing committed ownership. No default shortcut required.
- [ ] Add new-window target with pure aggregate live+unresolved capacity admission before staged factory. No 33rd reserved window or duplicate/new129th document; unregister only the unused provisional endpoint.
- [ ] Add independent document groups with actual group host/routing/session schema tests; current single-group projection is not silently bypassed or flattened on save.
- [ ] Add streaming document transfer with the existing reader/page task identities, separate byte-offset state and no editable recovery adapter.
- [ ] Run actual desktop transfer/undo/close/restart acceptance when GUI access is available. Hidden AppKit semantic tests do not substitute for this gate. F-02 remains partial until all committed scope passes.
