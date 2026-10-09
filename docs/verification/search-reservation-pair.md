# Same-ledger paired reservation verification

The inactive internal ledger primitive admits base and producer charges together while preserving independent retirement authority. It adds only `SearchAdmissionReservationPair` and `reservePair(base:producer:)` to `SearchAdmissionLedger.swift`. The ordinary controller, service, accounting formulas and decoder remain unchanged; no production call site selects this new method yet.

## Implemented contract

Producer retained credit must be zero. Invalid producer charges refuse with `invalidDescriptor` before either reservation, including when the base independently exceeds a limit. A zero active producer still owns a real second entry.

Both phases use the existing ledger and checked aggregate budgets, including resident credit, earlier reservations and retained leases. If second admission throws, the newly admitted base is abandoned and the original error rethrown. There is no suspension or callback inside the transaction. Base retention and producer abandonment remain separate existing operations; one cannot implicitly retire the other.

The pair has readonly opaque tokens and a fileprivate initializer. Copying or dropping tokens is not payload retirement, and callers still require one logical mutable ledger owner. No concurrency, allocation-failure, UUID collision, OS atomicity or RSS guarantee is added.

Current source: ledger4,870 bytes/SHA256 `ffd32b52b31079c15382a8c65f59bf0abc55213f7fbd4de8289dbc9ea372472f`; new nine-test file14,270 bytes/SHA256 `92ae570c404f5609bfabd1dd4d4e99d51c43d8b79a370509e22e1ba4f896fbb2`. Removing the847 additive bytes restores the exact previous4,023-byte ledger. All14 existing ledger test methods and their source bytes are preserved.

## Tested evidence

Root executed serially on ARM64 macOS26.6.2 with Swift6.3.3 in Swift5 language mode. The package deployment floor remains macOS14; that platform and Intel runtime were not tested.

- Genuine missing-API compiler RED:14 absent `reservePair` diagnostics,28 associated initializer inference diagnostics and the terminal SwiftPM failure. No XCTest method ran during RED. Complete captures and consuming owned-process receipt were verified before implementation.
- Matching minimal frozen package: all79 actual PadCore/SearchExecution Swift sources, exact generated manifest, new9 and unchanged legacy14 tests;23 tests passed with no warnings or skips.
- Matching frozen public package:125 related controller, ledger, accounting, service, joined-shutdown and decoder tests passed. Full suite1,025/0 retained every previous1,016 method plus the new9. Exact409 input bindings, artifact and complete direct-watchdog receipts were verified.
- Actual public-package focused command:23/0. Recursive strict formatting, public-source checks and whitespace checks passed.

Three separately reviewed private copies of the actual ledger were compiled and tested with unchanged nine-test bytes. Every control started and finished all9 methods, exited1 for intended XCTest assertions, and had0 unexpected errors, warnings or skips. Production source stayed unchanged.

| Deliberate fault | Failed methods | Assertion failures |
|---|---:|---:|
| Remove second-admission rollback |2|4|
| Remove producer retained-credit guard |1|3|
| Return base token for both halves |8|20|

The alias control retains both real entries and explicitly discards its unused local token solely to avoid a compiler warning; separate retirement then exposes stranded producer credit. Failed-method counts and assertion counts are distinct.

## Reproduce focused public tests

```sh
scripts/swift.sh test --scratch-path .build/search-reservation-pair-public --filter 'SearchAdmissionReservationPairTests|SearchAdmissionLedgerTests'
```

The broad adversarial suite requires the accepted owned-process watchdog. A runner that owns that watchdog must never be wrapped in another session-owning watchdog. Raw synthetic captures, source snapshots and control artifacts remain ignored under `.local/search-reservation-pair-component/` and `.local/search-reservation-pair-integrated/`; no raw logs or machine paths are published here.

## Planned and excluded acceptance

The next work is the admitted file reader/producer, actual worker and Task returns, progress delivery and helper/editor routing. This primitive neither activates the accepted decoder nor approves a producer charge formula, file/root capability, close policy, task-return receipt, global capacity or native interface.

No helper, visible window, physical keyboard, IME, VoiceOver, packaged runtime or allocation/performance acceptance follows from these synchronous logical-accounting tests. The broader100MB/1GB product targets remain outstanding. Existing distribution artifacts were not repackaged or published.
