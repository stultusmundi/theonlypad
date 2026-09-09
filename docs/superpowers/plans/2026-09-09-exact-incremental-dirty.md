# Exact incremental dirty comparison: execution plan

Status: fixed native API-contract probe passed; remaining tests and optimized implementation are planned. The measured controller baseline and work-bound red precede implementation. Engine owns the ignored candidate; root owns production integration. Preserve unrelated changes. See [design](../specs/exact-incremental-dirty.md) and [contract evidence](../../verification/storage-edit-range-contract.md).

## First API-contract probe (before optimization)

Use real NSTextStorage with real DocumentTextView/EditorDocument and existing controller callbacks. Add isolated read-only logging at will/didProcessEditing and dirty-query entry: mask/range/delta/current length, edit nesting under fixture control, cache/proof counters. No document bytes in logs. Retain before/after synthetic strings in the test only.

For each processed notification with delta0, verify exact UTF16 equality outside the reported range. For nonzero delta verify the prefix before range.location is unchanged. Compare old and new suffix only with the documented shifted indices as an additional diagnostic, not candidate proof. Assert priorLength + delta == finalLength for completed batches. Exercise:

- Single insertion/deletion/replacement at start/middle/EOF, empty initial/final string.
- Two distant same-length replacements in one batch, reversed order.
- Insert early/delete late; delete early/insert late; insert/delete same location; sequences whose net delta is zero but intermediate lengths differ.
- Nested begin/endEditing with dirty reads before/after EVERY mutation, between inner/outer end, and repeated queries at an unchanged pending tuple.
- Attribute edits widening range before/after character edits; attribute-only batch.
- Native insertText, native undo/redo and setMarkedText updates/commit/cancel.
- Whole .string assignment and mutableString replacement independent of textDidChange.
- A one-shot willProcessEditing delegate fixture edits additional characters to test aggregate coverage. Do not mutate characters in didProcessEditing, which violates AppKit's contract. An observer queries dirty during didProcessEditing to exercise conservative transient handling.

If any aggregate coordinate claim fails, retain failing seed/sequence and narrow admission to cases actually justified by documented behavior; never silently change expected equality.

## Oracle-driven state histories

Oracle at every checkpoint:

    expected = pendingPublication != nil
               || encoding != savedEncoding || BOM != savedBOM
               || !storage.string.utf16.elementsEqual(savedText.utf16)

Always evaluate oracle against current native storage; do not derive it from the candidate's intervals, revisions or cached values. For small fixtures full snapshots are cheap. Assert candidate dirty equals oracle before and after every operation, within pending batches, after drain, and after undo/redo. After EVERY proof transition (including pending getter, metadata short circuit, baseline setter, notification and stable getter), assert interval bounds/length alignment and exact equality of EVERY claimed outside unit against savedText. For suffix proof assert its entire claimed prefix; unknown claims nothing. Empty is mathematical empty: clean EOF edit must not widen to zero. Check invariants even if candidate dirty is true, because a broken proof may not affect the Boolean until a later restoration. Also assert storage exact text, current selection, native undo availability/action name, editRevision and recovery logical-document count match control where applicable. Track native units examined only in candidate/control instrumentation; counters must not change computation.

Deterministic seeded operation grammar (at least100 seeds ×200 operations on <=4096 UTF16-unit strings): scalar-safe insert/delete/replace, repeated no-op replacement, attribute edit, save-baseline assignment to current or retained old text, metadata change/baseline change, start/end nested batch, direct whole assignment, native undo/redo. Generate both same-length and length-changing operations. Pool contains ASCII, CR/LF/CRLF, NUL, bidi marks, composed/decomposed accents, equal-length reordered combining marks, supplementary emoji and ZWJ sequences. Keep nesting bounded4; unwind at end. Reproduce failures with seed+operation descriptors, not user data. Use actual valid scalar boundaries; malformed native UTF16 is outside user editor string contract and separately labeled if tested.

Explicit adversarial histories:

