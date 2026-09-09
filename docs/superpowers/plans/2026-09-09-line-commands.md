# Logical line commands

Use TDD in ignored .local/line-commands-spike while root verifies current baseline. Copy only verified green exact sources after notifying root. Own new LineCommands.swift, tests and this final plan; no registry/UI/LineTransform changes.

Model CRLF as one separator and preserve CR/LF/CRLF slots and scalar sequences. Include trailing empty logical line after terminal separator; empty document is one empty line. Selection is UTF16, scalar-safe, nonnegative and bounded; a nonempty range ending at a following line start excludes that line. CRLF interior positions refer to the preceding line. Empty selection targets current line. Moves at edges return exact input/selection. Moves permute content while preserving separator slots, so up/down inverse restores exact bytes even with mixed separators and unterminated final line. Moving visible trailing empty lines may change which content occupies the terminal slot.

Duplicate inserts the selected lines after themselves; a required new separator copies that line's marker or nearest preceding marker, default LF. Duplicate at EOF empty line adds a separator. Delete trailing empty line removes preceding separator; delete all returns empty. Join combines touched lines (or current plus next for a one-line target) with one ASCII space, retaining content whitespace and final touched terminator. Result selection/caret points to affected lines; root applies one undo transaction.

Tab conversions apply to touched lines, with stops every tabWidth columns (1...32), each extended grapheme cluster counting as one logical column. This is logical monospace column arithmetic, not font-dependent glyph widths; wide glyph pixel alignment is not claimed. SpacesToTabs converts space runs reaching stops, preserving existing tabs; TabsToSpaces expands to next stop. Content and untouched markers remain byte-exact. Input/output bound 20,000,000 UTF16 units and 200,000 logical lines for worker-safe bounded allocation; root owns background execution and undo.

Tests: exact Unicode bytes, surrogate/overflow validation, selection endpoint semantics, duplicate/delete empty/trailing/unterminated lines, mixed marker join, edge no-op, generated movement inverse cases, logical tab stops. Red first, implement, green then root handoff. Initial status planned.

## Verified implementation

2026-09-09: isolated API-shell run failed 37 behavioral assertions across eight tests. The implementation then passed eight tests. Two supplemental property/bound tests bring final isolated verification to ten tests with zero failures at 13:27 local time (0.235 seconds). The exact green source and tests were copied into their owned repository paths after notifying root. No root UI/registry edits were made and no integrated build was run by this subagent during the baseline checkpoint.

```sh
scripts/swift.sh test --package-path .local/line-commands-spike --filter LineCommandsTests
```

Public API: `LineCommand.apply(to:selection:tabWidth:) throws -> LineCommandResult`, whose public fields are `text` and `selection`. Errors distinguish invalid selection/tab width, text bound and line-count bound. Nonempty result selections expand to the affected whole lines; empty selections remain carets. Moves at edges return the original selection unchanged. Tab conversion uses grapheme logical columns, not font shaping. The editor integration still owns background dispatch, stale-document validation, a grouped undo transaction and menu actions. This evidence proves the isolated core behavior, not native command routing or undo.

## Editor integration review

Capture full document text, selectedRange and document identity before worker execution. Validate current document/membership, quit/saving state, exact UTF16 text and unchanged original selection before applying a late result. The existing replacement helper may reject shouldChangeText: report success to the caller or keep transaction and selection application together, so selection is never applied after a rejected mutation. Do not create an undo entry for byte-identical edge no-ops. Set the returned selection and scroll it into view only after successful replacement. Unlike older whole-document LineTransform behavior, an empty selection must remain the current logical line target.

Required native checks for the integration owner: EOF `a\r\n` at UTF16 offset3 duplicates to `a\r\n\r\n` at offset5; deleting that original trailing empty line produces `a` at offset1. Moving a selected block carries its expanded whole-line selection; a cursor/selection changed during the worker operation must reject the stale result. Native grouped undo remains the integration owner's verification, not a claim from isolated core tests.

## Shared transform execution

Older sort/case/indent/deduplicate/trim actions now share the asynchronous document executor. A native regression first failed because sort remained synchronous, then passed after migration. Captured text/selection must still match at completion; editing is temporarily locked; output is capped at100MB UTF8 with explicit errors. The full native harness passes native undo and macro recording for these actions. This is thread-placement and integration evidence, not measured100MB latency acceptance.
