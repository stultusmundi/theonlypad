# Searchable offline Help — 2026-10-08

The existing native Help window now searches its complete offline guide and command reference. Every effective registered command appears, including disabled or unassigned commands as **No shortcut**. The shortcut legend includes Control. This is a bounded H-09 implementation; complete recovery-message usability, desktop interaction and accessibility acceptance remain outstanding.

| State | Scope |
| --- | --- |
| Planned | Run the prepared packaged Help desktop workflow after user-owned macOS UI Automation authentication is available. |
| Implemented | Literal case-insensitive search, first-match selection, next/previous wrapping, match status, complete effective command reference and Control legend. |
| Tested | One frozen native XCTest passes all search/reference assertions; 40 pure runner checks pass. Current app build and full core suite pass 848 tests. The shown guide viewport harness passes its original initial-size and two explicit-size checks. The desktop test bundle compiles. |
| Blocked | Actual XCUITest execution: the preceding packaged baseline runner timed out requesting Enable UI Automation authentication. No grant is inferred. |

## Behavior and boundaries

Typing selects the first matching passage. Return, the search button and Next advance; Previous moves backwards. Both directions wrap. Empty input clears the status; unmatched input reports **No matches**. Navigation is disabled in either case. Searches use UTF-16 ranges compatible with the native text view and never modify the guide.

Help continues receiving the effective command registry from AppDelegate. It does not read shortcut drafts or stored profiles independently. Existing shortcut publication closes Help; reopening after Apply reflects the new registry. Dispatch, menu readiness, command availability and shortcut persistence are unchanged. Private supervised-search work is not described as activated editor behavior; the guide retains its cooperative ICU cancellation limitation.

`HelpController.swift` is the only changed production source. No package or asset dependency was added.

## Native evidence

`scripts/test-help-reference.sh` uses the existing frozen native coordinator and its direct owned watchdog. It shows no windows and posts no keyboard events. The real controller receives a real ShortcutComposer result containing an override, a disabled assignment, unassigned and extension-style commands. Assertions cover every effective reference row, stale-default refusal, literal punctuation, case-insensitive matching, supplementary Unicode selection, exact selected ranges/substrings, scrolling, forward/backward wrapping, Return, query reset, no-match/clear states and unchanged read-only guide content.

The old controller compiled and executed one test with **58 failed assertions** for missing controls/reference entries and the incomplete legend. The complete implementation passed that same test. Review then added a discriminator for `sendsWholeSearchString`: a separate copy of the earlier frozen configuration failed **one test/one assertion**, and the corrected current configuration passed. All earlier assertions were retained. The AppKit SDK confirms that this setting restricts target actions to Return/Enter or the search-button click, preventing delayed keystroke actions from advancing the first match. Hidden checks do not prove physical typing.

The pre-format passing native source manifest is SHA-256 `324be9455b89a68139da5f68b2a4e08fb16cff202d56f5210510a42138ffd804`. A fresh run after test-only formatting also passes one test with zero failures; its manifest is `202ab4a04340b67e67b8d31edbe80b9157b492fce48257195d139aa97a9d013b`. Root verified each inventory of 168 original and 132 generated input files and both complete stage receipts. The pure coordinator selection/result/freezing checks had an initial 40-test run with two failures for the missing Help selection, followed by **40/0**. Existing receipt, source-membership and symlink checks were preserved; the new wrapper must not be enclosed in another session-owning watchdog. The CI entry was added but hosted CI was not executed here.

## Visible viewport target correction

The existing shown `HelpHarness` initially failed its usable-viewport assertion. A retained geometry diagnostic showed it had selected the search field's native 16-pixel-high field editor, with no enclosing scroll view. Its old first-descendant lookup did not identify the guide after the new search field became the initial responder.

The corrected harness selects the unique `help.text` guide and additionally rejects field editors or a missing scroll owner. Every original viewport threshold, initial/700×600/440×360 size, start/end glyph visibility and text-preservation assertion remains. The corrected run passed against the same production controller and verified core build. Neither the first failure nor the diagnostic is relabeled as a pass. This shown native viewport check is separate from XCUITest, physical input and VoiceOver acceptance.

## Review and reproducibility

Independent source review approved the bounded implementation and identified two resolved preparation gaps: the desktop test now waits for the actual Help menu item to become enabled after asynchronous shortcut composition, and the native test checks the configured search-action boundary. The later viewport target correction is recorded separately from that original review.

Proven focused commands:

```sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
scripts/test-help-reference.sh
```

The existing `scripts/test-native-integration.sh` includes the shown Help viewport harness. Only its Help subset was executed for this checkpoint; its full current suite is not claimed rerun. Exact frozen compilation/execution inputs and owned receipts remain in ignored local evidence.

`testHelpSearchUsesEffectiveShortcutReference` is prepared in the actual GUIProbe target. It seeds an isolated strict shortcut profile before launch, checks customized Open, disabled Save, unassigned Help and default New Tab rows, then exercises native search/navigation and guide immutability. `xcodebuild build-for-testing` passed. The test itself is **unrun**. The [separate packaged baseline](packaged-checkpoint-2026-10-08.md) records the authentication failure and older artifact hashes; those artifacts do not include this Help change.

## Local package

`scripts/package.sh --ad-hoc-sign` and the standalone `scripts/check-package.py`
check pass for this Help source. Root reverified all 727 pinned repository inputs
and the complete direct-watchdog receipt. The bundle contains six verified files;
the archive bytes and SBOM hashes match. This is local ad-hoc packaging, with no
release publication, Developer ID or notarization claim.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| App executable | 6,729,664 | `905ebc2489cc91042a9b77cb83857bffad5f66b6aa71cfa2bb0b96fb07f4a22e` |
| Development ARM64 archive | 2,469,276 | `b5e5a9dbdc0bf4ee07f1bcba5d3a6979963536651aa124a61c73a07d40550aab` |
| SBOM | 986 | `44076c322c0df9a299f63153fa24d043b6512de88c601e2c5fef9a00a91fb921` |

The shown viewport was tested against a debug source build; this new release
package has not passed desktop interaction. Earlier packaged desktop successes
belong to their recorded historical artifacts.

Raw evidence stays ignored under `.local/help-reference-tests/`, `.local/help-search-action-regression/`, `.local/help-viewport-checked/`, `.local/help-core-owned/` and `.local/help-desktop-build-owned/` and `.local/help-package-owned/`. No minimum-OS, Intel, large-file performance, physical IME, VoiceOver, full H-09 or release acceptance is established.
