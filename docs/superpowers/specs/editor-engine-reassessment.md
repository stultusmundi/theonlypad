# Editor engine reassessment

Date: 2026-09-09. Status: research and throwaway Scintilla Cocoa probe completed; no engine adopted, vendored, or wired into the application. This is a bounded architectural reassessment, not feature-completeness evidence.

## Decision

Scintilla is the strongest next **native adapter prototype**, because an actual Cocoa probe retains two empty carets, edits both through its native text-input entry point, and performs rectangular replacement with undo. Those behaviors materially improve on the earlier stock NSTextView feasibility result. However, **do not replace the current adapter immediately**: the same probe found that default movement/backspace split an emoji grapheme, and upstream labels Cocoa bidirectional support experimental. Full Unicode, IME, accessibility, and interactive performance are unresolved migration gates.

Keep the working TextKit application as the baseline while testing a narrow Scintilla adapter. Do not add a bespoke multicursor text engine to NSTextView before that comparison. CodeMirror 6 in WKWebView is a credible fallback if Scintilla fails the Unicode/accessibility gates, but there is no local CodeMirror runtime evidence yet. Native integration preference favors Scintilla; it does not override correctness.


Subsequent evidence: [CodeMirror feasibility](codemirror-feasibility.md) now records local functional/tuned and ordinary multiline probes; the no-runtime statement above is historical. Its tuned adapter's1M-unit cap does not establish100MB acceptance. The additional native selection probe in [editor feasibility](../../verification/editor-feasibility.md) confirms that retained nonempty ranges still do not provide multicursor typing. A bounded command transaction gate remains isolated; no engine migration or production multicursor layer has been adopted.
## Official capability evidence

| Area | Scintilla Cocoa | CodeMirror 6 |
| --- | --- | --- |
| Selection/editing | Multiple selections, additional-selection typing, rectangular selections and virtual space are documented; local probe below verifies a subset. | Multiple selections are supported; rectangular selection is an extension with Alt-drag default. Drawn selection is needed for visible additional ranges instead of relying solely on the DOM selection. |
| Unicode and IME | UTF-8 storage; inline IME is documented for macOS. Cocoa bidi is experimental and requires explicit enablement; virtual-space interactions have limitations. | Advertises mixed-direction text; source contains composition handling and Safari-specific workarounds. These are not WKWebView IME test results. |
| Undo/accessibility | Grouped undo and Cocoa accessibility are documented. Actual probe verifies undo, but accessibility is only advertised by the engine. | History is provided by the commands package; upstream advertises keyboard and screen-reader support. Native menu routing and VoiceOver inside our wrapper remain untested. |
| Large documents | Large-document options allow over 2 GB on 64-bit builds; disabling style storage reduces memory. This is not a bounded-memory viewer or latency guarantee. | Official million-line demo exists; parser work is limited and highlighting may lag. No local memory/latency measurements. |

