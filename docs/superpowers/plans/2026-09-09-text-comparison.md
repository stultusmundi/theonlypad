# Read-only text comparison implementation plan

**Goal:** Compare a captured editor snapshot with a local file or supplied text, without editing either source.

**Architecture:** Byte-exact logical-line LCS with interned line identifiers, at most 2 MB UTF-8 per input, 2,000 lines per input and 4 million comparisons. Aligned optional rows retain exact original line strings; native display annotates endings and inserted/deleted blanks. Independent AppKit snapshot panel performs work off-main, invalidates stale results, synchronizes vertical scrolling, and navigates changed rows.

- [x] Write core tests for insert/delete alignment, exact Unicode and mixed endings, limits, cancellation, strict bounded file loading; observe missing-type failures.
- [x] Implement TextComparison.swift and pass targeted tests.
- [x] Implement ComparisonController.swift with file/text entrypoints, explicit snapshot labels, no write callbacks, next/previous controls, close cancellation.
- [x] Retain and execute native harness checking actual views, alignment, navigation, scrolling, stale results, and close invalidation.
- [x] Record verified commands and remaining limits. Root integrates command registry and full native script; no remote actions.

Review refinement: render expansion is prepared off-main with 16,000 UTF-16 units per displayed row and 2 million per pane; explicit rejection is tested before native layout. Verification: docs/verification/text-comparison.md. Root integration and full application acceptance remain separate.
