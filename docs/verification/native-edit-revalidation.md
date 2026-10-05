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

These checks do not establish visible Find-panel, physical input, IME, macro-cap modal or arbitrary reentrancy during actual text-storage mutation/didChangeText acceptance. Four neighboring mutation routes (document transforms, Text Utilities, JSON formatting and macro replay) remain identified follow-up work. This fix is limited to the tested search commit boundary.
