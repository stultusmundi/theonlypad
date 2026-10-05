# Search admission verification

The admission system is under implementation. Driver settlement and the numeric ledger are implemented and independently reviewed. Queue/capture/cancellation and result borrowing remain planned. No production budget, helper accumulator or native route is selected.

## Descriptor and ledger — 2026-10-05

Fourteen tests passed after compiling behavioral RED with30 failed assertions. The descriptor bounds query/template UTF-16 traversal, input estimate and subtraction-safe scope metadata against existing validated wire limits. Tests preserve the100,000,000-unit ceiling using metadata without allocating a maximum document.

The ledger uses checked unsigned arithmetic and atomic refusal. Existing result leases compete with future retained reservations; reservation-to-lease transfer occurs once. Foreign/consumed reservations and duplicate leases refuse without partial changes; release and abandonment are idempotent. Resident transport stays charged. Entry-count limits and actual source/borrow lifetime are later controller responsibilities, not established by these counters.

Root independently checked all70 source/test hashes, exact compiler-input membership, current-source equality for GREEN and complete direct-watchdog receipts. GREEN inventory SHA256: `0d6da60adf3a28b326ea212321bce90490e456289f101529d34620c614a9857d`. RED inventory: `062d7be65d4508d2cd495972c181d964bd98ad4ea262255c8745a14628e9739b`. Private snapshots and receipts remain in `.local/search-admission-ledger/`. Independent source review approved descriptor/ledger scope with no blockers.

Executed focused command (the package is a frozen minimal copy of actual production inputs):

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/search-admission-ledger/green -- scripts/swift.sh test --package-path .local/search-admission-ledger/green-package --scratch-path .build/search-admission-ledger-green --filter SearchAdmissionLedgerTests
```

Use a fresh output directory for a new run. These tests launch no helper and establish no physical memory bound. Full current application integration remains separate. Nonterminal driver evidence is in [the driver verification record](search-parent-driver.md).
