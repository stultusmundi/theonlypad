# Persisted document pane presentation — reviewed design

Status: core metadata and startup/session flow implemented and tested; native integration is being revised after a reproduced layout race. Root and independent review approved bounded synchronous native selection revalidation on 2026-09-10. Desktop acceptance remains outstanding; no complete-feature claim.

## Scope and current facts

Persist the selected document's one/two-pane arrangement, axis, each attached pane's selection and independent scroll origin, and preferred pane across session reopening. This advances F-01 presentation persistence. F-02 moves documents between panes/windows and remains outstanding: this change neither transfers ownership nor makes the same document editable in multiple windows. One SessionTab UUID still means one EditorDocument, NSTextStorage, UndoManager, file baseline, monitor binding and recovery item. No duplicate content or path is introduced for a second pane.

At the original design checkpoint, `Sources/PadCore/SessionStore.swift` owned canonical v1 metadata, 16,777,216-byte envelope and private publication; `SessionRestoration.swift` separately validates direct callers and merges recovery by document ID. `RestoredViewState.swift` clamps scalar-safe selections and validates bookmarks against actually loaded text. `EditorDocument.swift` owns the bounded two-pane pool, preferredPaneID and splitAxis. `EditorWindowController.swift` captureSessionCheckpoint/sessionMetadata currently capture only preferred selection; restoreSessionTab creates one pane. splitCurrent refuses an additional pane beyond 2,000,000 UTF16 units. presentPanes applies host layout/settings; display activates a tab. SessionCoordinator.captureSession merges unresolved SessionTab values unchanged. Existing focus/selection callbacks reach notifySessionChange via updateStatus; scroll-only changes currently have no checkpoint hook.

Read together: docs/BUILD_PROMPT.md; docs/superpowers/specs/{shared-editor-views,session-restoration,session-checkpoint-ordering}.md; docs/superpowers/plans/2026-09-09-shared-document-panes.md. Earlier shared-pane documents describe historical extraction state; actual source is authoritative for existing behavior.

**Original version boundary:** Before this change SessionStore accepted canonical version 1 only. There is no released/implemented v0 decoder. Preserve unsupportedVersion(0), its exact bytes, and refusal to save over it. Implement v1-to-v2 migration only. Versions beyond 2 remain unsupported and untouched. Settings migrations are unrelated.

## Options

1. **Chosen: Session v2 embeds presentation in each tab.** One ordered one/two-element array maps to fresh runtime pane IDs; focused index identifies the preferred presentation. Transactional recovery→session publication remains unchanged. Unresolved tabs retain their entire presentation without allocating views. A version-specific decoder checks old canonical bytes before migrating in memory. Cost: touches both session validators and native restore/capture chain, but this is one bounded ownership boundary.
2. **Separate presentation sidecar keyed by tab/pane UUID.** Leaves Session v1 unchanged and could evolve independently. However two files can publish different document generations; crash recovery would require a cross-file journal or explicit stale-sidecar handling. Persistent pane IDs also suggest transferable/multiwindow ownership that does not exist. Rejected: more authority and failure states for no current feature gain.

Do not add optional fields to the v1 wire while claiming compatibility: the old canonical re-encoding check rejects extra fields. New builds must decode the exact old wire using an unchanged WireV1, then migrate; emit v2 only after an already-authorized successful checkpoint/quit. Loading alone writes nothing. Old binaries correctly reject v2 rather than drop fields.

## Proposed PadCore contract

New `SessionPresentation.swift` (Foundation only) owns value types and shared structural validator:

```swift
public enum SessionPaneAxis: String, Codable, Sendable { case sideBySide, stacked }
public struct SessionScrollOrigin: Equatable, Sendable {
  public let x: Double
  public let y: Double
}
public struct SessionPaneState: Equatable, Sendable {
  public let selection: NSRange
  public let scrollOrigin: SessionScrollOrigin
}
public struct SessionPresentation: Equatable, Sendable {
  public let axis: SessionPaneAxis
  public let panes: [SessionPaneState] // ordered, count 1...2
  public let focusedPaneIndex: Int    // valid array index
  public static func single(selection: NSRange) -> Self // zero scroll, sideBySide
  public func validate() throws
}
```

