# CodeMirror 6 in WKWebView: bounded feasibility gate

Date: 2026-09-09. Status: exact npm resolution, license inventory, local JavaScript bundle and native wrapper compiled; first actual WKWebView gate completed with 27/33 checks passing. The coordinated final rerun also passed an enforced connect-src violation assertion. No engine adoption, production edits, vendoring, publication or performance claim.

## Scope and first gate

Read the existing editor-engine reassessment before this spike. The current TextKit baseline remains functional but long-line latency is unresolved; the Scintilla probe found default emoji-grapheme splitting. This spike asks whether CodeMirror can provide a small, bounded local-native adapter worth further evaluation. It does not rewrite the app.

Prepared runtime assertions exercise actual CodeMirror state/view objects in macOS WKWebView: two carets and grouped insert/undo/redo; rectangular-selection extension using synthetic DOM drag events and replacement; ZWJ/skin-tone/family/flag and combining-mark movement/backspace/undo; mixed line-ending roundtrip; synthetic composition start/end state; safe document transfer including script-like content, NUL and Unicode separators; blocked network fetch. Results distinguish API/command events from trusted keyboard/mouse gestures or real IME input. Default behavior failures will remain visible.

No CJK input method, candidate window, dead-key, reconversion, bidi visual selection, VoiceOver, clipboard, native menu, process-crash recovery, or performance acceptance is established by these prepared tests. Those remain later gates. A synthetic CompositionEvent cannot certify native IME support.

## Exact dependency and license inventory

Installed with Node 24.14.1/npm 11.11.0 and `--ignore-scripts --save-exact --no-audit --no-fund` into ignored `.local/spikes/codemirror`. Package is private. Exact integrity-bearing npm lockfile is retained there; no mutable CDN dependency is used.

| Installed package | Exact version | Declared license |
| --- | --- | --- |
| @codemirror/state |6.7.4|MIT|
| @codemirror/view |6.43.11|MIT|
| @codemirror/commands |6.11.0|MIT|
| @codemirror/language |6.12.4|MIT|
| @lezer/common |1.5.2|MIT|
| @lezer/highlight |1.2.3|MIT|
| @lezer/lr |1.4.10|MIT|
| @marijn/find-cluster-break |1.0.4|MIT|
| crelt |1.0.7|MIT|
| style-mod |4.1.3|MIT|
| w3c-keyname |2.2.8|MIT|
| esbuild |0.28.2|MIT|
| @esbuild/darwin-arm64 |0.28.2|MIT|

Twelve installed license files were read and inventoried, including copyright, permission/notice retention and warranty clauses. `license-inventory.json` records file hashes and notices; `THIRD-PARTY-NOTICES.txt` retains their text. The esbuild platform binary package has no separate license file; it declares MIT and the same-version parent esbuild license is retained. Esbuild and its platform binary are build tools, not runtime code proposed for the application. No grammars or language extensions beyond commands' resolved dependencies were added. Other platform optional packages appear in the lockfile but were not installed or inspected as binaries on this machine.

All runtime packages in the installed graph declare MIT. Future redistribution must carry the corresponding copyright and permission notices; this local inventory is not a release audit or authorization to ship. Upstream implementation was obtained from its own npm packages, not Notepad++ code/assets.

## Native wrapper boundary

`Wrapper.swift` compiles against system AppKit/WebKit. It uses a nonpersistent website data store, an explicit private local rule-store directory, a custom `cm-spike://app` scheme handler that serves only preloaded index.html/bundle.js bytes, and rejects other resource paths. Main-frame navigation is restricted to that one index URL; new/external navigation is canceled. CSP denies default resources, connections, frames, objects, forms and base changes. Only same-origin bundled script and required inline styles are permitted. A content rule also blocks HTTP(S) requests. Automatic JavaScript windows are disabled.

Native document data is passed through `callAsyncJavaScript`'s arguments dictionary to fixed function code. It is never interpolated into JavaScript or HTML. The functional test input cap is one million UTF16 code units. The ready callback checks main frame, expected custom origin, payload shape and single-run state. Test output goes to stdout in the ignored spike. A 45-second watchdog and web-process/navigation errors make failure visible; no process restart/recovery strategy is implemented yet.

