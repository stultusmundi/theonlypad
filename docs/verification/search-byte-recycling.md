# Search wire-byte retirement prerequisite

The existing supervised-search specification requires separate request-count, wire-byte and idle recycling boundaries. The new internal `requestIdleRetirement(generation:)` lifecycle seam and `SearchParentWireByteCounter` implement only the component prerequisites for the byte boundary.

The retirement request is accepted only for the exact owned generation with an accepted handshake and no active operation, stopping state, reap or quarantine. Acceptance means stop requested; it does not mean cleanup complete. Existing lifecycle signal/reap/channel-close ownership is unchanged. Success and semantic receipts remain intact. A false return cannot authorize a future driver to reuse a generation whose counter has crossed its threshold.

The counter holds generation/session epoch, an explicitly supplied nonzero threshold and a saturating UInt64 total. Stale observations are ignored, matching negative lengths are rejected, and zero lengths do not alter the total. The caller must record each successful complete write and nonempty read exactly once. It contains no payload or per-chunk history, and does not select production memory budgets.

## Component evidence

Private no-op contract overlays produced12 tests/23 explicit failed assertions. Implemented candidates passed57 tests/0 failures: all51 lifecycle tests and6 counter tests. Both68-input snapshots, exact original/compiled inventories and complete owned-watchdog receipts were independently verified. Only the lifecycle and counter implementations differ between RED and GREEN. No stub was adopted into production.

Tests cover active/pre-handshake/foreign refusal, repeated retirement, successful and semantic receipt preservation, held reap/close admission refusal, reserved replacement generation, competing idle trigger, exact threshold, stale generation/epoch, invalid input and overflow saturation. Private evidence remains under `.local/search-byte-recycling/`.

Source formatting passed after adoption. The matching frozen integrated app/core candidate passed721 tests/0 failures, including these components; all676 input hashes and complete owned-watchdog receipts were verified. This is component integration evidence, not real byte-retirement acceptance. Reproduce with `scripts/swift.sh test --filter 'SearchChildLifecycleTests|SearchParentWireByteCounterTests'`, under the accepted owned watchdog where required by the environment.

## Outstanding integration

The parent driver must arm the sole idle read before retirement, settle its actual result without relabeling a cancellation/error as EOF, preserve accepted output without waiting for reap, and prevent immediate result-observer resubmission into the old generation. Exactly-once real stream accounting and these driver transitions are not proved by the pure counter. The actual allocation gate must independently cross512,000,000 bytes and observe exact cleanup/replacement; no such run or allocator/RSS claim is made here.
