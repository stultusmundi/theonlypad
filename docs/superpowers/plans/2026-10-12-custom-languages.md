# Custom language implementation plan

Design: [custom languages](../specs/2026-10-12-custom-languages.md).
All steps require failing behavioral tests before implementation, source review,
matching executed evidence and unchanged neighboring regressions. Private source
candidates are not public implementation. Root owns serial compiler and GUI runs.

| Step | Deliverable and acceptance | State |
| --- | --- | --- |
| 1 | Validated profile values, exact literal equality, bounded strict JSON, definition codec and catalog resolver; preserve existing shortcut/language fixtures | Adopted at `4d22211`: corrected frozen76/0 and current application/helper build with focused77/0; strict lint and independent review pass. See ../../verification/custom-languages-core.md |
| 2 | Owned durable catalog store; stable revisions; import/export, corruption and interrupted replacement controls | Implemented/tested core component: baseline28/115 ordinary failures; matched104/0 plus separate real readback faults2/0 and wrapping control2/4. Formatted public package1122/0 and app/helper build pass; native use remains planned. Read-only inspection subsequently passes focused5/0, compatibility35/0 and formatted application1164/0 with a cold app/helper test dependency build and incremental build confirmation, independently audited; repair/evidence recovery remains outstanding. See ../../verification/custom-language-catalog-inspection.md |
| 3 | Bounded cancellable literal lexer; Unicode, delimiter priority and span-limit fixtures | Implemented/tested core component: baseline26/90 ordinary failures; matched35/0, reviewed formatted adoption and public1122/0. Native highlighter remains planned |
| 4 | Per-language indentation and comments; exact edits and reversible grouped undo | Core implemented/tested: authentic baseline45/99 ordinary failures; reviewed frozen54/0 with unchanged compatibility tests. Formatted application1143/0 and app/helper build pass; native admission/Tab/undo remain planned. See ../../verification/custom-language-editing.md |
| 5 | Authoritative document selection and compatible persistence; missing-ID restoration, duplication, history and transfer | Core persistence implemented/tested: genuine baseline35/51 ordinary failures, reviewed unchanged35/0; formatted current public1159/0 and app/helper Werror build. Native propagation through seeds/model/history/duplication/reload/transfer/capture and visible missing-profile UI remain planned. See ../../verification/custom-language-session-codec.md |
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
warnings as errors. The adopted store and lexer are component evidence only; native language UI and desktop acceptance remain outstanding. See [component verification](../../verification/custom-languages-components.md).
