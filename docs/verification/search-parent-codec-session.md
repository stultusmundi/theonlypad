# Parent search codec session

The parent codec session is implemented behind the retained codec lane. It validates generation, session epoch, operation, phase and ordinal before emitting request bytes; constructs the response accumulator before upload; and retains the exact writer-returned index for response validation. Reader terminals remain provisional until the outer consume call succeeds. Callback reentry poisons the session even when a callback catches the nested error. Failure/discard releases the reader and index on the codec lane. The bridge exposes its immutable writer identity for this validation.

## Verification

A compiling no-op contract produced16 tests/173 failed assertions. The first implementation run produced16 tests/3 failures, uncovering the independently corrected parsed-header accounting bug described in [wire verification](search-wire.md). Final focused verification passes135 tests/0 failures:21 session behavior tests and114 wire tests. Independent review verified all six source inventories, candidate hashes, owned-watchdog receipts and the retained final binary.

Two instrumented tests pass; a poisoning mutant produces one test/three explicit assertion failures. Instrumentation records iterator calls and logical ownership scopes. Its six modeled chunk credits do not prove actual allocation, retained backing storage, copies or RSS. The response accumulator remains responsible for its documented output contract; the session does not duplicate its source scan.

The final adopted files match the676-input integrated snapshot, which passes721 tests/0 failures and builds the app. Private evidence is retained in ignored `.local/search-parent-codec-task2/` and `.local/search-codec-integrated/`. Reproduce focused behavior with `scripts/swift.sh test --filter 'SearchParentWireCodecSessionTests|SearchWire'` under the accepted owned watchdog.

## Remaining acceptance

The component does not launch a helper, coordinate connection/lifecycle tasks, route application search, or establish desktop, cancellation-containment, memory or performance acceptance. Those remain separate driver and runtime gates.