Provide explicit public initializers for each value; validation occurs at store/plan/resolve boundaries, allowing tests to construct invalid data without unsafe decoding bypasses. `SessionTab` stores `presentation: SessionPresentation`. Preserve its existing `selection` API as a computed focused-pane range and existing initializer arguments; add final `presentation: SessionPresentation? = nil`. Nil becomes single(selection: selection). If nonnil supplied, presentation is authoritative (document this; new callers omit legacy selection). The computed selection getter must safely handle malformed direct values: check focusedPaneIndex >= 0 and < panes.count before indexing, otherwise return NSRange(location:0,length:0). This fallback is accessor safety only; validate() must still reject empty panes and negative/out-of-range focus. Never normalize invalid data into an accepted single-pane record. Tests call the getter before validation for all malformed focus cases and assert no trap followed by thrown validation. The v2 wire omits duplicate top-level location/length. This avoids two divergent selections in storage. WireV1 retains its exact former shape/canonical checks, including omitted recentPaths behavior.

V2 Tab has existing identity/path/pinned/encoding/language/bookmarks plus required presentation: `{axis:"sideBySide",focusedPaneIndex:1,panes:[{location:0,length:0,scrollX:0,scrollY:120},{location:8,length:2,scrollX:0,scrollY:420}]}`. No runtime pane UUIDs, text, undo, monitor, recovery revisions, or implicit file URLs in the presentation. Canonical sorted JSON and exact re-encoding continue to reject unknown/duplicate fields, noncanonical enum/numeric spellings and malformed records. Current reader bound remains 16 MiB.

Structural validation is identical for SessionStore and SessionRestoration direct callers: 1...2 panes, valid focused index/axis, selection location and length nonnegative with subtraction-safe sum <=100,000,000; finite x/y in 0...1,000,000,000 points. Reject NaN/infinity/negative/oversized values rather than feed AppKit. The scroll limit is a persisted-layout safety bound, not a new text-size acceptance claim. Existing 32 windows/128 persisted tabs/10,000 bookmarks, recovery aggregate and path rules remain. Restore planning's existing 256 recovery/orphan upper bound remains; do not accidentally reduce it to store capacity.

New `RestoredPresentationState.resolve(_ presentation: SessionPresentation, bookmarks:[Int], in text:String) throws -> Self` resolves each of at most two ranges against the same immutable NSString/scalar boundaries; reuse extracted range-validation logic from RestoredViewState, validate bookmarks once. Expose resolved panes, axis, focused index, bookmarks and explicit adjusted-pane indices/invalid bookmark offsets. Preserve `RestoredViewState.resolve` compatibility for existing callers. A range inside a surrogate pair is expanded/clamped by existing policy, not silently interpreted as grapheme positions. Mixed CR/LF/CRLF and normalization remain exact. Scroll values require structural validation only off-main; geometry constrains them after view layout.

## Scroll and focus semantics

Choose document-view point origins, not percentages or a text anchor. Capture `scroll.contentView.bounds.origin` in O(1) per attached pane, never force layout or enumerate glyphs during checkpoint. Under unchanged settings/window geometry this restores the same origin, bounded by the valid clip-view extent. Under changed font/wrap/window dimensions it is a best-effort document coordinate, not the same logical top line. Record this explicit limit; logical-anchor restoration would require an additional measured glyph-query design and is not claimed here. Divider ratios and per-pane wrap/font settings remain outside this scope; existing settings apply to both panes.

