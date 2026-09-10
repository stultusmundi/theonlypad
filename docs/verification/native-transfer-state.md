# Native transfer state verification

The native adapter captures bounded document scalars and geometry for at most two retained panes. It preserves the original model and immutable presentation receipts. Validation accepts only the exact ownership/mutation rotation supplied by the registry and rejects unrelated edits, geometry changes, preparation, composition, pending publication, unfinished text processing and undo activity.

`EditorDocument.rotateTransferOwnership()` mints and assigns both UUIDs, then returns that exact pair without callbacks. It does not change recovery authority or revision issuance. Existing ownership rotation callers retain their original interface.

Command: `scripts/test-native-document-transfer.sh`. The private snapshot injects a counter before the unchanged dirty getter; tests assert transfer capture/validation never invoke it. Production code contains no counter. Attached selections are checked against current UTF-16 bounds; detached historical ranges are retained without clamping or rewriting undo history. The tests do not establish physical IME behavior or replay of every detached selection.

Twelve hidden tests passed with zero failures in 0.131 seconds (`.local/native-document-transfer-adapter/rotation-green.log`). The initial adapter refusal seam produced eight tests with 13 failures before implementation; rotation subsequently produced 12 tests with two failures before the exact token method was implemented. Setup failures remain separate from behavioral evidence. Strict formatting checks passed and independent review found no material issue.

This verifies the model adapter only. Controller projections, process integration, actual window movement and desktop acceptance remain outstanding.
