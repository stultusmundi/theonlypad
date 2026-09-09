# Asynchronous window lifecycle review

Status: reviewed fixes copied into production; full integrated verification is running. This is not packaged desktop evidence.

The known regression is a delayed editing completion presenting an error after its owning window closes. Weak controller capture alone is insufficient: other owners can retain a closed controller. UI delivery must validate lifecycle or a generation invalidated by closure.

The routing harness reproduced a late transform alert after `windowWillClose`; the guarded `present` helper passes that regression. Independent review found `formatJSON` created its own stale-result `NSAlert`, bypassing the helper. Its actual delayed-format modal was reproduced, then the closed-window guard passed. A further review found encoding validation could apply metadata and register undo after forced teardown; a gated validation regression reproduced that mutation, then passed after guarding only the async completion. The undo setter remains unchanged.

The bounded variant search started with the exact JSON stale-result message, expanded to `runModal` in the controller, then searched `Sources/TheOnlyPad` for the same sink. Broader results were predominantly synchronous user actions or application-level dialogs, so no blanket alert rewrite or lexical CI prohibition is justified. Direct alerts are not inherently erroneous.

| Candidate | Triage |
| --- | --- |
| Delayed selection transform | Confirmed lifecycle bug; medium usability impact, runtime confidence. Candidate fix tested. |
| JSON formatting stale-result alert | Confirmed lifecycle bug; medium usability impact, runtime confidence. Candidate regression and fix passed. |
| Encoding conversion completion | Confirmed metadata/undo mutation after forced teardown; medium correctness impact, runtime confidence. Completion guard and regression passed, as did the unchanged DirtyState compatibility harness. Normal window close is already blocked while conversion runs. |
| Statistics completion | Ruled out: window close increments the generation checked before presenting. |
| Search replacement confirmation | Ruled out: closing the search panel cancels work and advances the completion generation. |
| Standalone startup recovery delivery | Added a closed/quitting completion guard; source-reviewed defense. No dedicated delayed-restoration race test is claimed. |
| Recovery failure reporting | Added a closed-window guard; source-reviewed defense. Quit-veto reporting remains available after its existing veto reset. |
| Encoding panel scratch reopen | Panel closes and is released on owner teardown; callbacks validate live document/window. Source-reviewed defense, not a detached-worker regression claim. |

Regression protection belongs in the native integration harness: suspend actual work, close the owning window, release the worker, and assert no alert or document mutation. Generation-protected panels should retain their existing cancellation coverage. This is a narrow correctness review, not a completed distribution security audit.
