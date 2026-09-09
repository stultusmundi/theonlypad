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

## Exact dirty-baseline comparison investigation (2026-09-09)

This separate investigation concerns the editor's dirty-state equality check, not the read-only comparison panel above. Recommendation: adopt the one-line `!storage.mutableString.isEqual(to: savedText)` comparison on an existing dirty-cache miss, subject to the retained production dirty-state regression suite. Preserve the native UTF-16 length precheck, character-edit observer invalidation, unfinished-edit-batch invalidation, saved-baseline invalidation, and independent encoding/BOM checks. Do not replace exact equality with Swift canonical-equivalence equality or an unconditional edited flag.

The ignored `.local/spikes/dirty-native` experiment compiled an optimized, isolated actual `EditorWindowController` copy and its native dependencies. The snapshot includes the dirty cache and corrected scroll extent; subsequent Recent callback work was not part of this copy. It compared the existing UTF-16 `elementsEqual`, the `NSMutableString` facade's `isEqual(to:)`, and a separately maintained immutable `NSString(string: savedText)` baseline compared with the storage string as `NSString`. Production sources were not modified by this experiment.

### Executed semantics and measurements

Both candidates passed native semantic checks for direct `.string` and storage mutations, saved-baseline changes, decomposed/composed Unicode, equal-length reordered combining marks, immutable-baseline survival during storage mutation, unfinished `beginEditing` batches, attribute-only changes, encoding/BOM changes, native undo/redo, and programmatic marked-text/unmark APIs. Earlier independent literal-comparison fixtures checked 361 pairs against exact UTF-16 equality, including embedded NUL, mixed endings, emoji, and normalization differences. This is evidence for valid editor Unicode strings on the tested runtime; it does not establish physical IME behavior or behavior of malformed UTF-16 injected through arbitrary Objective-C clients.

Eighteen fresh child processes completed successfully: three variants × decimal 10 MB/100 MB ordinary ASCII multiline fixtures × three repetitions. Each opened the synthetic file through `open(_:onOpened:)`, then performed six actual `NSTextView.insertText` calls replacing its final UTF-16 unit: changed, restored, repeated three times. Every changed state was dirty and every restored state clean. Each edit incurred exactly one full comparison. Each child had a 60-second supervision timeout; none timed out. The machine was Apple M4 Pro, 48 GiB, macOS 26.6.2, Swift 6.3.3. Agents reserved the CPU slot; these are diagnostic local measurements, not a cross-machine acceptance run.

Median milliseconds across nine samples per state (three processes × three edits):

| Fixture | Comparison | Changed edit total / comparison | Restored edit total / comparison |
| --- | --- | ---: | ---: |
| 10 MB | Existing UTF-16 iteration | 98.04 / 91.59 | 98.90 / 92.10 |
| 10 MB | Mutable facade `isEqual(to:)` | 48.96 / 40.69 | 47.74 / 40.94 |
| 10 MB | Separate immutable NSString | 47.97 / 39.99 | 46.12 / 39.85 |
| 100 MB | Existing UTF-16 iteration | 941.69 / 934.88 | 943.24 / 936.39 |
| 100 MB | Mutable facade `isEqual(to:)` | 421.25 / 414.07 | 414.88 / 408.33 |
| 100 MB | Separate immutable NSString | 417.38 / 410.80 | 412.88 / 405.56 |

The one-line candidate's total changed-edit range was 46.14–59.06 ms at 10 MB and 410.52–434.95 ms at 100 MB. Restored-edit ranges were 46.34–49.29 ms and 410.53–430.09 ms. Thus even the 10 MB case does not consistently satisfy the 50 ms target, and the 100 MB same-length case still misses it substantially. This optimization reduces a known main-thread cost; it does not establish normal-editing performance acceptance.

Opening completion ranged 166.99–212.43 ms / 1087.61–1127.84 ms for the existing comparison, 118.92–130.30 ms / 518.71–526.09 ms for the facade, and 116.40–122.05 ms / 522.52–531.82 ms for the separate baseline (10 MB / 100 MB). The open path also evaluates dirty state, so changing its exact comparator changes this measurement. These hidden-window API timings include native delegates and controller refresh but do not measure first visible frame, physical keyboard latency, cold application launch, or displayed long-line layout.

Peak resident memory reported by child `getrusage` was 132.09–132.43 MB for all 10 MB variants, and 497.11–499.48 MB for all 100 MB variants. No material separate-baseline increase appeared in these ASCII cases. This high-water measure does not prove zero allocation/copy overhead, memory independence, or equivalent Unicode storage behavior. Explicit baseline construction took 0.30–0.36 ms at 10 MB and 3.15–3.24 ms at 100 MB. The separate NSString variant's small extra speed difference does not justify another cached baseline and its invalidation burden. Private Foundation backing-class observations are diagnostic only, not an API contract.

Ignored reproduction artifacts: `Controller.swift`, `Probe.swift`, `Semantics.swift`, `run.py`, and `results.json` under `.local/spikes/dirty-native`; the runner uses synthetic fixtures under `.local/spikes/native-performance/fixtures`. Executed measurement command: `python3 .local/spikes/dirty-native/run.py`. These ignored artifacts are local investigation aids, not a retained public benchmark distribution. The existing retained `Tests/NativeIntegration/DirtyStateHarness.swift` should verify any production adoption. Large same-length Unicode performance, broader operating-system versions, and physical IME behavior remain unmeasured by this performance batch.