Primary sources: [Scintilla API](https://www.scintilla.org/ScintillaDoc.html), [CodeMirror features](https://raw.githubusercontent.com/codemirror/website/main/site/index.html), [rectangular selection reference](https://codemirror.net/docs/ref/#view.rectangularSelection), [draw-selection implementation](https://raw.githubusercontent.com/codemirror/view/main/src/draw-selection.ts), [history implementation](https://raw.githubusercontent.com/codemirror/commands/main/src/history.ts), [current composition implementation](https://code.haverbeke.berlin/codemirror/view/src/branch/main/src/input.ts), [million-line example source](https://raw.githubusercontent.com/codemirror/website/main/site/examples/million/index.md).

## Licensing and dependencies actually inspected

**Scintilla:** downloaded release 5.6.6 from the [official download page](https://www.scintilla.org/ScintillaDownload.html), read the archive's `License.txt` and Cocoa source headers. The [Scintilla license](https://www.scintilla.org/License.txt) permits use, modification and distribution with copyright and permission notices. Cocoa headers and implementation files explicitly offer LGPL v2.1 **or the Scintilla license**; the permissive option is available. Preserve upstream copyright/permission notices, including the Cocoa contributors' notices, in any future redistribution. This is separate upstream Scintilla source, not Notepad++ source or assets. Nothing from Notepad++ was downloaded.

The Cocoa framework builds from C++/Objective-C++ and Apple frameworks. The inspected Xcode project selects C++17/libc++, macOS SDK, deployment target 10.13, Cocoa and QuartzCore. That project setting is not proof this release runs on 10.13 or Intel. Upstream README says Xcode 9.2+, but the local result below is the relevant current-toolchain evidence. No external dependency manager or Lexilla was required for this framework probe. Syntax lexers are now a separate [Lexilla project](https://www.scintilla.org/Lexilla.html); any adoption must pin and review its exact release and included lexer notices separately.

**CodeMirror:** the [official GitHub README](https://raw.githubusercontent.com/codemirror/view/main/README.md) announces a move to `code.haverbeke.berlin`. The GitHub manifest was stale (view 6.41.0); the canonical main-branch manifests fetched directly during this review report **view 6.43.11, state 6.7.4, commands 6.11.0**. These are observed source manifest versions, not a verified npm resolution or lockfile. Read actual MIT licenses for [view](https://code.haverbeke.berlin/codemirror/view/src/branch/main/LICENSE), [state](https://code.haverbeke.berlin/codemirror/state/src/branch/main/LICENSE), and [commands](https://code.haverbeke.berlin/codemirror/commands/src/branch/main/LICENSE): retain copyright and permission notices.

Canonical manifests: [view](https://code.haverbeke.berlin/codemirror/view/src/branch/main/package.json), [state](https://code.haverbeke.berlin/codemirror/state/src/branch/main/package.json), [commands](https://code.haverbeke.berlin/codemirror/commands/src/branch/main/package.json). View depends on state, crelt, style-mod and w3c-keyname; state adds find-cluster-break; commands adds language and Lezer common. Grammars add further dependencies. A future adoption needs a complete resolved license inventory and lockfile; this review does **not** approve all transitive dependencies. The source uses TypeScript/buildhelper and publishes ES-module/CommonJS entry points. A proposed wrapper would build pinned packages into local JavaScript resources with a JavaScript package manager/bundler, then use the app's Xcode/Swift toolchain and system WKWebView. No exact Node/bundler version was selected or tested here.

## Actual Scintilla experiment

All downloaded source, binaries, raw build logs and synthetic probe code remain under ignored `.local/spikes/engine-reassessment`. The only tracked artifact from this task is this report.

Archive SHA-256:

```text
b6b08598c68fac90990d010c1142494d707530602b5320753274d045c2b02189
```

Environment: Apple Silicon, Xcode 26.6 build 17F113, Apple clang 21.0.0. Release arm64 Cocoa framework built without source changes or signing. The first sandboxed build failed creating Xcode build metadata; the same command succeeded with permitted escalation. This was an environment write restriction, not a compiler defect.

Commands run from repository root after extracting the official archive:

```sh
xcodebuild -project .local/spikes/engine-reassessment/scintilla/cocoa/Scintilla/Scintilla.xcodeproj \
  -configuration Release -derivedDataPath .local/spikes/engine-reassessment/DerivedData \
  -scheme Scintilla CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
xcrun clang++ -std=c++17 \
  -F.local/spikes/engine-reassessment/DerivedData/Build/Products/Release \
  -framework Scintilla -framework Cocoa -framework ApplicationServices \
  -Wl,-rpath,@executable_path/DerivedData/Build/Products/Release \
  .local/spikes/engine-reassessment/probe.mm -o .local/spikes/engine-reassessment/probe
.local/spikes/engine-reassessment/probe
```

The probe instantiates `ScintillaView` and calls its `SCIContentView` text-input method; it does not synthesize physical mouse/keyboard input or display a document window.

Passed assertions:

- Enable multiple selection/additional typing; set empty selections at byte offsets 1 and 3 in `a\nb\n`; native `insertText:replacementRange:` with `X` produces `aX\nbX\n`. A single undo restores the original and redo restores both inserts.
- Set rectangular anchor 1/caret 13 in `abcd\nefgh\nijkl`; engine reports three selections and rectangular mode; typing `X` produces `aXd\neXh\niXl`.
- Insert into text containing decomposed accents, a ZWJ emoji, Hebrew and CRLF; undo restores identical UTF-8 bytes.

**Important adverse result:** with the sole grapheme `👩🏽‍💻` (15 UTF-8 bytes), `SCI_CHARLEFT` from the end lands at byte **11**, and `SCI_DELETEBACK` leaves **11 bytes**. It removes the laptop scalar and leaves the preceding woman/skin-tone/ZWJ sequence. These default commands do not satisfy whole-extended-grapheme movement/deletion expectations. This does not prove every configurable Scintilla command behaves identically, but it is enough to prohibit claiming complete Unicode editing compatibility.

`AXIsProcessTrusted()` returned false. `SCI_GETACCESSIBILITY` returned 1. The latter reports support; it is not a VoiceOver test. No actual CJK input method, candidate window, reconversion, dead-key sequence or assistive client was exercised.

Insertion-only timings, one fresh run after the Unicode probe:

| Synthetic input | `SCI_ADDTEXT` elapsed |
| --- | ---: |
| 1,000,000 bytes, short repeated lines | 0.580 ms |
| 10,000,000 bytes, short repeated lines | 5.127 ms |
| 100,000,000 bytes, short repeated lines | 48.368 ms |
| 10,000,000-byte single line | 2.869 ms |

Undo collection was disabled and input strings allocated before timing. No layout, paint, scrolling, syntax, recovery copies, decoding, peak memory, or p95 measurement is included. These results are **not comparable** to the prior NSTextView forced-layout measurements. No 1 GB test, Intel build/run, packaged framework load, or minimum-OS run was performed.

## Integration implications and next gates

These are architectural inferences, not measured properties of an implemented adapter:

1. Scintilla needs a narrow Objective-C/Objective-C++ boundary and explicit UTF-8 byte ↔ UTF-16/grapheme mapping. Existing search ranges, CLI positions, macro offsets, document snapshots and native undo assumptions cannot be passed through unchanged. Keep file codec/atomic save/recovery services independent; use engine change notifications and revision checks rather than synchronizing entire strings on every keystroke.
2. A CodeMirror wrapper adds a JavaScript/native bridge, local-resource packaging, focus/clipboard/menu coordination, and web-process termination recovery. Ship local resources, reject navigation/network access, and expose only validated document operations. File contents must remain text, never executable JavaScript or injected HTML. Snapshot acknowledgements and revision ordering need explicit crash tests. These protections are proposed design requirements; no wrapper exists yet.
3. Before choosing, require the same adapter contract tests for exact Unicode edits, native input, multiple-carets/rectangle gestures, grouped undo, dirty state, stale async operations, save/recovery and crash recovery. Test marked-text cancellation/commit in real Japanese/Chinese/Korean input, combining/ZWJ movement/deletion, mixed RTL/LTR selection, and VoiceOver focus/value/selection announcements.
4. Benchmark displayed documents at 1/10/100 MB and pathological long lines, including first paint, edits, scroll/jump latency and peak memory. Retain the bounded large-file viewer until there is evidence a replacement meets its role; an engine's large-document flag is insufficient.
5. Only then make a migration decision. If Scintilla meets these gates with a small adapter, replacing the provisional TextKit view would reduce custom editor-feature work substantially. If it needs extensive bespoke Unicode or accessibility machinery, test CodeMirror in a minimal WKWebView wrapper before committing to either path.
