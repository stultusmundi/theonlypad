# Custom-language session codec — 2026-10-12

`SessionTab` stores one `DocumentLanguageSelection`. Its compatible
`manualLanguage` view derives only manual built-in selections. A custom UUID
remains a custom choice even when no catalog definition exists; catalog fallback
does not rewrite persisted identity.

`SessionStore` writes canonical version 2 when every choice is automatic or
built-in. Version 3 carries custom IDs and explicit choices. Fixed version 1/2
fixtures retain earlier loading and canonical-save behavior. Known version 3
invalid, conflicting, unknown, duplicate and incomplete metadata is rejected;
future versions are refused without replacing the original file. Existing
filesystem, locking and publication protections remain unchanged. Older readers
refuse version 3 instead of silently discarding selection.

The authentic API-only baseline completes **35 tests with 51 ordinary failures
and no unexpected failures**: nine new methods fail; seven new methods and 19
compatibility methods already pass and receive no failing-baseline credit.
That private bridge is never adopted. The reviewed implementation passes the
unchanged 16 new methods plus 19 compatibility methods, including actual
temporary-file faults and readback. Two original future-version fixture premises
move from 3 to 4 by one byte each; rejection assertions remain unchanged.
Independent review verifies source, compiled products and complete receipts.

After adoption and formatting, the current public working-tree snapshot passes
**1,159 unique default SwiftPM tests with zero failures or unexpected failures**.
All 484 frozen manifest/source/test/resource payloads remain unchanged. The app
and helper compile with warnings as errors; the following build on the same
scratch directory is incremental. Separate public macro19 evidence is described
in [native macro verification](native-macro-recording.md), not added to 1,159.
The snapshot includes Core version 3 and the adopted native macro/transfer
sources. This record describes the verified local source checkpoint.

Use fresh output and scratch directories and isolated synthetic state:

```sh
mkdir -m 700 .local/session-codec-state
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/session-codec-full-owned -- /usr/bin/env THEONLYPAD_STATE_DIRECTORY="$PWD/.local/session-codec-state" scripts/swift.sh test --scratch-path .build/session-codec-full -Xswiftc -warnings-as-errors
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/session-codec-build-owned -- /usr/bin/env THEONLYPAD_STATE_DIRECTORY="$PWD/.local/session-codec-state" scripts/swift.sh build --scratch-path .build/session-codec-full -Xswiftc -warnings-as-errors
```

The checked-in watchdog must directly own each stage; do not nest a second
session-owning watchdog. The focused component selector is
`LanguageSelectionPersistenceTests|SessionStoreTests|SessionPresentationTests`.

This implements the **Core persistence portion of plan step 5**. Native seeds,
document model, history, duplication, reload, transfer and session capture remain
to be integrated. Missing-profile warning resolution is tested as a Core result;
a visible warning and native manager/picker remain outstanding. No native language
workflow, desktop or full D-04 acceptance is claimed. Original code is
MIT-licensed; no external dependency or asset is added. Raw synthetic evidence
remains ignored.
