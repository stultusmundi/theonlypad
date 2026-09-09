# TextKit 1 pathological long-line investigation

Date: 2026-09-09. Scope: a 10,000,000-byte synthetic single line in an isolated copy of the actual current editor controller. Production sources are not changed. The original targets remain unchanged: ordinary input p95 below 50 ms, normal editing through 100 MB, and safe bounded viewing/search at 1 GB. This investigation is not complete acceptance for those requirements.

## Mechanisms being compared

The production adapter already enables [allowsNonContiguousLayout](https://developer.apple.com/documentation/appkit/nslayoutmanager/allowsnoncontiguouslayout). Apple's installed SDK header describes this as permitting layout without laying out preceding text, but explicitly notes that non-contiguous layout is not always used. It is not a guarantee of bounded work within one paragraph.

[backgroundLayoutEnabled](https://developer.apple.com/documentation/appkit/nslayoutmanager/backgroundlayoutenabled) controls idle-time layout on the main thread. Disabling it does not move layout to a worker thread. [limitsLayoutForSuspiciousContents](https://developer.apple.com/documentation/appkit/nslayoutmanager/limitslayoutforsuspiciouscontents) enables defensive behavior; Apple's SDK warns that a very long paragraph may then have unexpected layout. A speed improvement accompanied by missing visible text is not a successful editor configuration.

The isolated source adds environment-selected layout flags before text assignment. Normal wrap selection uses the controller's actual settings API. Configurations are wrapped baseline, unwrapped baseline, wrapped without background layout, wrapped with defensive layout, and unwrapped with defensive layout. Maximum-line clipping or document truncation is not used.

## Method and reproducibility

Reference: Apple M4 Pro, 48 GiB RAM, macOS 26.6.2, Apple Swift 6.3.3, arm64. Current native/core sources are copied into ignored `.local/spikes/long-lines/Sources`; the modified controller and source hashes are retained there. The core and executable are independently compiled with `swiftc -O`, without using the main package build directory.

The fixture contains a BEGIN marker, repeated ASCII x characters, and an END marker, with exactly 10,000,000 bytes and no line terminator. A shown native window has 900 × 650 points of content area. No bookmarks, syntax token work, or user documents are involved. Default production behavior reduces status detail and disables the ruler at this size.

Each child runs actual `open(onOpened:)`, then 12 native insertText calls cycling end/start/middle. Selection, scrolling, and display are timed separately from insertion plus display. Individual edits assert length and inserted character; after all operations, the entire text must match an independent mutable reference exactly in UTF-16. First-cycle glyph bounds and intersection with the visible rectangle check whether the navigated text is actually laid out and visible. These coverage checks are API geometry checks, not screenshot or physical accessibility verification.

Three children per configuration are attempted. Each owned child has a 60-second supervisor timeout; a timed-out configuration stops further repeats. Peak RSS uses the child's Darwin getrusage high-water mark, with additional child-only RSS monitoring. The reference string and normal editor state are included in memory usage. Physical keyboard-to-photon latency, compositor completion, cold launch and cleared filesystem caches are not measured.

Local build artifacts, fixtures, raw logs and `run.py` remain ignored. The prepared run command is:

```sh
python3 .local/spikes/long-lines/run.py
```

GUI probes were deliberately held while the separate XCUI test used application focus. Preparation and compilation alone do not establish a result; measurement findings follow after that GUI gate clears.

## First batch: layout flags do not solve the miss

All 15 children completed without timeouts and passed final exact-text comparison. The following values use three runs and 36 total insertion samples per configuration. P95 is nearest rank. RSS is decimal MB.

| Configuration | Open callback range (ms) | Insert + display p95 / maximum (ms) | Maximum navigation (ms) | Peak RSS range (MB) |
| --- | --- | --- | --- | --- |
| Wrapped | 4651–4732 | 1054 / 1088 | 1.7 | 658–658 |
| Unwrapped | 4482–4605 | 1580 / 1645 | 326 | 1220–1485 |
| Wrapped, background layout off | 4728–4864 | 1093 / 1094 | 1.9 | 617–658 |
| Wrapped, defensive layout | 3416–3449 | 762 / 769 | 2.0 | 658–659 |
| Unwrapped, defensive layout | 3163–3281 | 1256 / 1266 | 320 | 1388–1485 |

**All configurations failed endpoint/middle visibility.** Only the start glyph was visible after navigation. Thus these callback timings are not evidence of a usable long-line editor, and the small navigation timings on wrapped text must not be represented as successful navigation. Defensive layout reduced some processing time but still missed the input target by a large margin and did not repair access to remote content.

## Separate view-extent defect and minimal correction

The actual text view reported maximum size near its construction size, `(900, 650)` points in wrapped mode. At the end of the 10 MB wrapped fixture, the glyph was laid out around y=1,553,402 while the visible rectangle remained near y=0. The storage was intact; the document view could not grow enough to expose it.

The retained `Tests/NativeIntegration/ScrollExtentHarness.swift` reproduced this on an ordinary 400-line document: navigation selected line 400 but its glyph was outside the visible rectangle. An ignored candidate added only these two assignments immediately after constructing DocumentTextView:

```swift
editor.minSize = NSSize(width: 0, height: 0)
editor.maxSize = NSSize(
  width: CGFloat.greatestFiniteMagnitude,
  height: CGFloat.greatestFiniteMagnitude)
```

The same harness then passed all 12 start/middle/end visibility checks across 400 short lines and a 100 KB single line, wrapped and unwrapped. It also checked unchanged exact text and clean dirty state. No configureWrap modification was needed. The baseline child failed its visibility assertion; the corrected child exited zero. These are actual controller.open/navigate calls with layout geometry assertions, not physical GUI acceptance.

The minimal proposed hunk is ignored `.local/spikes/long-lines/extent.patch`; root owns its integration. The full copied candidate must not replace newer production changes. This correction restores scroll extent in the retained small fixtures; it does not itself establish acceptable 10 MB long-line latency. A corrected-extent performance follow-up is prepared to avoid comparing engines using inaccessible text.

## Corrected-extent follow-up

With only the min/max-size correction added to the copied controller, all nine subsequent children completed, preserved exact text, and passed all nine sampled glyph-visibility checks per configuration. Values remain diagnostic: another agent performed a short isolated compilation during part of the batch. A controlled final performance acceptance run would need to avoid concurrent builds.

| Corrected configuration | Open callback range (ms) | Insert + display p95 / maximum (ms) | Maximum navigation (ms) | Peak RSS range (MB) |
| --- | --- | --- | --- | --- |
| Wrapped | 4710–4779 | 1062 / 1067 | 2.8 | 658–659 |
| Unwrapped | 4517–4574 | 1570 / 1581 | 323 | 1485–1486 |
| Wrapped, defensive layout | 3394–3463 | 764 / 774 | 1.8 | 658–659 |

The extent correction solves access to the sampled remote text, not the paragraph-layout cost. Even the fastest tested defensive configuration misses the 50 ms input target by more than an order of magnitude. Background-layout disabling in the first batch did not improve the delay. Unwrapped mode was slower and consumed roughly 1.5 GB for this 10 MB fixture.

There is an additional observed unwrapped-layout caveat: the first glyph was at y=10, but the final glyph was at y=138 in a document without any line terminator. The engine produced more than one visual fragment despite the unwrapped configuration. The probe does not establish the internal reason; a possible internal width limit is an inference, not a verified implementation detail.

No safe universal line-length cutoff was established. Passing the 100 KB structural visibility regression does not establish its p95 typing latency, performance across Unicode scripts, or behavior on the minimum supported machine. Do not infer a new advertised editing limit from that test.

## Provisional consequence

The tested TextKit 1 configuration changes do not satisfy the pathological-line editing requirement. Keep the repaired extent behavior, but do not present it as the performance fix. A defensible temporary escape hatch is an explicit bounded read-only viewer for an otherwise blocking document, preserving bytes and explaining the editing restriction. That remains a product gap against normal editing through 100 MB, not a reduction of the user's target. Truncating text, inserting artificial line endings, or clipping away unrendered content is not an acceptable optimization.

The existing Scintilla Cocoa build is prepared for a displayed-view comparison using the same 10 MB fixture, 900 × 650 point window, native insertText calls, and endpoint checks. Its loading timer is view assignment/display after UTF-8 decoding, whereas the TextKit controller timer includes file reading and document construction; those open times must not be labeled equivalent end-to-end measurements. Engine-only results do not authorize migration. The previously measured default grapheme movement/deletion failure remains an explicit gate; see `docs/superpowers/specs/editor-engine-reassessment.md`.

## Displayed Scintilla Cocoa comparison

The existing unsigned local Scintilla 5.6.6 Cocoa framework was reused; no new dependency was adopted or vendored. Its prior license review and adverse Unicode findings remain in the engine reassessment. The Objective-C++ wrapper is ignored `ScintillaProbe.mm` and uses a shown 900 × 650 point window, Menlo 13, UTF-8, native SCIContentView insertText calls, normal undo collection, and scroll-width tracking. Wrapped and unwrapped modes each received three fresh child runs with the same 12 insertion positions and final exact-byte comparison. Its viewport/font and document-adapter overhead differ from the TextKit application, so these are diagnostic component comparisons, not equivalent packaged-application benchmarks.

The initial six-run pass exposed another timing trap: setString plus display returned around 11–16 ms, but the first wrapped end position was not visible. Deferred wrapping had not settled. The final probe therefore measured a separate load-to-end-visible readiness gate, pumping the run loop and requesting caret scrolling until the end point lay inside the content view. It did not silently count the early return as usable loading.

All six final children completed within their timeout, preserved exact text, and passed all nine sampled endpoint/middle visibility checks per mode. No other GUI benchmark ran concurrently in this final batch.

| Scintilla configuration | SetString + first display range (ms) | End-visible readiness range (ms) | Insert + display p95 / maximum (ms) | Maximum navigation (ms) | Peak RSS range (MB) |
| --- | --- | --- | --- | --- | --- |
| Wrapped | 10.8–16.4 | 339.4–355.9 | 263.4 / 287.2 | 41.6 | 386.0–386.2 |
| Unwrapped | 11.3–12.1 | 358.0–370.2 | 257.4 / 257.9 | 22.0 | 371.4–384.9 |

These displayed/native-input measurements are substantially slower than the earlier raw SCI_ADDTEXT insertion-only numbers. Both modes still miss the 50 ms editing target. Scintilla showed lower latency and memory than the tested TextKit controller for this fixture, but the result does not prove a migrated application would meet its targets. Further profiling must include the actual Cocoa input and display path rather than substituting a fast buffer-only API.

The default Scintilla movement/deletion probe previously split `👩🏽‍💻`: moving left from its end stopped at UTF-8 byte 11 of 15, and backspace left 11 bytes. That explicit correctness failure remains unresolved. No physical IME or accessibility acceptance was performed here. Faster rendering would not erase that migration gate.

Final local reproduction commands are `python3 .local/spikes/long-lines/run-corrected.py` and `python3 .local/spikes/long-lines/run-scintilla.py`, after coordinating exclusive GUI use. `results-corrected.json` and `results-scintilla.json` hold the final structured results. The initial Scintilla pass is retained separately as `results-scintilla-initial.json`. Every child uses synthetic fixtures and a 60-second timeout; no user data or unsanitized diagnostic artifacts were added to the repository.

## Bounded verdict

Keep the independently verified native extent correction. The tested TextKit flags do not resolve giant-paragraph editing, and the displayed Scintilla baseline also misses the input target while retaining an unresolved Unicode correctness gate. There is no migration approval or hard universal safe-line-size conclusion from these experiments. A bounded read-only fallback can preserve access while the mature-engine decision is tested further; it must be labeled as an editing restriction rather than represented as fulfillment of the 100 MB normal-editing requirement. Evaluate the CodeMirror fallback and profile actual native-input costs before committing to another adapter. Do not build a bespoke text engine or alter document contents to make this benchmark pass.
