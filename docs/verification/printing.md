# Printing verification — 2026-09-09

Implementation: `Sources/TheOnlyPad/DocumentPrinting.swift`, `file.print` registry command, editor dispatch. The native Print dialog provides system PDF export. Print layout uses an independent black-on-white text view, preserving source editor selection, theme and wrap state. Documents above2million UTF-16 units return an actionable limit message before layout.

Tested: native AppKit harness builds the print view from synthetic Unicode text, checks exact text and nonempty height, and verifies AppKit generated PDF bytes begin with `%PDF`. This passed in `scripts/test-native-integration.sh` before subsequent extension integration. Rerun at final checkpoint.

Independent review found no new data-integrity issue. Layout is synchronous before the print progress panel; worst-case print responsiveness remains unmeasured. The PDF test does not prove pagination, glyph fidelity, printer output, Print dialog keyboard behavior, or system Save as PDF workflow. Those acceptance checks remain outstanding. No print-completion claim is made.
