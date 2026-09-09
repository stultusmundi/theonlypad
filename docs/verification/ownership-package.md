# Ownership foundation package verification

A fresh package was built from isolated committed source `f9bd511`, excluding concurrent managed-publisher, intake and close-model work. The release build completed in 26.94 seconds; raw log is retained at `.local/ownership-package-build.log`. Source archive and exact commit are retained under `.local/ownership-package-source`.

The app, ZIP and SBOM passed six-file inventory/byte equality, safe archive path, public machine-path marker and executable hash checks before and after local promotion. Strict deep ad-hoc signature verification passed on both copies. Executable SHA-256: `b18bd4f7f2703c8dc6d261f4b7f833e56d68039630944f4d5e3ef87104974a7a`.

Current artifacts:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`
- `dist/TheOnlyPad.sbom.json`

Commands: `scripts/package.sh --ad-hoc-sign` in the isolated source, `codesign --verify --deep --strict dist/TheOnlyPad.app`, and `python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json`.

This is an unsigned-for-distribution development package with an ad-hoc local signature. No Developer ID, notarization, remote publication or desktop launch was performed. GUI access remains blocked, so clean packaged open/edit/save/quit/reopen acceptance is outstanding. Earlier packaged GUI evidence belongs to a different binary. Current Intel evidence also belongs to the earlier `6c7fb68` cross-build, not this package.
