# Local development package — 2026-10-17

The latest local distribution was built from reviewed source `a4202be6726ab918bca1355586090ca46a447614`, including the transfer preferred-responder correction. `scripts/package.sh --ad-hoc-sign` returned zero. Separate post-promotion checks also returned zero for the archive/SBOM validator and strict signature verification of both the application and fixed helper. The previous distribution was preserved locally before promotion.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| App executable | 11,021,648 | `78dfa1807e8565a1b18dd2a943f8b6856b8470cdd72fae4f5545e3aed51b4262` |
| Fixed search helper | 4,063,968 | `d28a722ba72a7cf640fd9781a8bac0379a3ed26857625a20f196270aa662b820` |
| ARM64 zip archive | 5,037,033 | `7e17d628b0de130242d576a338f7e0f497ce470ee687ee340e57fee5e267dd2c` |
| Development SBOM | 1,786 | `74b4ee4878d27512ad9344763cf6684cfbacc09a044480557829589b8b52d416` |

This package has no new desktop test run, notarization or release publication. Matching source verification includes 1,228 default-package tests, 74 distinct native approval methods/75 executions and the separately documented transfer neighbors; see [transfer focus verification](native-transfer-focus.md). Source tests do not establish packaged runtime acceptance. Broader desktop, physical keyboard/IME, VoiceOver, Intel, oldest-system and performance acceptance remain outstanding.

Reproduce from the recorded source:

```sh
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
codesign --verify --strict dist/TheOnlyPad.app
codesign --verify --strict dist/TheOnlyPad.app/Contents/Helpers/PadSearchWorker
```

Launch the local bundle with `open dist/TheOnlyPad.app`.

## Earlier package on the same date

The reviewed source at `42f6c4cab7f3d75f977ff4244cd1a86320366192` builds a local ARM64 release application and fixed search helper. `scripts/package.sh --ad-hoc-sign` returned zero. The package script verified ad-hoc signatures, the archive contents and SBOM against seven bundle files before promotion to `dist/`. All 1,023 tracked input files remained byte-identical across packaging. The preceding distribution was backed up locally before replacement.

This is a local development artifact. No release, notarization or new desktop run is claimed. The earlier source-bound default tests (1,228) and maintained native approval regressions (68 distinct methods/69 executions) are documented in [native editing verification](native-approval-regressions.md); they do not establish packaged runtime acceptance.

Reproduce from the recorded source:

```sh
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

Launch the local bundle with `open dist/TheOnlyPad.app`.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| App executable | 10,963,872 | `8cb009566e9206f57c049375c630967017b11714fb24fd44a5eeebd6a4fba456` |
| Fixed search helper | 4,063,968 | `d28a722ba72a7cf640fd9781a8bac0379a3ed26857625a20f196270aa662b820` |
| ARM64 zip archive | 5,010,579 | `8ab43c8c80fe54493babb2cb176fd8fa9c8be223bb909cfc30344566a990aad8` |
| Development SBOM | 1,786 | `233a43ddfbf03135c9e2c0745d52c0f6b85e04ab030cbcb3720c72b50557af5c` |

The actual packaged desktop flows, physical keyboard and IME behavior, VoiceOver, older macOS, Intel and performance acceptance remain outstanding. Hosted run [38989381995](https://github.com/stultusmundi/theonlypad/actions/runs/38989381995) at the same source failed in its initial unit-test step and skipped later native checks. Its production cause remains unknown; local packaging does not resolve that failure.
