# Custom language implementation plan

Design: [custom languages](../specs/2026-10-12-custom-languages.md).
All steps require failing behavioral tests before implementation, source review,
matching executed evidence and unchanged neighboring regressions. Private source
candidates are not public implementation. Root owns serial compiler and GUI runs.

| Step | Deliverable and acceptance | State |
| --- | --- | --- |
| 1 | Validated profile values, exact literal equality, bounded strict JSON, definition codec and catalog resolver; preserve existing shortcut/language fixtures | In progress: private baseline compiles; 21 component cases expose 109 ordinary failed assertions. Fresh implementation pending verification |
| 2 | Owned durable catalog store; stable revisions; import/export, corruption and interrupted replacement controls | Planned |
| 3 | Bounded cancellable literal lexer; Unicode, delimiter priority and span-limit fixtures | Planned |
| 4 | Per-language indentation and comments; exact edits and reversible grouped undo | Planned |
| 5 | Authoritative document selection and compatible persistence; missing-ID restoration, duplication, history and transfer | Planned |
| 6 | Native catalog owner/highlighter/policy integration; current-generation admission and applied-setting receipts | Planned |
| 7 | Working native manager/picker and command routing; real create/edit/delete/import/export and missing-profile presentation | Planned |
| 8 | Complete frozen application integration, source review and existing regression suites | Planned |
| 9 | Actual desktop workflow, packaged runtime, documentation and final requirement review | Planned |

The separate existing command-registry baseline reaches one expected assertion:
the manager command is absent. It stays outstanding until step 7 supplies the
working manager; a placeholder command cannot satisfy it. Private compilation
contracts are deliberately incomplete and must not be adopted as implementation.
Already passing private value comparisons and guarded assertions not reached in
the baseline receive no failing-test credit. The original built-in block-comment
comparison does reach its normalization-distinct literal failure.

Public contributor commands will be recorded after the corresponding code and
runner are adopted and executed. The current baseline runs in an isolated private
Swift 5 package using the checked-in owned-process watchdog, synthetic data and
warnings as errors. No store, native language UI or desktop result is claimed.
