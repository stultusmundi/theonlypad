# Preferred pane focus verification

Task2 of the [pane restoration remedy](../superpowers/plans/2026-09-10-pane-restoration-remedy.md) is implemented, independently reviewed and verified with hidden native tests on macOS (2026-09-10). Packaged desktop and physical input acceptance remain outstanding for this production snapshot.

Saved presentation installation now requires both AppKit's acceptance and the exact requested editor as the window's actual first responder. It revalidates installation authority after focus callbacks and checks responder identity again after origin callbacks, before clearing pending presentation metadata. Owner projection uses the existing token-and-pane-scoped focus helper; ordinary installation uses ordinary native focus. Refusal follows existing structural rollback and preserves pending presentation without claiming that native focus was restored.

General editing, selection, configuration, composition and transfer admission remain unchanged. No queued refocus, eager layout, diagnostic tracing or new persistence field is included.

## Verified results

| Check | Result |
|---|---|
| Preferred focus and existing controller projection | 20 tests passed |
| Applied settings and native admission | 24 tests passed |
| Existing native document transfer | 12 tests passed |
| Native close model | 106 checks passed |
| Document factory | 133 checks passed |
| Shared pane ownership | 1 complete scenario passed |
| Pure native coordinator contracts | 30 tests passed |

The close runner also built the complete frozen application. All 15 native stage receipts passed strict typed validation, including exact commands, wait completion, process-group cleanup and actual captured byte lengths. Original/generated source inventories, core-object membership and hashes, and native binaries were checked against the frozen inputs. The separate pure-test receipt was complete. Scoped strict formatting, public-source and whitespace checks passed.

Proven commands:

```sh
scripts/test-editor-transfer-projection.sh
scripts/test-document-applied-settings.sh
scripts/test-native-document-transfer.sh
scripts/test-native-close-model.sh
python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
```

These coordinators freeze inputs and call the accepted watchdog in the same process. Do not wrap them in another session-owning watchdog. The zero-argument close runner builds its own matching application; [runner verification](native-regression-runners.md) describes optional prebuilt prerequisites.

## Behavioral red and regression coverage

The original-controller run executed 14 tests and produced four failures: both focused slots in both split orientations lacked the expected actual responder after managed startup. The single-pane insertion/undo control and original nine projection cases passed. The narrow repair then passed all 14.

A separate supplemental negative control executed 18 tests with 26 failed assertions across eight cases. It restored only the original saved-installation body, retaining the Bool-returning helper so test access still compiled. Its failures mapped to the four split-responder cases, ordinary focus refusal, scoped focus refusal, misleading native success and responder displacement after origin application. This controlled result is distinct from the actual original-controller 14-test baseline. An earlier supplemental fixture type error was a compilation failure, not behavioral red evidence.

The final 20 tests retain the original nine and add five startup cases, ordinary success/refusal, three scoped refusal/displacement cases and reentrant interaction invalidation. Startup uses real synthetic session/recovery stores and the native process owner. Assertions check the actual first responder after startup and subsequent admission changes. Insertion is sent only through that independently verified responder; exact shared text and undo restoration are required. A missing responder fails before the conditional insertion step.

Refusal tests verify attached panes, selections, preferred pane, ownership/revision, retained pending/session presentation, and cleared installation/suppression state. They do not fabricate accepted session receipts or assert successful native refocus during rollback.

Focus-entry and post-origin probes, plus private test access, are inserted only into frozen test copies. Successful focus retains the original native admission/body; explicit refusal and false-success overrides are identified simulations. Removing those declared probes/access reconstructs the production controller byte-for-byte. Independent review returned **specification PASS and code-quality/admission/rollback PASS**, with no material findings.

## Reviewed source identity and limits

| File | SHA256 |
|---|---|
| `Sources/TheOnlyPad/EditorWindowController.swift` | `cba2ab870a416591f20b6f3f1bfadeff5117c2a629945b3ef8c1bb362182b0f1` |
| `Tests/NativeIntegration/EditorTransferProjectionTests.swift` | `419f56da87419668d11d39b08197b81393c0023343e9dbc8cb3459d4b5ac7547` |
| `Tests/NativeIntegration/run_native_regressions.py` | `ab36795c0d8395fc37edfa67339d8a02f8491da74cd0e0aa5179dd1c95bc10df` |
| `Tests/NativeIntegration/test_native_regressions.py` | `4df9e51687669864b4daf3c86329c3a10155681ea231788ff7e0e470211e9cca` |

Final projection manifest SHA256: `755132bda8db037e3bcb3bdca3e601c3190424c700a962c57ae520245c67954c`. Raw receipts, negative-control mapping and synthetic state remain ignored and private.

These checks do not show windows, post keyboard events, or establish physical keyboard, IME, VoiceOver or packaged desktop behavior. Native scroll restoration remains the existing best-effort behavior. Eager-layout eligibility, changed-typography cost and integrated desktop acceptance remain separate tasks; no origin or timing guarantee follows from these focus results.
