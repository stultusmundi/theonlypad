# Search admission verification

Driver settlement, the numeric ledger and the policy-injected admission controller are implemented and independently reviewed. The controller remains unrouted; native/modal integration and measured policy selection remain planned. No production budget, helper accumulator or native route is selected.

## Descriptor and ledger — 2026-10-05

Fourteen tests passed after compiling behavioral RED with30 failed assertions. The descriptor bounds query/template UTF-16 traversal, input estimate and subtraction-safe scope metadata against existing validated wire limits. Tests preserve the100,000,000-unit ceiling using metadata without allocating a maximum document.

The ledger uses checked unsigned arithmetic and atomic refusal. Existing result leases compete with future retained reservations; reservation-to-lease transfer occurs once. Foreign/consumed reservations and duplicate leases refuse without partial changes; release and abandonment are idempotent. Resident transport stays charged. Entry-count limits and actual source/borrow lifetime are later controller responsibilities, not established by these counters.

Root independently checked all70 source/test hashes, exact compiler-input membership, current-source equality for GREEN and complete direct-watchdog receipts. GREEN inventory SHA256: `0d6da60adf3a28b326ea212321bce90490e456289f101529d34620c614a9857d`. RED inventory: `062d7be65d4508d2cd495972c181d964bd98ad4ea262255c8745a14628e9739b`. Private snapshots and receipts remain in `.local/search-admission-ledger/`. Independent source review approved descriptor/ledger scope with no blockers.

Executed focused command (the package is a frozen minimal copy of actual production inputs):

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/search-admission-ledger/green -- scripts/swift.sh test --package-path .local/search-admission-ledger/green-package --scratch-path .build/search-admission-ledger-green --filter SearchAdmissionLedgerTests
```

Use a fresh output directory for a new run. These tests launch no helper and establish no physical memory bound. Full current application integration remains separate. Nonterminal driver evidence is in [the driver verification record](search-parent-driver.md).

## Queue, capture, cancellation and leases — 2026-10-05

Implemented: a MainActor owner admits at most eight outstanding jobs and one per consumer, queues bounded metadata, reserves before capture, validates actual UTF-16 length off-main, and retains one submit/wait observer. Cancellation intent survives a delayed handle and cannot cancel the sole wait observer. Pending cleanup holds credit and capacity. Exact driver settlement precedes result publication; opaque leases retain credit until the last synchronous borrow returns. Shutdown closes callbacks/admission before awaiting, joins one terminal command and separately reports current settlement. It does not replace a driver or certify launcher quarantine.

The focused frozen suite passes56 tests (42 controller,14 ledger). Genuine staged RED/GREEN covers queue/capture/preparation/driver/lease/shutdown behavior. Independent review found accounting callback cancellation could still invoke capture; a compiling42-test RED reproduced one failed assertion, then revalidation before reservation/capture fixed it. Test-only closure-inference compilation failure and an earlier omitted driver branch's failed GREEN remain retained separately. Tests were not weakened.

Root independently verified73 frozen/live inputs and strict watchdog receipts; final focused inventory SHA256: `fadf596cb787bbf4625e1c12cbe57e264dbf18c19a509ba30ed111dbc2d5b5e5`. A matching frozen integrated snapshot passes839 tests and builds the actual app without warnings (238 inputs; inventory `57739c5f0ad991d80524be9afbb1a0e1c88dd9bd3105bff7653e2bc6b00982b9`). The actual-driver coordinator separately passes54 injected ordinary/instrumented tests, with83 originals and one generated manifest entry, exact transform relationships and strict receipts verified. Evidence remains ignored under `.local/search-admission-controller/`, `.local/resumption-integration-20261005/` and `.local/search-parent-driver-integration/run.zs7z0oo0/`.

Controls include weak context/completion destruction, retained old-result pressure, held cancellation commands, post-wait cancellation, immediate delivery release/cancel/unregister, independent consumers, simultaneous shutdown callers and stale retries. A nested synchronous borrow verifies invalidation with deferred payload/credit destruction; reentrant submission remains queued until the borrow returns. It does not simulate an AppKit nested modal loop admitting a replacement while that borrow remains live. That composition and native shutdown integration remain separate gates.

All controller tests inject the driver and accounting policy and launch no helper or windows. The actual-driver suite injects its OS collaborators. Numeric accounting is not measured heap/RSS, a default budget, packaged helper acceptance or user-facing search routing.

Two separately frozen mutation controls fail as intended with unchanged tests: removing cancellation-settlement guards produces three assertions in the held-cancellation case; removing the borrow-depth release fence produces two live-borrow accounting failures. Root verified each exact73-input mutation inventory and complete expected-exit1 watchdog receipt. Neither mutation altered accepted production sources.
