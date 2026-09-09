# Recent Files integration review

Date: 2026-09-09. Read-only focused review against baseline `3c70180`, including the uncommitted Recent Files additions. Scope: AppDelegate, EditorWindowController open/reload completion, SessionCoordinator MRU persistence, RecentFilesController, and both RecentFiles native harnesses. No production edits or GUI runs were performed by this review. Root owns concurrent desktop testing. This is a source review, not a new passing runtime assertion.

## Findings

### P2 — Recent history mutations remain enabled after quit captures its persisted snapshot

`AppDelegate.swift:217` wires Remove and Clear directly to SessionCoordinator without checking `preparingQuit`. `applicationShouldTerminate` freezes editors and guards open callbacks, but leaves the Recent Files panel's Remove/Clear controls usable. `SessionCoordinator.swift:311` constructs an immutable EditorSession containing the current recentPaths before awaiting its asynchronous save. A subsequent clear/remove updates the panel and in-memory history but cannot change that captured snapshot.

Reproduction: leave Recent Files open, initiate quit, and click Clear List after session persistence starts but before termination completes. On a slow save (or while external-command cancellation delays the final quit reply), the panel reports an empty list yet the old history reappears after relaunch. No original file content is deleted; this loses a confirmed history mutation and can retain paths the user intended to remove.

Deterministic regression seam: inject `saveSession` to capture its EditorSession argument and suspend; start persist; clear recent history while suspended; resume save and compare saved recentPaths with the now-empty coordinator. At application integration level, the desired fix is to refuse/disable panel history mutations during the frozen quit interval and re-enable after canceled quit, or explicitly coordinate a revised persistence snapshot. Existing harnesses test clear-before-persist only, so they do not cover this interleaving. Confidence: high from the actor suspension and callback order; no GUI reproduction claimed.

### P3 — Successful recent open invalidates its own completion status (already reported)

`EditorWindowController.swift:387` invokes onOpenedURL before onOpened. The application's onOpenedURL callback calls `recentFiles.update`, whose invalidate increments generation and cancels the panel task. The document successfully opens and MRU updates, but the resumed panel task fails its generation guard and never displays Opened. This does not strand isBusy: update resets it. Existing panel and editor harnesses test the two components separately and do not wire this real application feedback loop.

Regression: wire onOpenedURL to update the same panel, open a valid selected entry, and assert both updated MRU and final success status. Preserve invalidation for genuinely external selection/list replacements. Confidence: high, deterministic callback ordering. Owner already addressing this known feedback.

## Safety paths examined

The open finish closure marks completion before invoking external callbacks, preventing a second outcome on its own paths. Failed/stale/closed and oversized text opens complete through explicit failure. Detached completion checks window closure, quit state and caller acceptance before appending a document. Overlapping opens recheck existing tabs and select the first result without overwriting dirty text. Explicit encoding reopen routes through discard confirmation and reports decode failure without replacing the prior buffer. Reload freezes editability and checks membership/lifecycle after its read. Session restoration bypasses onOpenedURL, preserving MRU order; early successful opens merge ahead of delayed restored history. Local-path validation rejects remote schemes and bounded metadata remains subject to SessionStore validation.

Both retained harnesses meaningfully cover cancellation, stale list/selection, closed targets, failed decoding, dirty-buffer reuse, duplicate in-flight open, frozen windows, oversized files, MRU bounds, removal and persisted clear. They do not establish the application-level success feedback loop or quit-time MRU mutation guard above. The changed open API has five explicit call sites across AppDelegate and EditorWindowController; original read/codec internals were not re-audited as a new file-storage security assessment. No additional document-data-loss or double-continuation defect was established in the reviewed change.

The explicit accessibility identifier omission was already assigned to the owner and is intentionally not counted as a new finding. No claim is made about physical GUI behavior or updated harness runs from this review.

## Independent resolution review (2026-09-09)

Read-only follow-up of the merged AppDelegate, RecentFilesController, and editor open/reload paths. No build, GUI probe, or harness was executed for this follow-up; earlier owner-reported harness outcomes remain separate evidence.

**P2 quit-time history mutation: addressed in source.** AppDelegate sets `preparingQuit` and suspends the panel synchronously before creating the asynchronous quit task. Suspension invalidates the request generation, cancels its task, disables the table/actions, and is checked again by the action methods. Both application Remove/Clear callbacks independently guard `!preparingQuit`. All three veto paths examined—an editor refusing preparation, failure draining pending closes, and recovery/session persistence throwing—cancel editor preparation, clear the application flag, resume the Recent panel, and reply false. The successful path keeps the panel suspended through external-command cancellation and final termination reply. No veto branch missing panel resumption was found.

**P3 successful-open status feedback: addressed in source.** The application's successful-open callback passes `openedPath` together with refreshed MRU paths. `update` deliberately retains generation invalidation, replaces/reloads the list, then writes the explicit successful-open message unless suspended. Thus the successful open's now-stale task cannot overwrite that message, and a genuinely stale completion still fails its generation guard. Selection changes, external list replacement, closure, and suspension all invalidate in-flight requests. This fix does not relax the editor's acceptance predicate or turn a canceled request into a successful document load.

The Recent onOpen entry callback and its completion acceptance predicate both guard application quit and target-window membership. The predicate also checks the panel request's generation and selected path. Editor open checks acceptance before beginning and after detached reading; encoding reload rechecks after discard confirmation and after its read. The general `onOpenedURL` notification itself has no application-quit guard, but its reviewed Recent-file route cannot reach it after quit starts because the acceptance predicate rejects that state. Startup work may finish while quit awaits startup, before the session snapshot is captured; that ordering is not the reported post-capture history race. No additional stale-success or double-continuation defect was established in these paths.

**Accessibility identifier omission: addressed in source.** The table, status label, and three action buttons now set both the NSView identifier and explicit accessibility identifier, while retaining localized accessibility labels. This confirms the API wiring, not physical VoiceOver or desktop automation behavior.

Resolution is bounded to these reported issues and their callback/lifecycle paths. It is not a new runtime acceptance result or a feature-completeness claim.