Choose **one bounded synchronous best-effort scroll application**, avoiding delayed origin callbacks entirely. Apply selection first, then attempt scroll once after presentPanes/configureWrap and the ordinary host layout pass. With a finite positive viewport and document geometry, constrain the requested rect through NSClipView.constrainBoundsRect, apply it and reflectScrolledClipView. Do not call scrollRangeToVisible afterward. Never force full-document ensureLayout, poll for geometry, or subscribe a pending-origin replay to later bounds notifications. If geometry is unavailable, keep the actual current origin and expose a restoration warning that scroll position could not be restored. Lazy/unselected presentation metadata retains requested origins only until its one actual installation attempt; after installation checkpoint the actual constrained or fallback origin. This means exact scroll restoration is conditional on available native geometry and unchanged settings, not promised universally.

Bounds notifications serve metadata capture only. Resize/layout/clamping notifications must never be interpreted as evidence of a user scroll or trigger a second application of saved origin. Programmatic synchronous install notifications are suppressed only within the installation transaction. Hidden tests verify one-shot geometry and explicit fallback, plus no later jump after resize or user scrolling. There is no native deferred-validation task whose authority depends on distinguishing layout changes from user scrolling; the reason for this revision is documented below.

Restore preferred pane by array slot to the newly allocated runtime pane's UUID. Inactive tabs preserve preference without stealing first responder. Only the selected tab receives focus, and only through existing startup user-open/lifetime guards. Retry of an unresolved tab does not steal the user's subsequently selected tab unless current coordinator policy deliberately restores the unresolved original selected tab. Tab focus is not application activation; no window ordering change is introduced.

## Native ownership and lifecycle

Native engine owner edits EditorWindowController/EditorDocument/EditorPane; root owns restore payload/AppDelegate/SessionCoordinator integration. Coordinate these call-site changes as one reviewed integration. Independent core owner handles SessionPresentation, SessionStore, SessionRestoration and resolver/tests first.

Native APIs proposed:

```swift
// Controller, synchronous MainActor; no source copy/I/O/layout:
private func capturePresentation(_ document: EditorDocument) -> SessionPresentation
// Called before insertion/activation, after resolver has validated the actual text:
private func installRestoredPresentation(
  _ state: RestoredPresentationState, on document: EditorDocument
) throws
// Existing restoreSessionTab adopts an additional final optional resolvedPresentation
// argument; old viewState callers retain single-pane behavior during migration.
```

Capture order is attached panePool order, focused index from preferredPane(in:), with not-yet-installed presentation metadata merged as described below; there are no pending scroll callbacks. Collapsing to pool slot 1 produces a one-element persisted array focused at 0; detached undo-retained panes are not persisted. RecoveryBatch remains document-based and pairs with presentation in the existing synchronous captureSessionCheckpoint (no awaits). Dirty pending Save As still forces exactly one recovery snapshot and preserves original logical URL. Presentation changes neither advance edit/baseline revision nor create undo/macro entries; they notify the same application checkpoint scheduler, never another writer.

Add one owned bounds-change observer per pane, remove it on final release, guard document/window ownership and isAttached. Do not retain the unowned document through a notification closure. During programmatic restore use a synchronous suppression counter for scroll/selection metadata notifications, then notify once after a complete coherent state. Existing meaningful selection/focus/split/collapse events continue through notifySessionChange; scroll-only observer calls that same scalar invalidation. Freeze/quit guard prevents new dirty metadata notices; capture can read frozen pane origins. Veto restores interactivity and future notifications. No asynchronous restore block may change a closed/replaced pane or overwrite later user scrolling.

At restore >2M UTF16, load the document safely in one pane and show an explicit persistent message: saved split could not be restored at the current size limit. Retain the requested two-pane presentation and a stable mapping from the one live pane UUID to its original saved slot (choose the original focusedPaneIndex). Initialize this pane from that slot. **Every checkpoint replaces that mapped slot's selection and scroll origin with the actual live values**, retaining the dormant other slot, requested axis and requested focused index. Thus typing/navigation/scrolling while split is deferred remains persistent. Do not use an unchanged saved presentation as the checkpoint value. The mapping is independent of panePool array positions. A checkpoint does not resolve or mutate dormant ranges; they will be checked against actual text at restoration.

