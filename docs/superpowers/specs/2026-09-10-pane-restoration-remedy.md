# Pane restoration: applied settings and bounded origin layout

Status: reviewed design adopted for staged implementation. No production implementation or layout-cost result is claimed. Independent review required configuration-token admission coverage and an explicit distinction between skipped eager layout and implicit framework work; both are incorporated below. The separately reviewed private focus candidate passes both complete desktop layouts, with evidence in `docs/verification/persisted-pane-presentation.md`. Those small-document results do not establish transfer/settings coherence or cost bounds.

## Selected policy: preserve existing intent

| Trigger | Intended production behavior |
|---|---|
| First configuration/new document | Apply the owning window's validated typography and wrap policy. |
| Every accepted applySettings, including unchanged/theme-only | Reconcile each document to that window's desired policy; avoid setters only where the DOCUMENT already proves that component is applied. |
| Manual Toggle Wrap | Change this document's effective wrap. It remains until the next accepted applySettings, which restores the global/window wrap default, matching current production behavior. |
| Atomic cross-window transfer | Preserve the source model's typography, effective wrap, native views and presentation through commit/rollback. Do not restyle during transfer. |
| Next accepted destination applySettings | Reconcile transferred models to destination policy, even when destination controller.settings itself did not change. |
| Settings blocked during startup or loaded late | Keep AppDelegate's existing final ready-time applySettings and later settings-load delivery. Do not delete them or infer a prior blocked call applied anything. |

This deliberately rejects the private controller-delta behavior that accidentally preserves a manual wrap choice through unrelated settings applications. It also avoids a new immediate post-transfer restyle that could destroy the origin preserved by transfer. These choices preserve current semantics, rather than adding per-document persistent font/wrap preferences.

## Bounded applied-state model

Add an internal Equatable applied-typography value beside the native document state. Suggested fields:

- validated requested fontName/fontSize/tabWidth;
- resolved NSFont.fontName and pointSize;
- computed defaultTabInterval.

Resolve the requested font using the existing named-font/system-monospaced fallback on each accepted settings application, and compare this small value per document. This includes fallback resolution in the proof, so unavailable fonts do not cause permanent repeated setters and a later different resolved font is noticed. A local resolved plan retains the NSFont/paragraph objects needed for the actual writes; the receipt remains scalar/value data. Theme is absent from this signature. No attribute-run scan, whole-string equality, first-character shortcut or layout query decides a no-op.

Document state:

- `appliedTypography: AppliedTypography?` (nil means not established or invalidated);
- `appliedWrap: Bool?` (effective semantic state, not last controller preference);
- a synchronous native-configuration token while setters/inheritance run.

Prefer making existing `settingsApplied` a derived read-only compatibility check that both components are established, then migrate its few call sites/receipt fields. Do not retain an independently writable bool that can disagree with the two proofs. Tests currently toggling that bool should instead invalidate/change the actual applied state.

Window settings remain the desired policy. Use a small `WindowPresentationPolicy` (requested typography + wrap, excluding theme) or equivalent revision to validate reentrant application and endpoint captures. Do not mistake the window value for proof about transferred documents.

## Applying settings safely

1. Preserve existing user/projection admission, validate to a local requested value, and resolve a local typography plan. Every accepted applySettings visits documents even when controller settings compare equal.
2. If a document's typography signature equals the plan, skip the entire native font/default-paragraph/typing-paragraph/shared-storage setter group. If effective wrap already equals desired wrap, skip semantic wrap setters for this settings application. No-op/theme-only passes still refresh appearance/status as today.
3. Before a required native write, acquire a non-nested document configuration token and invalidate that component's applied proof. Fence the exact document, ownership/endpoint, pane objects/attachment set, edit revision and desired window-policy revision around each AppKit mutation group. Existing callbacks can reenter synchronously despite no await.
4. Publish the new proof only after all corresponding writes and scalar/pane checks succeed. A failure leaves that component unknown, never stamped as applied; report/defer through the caller's existing failure handling. Do not attempt an O(text) attribute rollback or let a later stale outer call overwrite newer applied state.
5. Before the first setter, the exact configuration token must become a real admission predicate: `mayMutate` (including insertText, setMarkedText and delegate edits), focus/selection-changing pane commands, split/collapse/wrap commands, transfer capture and close capture all refuse or report busy while it is active. Do not silently reuse `panePresentation.installing` without extending its meaning and every admission call site. Clear only the exact token after post-write authority/pane/edit-revision validation; a stale outer call cannot stamp proof or clear newer configuration. Transfer capture must report busy and close capture must refuse a partially configured state. Applied-state changes should rotate the existing document close-mutation generation (via didSet inside EditorDocument), so receipts for inactive documents are invalidated too. Do not introduce a public core-state field just for this native cache.

