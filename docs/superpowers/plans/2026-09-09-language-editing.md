# Language-aware comment commands

Planned: explicit per-language line/block delimiters and recommended indentation; pure comment transformations returning exact text and UTF-16 selection; unsupported operations fail actionably. Input/output cap 2 million UTF-16 units and line-command cap 20,000 lines. Work first in ignored isolated package, red tests before production changes; root integrates native grouped undo separately.

Line toggle: operate on touched logical lines (LF/CRLF/CR), excluding a following line when a nonempty selection ends at its start. Insert delimiter plus one space after indentation; if every touched line is commented, remove delimiter and at most one following space. Caret maps through prefix edits; nonempty selection covers the affected lines. Empty final lines are valid.

Block toggle: wrap exactly the selection with delimiters (no added whitespace); a fully enclosed selected comment unwraps. Empty caret produces paired delimiters and selects the wrapper. Reject embedded opening/closing delimiters when wrapping, and reject '--' inside new HTML/XML comments. No Python triple-quote pseudo-comments. Commands are textual, not semantic parsers; strings and embedded-language regions are not inferred. Bracket matching is not included in this task.

Tests: exact normalization/emoji, mixed endings, endpoint rules, empty EOF, inverse toggles for supported cases, invalid/surrogate selections, unsupported delimiters, unsafe nested/HTML content, bounds and cancellation. Record actual status after execution.

## Implemented and tested

Implemented `LanguageConfiguration(language:)` with `lineComment`, `blockComment` (`opening`/`closing`) and `indentation`; `LanguageEditing.toggleLineComment(text:selection:language:isCancelled:)` and `toggleBlockComment(...)` return the existing `LineCommandResult` for root-owned native undo integration.

Isolated red state first confirmed missing types. Five behavior tests then passed. A sixth bounds test exposed that block commenting initially lacked the 20,000-line limit; the test failed, the guard was added, and all six isolated tests passed (2026-09-09, 0.320 seconds). Only after that green run were source/tests copied into the main package. Source and tests were formatted. Exact-source isolated command: `scripts/swift.sh test --package-path .local/spikes/language-editing-package` (the temporary package is ignored, not distributed).

Coverage includes mixed line endings and next-line endpoints; normalization/emoji bytes; empty EOF and indentation caret mapping; generated comment inverse toggles; JSON/plain/Python-block limitations; C delimiters and HTML/XML '--'/trailing-hyphen rejection; invalid/surrogate/overflow selections; input/output growth and line budgets; cancellation. Recommendations for indentation are editor defaults, not claims of mandatory language standards.

## Limits and integration status

These helpers are textual. They do not parse strings, nested language regions, preprocessor branches or surrounding comments. New block comments reject embedded delimiters even in languages permitting nested block comments; this is intentionally conservative. Uncommenting removes at most one space after the marker, so toggling an arbitrary existing unspaced comment twice may normalize marker spacing. Root still owns command/menu wiring and actual native undo/selection integration tests. Bracket matching is not implemented here. No production document, preference or UI source was changed by this task.

## Native integration

The shared command registry now exposes line/block comment actions, including Command-/ and Command-Option-/. The native harness first failed on the missing command, then passed after wiring through the asynchronous document command executor. It verifies Swift line commenting and one native undo. The full native harness suite and combined142 core tests passed. Unsupported languages report explicit errors; bracket/pair behavior and physical keyboard verification remain outstanding.
