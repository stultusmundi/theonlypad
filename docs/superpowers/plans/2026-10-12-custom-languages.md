# Custom language implementation plan

Design: [custom languages](../specs/2026-10-12-custom-languages.md).
All steps require failing behavioral tests before implementation, source review,
matching executed evidence and unchanged neighboring regressions. Private source
candidates are not public implementation. Root owns serial compiler and GUI runs.

| Step | Deliverable and acceptance | State |
| --- | --- | --- |
| 1 | Validated profile values, exact literal equality, bounded strict JSON, definition codec and catalog resolver; preserve existing shortcut/language fixtures | Adopted at `4d22211`: corrected frozen76/0 and current application/helper build with focused77/0; strict lint and independent review pass. See ../../verification/custom-languages-core.md |
| 2 | Owned durable catalog store; stable revisions; import/export, corruption and interrupted replacement controls | Implemented/tested core component: baseline28/115 ordinary failures; matched104/0 plus separate real readback faults2/0 and wrapping control2/4. Formatted public package1122/0 and app/helper build pass; native use remains planned. Read-only inspection subsequently passes focused5/0, compatibility35/0 and formatted application1164/0 with a cold app/helper test dependency build and incremental build confirmation, independently audited; repair/evidence Core subsequently passes focused47/0 and formatted full application1176/0; owner recovery and native manager integration remain outstanding. See ../../verification/custom-language-catalog-inspection.md and ../../verification/custom-language-catalog-repair.md |
| 3 | Bounded cancellable literal lexer; Unicode, delimiter priority and span-limit fixtures | Implemented/tested core component: baseline26/90 ordinary failures; matched35/0, reviewed formatted adoption and public1122/0. Native highlighter remains planned |
| 4 | Per-language indentation and comments; exact edits and reversible grouped undo | Core implemented/tested: authentic baseline45/99 ordinary failures; reviewed frozen54/0 with unchanged compatibility tests. Formatted application1143/0 and app/helper build pass; native admission/Tab/undo remain planned. See ../../verification/custom-language-editing.md |
| 5 | Authoritative document selection and compatible persistence; missing-ID restoration, duplication, history and transfer | Core persistence implemented/tested: genuine baseline35/51 ordinary failures, reviewed unchanged35/0; formatted current public1159/0 and app/helper Werror build. Native propagation through seeds/model/history/duplication/reload/transfer/capture and visible missing-profile UI remain planned. See ../../verification/custom-language-session-codec.md |
| 6 | Native catalog owner/highlighter/policy integration; current-generation admission and applied-setting receipts | Standalone read owner and fixed native regression adopted locally: fourteen tests pass; matching application candidate passes1,203 and app/helper build. See ../../verification/native-language-catalog-loading.md. Full native activation/highlighter/policy acceptance remains outstanding. See 2026-10-15-native-language-catalog-loading.md |
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


Standalone Core URL transfer checkpoint: implemented `LanguageProfileTransfer` with matching metadata/identity reads, strict definition codec and create-only atomic export. Tested fourteen real-file cases plus current full application/helper 1,190/0 and actual contributor filter; reviewed Source and actual evidence independently. Manager integration, recovery dialogs, application owner activation and native/desktop acceptance remain planned. See `docs/verification/custom-language-profile-transfer.md`; do not mark D-04 complete from this Core checkpoint.

## Catalog loading design checkpoint — 2026-10-15

The [standalone loading-owner design](../specs/2026-10-15-native-language-catalog-loading.md)
and [execution plan](2026-10-15-native-language-catalog-loading.md) are reviewed.
One retained off-main read publishes immutable catalog state; busy admission,
observer reentry, failed reload and joined invalidation have explicit contracts.
The subsequent inert baseline reached thirteen failing methods/eighteen ordinary assertions. The completed standalone owner and retained command now pass fourteen formatted tests, with a separate matching application build and1,203-test pass. See [read-owner verification](../../verification/native-language-catalog-loading.md). Manager activation and desktop acceptance remain outstanding.

## Private manager progress checkpoint — 2026-10-13

