# Bookmark gutter implementation plan

**Goal:** Add visible bookmark indicators and native click callbacks to the existing logical-line ruler while preserving line numbers.

**Architecture:** Expose `bookmarkOffsets: Set<Int>` and `onToggleBookmark: ((Int) -> Void)?`. Draw only visible first fragments of logical CR/LF/CRLF lines. Resolve clicks through native glyph layout then normalize to a UTF-16 logical line start, including wrapped continuations and final empty lines. Reuse the existing two-million-unit ruler limit. Accessibility label reports bookmark count; keyboard commands and editor state belong to root integration.

- [x] Create an isolated retained native harness; capture missing API failure.
- [x] Add indicators/count labels and checked click routing with original line numbers retained.
- [x] Execute actual AppKit drawing/click/scroll/wrap/EOF checks with synthetic text.
- [x] Format and copy only the green ruler/harness after coordinating build timing. Record limitations separately from native editor acceptance.

## Native evidence and limitations

The isolated native harness passed actual AppKit rendering: bookmark changes altered gutter pixels while the line-number-only image remained identical. It also verified the bookmark count accessibility label, emoji/CRLF UTF-16 click locations, wrapped continuation mapping, scrolled viewport coordinates, empty and final-empty lines, rejection below the document, and hit-test refusal above the existing two-million-UTF-16-unit ruler limit. Fixtures and image buffers are synthetic and in-memory; no screenshots or user documents are saved.

Indicators are drawn in a separate left-hand strip; the ruler grows from 52 to 68 points to preserve room for line numbers. Clicking any visible gutter line sends the logical line-start offset through the callback; the ruler itself does not mutate text or bookmark state. CR, LF and CRLF define logical lines consistently with the bookmark core. Other Unicode separators remain visual text-engine breaks, not extra logical bookmark lines.

The retained harness compile/run command (after copying green files into root) is:

```sh
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library Sources/TheOnlyPad/LineNumberRuler.swift Tests/NativeIntegration/BookmarkRulerHarness.swift -o .local/native-integration/bookmark-ruler-test
.local/native-integration/bookmark-ruler-test
```

Core bookmark tracking can support larger text than this ruler: gutter drawing and clicking remain deliberately omitted above two million UTF-16 units pending an incremental viewport line index. No keyboard-command, VoiceOver navigation, native bookmark undo, persistence, or complete B-06 acceptance is claimed by this harness. Root owns editor integration and the common test script.
