# Integrated editor progress

Full scope remains the master roadmap and requirements matrix. These are partial checkpoints.

## Planned

Shared native registry dispatch; secure document lifecycle; macro, external-command and declarative extension integration; bounded workspace/folder search; Unicode CLI navigation; native conversion tools and printing; independent review and fresh packaged checks.

## Implemented

- Tab pin/reorder/close/reopen controls and codec/endings panel.
- Native macro record/manage/repeat/one-undo replay, retaining unsaved recording during library save and blocking quit while persistence is active.
- Bounded read-only large file UI; filtered workspace file list.
- External command UI/runner, explicit user invocation, literal arguments, bounded captured output/timeout, process cancellation and quit drain.
- Declarative extensions with disabled initial install, capability disclosure, strict catalog validation, sample and command registry integration. Dispatch revalidates enabled state.
- Independent print view with native print panel, shared-registry Help and shortcut reference.

## Tested

Native integrated harness passed after workspace, encoding, macro and print integration. Separate external and extension lifecycle harnesses passed; script now incorporates them and workspace harness. Core suites have separate passing records; the final combined suite must be rerun after all current workers settle.

Independent reviews resolved external controller retention and quit-time launch races, stale enabled extension dispatch, and unbounded save-conflict reads. Printing PDF generation verified; pagination/UI flow not accepted yet.

## Active / outstanding

CLI URL protocol/Unicode navigation, conversion tools and folder search are active worker tasks. Root integrates callbacks with document identity/text checks. Subsystem tests and native controller checks are not complete desktop acceptance.

AX permission absent; physical desktop keyboard/dialog/IME/VoiceOver, app-level protocol delivery, complete packaged workflows and GUI performance remain unverified. Full advanced editor, panes, persisted workspace tree, preview/diff/language intelligence, folder replacement backup transaction, preferences/shortcuts/localization and remaining matrix requirements are outstanding.

## Verification commands

`scripts/swift.sh test`; `scripts/test-native-integration.sh`; `xcrun swift-format lint --strict --recursive Sources Tests Package.swift`; `python3 scripts/check-public.py`; `scripts/package.sh --ad-hoc-sign`.
