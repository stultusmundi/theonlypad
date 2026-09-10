# New-window integration and local package

Verified source: `55a7b1bb9ee50b6ea5f94b64cae5657a25e9dd5b`. All three new-window implementation tasks received independent specification and quality approval. This closes the local implementation slice, not aggregate F-02 or the application brief.

## Committed-source integration

A clean detached worktree under ignored `.local/new-window-integrated` held the exact commit. Its 580 tracked files have SHA-256 provenance in `.local/new-window-integrated-evidence/source-provenance.json`. Tests used synthetic data and hidden native windows only.

| Verification | Result |
|---|---|
| `scripts/swift.sh test --scratch-path .build/integrated` | 404 tests, zero failures, 16.433 seconds suite |
| `scripts/test-managed-documents.sh` | 71 tests, zero failures, 5.954 seconds suite |
| `scripts/test-native-new-window-transfer.sh` | 44 tests, zero failures, 8.111 seconds suite |
| `scripts/swift.sh build --scratch-path .build/integrated` | Passed; incremental confirmation after the clean test build |
| Final chooser and existing-transfer source manifests | Match the same production revision; 15 and 12 tests passed, respectively |

Each root test command had an owned-process watchdog; none expired. The adversarial core regex fixture remains a cooperative-deadline test, not proof of hard engine termination. Process17, owner9, projection9 and monitor compatibility evidence belongs to the unchanged Task2 components, as recorded in [handoff verification](new-window-handoff.md). Final chooser tests and independent review are recorded [separately](new-window-chooser.md). These component checks were not redundantly rerun.

## Local artifacts

`scripts/package.sh --ad-hoc-sign` succeeded in the committed worktree. Release compilation took 31.12 seconds; complete packaging took 35.784 seconds. The checked artifacts were promoted with the repository's rollback-aware promotion script:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`
- `dist/TheOnlyPad.sbom.json`

Executable SHA-256: `f02db4960212814ea8cbf38b351f466081f310a4ec1db7135a2f6a62f70525eb`.

`python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json` verified six bundle files, archive consistency, public-path checks and SBOM hash. `codesign --verify --deep --strict dist/TheOnlyPad.app` passed. Both checks passed before and after promotion. Original branding, MIT license and third-party notices are included. No runtime dependency was added by this slice.

To launch when an interactive desktop is available: `open dist/TheOnlyPad.app`. This is an ARM64 development package with ad-hoc signing, not Developer ID signing or notarization. No artifact was published, pushed or released.

## Outstanding acceptance

The initial locked console prevented packaged desktop testing. Access was later restored as recorded below; VoiceOver, IME and display-scale validation remain outstanding. Earlier desktop and Intel-build results refer to older binaries. Local build/package success does not satisfy these tests or the full performance targets. Independent groups, streaming transfers and other outstanding requirements remain tracked in the matrix.

Raw command logs, status records and synthetic native snapshots remain private under `.local/new-window-integrated-evidence` and its isolated worktree. Public evidence contains no user document or signing credential.


## Packaged desktop access restored — 2026-09-10

After the user authorized the native UI Automation prompt, the unchanged55a7b1b package passed the real `GUIProbe/testOpenEditSaveQuitRelaunch` XCUITest: **1 test,0 failures**,61.302 seconds. The isolated app copy has executable SHA256 `f02db4960212814ea8cbf38b351f466081f310a4ec1db7135a2f6a62f70525eb`. The test used a private synthetic state directory, opened a synthetic file through the native dialog, selected and replaced text, saved and checked exact disk bytes, quit normally, relaunched and checked persisted content. Raw logs, result bundle and six test/project source hashes remain ignored locally.

This resolves the earlier access blocker for this session and verifies this primary packaged workflow. It does not establish all desktop, pane, transfer, IME, VoiceOver, performance or later search-code requirements. The subsequent desktop suite result is recorded below. No credentials were read, authentication-bypass setting changed, package rebuilt or remote artifact published.

## Desktop regression results

The complete packaged suite returned **14 tests: 6 passed, 8 failed, none skipped**. Passing workflows covered clean external reload, multiple-window/pinned restoration, open/edit/save/reopen, recent files, scratch recovery, and undo/redo/tab isolation/theme reset. This is a failing suite, not full desktop acceptance.

Two failures were test-harness defects: an application-wide Cancel selector also matched the Touch Bar, and a session-write fault assumed periodic checkpoints had not created the directory. The corrected tests scope the alert and restrict only the synthetic private Session directory, restoring its permissions even on failure. All original content, disk-byte, quit-veto and recovery assertions remain. Independent specification/code review approved both corrections. A fresh focused packaged run passed **2 tests, 0 failures**,104.613 seconds (dirty reload65.630; failed-quit recovery38.983). Test-source SHA-256: `66beb0284543cd6df20ac2c8510d764ee4cb87d1cc7855b191c22e4fd90addd8`.

The unchanged Locate workflow separately passed85.760 seconds; its earlier stale-status alert remains an unresolved intermittent failure. Shortcut reset, pane layout/scroll restoration and shared-pane failures remain under investigation. The shortcut timeout occurred during XCTest failure symbolication following a real tab-count assertion failure; this does not establish an application hang.

All runs used the unchanged packaged executable hash above. Private provenance and raw evidence remain under `.local/desktop-ui/`; no raw screenshots, system diagnostics or personal paths are included here. No production fix or complete-suite success is claimed from these focused checks.