These controls are implemented and compiled. Runtime verified inert exact document transfer. An initial fetch-rejection assertion was insufficient to distinguish blocking from DNS failure and was replaced; the final rerun observed an actual enforced connect-src security-policy violation for the expected synthetic URI. This verifies CSP blocking for that probe request, not a general security audit. No script has file-system access, document-selected URL loading, shell execution, or a general native command bridge. The wrapper exposes only its fixed functional probe. Future app integration needs a separately reviewed revision-aware document protocol.

## Reproduction

From repository root, after restoring the retained npm lockfile/dependencies:

```sh
npm ci --prefix .local/spikes/codemirror --cache .local/spikes/codemirror/npm-cache --ignore-scripts --no-audit --no-fund
node .local/spikes/codemirror/node_modules/esbuild/bin/esbuild .local/spikes/codemirror/probe.js --bundle --format=iife --outfile=.local/spikes/codemirror/resources/bundle.js
xcrun swiftc -parse-as-library -module-cache-path .local/spikes/codemirror/swift-cache .local/spikes/codemirror/Wrapper.swift -o .local/spikes/codemirror/wrapper
```

Launch only in a coordinated GUI slot:

```sh
.local/spikes/codemirror/wrapper .local/spikes/codemirror/resources > .local/spikes/codemirror/runtime.json
```

The wrapper is a throwaway local executable, not a packaged/signed application. No CPU/layout benchmark should overlap another measurement batch. No benchmark has run here.

## Primary references

