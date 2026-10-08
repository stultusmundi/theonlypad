# Editable disk admission — 2026-10-08

Fresh disk content containing decoded NUL characters or one of four unsupported/ambiguous UTF-32 prefixes is refused before editable text adoption. Valid UTF-16 structural zero bytes remain readable. This is a conservative E-06 slice: it deliberately refuses even valid text containing U+0000, and does not identify every binary format.

| State | Scope |
| --- | --- |
| Implemented | Shared strict disk decoder; normal/explicit Open and Reopen read boundary; disk-only session restoration; external reload/copy decoding; distinct monitor refusal and recovery guidance. |
| Tested | Full app/core 852/0; focused codec/file-action/backup/recovery 50/0; native factory 198 checks, close 106 checks and shared-pane ownership control pass; frozen session coordinator 12/0. |
| Planned | Actual controller dirty-Reopen and visible external-reload preservation workflows; broader binary classification and optional small-file byte viewer. |
| Blocked | New packaged desktop execution awaits user-owned macOS UI Automation authentication. No grant is inferred. |

## Admission and preservation

`EditableDocumentDecoder` checks the four full signatures `FF FE 00 00`, `00 00 FE FF`, `00 00 FF FE` and `FE FF 00 00` before supported BOM decoding. It then delegates once to the existing strict codec with the caller's selected encoding and scans decoded UTF-16 units for U+0000. Successful text, bytes, BOM and line endings are unchanged. There is no replacement decoding, stripping, encoding guess, extra disk read or new dependency.

External reload still honors supported BOMs over the saved encoding, while BOM-less reload uses the saved encoding. Its established `unsupportedUTF32` error identity is preserved. The monitor reports admission refusals as `notText`; malformed encoding remains `decoding`. The new native refusal guidance preserves the current buffer and recommends suitable read-only inspection or conversion of a copy. It does not promise a built-in small-file viewer or an encoding bypass.

Raw `DocumentCodec` remains reversible, including all 256 legacy byte values. Already-owned decoded recovery, backups, duplicates and closed-tab history retain their existing contracts. Disk-only session restoration uses admission; recovered snapshots do not adopt their historical disk destination. Already-open or recovered NUL-bearing text is not subject to a new save-time ban.

The existing large-file byte viewer remains read-only, labels its potentially lossy UTF-8 display and shows byte offsets. Its limits and behavior are unchanged. NUL-free binary, unsupported encodings without these markers, universal text classification, allocation/RSS and large-file performance remain outside this checkpoint.

## Behavioral evidence

Before production changes, eight intended refusal assertions failed across the existing external decoder API, while six methods passed, including valid UTF-16 and all original decoder controls. A real monitored NUL-file read failed one assertion because it published an editable snapshot. The native factory ran 198 checks with 15 intended admission failures; all original 133 checks and NUL recovery positives remained. The matching close harness passed 106 checks before the factory failure. These failures are retained separately from setup errors.

After implementation, the 50 focused core tests and all native factory/close/shared controls pass. The current complete app/core suite passes **852 tests with zero failures**, with 239 production/test input hashes and the complete owned receipt verified. Native compile/runtime inputs and three binaries were separately bound to the rebuilt core. All prior assertions were retained; added tests use synthetic literal bytes and real temporary files.

The session suite adds three tests to the original nine. Current real stored-session startup refuses NUL disk content while retaining the unresolved record; failed retry and subsequent persistence preserve metadata and original disk bytes. Real NUL-bearing recovery snapshots restore exact Unicode, pane state and bookmarks over NUL/UTF-32 historical files. Literal UTF-16 LE/BE disk fixtures restore correctly.

A separate old-routing control replaces only `NativeDocumentSeed.swift` with its genuine prior committed source, retaining the current real core and unused decoder declaration required by the typed tests. That control runs 12 tests with three intended startup assertions failing and zero unexpected failures. The current matching package passes **12/0**. Each frozen package has 56 verified input files and a complete direct owned-watchdog receipt. This is a routing regression control, not a full old-repository baseline. The legacy session-owning shell runner was not nested under another watchdog or represented as executed here.

The native wrapper's first invocation incorrectly used a named build-path option and exited before tests; the corrected positional invocation executed the retained behavioral RED. An inert result reader first expected 14 rather than the observed 15 factory failures and was corrected from the complete capture. Neither is relabeled as a product result.

## Review and limits

Independent source review found no blocking defect, verified all intended disk ingress callers and preserved original assertions. Root separately verified runtime receipts and frozen source/artifact membership. Source review of the reload failure branch supports buffer, undo, bookmark and baseline preservation; a real dirty-controller Reopen workflow and physical error/dialog usability remain **unverified**. Factory, monitor and session tests do not substitute for those workflows.

Proven core and native commands:

```sh
scripts/swift.sh test
scripts/test-native-close-model.sh .build/arm64-apple-macosx/debug
```

Development runs use the checked-in direct owned watchdog for the broad adversarial core suite. The native wrapper already owns its watchdog and must not be nested inside another session-owning watchdog. This checkpoint ran that native wrapper with a separately verified matching debug directory, rather than claiming a new standalone build run.

## Local package

The release app bundle, archive and SBOM pass local ad-hoc packaging and the
standalone six-file/archive/SBOM verification. Root reverified all 729 pinned
inputs through the build and the complete direct-watchdog receipt. The package
includes this disk-admission implementation and the preceding searchable Help.
It has not passed desktop interaction, Developer ID signing, notarization or
release publication.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| App executable | 6,734,560 | `20ed44d8defc2170ae23b70875aecb49df31a1752f999b13a0bbf6611e8465b9` |
| Development ARM64 archive | 2,469,684 | `6dae4ee48208c45b9388a00dbb91e530918f20e4e9a9afdcd099a48ae59db6a7` |
| SBOM | 986 | `704be84120ac63eb0bc25e52d657f7d67749e2af4e4f268437595b3db208f0d1` |

Raw source inventories, original failures, frozen session packages and receipts remain ignored under `.local/binary-*` and `.local/native-close-model/`. No full E-06, visible desktop, physical IME, VoiceOver, Intel, minimum-OS or release acceptance is established.
