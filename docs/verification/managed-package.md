# Managed lifecycle package verification

A local development package was built from isolated committed source `81db2517dc85e17f58d69734acb9b84727439b0a`. The release build completed in 29.41 seconds. Source provenance is retained under `.local/native-managed-package-source`; the raw build log is `.local/native-managed-package.log`.

The app, ZIP and SBOM passed the six-file inventory, archive safety, byte equality, public-path marker and executable identity checks before and after promotion. Strict deep ad-hoc signature verification passed on both copies. Executable SHA-256: `03606c59b55d33b67f46d465ae1c4727492277480c3b67da45afa7a5a0675bb9`.

Artifacts:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`
- `dist/TheOnlyPad.sbom.json`

Commands: `scripts/package.sh --ad-hoc-sign` in the isolated source, `codesign --verify --deep --strict dist/TheOnlyPad.app`, and `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json`.

The corresponding frozen integration passed 404 core and 71 hidden native tests, plus legacy monitor lifecycle compatibility. This package supersedes the ownership-foundation package; it does not establish product completeness. No desktop launch was performed because console access remains blocked. Clean packaged open/edit/save/quit/reopen, physical IME, VoiceOver, Intel and minimum-OS runtime acceptance remain unverified. The signature is ad-hoc, with no Developer ID, notarization or remote publication.