- [CodeMirror reference](https://codemirror.net/docs/ref/): multiple selections, rectangularSelection, moveByChar grapheme movement, composing/compositionStarted state, editor extensions.
- [CodeMirror rectangular selection](https://codemirror.net/docs/ref/#view.rectangularSelection): default Alt-drag extension behavior.
- [CodeMirror commands](https://codemirror.net/docs/ref/#commands): history, undo/redo and default editing commands.
- Exact installed package LICENSE and package-lock.json files provide the release-specific inventory; source repository main versions alone were not used as resolution evidence.

A passing first functional gate would justify the next adapter experiment only. Native IME/accessibility, exact line endings, save/recovery ordering, crash recovery and long-line performance still govern adoption.

## Early adverse state-only evidence

A small Node check against the exact installed packages ran while the native GUI was reserved elsewhere. This is **not WKWebView or input-method evidence**. Calling the package's default `deleteCharBackward` with an EditorState-backed command target produced:

| Original single grapheme | Remaining text |
| --- | --- |
| `👩🏽‍💻` | `👩` |
| `e` + combining acute | `e` |
| `🇬🇷` | empty |
| `👨‍👩‍👧‍👦` | empty |

Thus the default command does not uniformly delete an entire extended grapheme. The command source uses `findClusterBreak` with backward extending-character behavior; a full-grapheme contract cannot be inferred from the separate moveByChar API. Any alternative configuration or small command adapter would require its own explicit tests, not an unqualified claim of default correctness.

`EditorState.create({doc: "a\r\nb\rc\n"}).doc.toString()` returned `a\nb\nc\n`. Default state construction normalizes mixed line endings. The native file codec currently preserves them; an adoption decision needs an explicit preservation strategy and tests. Neither a global line-separator setting nor a successful Unicode movement test alone proves mixed-ending roundtrip.

The native functional gate keeps both assertions and will report their actual WKWebView outcomes rather than changing expected values to pass.


## Actual WKWebView first-gate result

The real native wrapper loaded the local bundle and returned all 33 check results on macOS 26.6.2/Xcode 26.6. It exited 1 because six explicit acceptance checks failed; this was not a launch failure or crash. 27 checks passed. WebKit's user-agent reports a compatibility Intel 10_15_7 token; it is not evidence of an Intel/minimum-OS test. Actual host is the Apple Silicon development machine.

Passed functional behavior:

- Two retained carets inserted at both positions with one undo/redo transaction.
- Consecutive typing grouped into one undo/redo event.
- The actual rectangularSelection extension handled synthetic Alt-drag DOM events at laid-out coordinates, yielding three ranges and expected replacement, then exact undo. No physical/trusted drag gesture was synthesized.
- `cursorCharLeft` moved across each entire tested grapheme: woman/skin-tone/ZWJ/laptop, decomposed accent, flag, family ZWJ. Exact undo restored original text after deletion.
- Synthetic compositionstart/end toggled CodeMirror's state. This is lifecycle plumbing evidence only, not actual macOS marked-text/candidate handling.
- Native argument transfer preserved inert script-like text, Unicode separator, emoji and NUL without executing it.

Adverse behaviors confirmed in WKWebView:

| Check | Actual | Required baseline |
| --- | --- | --- |
| Default backspace on `👩🏽‍💻` | `👩` remains | empty |
| Strict backspace on `👩🏽‍💻` | `👩` remains | empty |
| Default backspace on decomposed `é` | `e` remains | empty |
| Strict backspace on decomposed `é` | `e` remains | empty |
| Default mixed CRLF/CR/LF input | normalized LF serialization | preserve all markers |
| Explicit LF separator facet | bytes preserved, 3 logical lines | 4 logical lines |

The exact installed `deleteCharBackwardStrict` source differs from default only in indentation-unit handling; it is not a whole-grapheme variant in this version. This distinction was verified through both state-only calls and actual WKWebView commands. At this baseline stage a custom command remained unimplemented; the later bounded adapter gate below tests one alternative. These observations demonstrate mismatched defaults, not fundamental engine impossibility.

A separate hidden native NSTextView probe used `moveLeft` and `deleteBackward` on all four graphemes: every left position was 0 and every backspace left empty text. No window was shown for that comparison. Thus CodeMirror's tested two partial deletions differ from this platform's actual NSTextView action behavior, not merely a speculative Unicode preference.

Setting `EditorState.lineSeparator.of("\n")` returned the original mixed byte sequence through sliceDoc, but counted 3 lines with contents `a\r`, `b\rc`, empty. It treats bare CR as inline content. Serialization alone is insufficient for native line-number, movement, search and editing parity. A future adapter needs an explicit tested strategy for mixed endings.

The first gate supports further bounded adapter investigation, not adoption. Exact default Unicode deletion and mixed-ending logical semantics remain unresolved alongside real IME, accessibility, crash recovery and displayed large-file performance. Raw results/fixtures remain ignored under the spike.


Final rerun: `runtime-final.json` again contains 33 checks/27 passes and the same six semantic differences. The strengthened network assertion passed only after receiving `securitypolicyviolation` with `effectiveDirective == "connect-src"`, `disposition == "enforce"`, and the expected blocked HTTPS URI. The result is not based merely on fetch rejection. Native wrapper exits 1 intentionally when any gate assertion fails; exit 2 is reserved for wrapper/timeout errors. This run was a completed adverse functional result, not an unavailable runtime. No performance measurement or GUI screenshot was used as substitute evidence.

## Bounded tuning experiment — implemented and tested

The custom backward-deletion command uses Intl.Segmenter grapheme boundaries in logical text order, preserves selections and combines multicaret changes into one CodeMirror transaction. It explicitly rejects unsupported size/boundary inputs before dispatch. This is a small command adapter, not a replacement Unicode engine. Native movement remains provided by CodeMirror; physical key routing and real IME still require separate tests.

For mixed endings, the implemented experiment keeps normalized LF separators inside CodeMirror so all original CRLF/CR/LF logical breaks remain lines, plus an exact separator map outside the line text. The map is an EditorState field; history inverted-effects restore text and separator metadata together. An explicit external-text insertion helper parses pasted markers instead of losing them at the boundary. Tested untouched separator types survive edits, serialization and undo. Native-generated new line breaks default to LF for this experiment.

The experiment is capped at one million internal UTF16 units and 10,000 breaks. Full separator-map snapshots may be acceptable for a throwaway proof but are not a production scalability recommendation. External UTF16 offset mapping, selection inside CRLF, native paste interception, history rebasing, collaboration and large-document memory costs remain separate integration concerns. Raw original bytes still belong to the existing codec/file services; this model preserves decoded text markers rather than replacing encoding/BOM handling.

The tuned Node gate passed **192 assertions**. The retained red evidence first showed default partial grapheme deletion (`tuned-red.log`), then a second regression showed selected surrogate-interior deletion was not refused (`tuned-boundary-red.log`). The final implementation validates both selection endpoints before any dispatch. Tests cover five graphemes including Hebrew plus niqqud, multicaret text and selection restoration in one undo, selected deletion, explicit oversized-input refusal, 40 seeded mixed-ending edits checked against an independent external-string reference, complete undo/redo, and grouped ordinary typing. A segmented logical line is additionally capped at 65,536 UTF16 units.

The actual native WKWebView tuned gate then passed **31/31 checks**, exit 0. It observed full deletion/undo/redo for all five graphemes; multicaret positions and their exact undo restoration; selected emoji deletion; mixed-ending import `a\r\nb\rc\n` with exact serialization and **four logical lines**; insertion of a CRLF-bearing replacement with five lines; exact undo/redo; and removal of one logical CRLF separator with exact undo. These are actual editor command calls in WebKit. They are not physical key or macOS IME tests. Original default-mode adverse assertions remain unchanged.

Reproduction from the repository root (all generated artifacts stay ignored):

```sh
node .local/spikes/codemirror/tuned-tests.mjs
node .local/spikes/codemirror/node_modules/esbuild/bin/esbuild .local/spikes/codemirror/probe.js --bundle --format=iife --outfile=.local/spikes/codemirror/resources/bundle.js
xcrun swiftc -parse-as-library -module-cache-path .local/spikes/codemirror/swift-cache .local/spikes/codemirror/Wrapper.swift -o .local/spikes/codemirror/wrapper
.local/spikes/codemirror/wrapper .local/spikes/codemirror/resources tuned
```

Evidence is retained locally as `runtime-tuned.json` and `runtime-tuned.log`. No CPU benchmark was run. The result demonstrates feasibility of small bounded command and separator adapters, not a production replacement: full-map history snapshots and full-document validation remain unsuitable assumptions for 100 MB adoption without measurement/design. Nonhistorical change rebasing, external offset mapping, native clipboard routing, physical rectangle gestures, accessibility, actual IME, and crash recovery remain unverified.

## Ordinary multiline performance gate — planned, not yet run

The next isolated experiment uses exact 1,000,000 / 10,000,000 / 100,000,000-byte ASCII documents with 199 content characters plus LF per line. Fixture generation is measured separately in JavaScript; file decoding and native-to-WebKit document transfer are explicitly excluded. Plain CodeMirror and the tuned adapter are separate modes. The adapter must explicitly reject documents above its one-million-unit cap, with no fallback to the plain implementation.

Initial load ends only after the editor is focused, selection is at EOF, the visible document ranges reach EOF, and both coordinates and an actual rendered cursor rectangle lie inside the scrolling viewport. A same-length replacement in the final content line and its undo each record synchronous dispatch and completion with visible EOF caret. Exact full-document undo validation runs outside those latency measurements. Each fresh native wrapper has a 45-second watchdog. Planned sampling is three fresh processes per mode/size; first run a 1 MB smoke to validate the observer itself. No runs begin before the shared GUI/CPU slot is released.

This is engine command/layout evidence, excluding syntax highlighting, physical input, production dirty comparison, actual IME, native save/restore and accessibility. WebContent process memory is not yet measured; native wrapper RSS alone would undercount. Source lives in ignored `performance.js` and `PerformanceWrapper.swift` beside the existing locked dependencies. Results and logs will remain ignored. This plan does not alter the engine adoption decision.

First smoke outcome: the initial plain 1 MB wrapper stalled without a result and outlived its AppKit timer. Its owned process was terminated after approximately 83 seconds; no latency was inferred. This exposed inadequate process supervision, not proof of an engine size limitation. The wrapper now explicitly activates its application and logs start/load/ready phases; an external Python subprocess timeout kills and reaps its own child independently of the AppKit loop.

One 35-second-bounded retry completed exit 0 with all five exactness/visibility assertions passing: initial load to visible EOF 52 ms, same-length edit to visible EOF 31 ms, undo to visible EOF 33 ms. Dispatch measurements rounded to 0 ms at WebKit's available performance-clock resolution. This is one 1 MB plain-mode smoke, not the planned three-run matrix. The initial hang's precise cause remains unproven because activation and diagnostics changed together; it must not be reported as a permanent WebKit failure. Raw local evidence: `perf-smoke-retry.json` / `.log`. The GUI/CPU slot was returned for desktop tests before larger measurements.

## Ordinary multiline matrix — measured

All **18 fresh native wrapper processes exited 0** under an independent 35-second timeout per child. Twelve measured runs each passed all five assertions: logical line count, focused visibly rendered EOF caret, final-line same-length edit, undo of that edit, and exact whole-document undo. Six adapter-overcapacity runs explicitly returned `status: limit` / `RangeError: Functional document limit`; they did not create a plain editor or report edit timings. No child timed out in this matrix. The earlier failed smoke is retained separately.

Milliseconds below are medians of three samples, with sample ranges in parentheses. Decimal MB; same 199 ASCII characters plus LF per line in every mode.

| Mode | Size | Initial state/view to visible EOF | Edit dispatch | Edit to visible EOF | Undo dispatch | Undo to visible EOF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Plain | 1 MB | 70 (49–116) | 1 (1–1) | 31 (26–34) | 0 (0–1) | 33 (33–33) |
| Plain | 10 MB | 43 (31–119) | 1 (1–1) | 33 (31–34) | 0 (0–1) | 32 (32–33) |
| Plain | 100 MB | 56 (50–139) | 1 (1–2) | 32 (22–33) | 1 (0–1) | 34 (33–34) |
| Tuned adapter | 1 MB | 43 (43–52) | 6 (5–7) | 33 (33–33) | 1 (1–2) | 34 (33–34) |
| Tuned adapter | 10 MB | Explicit limit, all 3 | — | — | — | — |
| Tuned adapter | 100 MB | Explicit limit, all 3 | — | — | — | — |

The visibility observer deliberately waits two animation frames. Roughly 32–34 ms completion samples therefore include that observation floor; they are not sub-frame engine execution estimates. Dispatch values rounded to 0 ms mean below available clock resolution, not zero work. The nonmonotonic initial-load medians and wide ranges show why three samples must not be interpreted as a size-scaling law. Exact full-text undo validation was outside edit/undo latency: plain medians 1/4/29 ms at 1/10/100 MB, respectively.

Fixture construction occurred inside WebKit and was timed separately. This repeated ASCII fixture is compressible/repetitive and intentionally ordinary multiline; it does not represent unique-line, Unicode, long-line, syntax-highlighting, browser-to-native serialization, memory-pressure, real typing, real IME or native dirty-state workloads. The end caret assertion validates focus, EOF visible ranges, position geometry and a nonzero rendered cursor rectangle inside the scroll viewport; no screenshot or physical click was substituted for those checks. The same explicit application activation and observer source were used across every matrix child.

Reproduce only with an exclusive local GUI/CPU slot:

```sh
node .local/spikes/codemirror/node_modules/esbuild/bin/esbuild .local/spikes/codemirror/performance.js --bundle --format=iife --outfile=.local/spikes/codemirror/performance-resources/bundle.js
xcrun swiftc -parse-as-library -module-cache-path .local/spikes/codemirror/swift-cache .local/spikes/codemirror/PerformanceWrapper.swift -o .local/spikes/codemirror/performance-wrapper
python3 .local/spikes/codemirror/run-performance.py
```

Ignored `performance-matrix.json` contains every sample and assertion. Per-child `perf-<mode>-<size>-<sample>.json/.log` preserve outputs; the runner stops on its first failed child. No dependencies changed from the locked functional spike.

Decision implication: the plain engine's bounded ordinary-multiline command/layout result is promising enough to justify further investigation. It does **not** close native editor adoption requirements. The exact mixed-EOL adapter still cannot open 10/100 MB, its full separator-map history has no scalable design proof, WebContent memory is unmeasured, and real macOS IME/accessibility plus the existing exact file/save/recovery contracts remain unintegrated. No production engine was changed.