1. Clean100MB EOF same-length replace → dirty; undo → clean; redo → dirty; inverse replacement (not undo) → clean.
2. Clean append at EOF → dirty with length precheck; undo → exact clean by conservative tail proof, not an undo-position assumption.
3. Early insertion while an EOF mismatch exists; compensating deletion elsewhere restores length but NOT text; must stay dirty. Reverse order too.
4. Equal-length composed/reordered combining edit remains dirty; restoration clean. Decomposed→composed length change remains dirty.
5. Read dirty inside nested batch after insertion, then remove at another location; zero final delta must not reuse transient clean cache.
6. Save baseline changes while edits remain pending, and while encoding/pendingPublication masks text dirty. Later clearing metadata/publication must reveal correct text state.
7. Whole direct .string changes and native marked-text APIs must invalidate without relying on controller textDidChange.
8. Two attached panes share one proof/cache; insert in either, undo through sibling, detach origin, undo. No per-view dirty state.
9. Two distant changes grow convex interval; undo only one leaves dirty. Undo both clean. This may be slow, but must be exact.
10. Observer order: dirty queried before document's didProcess observer, inside callback, and after process complete. Transient reads must not damage final proof or manufacture cache hits.

## Measured baseline/red and actual-controller candidate

Use the current full-controller protocol in README.md: separate navigation time, actual editor insertText + visible layout/display, real open callback, strict native viewport intersection, independent owned processes and60s deadline. Do not use hidden adapter-only or stale engine spike results as new acceptance.

Before implementation, instrument existing comparator calls and examined-length:100MB same-length EOF replacement/restoration should show full-document work. The functional oracle should already pass control; red is a deliberately stated work-bound regression, e.g. first post-process same-length EOF change from known clean examines at most a fixed small bound (not100M). Do not use flaky wall-clock thresholds in retained semantic tests. Candidate must preserve functional suite while making bounded-case work counter green. Then separately measure3fresh processes and all requested operations, report worst case/first and p95 without concealing slow restores.

No promise all histories are O(edit size): unknown baselines, transient batches and widely dispersed edits deliberately fall back or widen. Keep under50ms user target unchanged and report any misses. Root controls exclusive benchmark slot and approves implementation after design review.

## Execution checkpoints

| Step | State | Evidence or next action |
|---|---|---|
| Fixed native edit-range contract | Tested | 31 processed edits and109 exact dirty-oracle queries passed; storage-edit-range-contract.md records limits and fixture failures. |
| Instrumented unchanged controller work bound | Tested red | Actual100MB EOF replacement reached the intended submitted-span assertion after exactness/visibility checks:100,000,000 units exceeds4,096. No optimized implementation yet. |
| Repeated unchanged controller attribution | Tested | All six fresh children passed,108 operations; same-length100MB medians433–456ms, comparator425–447ms. See ../../verification/incremental-dirty-baseline.md. |
| Implement conservative exact interval/suffix proof | In progress, isolated | Engine owns ignored candidate; root owns EditorDocument and native-suite integration. Keep metadata/publication independent and fallback exact. No candidate tests or production adoption yet. |
| Seeded transition/oracle and native history tests | Planned | At least100 seeds ×200 operations, proof invariants and exact dirty oracle at every state; retain native shared-pane/undo/marked-text cases. |
| Candidate work bound and measured comparison | Planned | Same retained baseline protocol and fixtures, unchanged gates/targets; incomplete runs remain incomplete. |
| Independent code review and production integration | Planned | Resolve material findings, copy only reviewed source/tests, run core and affected/full native compatibility, then package when appropriate. |

Current local baseline commands are `bash .local/controller-latency-review/baseline/compile.sh`, then `python3 .local/controller-latency-review/baseline/run.py 100000000 work-bound`, followed by `measure` mode for100000000 and10000000. The work-bound command intentionally returns failure on unchanged code. Initial restricted log-descriptor setup failure was preserved separately and does not count as behavioral red. These ignored investigation commands are not yet public reproduction tooling for an adopted optimization.
