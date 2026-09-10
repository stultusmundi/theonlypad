# Native close adapter verification

- Compiled red `run.NSisjPrz`: clean close failed the throwing adapter seam. The following dirty test encountered an AppKit InvalidTransition after the first test exited without cleanup; that second result is retained as a separate fixture/lifecycle limitation, not evidence of the close behavior.
- First implementation: two tests passed.
- Expanded test source initially had a missing declaration newline; compilation failure retained separately.
- Corrected expanded run `run.fPd5gUsC`: four native XCTest cases passed, zero failures, 0.493 seconds.
- Strict formatter lint, shell syntax and diff checks passed. Formatting-only changes followed the expanded run.

The tests use actual application-mode EditorWindowController, native factory/model, registry, recovery actor and paired publisher. They cover clean close preserving history and semantic state with empty projection/final recovery read; dirty native insertText followed by Cancel; confirmed discard without history; endpoint loss after deletion retaining the transaction until actual replacement-controller projection. Decisions are injected through the existing confirmManagedClose seam. No window is shown or activated and no input events are posted.

Private runs excluded the root's in-progress NativeApplicationDocuments.swift while using the other captured native sources. The retained `scripts/test-native-application-close.sh` now snapshots all production native files except the executable main; its full composition run is pending root integration. The subsequent full-source run below exercises the wrapper repair installer against actual actor publication.


## Actual actor repair regression

`run.qPRt6yjb` compiled the full retained native source snapshot and passed all five tests (zero failures, 0.527 seconds). The added test injects the real RecoveryStore `afterRename` removal fault, using no fabricated receipts. Before repair, the retained native model keeps its original authority, issuance fence and semantic close state; actual native insertion is refused. Explicit retry repairs through the real actor and native installer, preserves exact normalization-sensitive Unicode/CRLF text, retains the same model/projection, and reopens native editing. A pre-close-authority write is refused; a newly captured repaired-authority write succeeds and exact recovery readback matches the edited text.

This is additional coverage of existing implementation, with no observed shipping defect or production change. No new behavioral-red claim is made. Decisions remain injected; no visible desktop/physical-input acceptance is claimed. Formatting-only changes followed this run.
