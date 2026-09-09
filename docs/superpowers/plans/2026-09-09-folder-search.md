# Bounded folder search

Design approved through BUILD_PROMPT autonomous workflow. Own FolderSearch core/tests, FolderSearchController and native harness. Root owns menu/editor integration.

Use WorkspaceIndex recursive discovery (50,000 visited paths; hidden/symlink/.git/.build/node_modules excluded). Strict UTF-8 text only, NUL treated as binary; other encodings explicitly skipped. Read up to 10MB per file in <=1MB windows through LargeFileReader identity checks. Cap retained matched-file snapshots at 100MB and matches at 10,000; limit failures throw and do not present partial success. SearchService retains cooperative regex deadline limitations. Cancellation/progress run on workers. No replacement or config execution.

Include/exclude globs are case-sensitive POSIX fnmatch, basename when no slash, relative path otherwise; * and ? supported, no recursive ** special meaning. Native controls expose semicolon-separated patterns. Report binary/encoding, unreadable/changed, size and glob skips. Discovery errors fail the entire request.

TDD: write temp-file behavior tests and see red; implement service and pass; retain native harness before controller and see red; implement controls and verify. Results callback carries URL, UTF16 range and original text snapshot for root to verify before selecting. No physical GUI usability claim.

Status: planned; implementation and verification outstanding. Workspace persistence, folder replacement and non-UTF8 folder search remain outstanding.

## Implementation and verification 2026-09-09

Core and controller implemented. Four integrated FolderSearchTests pass (zero failures, 13:12:45 local); application compiled in the same run. Original API-shell red cycle produced 12 failed assertions in three isolated tests. The later UTF8 BOM regression test passed the existing Foundation decoder; switching to shared DocumentCodec explicit UTF8 decoding was a behavior-preserving refactor, not a claimed reproduced fix.

```sh
scripts/swift.sh test --filter FolderSearchTests --scratch-path .build/folder
swiftc -module-cache-path .cache/swift -parse-as-library -I .build/folder/arm64-apple-macosx/debug/Modules Sources/TheOnlyPad/FolderSearchController.swift Tests/NativeIntegration/FolderSearchHarness.swift .build/folder/arm64-apple-macosx/debug/PadCore.build/*.o -o .build/large-benchmark/folder-harness
.build/large-benchmark/folder-harness
```

Retained harness initially failed against the empty controller with `Missing control folder.query`. Green output: `PASS: native folder search result, snapshot callback and cancellation`. Final harness uses a BOM-bearing UTF8 fixture and verifies BOM-free callback snapshot and correct UTF16 offset. It exercises actual AppKit controls programmatically, not physical GUI input. Root owns editor opening and stale-snapshot selection validation.

Progress during metadata discovery says Discovering files; subsequent counts are actual processed/total indexed files. Cancellation discards the results and request generation rejects stale callbacks. Core timeouts, match caps, path caps and snapshot caps fail the request explicitly. Skip summaries distinguish globs, size, binary/encoding and unreadable/changed files. The 100MB snapshot limit counts source UTF8 bytes, not measured process RSS; String/array/runtime overhead adds memory. No cross-file replacement. No hard isolated regex deadline. No persistent folder state. Full GUI usability and inaccessible-filesystem scenario testing remain outstanding.

## Review follow-up: root changes and clicked-path safety

Retained native harness reproduced both review findings before correction: `Changing root must discard old results and selection`, then after root-clearing correction `Substituted symlink must not open`. The picker now calls the same `setRoot` operation used by the harness: cancel/invalidate generation, clear hits and selection, update folder label and explicit new-search status. Successful search stores its original canonical root. Clicking a result revalidates regular-file containment through WorkspaceIndex on a worker before callback; generation checks discard validation completing after folder/search/close changes. Root's independent snapshot check still validates text/range after open. URL handoff cannot eliminate filesystem mutation after validation.

The expanded retained native harness passes both scenarios plus existing BOM/range/cancellation checks. It invokes the production root-selection operation directly and does not pretend to automate NSOpenPanel.
