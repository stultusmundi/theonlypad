# Joined parent shutdown plan

Specification: [joined parent shutdown](../specs/2026-10-06-joined-parent-shutdown.md).
The original implementation author owns driver/types and tests/harness; root owns
serial execution, independent review, public records and local commits.

1. Private compiling RED against the reviewed contract; preserve all54 prior
   controls and immutable source/test evidence. **Verified:**59 tests/four explicit
   failures, zero unexpected;54 neighbors pass.
2. Implement one retained terminal owner and meaningful held/cancellation tests.
   Independently review source and exact input/receipt evidence; run focused
   mutants. **Verified private component:** final78/0; six focused assertion-failing
   mutants, independently reviewed. Details in [evidence](../../verification/search-parent-joined-shutdown.md).
3. Adopt the reviewed semantics and ordinary/frozen tests into the existing driver
   harness. Verify original-to-derived driver/lifecycle/lane relations and missing,
   duplicate and altered-input refusal. Run pure runner checks, complete frozen
   driver suite, full frozen application/core tests and build, formatting and public
   checks. Independent diff review precedes local commit. **Verified:** pure31/0, frozen78/0, full847/0 and warning-free app build;
   exact inputs/receipts and independent public diff review complete.

Proven existing command: `scripts/test-search-parent-driver.sh`. Its extended78-case selection passed matching execution. No remote integration or publication
is authorized. Continue afterward with reviewed cold finalization and actual
helper/editor search routing; this prerequisite is not product completion.