Changing typography genuinely can retain the existing full-range paragraph write; this design removes the redundant write, not its cost when settings actually change. Large-document changed-typography latency remains a separate measured obligation.

Wrap has two responsibilities that must remain distinct: semantic enabled/disabled policy and container geometry for a current host size. `presentPanes`/resize may still refresh width/container/frame geometry even when appliedWrap matches. Do not skip necessary geometry by treating a cached Bool as a width receipt. Manual toggle updates appliedWrap only after successful native configuration; the next applySettings compares it to the window default.

## New/reused pane invariant

Both splitCurrent and installResolvedPanes already capture live font, paragraph and typing attributes BEFORE makePane because constructing another NSTextView can affect shared storage. Preserve these inheritance paths. New/reused pane initialization cannot be skipped merely because the document signature exists.

Centralize/audit native typography writers (EditorPane initialization, split inheritance, saved split inheritance, actual settings application). Hold or invalidate the document typography proof while a new pane is constructed/adopted; restore the prior proof only after exact inheritance succeeds and authority/pane identity remain valid. On refused partial inheritance, leave it unknown. Apply the effective document wrap to the additional pane; do not substitute the current window default during transfer-preserving layout. No font zoom route was found in current relevant code; any future writer must participate in this invariant.

## Transfer capture, validation and reconstruction

`NativeDocumentTransferViewReceipt` must carry appliedTypography and appliedWrap instead of relying solely on settingsApplied. Capture them, compare them in validateTransferView, and copy the ORIGINAL receipt values unchanged in BOTH controller helpers:

- transferViewWithLiveOrigins;
- constrainedTransferView.

Those helpers may adjust their allowed geometry, never refresh applied configuration from the live model. A changed signature or effective wrap invalidates the receipt. Capture/validate remains bounded to scalar state and at most two panes; optionally verify native wrap flags agree with the non-nil proof using those same two panes. Do not inspect text attributes to validate transfer.

The endpoint receipt should additionally freeze the window presentation-policy value/revision and validate it. This covers an empty destination window whose applySettings document guard is vacuously true while a transfer is captured; the desired policy must not silently change the meaning of future reconstruction. A policy change rejects/retries that transfer; unrelated theme-only change does not. Existing transfer/settled-projection exclusions from configureSettings and pending restoration remain intact.

## Layout: a viewport rectangle is not a hard work bound

Inspected installed SDK AppKit NSLayoutManager.h: the comments immediately above ensureLayoutForBoundingRect reserve layout/glyph generation beyond requested ranges; non-contiguous layout may not always be used. `EditorPane` enables allowsNonContiguousLayout, but that is not a time/memory limit. Single-pane pending and deferred-live origins reach applyOrigin above the 2M split limit. Saved y coordinates may reach 1e9. A 100MB single long paragraph is therefore not contained by the small rectangle.

Do NOT promote the private unconditional ensureLayout call. Proposed narrow eligibility for new eager layout:

- exact attached pane/container/storage ownership and non-contiguous-layout flag;
- finite positive clip/editor geometry and finite translated rectangle, with coordinate/dimension limits chosen from supported test geometry;
- storage UTF-16 length at or below an explicit measured eager-layout ceiling, never above the existing2M split ceiling;
- one request per pane/origin attempt; no full-container layout, prefix-layout fallback, loop, timer replay or elapsed-time check advertised as cancellation of the synchronous call.