Offer explicit Restore Saved Split when eligible, or Use One Pane and Discard Saved Split Layout. Explicit restore snapshots the merged current live state and re-resolves both slots against current text, then installs only under the synchronous authority below; report any adjustments. Explicit discard records a fresh single presentation from the actual live pane, focused index 0, and retires deferred metadata/request. An unsuccessful/canceled restore retains dormant state and continues merging live changes. No quietly dropped metadata, relaxed 2M guard or automatic retry. This is a small explicit UI state with its own tests. Failed native pane setup before import leaves metadata unresolved rather than half-inserting a document.

### Bounded synchronous native revalidation

The first native design used a detached resolver and invalidated its authority on every bounds change. Full-sequence tests reproduced failure through both direct storage replacement and actual editor input: TextKit usage recalculation resized the document view and revealed selection after capture, canceling an otherwise valid explicit restore. A content-view layout pass and a separate private visible-rectangle experiment did not fix this. Historical failing assertions and source snapshots remain retained. Do not suppress bounds notifications, poll for stability or force full glyph layout to make those tests pass.

Review found that native installation consumes only two resolved selections and their adjustment indicators. It never uses the asynchronous resolver's bookmark result. The native path will therefore use shared `RestoredSelection.resolve(_:inUTF16:)` against the existing `document.storage.mutableString`. Clamp and scalar-boundary checks require at most four character accesses per range, eight for two panes, plus structural and length checks. No String bridge/copy, text enumeration, bookmark pass, I/O, await or layout query is needed for validation. This is a bound on API calls, not a universal Foundation wall-time guarantee for arbitrary NSString subclasses. Counting-string tests verify the work shape and exact boundaries. The 2M split limit remains unchanged.

Startup, file reads, recovery and unresolved repair continue to decode and perform full selection/bookmark validation off-main. Only the unnecessary native revalidation suspension is removed. Shared range logic prevents divergent surrogate handling between these paths.

Native restoration admits only a live, current document owned by this window, within the existing split size limit, without saving, composition, marked text, close/quit or another synchronous installation. Capture the merged live selection/origin immediately before validation. Use a synchronous reentrancy token; recheck document ownership, edit revision, operation and relevant pane state after callback-capable boundaries before further mutation. Keep intermediate metadata notifications suppressed only during the coherent install. On refusal retain deferred metadata and current live state, without leaked extra attachments, changed text, undo, baseline or recovery identity. Never run a modal or pump the event loop inside the transaction.

No native validation task/result snapshot or canceled-worker admission remains. After the method returns, later edits, saves, selection changes, scrolling or window closure cannot be overwritten by a delayed install. Tests must preserve original deferred-restore success, actual editor replacement, current live selection, both-pane undo and real-save checks. Worker-only hold/drain assertions become obsolete only when source review confirms no native task/await remains; corresponding product safety coverage moves to entry refusal, synchronous callback reentrancy, and post-completion no-replay tests. Historical failures are not erased or counted as passing.

Bounded resource statement: maximum two pane records per tab; no duplicate recovery text, original bytes, decoded strings or save ownership. At most two native layouts per live document, with second-layout admission capped at existing 2M; cap is not proof of acceptable worst-case aggregate RSS. Materialize restored second layouts when their tab is first presented, retaining only validated value state beforehand. A pending presentation must remain checkpoint-visible until consumed, and stale text must be revalidated on first presentation. No shared engine or cross-window registry redesign in this work.

## Implementation sequence and acceptance

See [implementation plan](../plans/2026-09-09-persisted-pane-presentation.md). Completion requires both core migration and native restore/capture integration. Hidden test success does not establish actual desktop scrolling/focus, physical IME, assistive technology, or latency. Desktop execution remains blocked until an unlocked authorized runner is available. No test target is lowered; existing 100MB single-pane behavior and 2M split guard survive. F-02 document transfer, divider persistence, logical-line scroll anchoring, and large split support remain explicitly outstanding.
