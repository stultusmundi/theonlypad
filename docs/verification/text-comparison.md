# Read-only comparison verification

Implemented: immutable left snapshot, strict local right-file loading or explicitly pasted right text, byte-exact line comparison, aligned insertion/deletion placeholders, changed-row highlighting, ending annotations, synchronized vertical scrolling and cyclic previous/next difference navigation. Original source strings remain separate from annotated display strings. There are no source-write operations or replacement callbacks.

The core uses exact UTF-8 line identifiers and a suffix LCS table: at most 2,000 logical lines per side, 4 million cell evaluations, and 4,004,001 UInt16 entries. Input limits are 2 MB UTF-8 per side and 2 MB encoded bytes for file loading. The file reader rejects a symlink leaf and nonregular files, verifies descriptor/path identity around chunk reads, and uses strict DocumentCodec decoding (BOM-based UTF-16 or UTF-8 by default). Parent-directory symlinks resolve through the shared reader; this is not a filesystem security sandbox or immutable filesystem snapshot.

Display preparation runs on the worker, escapes control characters, and rejects more than 16,000 UTF-16 units per displayed row or 2 million per pane, including annotations. These display bounds may reject input below the core byte limit. Native panes do not wrap; aligned rows have fixed line heights. Highlighting/navigation is line-based, not an inline/word diff. Editing, merging, saving a diff, and streamed large-file comparison are not implemented.

## Executed evidence

- Five `TextComparisonTests` passed after missing-type red failures: insertion/deletion reconstruction, changed rows, exact composed/decomposed Unicode and mixed endings, trailing empty lines, input/line limits, cancellation, strict UTF-16 file loading, malformed bytes, oversized files, symlink and directory refusal.
- Retained `Tests/NativeIntegration/ComparisonHarness.swift` passed with real AppKit controls: two read-only views, visible layout, aligned rows and ending markers, next/previous selection, synchronized scroll offsets, latest-request protection, real temporary UTF-16BE file loading with unchanged source bytes, and native window-close cancellation.
- Display-budget regression first failed because the production guard was missing; the expanded-control/long-row/aggregate-budget probes then passed. Panel-level long-row rejection is also retained in the harness.
- Strict swift-format lint passed for the four comparison Swift files. The public-source pattern checker passed during implementation.

Commands used on the established local macOS toolchain:

```sh
scripts/swift.sh test --filter TextComparisonTests
build_path=$(scripts/swift.sh build --show-bin-path)
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library -I "$build_path/Modules" Sources/TheOnlyPad/ComparisonController.swift Tests/NativeIntegration/ComparisonHarness.swift "$build_path"/PadCore.build/*.o -o .local/native-integration/comparison-test
.local/native-integration/comparison-test
```

These are in-process native integration checks, not physical keyboard, VoiceOver, packaged LaunchServices, or cross-platform acceptance. Full application scope remains incomplete. Root integrates the command registry and retained native test script.
