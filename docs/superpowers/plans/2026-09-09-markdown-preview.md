# Native Markdown preview

Scope: immutable, native, read-only preview; no browser, network requests, image loading or active links. Root owns registry/editor integration. This agent owns parser, preview controller, tests and native harness.

Plan: (1) failing tests for block/inline formatting, Unicode preservation, inert HTML/images/links, limits and cancellation; (2) pure bounded block parser using Foundation only for inline emphasis/code, mapping into safe text runs; (3) serial background parsing and native attributed styling with close cancellation/generation guard; (4) native properties harness and targeted tests.

The supported subset is ATX headings, simple unordered/ordered lists, fenced code, paragraphs, inline emphasis/strong/code. Lines containing HTML/image/link syntax stay literal. No CommonMark completeness claim. Limit input/output to 2 MB, blocks 20,000, runs 100,000; inline parsing per line at most 16 KiB, longer lines stay literal. Block rendering is explicit because native text views do not automatically style Foundation presentation intents. No dependency adoption. See Apple's inlineOnlyPreservingWhitespace documentation: https://developer.apple.com/documentation/foundation/attributedstring/markdownparsingoptions/interpretedsyntax-swift.enum/inlineonlypreservingwhitespace

Implemented/tested status will be recorded after execution; physical accessibility and print fidelity are outside this task.

## Implemented

`MarkdownPreview.parse(_:isCancelled:)` returns safe text/style runs. `MarkdownPreviewController(text:)` displays an immutable snapshot; `onClose` supports root retention cleanup. A shared actor serializes background parsing. Closing cancels the task and invalidates its generation; pending results cannot populate the closed window. Native attributes are allowlisted (font, text/background color, paragraph style), never links or attachments. Input normalization is limited to preview block separators; original document content is never changed.

## Tested

Tests first failed because `MarkdownPreview` did not exist. All three `MarkdownPreviewTests` then passed in the root package with `scripts/swift.sh test --filter MarkdownPreviewTests` (2026-09-09). They cover heading/list/emphasis/code parsing, exact decomposed/emoji/RTL text, inert HTML/image/link syntax, input/line/output/run limits and cancellation before/during parsing. The bounds case took 1.58 seconds in this run; no interactive-latency claim.

Tracked `Tests/NativeIntegration/MarkdownHarness.swift` compiled and passed against `MarkdownPreviewController.swift` plus PadCore objects. It asserts actual NSTextView heading size, list prefix, bold/italic/fixed-pitch font properties, read-only/selectable state, literal HTML/image markup, absence of link/attachment attributes, oversize error and no stale render after close. No screenshot or physical VoiceOver/keyboard session was exercised. Root owns command/menu integration and adding the harness to its aggregate script.

## Limits and remaining work

This is an intentionally bounded subset, without tables, nested list layout, HTML rendering, active hyperlinks, image fetching or full CommonMark conformance. Triple backtick/tilde fence handling is simplified. Long inline lines remain literal. The native property test establishes formatting attributes, not visual quality across all fonts/themes/OS versions. Full rendering of the maximum allowed output and peak-memory profiling remain unmeasured. Foundation is a system dependency; no third-party renderer was added.
