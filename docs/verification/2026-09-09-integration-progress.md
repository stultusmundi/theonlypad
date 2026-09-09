# Integrated development evidence — 2026-09-09

Status: incomplete application. This records a working development checkpoint and subsequent defects, not completion of the build brief.

Latest checkpoint: 190 core tests and the complete native suite passed after session startup/quit integration. Strict formatting, public-source pattern checks, diff checks and six packaging rollback tests passed. The refreshed ad-hoc package passed four actual XCUITests (181.300 seconds, zero failures), including failed session-write quit refusal followed by continued editing and successful recovery, tab undo isolation and appearance reset. See [the packaged UI evidence](xcuitest-feasibility.md) for its exact binary hash and retained result location. Native scroll visibility and tab accessibility-ID defects were reproduced and fixed. Earlier checkpoint details below describe their earlier scope; they do not supersede this evidence.

The full core suite passed 184 tests (local tool timestamp14:48:10), including nine SessionStore and six SessionRestoration tests. The complete native suite subsequently passed with the retained marked-text, typing-coalescing and responder-undo regressions. A separate retained DirtyStateHarness also passed against the merged controller. Strict formatting, public-source pattern checks and six package-promotion rollback tests passed at the earlier checkpoint; they must be repeated after the latest edits. Public checks are limited pattern checks, not exhaustive secret scanning.

| Subsystem | Actual evidence | Remaining limitation |
| --- | --- | --- |
| Save backups | Original UTF16 bytes/encoding captured; restore as scratch; storage obstruction leaves original unchanged; native manager confirms deletion | Power-loss, large-payload memory and broader fault acceptance incomplete |
| Comments and line commands | Native text changes, stale selection refusal, one undo, macro capture | Full language semantics and physical shortcuts unverified |
| Bookmarks | Native insertion/deletion/undo/redo, gutter draw/click, unrelated later bookmark retained after line duplicate; composition commit/restoration, coalesced typing and responder undo regression checks | Physical IME, multi-region mapping and persistence incomplete |
| Outline | Lexical core tests, filtering, unsupported language reporting, exact captured-document navigation across a tab switch | Heuristic subset; folding/completion/snippets absent |
| Markdown and comparison | Inert native preview; bounded comparison, synchronized scroll, strict input loading and unchanged source | Physical desktop/accessibility acceptance incomplete |
| Recovery | Bounded reads/scans, oversize preservation, save quotas, ordered batch updates, two-window quit flush, forced-process restart | Shared-owner assumption; not an atomic multi-file transaction |
| Sessions | Private strict v1 serialization, bounds, injected write failures and recovery/session merge planning | Native full-session restoration not integrated |

Independent native probes found that provisional `setMarkedText` can call shouldChange without textDidChange; bookmark anchors then stayed stale and subsequent composition was rejected. They also found bookmark metadata undo entries split native x/y/z typing into three undo steps instead of one. The integrated fixes explicitly handle nested composition callbacks and register a metadata snapshot before native text undo for a typing/composition run. The window delegate supplies the document undo manager for responder-routed Undo/Redo. Retained regressions pass, including independent field-editor Undo. These are programmatic NSTextInputClient tests, not physical IME results.

The local app, ZIP and SBOM were regenerated after these fixes with ad-hoc signing; signature verification passed. A real XCUITest on the preceding development package passed native dialog open, typed replacement, Command-S save and exact disk-byte verification. The retained test is being extended and rerun against the refreshed package; quit/reopen is not yet verified by this record.

Actual editor performance probes are in [native-editor-performance.md](native-editor-performance.md). Dirty-state comparisons accounted for over99% of the measured first100MB append. The integrated cache uses exact UTF-16 comparison, a length shortcut and synchronous character-edit invalidation; retained tests cover direct storage mutation, unfinished batches, Unicode normalization, save baseline, undo/redo, marked text and encoding/BOM changes. Isolated actual-controller measurements improved the first100MB append to11.89–13.93ms. Same-length first comparisons and pathological long-line layout still miss targets; final integrated performance acceptance remains outstanding. Targets have not been lowered.

No remote push, merge or release occurred. No DeveloperID/notarization, Intel/minimum-OS runtime, physical keyboard/IME/VoiceOver, clean-machine or full packaged workflow acceptance is claimed.
