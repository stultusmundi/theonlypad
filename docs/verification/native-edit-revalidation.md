# Native edit callback revalidation

## Search Replace All — 2026-10-05

Implemented and independently reviewed: Replace All revalidates the exact document, pane/storage identity, revisions, native authority and source bytes after edit-permission, undo-coalescing and undo-group callbacks. It rejects pending character edits. Bookmark and macro bookkeeping remains a local proposal until the final admission succeeds. An identical nested edit cannot claim the outer proposal. Refusal preserves callback-owned edits and undo rather than clearing or rolling them back.

The actual hidden controller/panel suite passes12 tests; neighboring native projection/responder/undo tests pass20; pure coordinator contracts pass32. Root independently verified frozen inputs, exact current controller/test bytes and all owned-watchdog stage receipts. Search manifest SHA256: `468802751822fa2a4538d5d15ae58ab54a88d33b7bda5a5739749afff950db73` (167 source and132 generated entries). Projection manifest: `7f133a2a7096f065274f72c6e051d70674d5e3668cd590128c4711284a17ec49`.

Behavioral RED first reproduced same-length overwrite (one test/two assertions); later managed-controller RED reproduced stale and duplicate macro bookkeeping (ten tests/two assertions). Earlier pending same-text/coalescing failures, a compiler annotation failure and an invalid registry setup are preserved separately. The final twelve cases include Unicode undo/redo, successful bookmark/macro commit, managed post-delegate callback edits, nested identical edits and undo-group notification invalidation.

```sh
scripts/test-search-replacement.sh
scripts/test-editor-transfer-projection.sh
python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
```

The coordinators own their watchdog directly; do not nest another. The search transform suppresses only panel presentation and appends explicit private-access extensions. Controlled tests replace or forward the delegate as documented; success/bookkeeping cases exercise the actual controller. No windows are shown or input posted. CI now includes the search runner; hosted execution is not claimed. Private evidence remains under `.local/search-replacement-tests/`, `.local/editor-transfer-projection-tests/` and `.local/resumption-20261005/`.

These checks do not establish visible Find-panel, physical input, IME, macro-cap modal or arbitrary reentrancy during actual text-storage mutation/didChangeText acceptance. The original checkpoint was limited to the search commit boundary. The neighboring routes are recorded separately below.

## Shared edit boundary and neighboring routes — 2026-10-05

Implemented: one private synchronous edit boundary now serves search replacement, minimal document transforms, line-ending conversion, Text Utilities, JSON formatting and macro replay. It validates the actual UTF-16 range and scalar endpoints, preserves partial edits, and stages macro/bookmark bookkeeping until callback admission finishes. Async callers retain their original context, operation ID and selection policy. Replay retains its original cancellation object even after the global replay slot is cleared.

Tested:32 hidden actual-controller tests and20 neighboring projection/undo tests pass against matching controller bytes. The expanded suite preserves the original12 search tests and includes benign Unicode partial edits, no-op bookmark behavior, JSON focus policy, and replay action/undo/redo. Each migrated family had a compiling behavioral RED: document transform13/3, async command18/4, line endings21/2, utilities24/6, JSON27/2 and replay31/3 (test count/failed assertions). Corresponding GREEN stages and earlier harness-transform failures remain retained. No failed assertion was removed to obtain the final result.

Root independently verified168 original and132 generated search inputs,167 original and132 generated projection inputs, current controller/test bindings, warning-free diagnostics and strict direct-watchdog receipts. Final search manifest SHA256: `05f98ac923530e9f6b532d15975d5d27309e7a19ff1ca36f60abaaa5691934b0`; projection: `182230cc6621cbe8d17344a14b6b755e74edab7f5e8874810a413959f653b08a`. Private evidence: `.local/search-replacement-tests/run.6frlmpht/`, `.local/editor-transfer-projection-tests/run.lau2wvvq/`, and `.local/resumption-20261005/root-edit-variants-final-verification.json`.

The search harness now also suppresses Text Utilities presentation, appends explicit private access, and observes the existing async command/line-ending/replay completion defers. These are frozen test-only changes, not production callbacks. The historical manifest's generic transformation description omitted those details; original/compiled hashes and exact transform source remain bound and verified. The runner description was corrected after a37-test pure suite reproduced the omission and then passed; historical evidence remains unchanged. Independent final source review approved the bounded repair with no blockers. The matching integrated snapshot also passes839 core/component tests and builds the actual app without warnings; this is separate from desktop acceptance.

These tests show no windows and post no input. They establish the tested precommit callback boundaries, not arbitrary reentrancy during storage mutation/didChangeText, physical typing/IME, modal macro-cap interaction, performance or packaged desktop acceptance.
