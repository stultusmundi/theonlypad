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

The locked console prevents current packaged clean-launch/open/edit/save/quit/reopen testing, visible chooser/focus, physical keyboard/menu, VoiceOver, IME and display-scale validation. Earlier desktop and Intel-build results refer to older binaries. Local build/package success does not satisfy these tests or the full performance targets. Independent groups, streaming transfers and other outstanding requirements remain tracked in the matrix.

Raw command logs, status records and synthetic native snapshots remain private under `.local/new-window-integrated-evidence` and its isolated worktree. Public evidence contains no user document or signing credential.