The ceiling is a total-input cap, so it protects against a long paragraph anywhere in the document without scanning for long lines. It must be selected from measurements, not guessed from the rectangle. Start the private cost probe at64Ki/256Ki and include1M/2M; the production ceiling can be no larger than the largest tested size that passes ALL paragraph/content cases. Current evidence has not established a safe numeric ceiling. If none passes the agreed budget, keep eager layout unpromoted rather than claim it is bounded.

Above the ceiling (including10/100MB), skip only the NEW eager-layout call. Preserve the legacy single constrain/scroll attempt against existing geometry and signal when the requested literal origin could not be achieved, using the existing restoration warning path or a small typed result (applied/clamped/layoutSkipped/unavailable). Selection restoration and existing large-file capability remain available. No silent assertion of exact origin restoration and no asynchronous replay. A precondition-false result may consume the one saved-origin attempt as existing pending-presentation semantics require; retain honest warning/receipt rather than freezing future live caret capture.

## Required bounded performance gate

Use an isolated native process per fixed synthetic case under the accepted owned watchdog, with exclusive performance ownership. Measure baseline vs candidate cold layout, repeated unchanged/theme-only settings, and changed typography separately. Do not add full-container layout to establish a fixture then call it cold.

Matrix:64Ki/256Ki/1MB/2M-UTF16 around proposed eligibility, plus10/100MB skip-path controls; newline-dense text, one huge paragraph/line, and mixed text with a pathological paragraph near a deep origin; wrap on/off; low/deep/out-of-bounds saved coordinates. One pane always; two panes only within real2M admission, never bypass the product cap to claim support. A1GB case belongs to large-file capability testing; the new eager-layout guard must skip the new explicit ensureLayout call. The preserved constrain/scroll attempt and framework construction can still induce implicit layout; neither this guard nor a zero explicit-call count proves zero framework layout.

Record requested/actual origin, clip/frame geometry, count/type of explicit layout requests, main-thread duration of applyOrigin and setter groups, peak/incremental RSS, source/toolchain hashes and exact guard decision. Avoid diagnostic getters that themselves perform layout (usedRect/numberOfGlyphs/range-with-layout); any observation should be documented as non-layout-causing. Do not log real text.

Recommended provisional slice budget for selecting the ceiling: added synchronous restore work p95<=50ms and max<=100ms, with bounded measured memory growth across the eligible matrix. These are proposed review gates, not claimed measurements or a substitute for BUILD_PROMPT cold-launch2s/100MB-usable5s/input-p95<50ms requirements. Record misses and lower eligibility or redesign; do not soften the expectations after a failure. The skip path must show zero NEW explicit eager-layout calls even at100MB/long-line and negligible additional work relative to baseline. Use repeated cases; one passing small GUI run is not cost acceptance.

## Implementation/test split after design review

1. Applied-state/receipt slice: EditorDocument (+small internal types if useful), EditorDocumentTransferAdapter, narrow controller application/inheritance and endpoint receipt changes; configuration busy guard in EditorDocumentCloseAdapter. Hidden tests establish idempotence and cross-window transfer/reconstruction coherence before GUI.
2. Layout eligibility/cost slice: bounded private measurement first, then DocumentPanePresentation guard/result plus all three callers/warnings and durable small/large-skip cases. Do not conflate literal-origin correctness with cost acceptance.
3. Integrate the separately approved focus remedy and run exact uninstrumented native/packaged restoration tests on both axes, with source-matched standard transfer/close/monitor compatibility.

Required settings cases: no-settings control, unchanged and theme-only preserve established literal240/940 origins through next turn/recapture with zero typography setters; font17/tab8 and wrap changes reach both panes/storage; manual wrap is reset by unchanged/theme-only applySettings as today; late/blocked startup settings reach restored documents; transfer between differing window policies preserves style during transaction, next destination no-op settings reconciles, later equal settings is setter-free; new/reused pane inherits current style; signature/wrap/policy tampering fails both transfer reconstruction paths; reentrant configuration refusal cannot stamp success or admit transfer/close mid-write.

This design imports no telemetry, raw traces, production timers, full-text comparisons or new persistence schema. It preserves current settings intent while making the applied-state proof explicit. Remaining acceptance is intentionally split among correctness, ownership, actual packaged behavior and measured layout cost.
