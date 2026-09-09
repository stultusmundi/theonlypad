# Document core verification

Date: 2026-09-09. Platform exercised: local Apple Silicon macOS, Swift package targeting macOS 14. No Intel or GUI validation is claimed by this report.

## Implemented

- Strict UTF-8 and UTF-16 LE/BE decoding, optional Unicode BOM preservation, explicit Latin-1 and Windows-1252, and lossless encoding refusal. Undefined Windows-1252 slots map reversibly to their corresponding C1 controls. No guessing legacy encodings. Line endings remain untouched.
- Atomic sibling-file writes with synchronization, expected-byte conflict checks, private new-file mode, existing POSIX permission preservation, symlink/nonregular target refusal, and exclusive creation. Parent directory is resolved deliberately and operations use its open descriptor.
- Version-1 SHA-256 checked recovery snapshots with document identity, content, encoding and optional original path. Recovery location is supplied by the caller. Directory permissions are 0700, snapshot permissions 0600; corrupt snapshots are retained under a `.corrupt` suffix. Checksums detect accidental corruption, not malicious changes by the same user.
- Only system Foundation, Darwin and CryptoKit frameworks are used. No third-party dependency or asset was adopted.

## Tested

Command: `scripts/swift.sh test --filter Document --scratch-path .build/core`.

Fresh result: **11 tests passed, 0 failures**, 2026-09-09. Coverage includes Unicode BOM and mixed-ending fixtures; all 256 bytes in each legacy encoding; invalid UTF-8, malformed UTF-16 and unrepresentable conversion refusal; 300 seeded Unicode round trips; real-file save and external conflicts; empty files; preserved 0640 permissions; symlink/read-only rejection; injected failures before write, after write, before replacement, and ENOSPC; original content and temporary-file cleanup; private recovery round trip/removal; checksum corruption quarantine while valid snapshots survive.

Tests were introduced before the implementation and the missing-type build failure was observed. Two added regression tests then failed observably: Foundation's UTF-8 data initializer stripped a second leading BOM that was document content; empty-file reads returned nil and incorrectly raised an external-change conflict. Both were fixed and the same tests passed.

## Planned / outstanding

- GUI document lifecycle wiring, background-owner integration, actionable dialogs, periodic snapshot scheduling, session management and packaged force-termination recovery must be verified independently.
- Real disk exhaustion, abrupt process termination during each syscall, hardware power-loss durability and filesystem-specific behavior remain unverified. ENOSPC coverage is injected, not actual exhausted storage.
- The byte comparison followed by POSIX rename is not a cross-process compare-and-swap. A noncooperating external writer can race the last comparison. Callers should coordinate access where possible and provide backups for stronger recovery.
- Save preserves POSIX mode bits, but does not yet preserve ACLs, extended attributes, Finder tags or hard-link relationships. Backups and transactional multi-file replace are not implemented here.
- Recovery APIs require serialized background ownership. They are synchronous and are not a large-file streaming persistence design. Recovery does not authenticate against another process with the same user's privileges.

## Tool constraints

The ordinary sandboxed SwiftPM command could not use default caches or read a generated build map. The existing `scripts/swift.sh` repository-cache wrapper was run with approved toolchain escalation. This is build-environment evidence only; no platform security setting was changed.
