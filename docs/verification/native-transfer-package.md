# Native transfer development package

Source commit: `324a3de6ef8ef94a143b448483ae4f805665de95`. Built from an isolated committed-source archive recorded in `.local/native-transfer-package-source/source-provenance.json`. Release build completed in 30.82 seconds; raw log `.local/native-transfer-package.log`.

Local artifacts: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256: `0d58d1ea0e6cff4ac73bbc1461dc8a57f6d0784301def59f472f195fb2df0ce6`. Six-file bundle/archive content checks, SBOM hash checks, public-path checks and strict deep ad-hoc signature verification passed before and after promotion. Promotion used the existing rollback-capable local helper.

Commands: `scripts/package.sh --ad-hoc-sign`; `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json`; `codesign --verify --deep --strict dist/TheOnlyPad.app`.

This is an ARM64 development build with ad-hoc signing, not Developer ID signing or notarization. No remote upload, release, push or merge occurred. The current package was not visibly launched because console/automation access remains blocked. Earlier desktop and Intel evidence belong to older binaries. Launch command when access is available: `open dist/TheOnlyPad.app`. Full product acceptance remains outstanding.
