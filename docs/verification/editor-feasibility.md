# Editor engine feasibility — 2026-09-09

Status: architecture research and a native engine microbenchmark completed. Product acceptance remains outstanding. No third-party editor dependency was added.

## Recommendation

Provisionally use AppKit `NSTextView` with an explicitly constructed TextKit 1 storage/layout stack behind an editor adapter. Keep the document model, selections, command transactions, language analysis, and persistence independent of the view. This uses the mature system editor instead of inventing a text engine. Initial native results support continued implementation but do **not** establish full-scope feasibility: multiple insertion cursors require adapter work, pathological lines miss the ordinary latency target, and real input/IME/accessibility still require GUI validation.

Do not adopt current STTextView assuming MIT licensing. Reconsider Monaco in WKWebView if native adapter complexity or measured large-file UI behavior becomes unacceptable. Neither alternative was built or benchmarked during this spike.

## Official-source comparison

| Candidate | Evidence and advantages | License/distribution | Risks and decision |
| --- | --- | --- | --- |
| AppKit NSTextView | Apple's [selectedRanges API](https://developer.apple.com/documentation/appkit/nstextview/selectedranges) exposes multiple selection ranges. Native undo, text input, and layout can be exercised without a downloaded dependency. | System framework; link the platform framework, do not redistribute Apple source/assets. Original adapter remains MIT. | The local probe retains multiple nonempty ranges but collapses multiple empty carets. Actual caret drawing, column selection, highlighting, IME, and VoiceOver need implementation/verification. Provisional choice. |
| STTextView | The current [official repository](https://github.com/krzyzanowskim/STTextView) describes a TextKit 2 editor with multicursor support, gutters, completion, undo, RTL, and syntax plugins; current stated macOS baseline is 14. | The [actual LICENSE.md](https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md) provides GPLv3 or a commercial license. No commercial purchase is authorized or needed for the chosen path. MIT original code can coexist with GPL obligations, but the resulting combined distribution cannot simply be represented as MIT-only. | Upstream documents TextKit workarounds. Excluded from current dependency plan to avoid changing distribution obligations. No source or assets copied. |
| Monaco in WKWebView | Microsoft's [official editor repository](https://github.com/microsoft/monaco-editor) supplies a browser code editor. Its [API](https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IStandaloneEditorConstructionOptions.html) exposes editor configuration, and the [accessibility guide](https://github.com/microsoft/monaco-editor/wiki/Monaco-Editor-Accessibility-Guide) documents keyboard and assistive features. | [MIT license](https://github.com/microsoft/monaco-editor/blob/main/LICENSE.txt); retain copyright/permission notice if distributed and review the exact bundle's separate dependency notices. | Inference: WKWebView integration adds a Swift/JavaScript document bridge, worker/resource packaging, focus/menu/IME integration, and extra memory copies. Browser accessibility documentation does not verify this desktop wrapper. Keep as fallback; no package adopted. |

## Executed native probe

Local-only source: `.local/spikes/native-probe.swift`. Synthetic strings only. Exact commands used:

```sh
swiftc -O -module-cache-path .local/spikes/module-cache .local/spikes/native-probe.swift -o .local/spikes/native-probe
/usr/bin/time -l .local/spikes/native-probe > .local/spikes/native-probe-final.log 2>&1
```

The probe completed and printed all cases. `/usr/bin/time -l` subsequently could not read `kern.clockrate` under the sandbox, so its extended memory statistics are unavailable and its wrapper exit status is not a successful memory measurement. Earlier direct execution of the probe exited 0.

Reference environment: arm64, macOS 26.6.2 build 25G83, Apple Swift 6.3.3, 14 logical CPUs, 51,539,607,552 physical-memory bytes. CPU marketing model queries were denied by the sandbox; no model claim is made.

Behavior observed:

- Requested insertion ranges `{0,0}` and `{6,0}` became only `{0,0}`. `insertText("X")` produced `Xalpha\nbeta\ngamma`.
- Requested nonempty ranges `{0,2}` and `{7,2}` were both retained.
- Explicit descending `insertText` replacements within one undo group produced `Xalpha\nXbeta\ngamma`; one undo restored the exact original. This proves a transaction mechanism, not visible multicursor behavior.
- Replacing the complete `👩🏽‍💻` grapheme with `🧪` in a string also containing a combining accent and Hebrew text preserved the other text; undo restored exact string equality. This is not an IME or bidirectional layout test.
- `AXIsProcessTrusted()` returned **false**. No security settings were changed or permission prompts requested.

Timing measurements below are milliseconds, each showing three repetitions in order. Bytes are decimal, ASCII synthetic source lines. `setString` excludes fixture generation and disk I/O. Layout explicitly calls `ensureLayout(forCharacterRange:)` for the first 2,000 characters. Edit is a middle insertion into `NSTextStorage`, without UI event processing, undo, highlighting, or repaint.

| Fixture | Set string ms, runs 1/2/3 | Initial layout ms, runs 1/2/3 | Middle storage edit ms, runs 1/2/3 |
| --- | --- | --- | --- |
| 1 MB | 1.049 / 1.025 / 1.006 | 0.701 / 0.629 / 0.605 | 0.281 / 0.278 / 0.277 |
| 10 MB | 3.281 / 3.025 / 3.041 | 1.824 / 1.859 / 1.723 | 2.653 / 2.579 / 2.583 |
| 100 MB | 32.115 / 25.882 / 24.948 | 13.487 / 13.797 / 14.010 | 25.011 / 26.081 / 25.709 |
| 1 MB single line, wrapping | 14.326 / 14.405 / 14.442 | 111.448 / 107.309 / 107.291 | Not measured |

An earlier `glyphRange(forBoundingRect:)` probe returned implausibly tiny times without explicitly forcing layout; those results are rejected as layout evidence. The retained table uses explicit `ensureLayout` with an explicit TextKit 1 stack.

## Consequences and remaining gates

The wrapped pathological-line layout takes over 100 ms even for the first 2,000 requested characters. Detect long lines before editor installation; expose a large-file/long-line capability mode and benchmark no-wrap/limited-layout behavior. Do not claim the 50 ms input target or 100 MB usable-within-five-seconds target from these storage timings.

Still outstanding: cold launch; repeated event-to-paint latency/p95; full document scrolling and jumps; 1 GB bounded-memory viewing/search; peak memory; incremental syntax edits and cancellation; rectangular-selection gestures/rendering; recovery; real IME composition; VoiceOver/focus; GUI automation; packaged-app behavior. Accessibility trust is unavailable for this process, and no UI automation or manual desktop test was exercised here. Continue independent implementation and use a permitted desktop harness or explicit user-granted accessibility access for those acceptance tests.


## Additional native selection semantics (2026-09-09)

A hidden AppKit probe used the actual DocumentTextView subclass, two TextKit1 layout managers and shared NSTextStorage/UndoManager without constructing a window. It retained three nonempty selected ranges, then tested insertion, newline, backward/forward deletion, subsequent insertions and programmatic marked text. Both insertion APIs and newline replace only the first range. Backward/forward deletion removes all three ranges, then collapses to one caret. Multiple empty ranges collapse; mixed empty/nonempty ranges retain only the nonempty selection. This agrees with the installed NSTextView header's restriction to nonzero-length multiple ranges.

All11 cases restored exact UTF16 content through grouped shared undo/redo, including whole combining/emoji graphemes amid Hebrew, CRLF and CJK. That does not prove multi-caret typing, physical IME, gesture rectangles, accessibility or real typing coalescence. No timing or memory claim is made. Private evidence: `.local/multiselection-spike/run.nxkGzSBp`, exit0, no compiler diagnostics.

A bounded real-controller command transaction gate is now being evaluated in ignored sources. It is not a production selection layer or adoption of a bespoke engine. Existing mature Scintilla/CodeMirror comparison and their Unicode, exact-line-ending, history and large-file limitations remain required architecture inputs.
