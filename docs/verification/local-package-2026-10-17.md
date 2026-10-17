# Local development package — 2026-10-17

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