Steps 6–9 retain their full integration and acceptance scope. A private candidate
now implements and tests part of step 7: real local profile workflows, advanced
rules and child closing, built-in overrides and two error-presentation fixes.
Reviewed composition preserves both parent branches, all original twenty-four
test bodies and the exact two-error/five-built-in suffixes. It does not adopt the
manager, register a placeholder command or activate it in AppDelegate.

Planned, implemented and tested states remain distinct. Native manager component
implementation is private; its composed package passed thirty-one unique methods
on one matching built bundle, after the focused seven-case run. Counts overlap
and are not added. Actual synthetic file publication, independent fresh readers,
raw Unicode preservation, inheritance/removal, invalid inputs, pending Retry and
native-close successor behavior are tested within those methods. Source/compiler/
link/bundle bindings and complete owned-process receipts were independently
reviewed. See [the private manager checkpoint](../../verification/custom-language-manager-private.md)
for exact limits and short evidence bindings.

Next required work includes reviewed public adoption and process activation,
picker/command/highlighter integration, availability and invalid-draft close
policy, built-in actionable validation, layout/accessibility polish, default
sheet and quit behavior, actual visible workflows and a new packaged test.
Native comment result and undo/redo selection is separately unresolved. None of
these outstanding acceptance gates is satisfied by hidden component tests or by
the older five-test packaged desktop checkpoint.

Public application code remains `70db8b1`; existing distribution artifacts remain
`f45f1e9`. No new public manager runner or contributor command is claimed before
its code and harness are adopted and executed. D-04 and the full BUILD_PROMPT
remain incomplete; no remote publication is authorized by this local checkpoint.


## Private presentation follow-up — 2026-10-13

Step 7 has further private component evidence: labeled scrollable forms and fixed
footers, accessibility/key-view metadata and built-in validation/correction/Save
now pass thirty-four unique methods on one frozen native bundle. The focused
three overlap this count. Actual geometry covers three windows at three content
sizes; the original tests remain unchanged after diagnosing and correcting one
optional fitting-priority tie. See the newest [private manager checkpoint](../../verification/custom-language-manager-private.md)
for bindings, historical failures and exact acceptance limits.

The full step remains outstanding. Layout and built-in guidance are implemented
and tested privately; public adoption, availability, unsubmitted/invalid edit
retention, real sheets/menu/keyboard workflows, quit and packaged application
acceptance still need completion. Close-retention design is being reviewed before
its next test cycle. No new public runner, production activation, full Core test
run or distribution artifact follows from this private checkpoint.


## Private parent closing follow-up — 2026-10-13

Step 7 now has reviewed private component evidence for parent user-close
confirmation and scoped raw-input retention through real owner reloads. The
unchanged test family passes four focused methods/eight fixtures and all
thirty-eight unique manager methods on the same frozen bundle. The focused four
overlap the total; no full Core or packaged desktop acceptance is claimed. See
[the private manager checkpoint](../../verification/custom-language-manager-private.md)
for the reached failures, repair and source/actual bindings.

Implementation and tests remain private. General raw preservation and stale-form
reconciliation, child user-close policy, actual field editors, pending/quit
behavior, default sheets/menu/keyboard routing and public application integration
still require completion. A bounded advanced-child three-method design has been
reviewed; its tests and implementation are next, not accepted behavior. Steps 6–9
and full D-04 retain their original outstanding acceptance scope.


## Private advanced-child user closing follow-up — 2026-10-13

Step 7 now includes reviewed private advanced-child user-close handling. Three
focused methods cover six fresh standalone/no-field-editor fixtures; the same
built bundle passes forty-one unique manager methods. Focused counts overlap
the total. The corrected baseline first exposed premature close and missing
confirmation; the implementation preserves unapplied/invalid raw fields, checks
current approval at native close and protects successors. See the latest
[private manager checkpoint](../../verification/custom-language-manager-private.md)
for compiler-failure history, reached paths and exact evidence limits.

Attached-sheet/default confirmation behavior, field editors/marked text, other
child families, pending/quit behavior, general raw retention and reconciliation,
menu/keyboard routing, public adoption and packaged desktop acceptance remain
required. This private component does not complete steps 6–9, D-04 or the full
BUILD_PROMPT, and does not change production code or distribution artifacts.
