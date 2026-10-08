# Production admission accounting and retry verification

Status: component implementation and runtime verification complete; independent final checkpoint evidence review approves the scoped local commit. This record separates component evidence from application acceptance; a passing build cannot establish feature completeness.

## Scope and current gates

The reviewed design adds standalone implementations of the existing admission accounting and retry protocols. Controller, ledger, driver, native routing and package dependency interfaces are preserved.

- Accounting source is implemented. Its focused frozen component run passed 12 tests with no failures: ten charge/boundary tests and two controller/lease integration tests. Independent test and source reviews found no blockers.
- Retry source is implemented and independently reviewed. The combined focused frozen selection passed 23 tests with no failures: seven real adapter methods, four additional controller/codec methods and the twelve accepted accounting methods. The accepted accounting integration prefix and original tests are preserved.
- Missing-API compilation failed before any test method ran. Two separate finite wrong schedulers each reached one test and one intended assertion failure: inline delivery failed the returned flag, and ignored cancellation yielded one unwanted callback after a delivered sentinel. Neither timed out. The inline control did not fail its minimum-delay assertion; only the observed returned-flag failure is credited.
- The frozen neighboring admission/parent/wire/resolver selection passed 357 tests with no failures or warnings. The fresh public-package app/core run passed 962 tests with zero failures or warnings and linked both TheOnlyPad and PadSearchWorker. Strict recursive Swift formatting and public-source checks passed.
- The distribution artifacts still represent source `4841d89`; they do not include this component checkpoint.

## Logical reservation policy

The accounting defaults are active limit 1,610,612,736, retained limit 1,342,177,280 and resident allowance 1,048,576. These are logical content reservations per controller, not measured allocations, RSS or a process-wide memory limit.

Let I be estimated full-source UTF-16 units; O be the replacement output ceiling, or zero for find; M be the match ceiling; Q be pattern UTF-16 units; and T be replacement-template UTF-16 units, or zero for find.

```text
active = 65536 + 6I + 6O + 32M + floor((I + 8) / 8) + 3(Q + T)
retained = 4096 + 3I + 3O + 16M
```

Scope does not discount the full source. Every intermediate addition and multiplication is checked; accepted dimensions and bounded pattern/template inspection use exact conversions. Invalid dimensions are distinct from arithmetic budget failure. Publication retains declared ceilings, including empty-result metadata. Borrowed result credits remain charged until the outer borrow returns.

Tests with maximum estimates use tiny synthetic captures. They do not allocate or search a 100M-unit document. Contexts, closures, aliases, editor storage, undo, helper/kernel storage and allocator capacities remain outside this policy.

## Retry contract and integration plan

The selected default scheduler posts a fresh main-queue work item after 25,000,000 nanoseconds. Each token owns its action and work item; the queue captures the token weakly. Fire and cancellation clear retained references before invoking or cancelling. A dropped token releases its action even if a no-op queued entry remains until its deadline. This contract does not certify physical queue retirement.

The new tests require real callbacks for delivery ordering and cancellation suppression. Scripted controller cases observe existing protocol calls without changing their arguments, results or returned tokens. The real-codec case uses the actual parent driver and production accumulator with synthetic injected process/channel collaborators, literal supplementary Unicode and generation-qualified session release. It preserves the first historical legacy shutdown receipt while checking later current settlement separately.

No actual helper process, regex engine, native search routing, joined admission terminal owner, heap/RSS acceptance, desktop, physical keyboard, IME, VoiceOver or additional platform acceptance follows from these components. Safe joined terminal ownership and native integration remain subsequent work.

## Source and runtime bindings

The implemented accounting source is SHA256 `b0031c8fcb9e75d526a154751216fc5ac14504a4048e49ee9517dabbba39ce9b`; the scheduler source is SHA256 `95ed4ea80a7008cfa79ddc1f36412b0e063fdd14bdb17791e4982eb3df8b8587`. Both are original project code and add no external dependency. Root formatting preserved all tokens and the accepted first 10,222 integration bytes; authored originals and complete preparation diffs remain in ignored local evidence.

Task1 and Task2 compiler RED snapshots adopted 80 and 83 exact inputs respectively, plus a generated minimal manifest, and executed zero test methods. Task1 wrong-formula control ran three methods with seven expected assertion failures. Task2 inline and no-cancel snapshots each adopted 83 exact inputs plus the manifest and one explicitly generated wrong scheduler. Task2 GREEN adopted 84 inputs plus the manifest; neighboring verification adopted 107 plus the manifest. These snapshots use complete actual PadCore and SearchExecution sources, the public dependency edges, macOS14 deployment and Swift5 mode. They omit native application/helper runtime targets.

Every stage directly invoked the checked-in owned-process watchdog, with complete captures, exact commands, observed exit and checked cleanup receipts. Inventories bind current and frozen source bytes, file modes and membership before and after component execution. The public-package run binds 387 current source/test/manifest/tool inputs by exact bytes and membership before and after execution; it does not use a generated component manifest. Generated wrong controls remain private and were never adopted into production. No tests, security checks, original fixture assertions or platform gates were weakened.

## Reproduction and retained limits

Root executed the full public package through the sole direct owned watchdog:

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/admission-production-full-owned -- scripts/swift.sh test --scratch-path .build/admission-production-integrated
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
```

Use a fresh output directory on reproduction; the watchdog refuses overwriting prior evidence. Root's private component-freezing coordinator invoked that same checked-in watchdog directly for each compiler RED, behavioral RED, GREEN and neighbor stage, using separate scratch paths and the minimal manifest described above. Never nest another session-owning watchdog around these stages. Raw synthetic receipts, immutable inventories, originals, diffs and independent reviews remain under ignored local directories.

Verified locally on ARM64 macOS26.6.2 with Swift6.3.3 in Swift5 language mode. macOS14 is the compiled deployment floor, not a tested runtime platform. No GUI, helper process or regex engine executed in the new component scenarios. The full suite is automated regression evidence, not whole-product acceptance. Existing packaged desktop results retain their dated source; no package was rebuilt or promoted for this collaborator-only checkpoint.

Next is the admission terminal-owner design. Existing controller shutdown selects the parent's legacy terminal path and cannot later establish joined terminal cleanup. The new design must drain actual request/wait/cancel ownership before the parent's immutable first join, preserve historical receipts, and avoid waiting on a result still borrowed by its own native callback. Native document and folder consumers remain subsequent integration work.
