# Parent search wire bridge and codec lane

The parent-driver plan's Task1 primitive is implemented in `Sources/SearchExecution/SearchParentWireBridge.swift`, with20 tests in `Tests/SearchExecutionTests/SearchParentWireBridgeTests.swift`. This is an internal transport primitive, not an application search service or helper integration.

One dedicated blocking-capable thread admits one job with no queued source. Synchronous `submit` transfers the closure into that lane; the result-only one-shot `Work.value()` receipt does not retain a reverse edge to the source-bearing job. Job/body ownership is released before lane admission and completion publication. The reported `loopStopped` state is not a physical OS-thread join.

Each writer owns one bounded upload bridge. Emission waits for the exact full asynchronous write, then drops payload ownership outside locks before publishing its acknowledgment. A metadata-only retirement record prevents reentrant close from claiming settlement during payload release. Tokens fence generation, writer epoch and sequence. Producer exit, active emission and consumer/write-scope exit are independent settlement conditions. Closing or reaping does not establish those conditions. Errors retained by the bridge are compact typed values.

## Evidence

Private evidence lives under `.local/search-parent-wire-task1/`. Final independently reviewed snapshot `final-reviewed` binds60 inputs. Exact adopted source SHA256 is `1fac24c63d9fd2810957cd4a945095794982a094824511670d723f3e55d3ce3f`; test SHA256 is `c6ad896b17cc6309c0e4a3c86490e26faabc97989147138760ef5e1e77e80df0`.

- Initial behavioral RED:1 test/1 assertion, detecting acknowledgment before completion of the held write.
- Duplicate producer-exit regression:1 test/2 assertions before the guard fix.
- Expanded/final suite:20 tests/0 failures, warning-free.
- Early acknowledgment mutant:1 test/1 explicit assertion failure.
- Missing consumer-exit settlement mutant:1 test/1 explicit assertion failure.
- Foreign-token mutant:1 test/2 failures, including the explicit stale-acknowledgment assertion and a cleanup cancellation error.

None of the mutation failures relied on an outer timeout. Source inventories, generated manifests, exact commands, captured log lengths and complete owned-watchdog receipts were independently checked. The final integrated frozen app/core snapshot under `.local/search-wire-primitives-integrated/` passes679 tests/0 failures, including the9 new lifecycle tests and20 bridge tests. The actual app also compiled in this invocation. Test duration15.864s is not a performance benchmark.

Reproduce the focused behavior with `scripts/swift.sh test --filter SearchParentWireBridgeTests`; use the owned watchdog for the broad suite containing adversarial regex. Public-pattern, scope-format and diff checks accompany adoption.

## Limits and next integration

No concrete child connection, driver, helper, application search routing, cancellation deadline policy, allocator or RSS budget is established here. Data-deallocator controls prove logical release ordering, not backing allocation counts. Codec session Task2 and exclusive driver Task3 remain required before the two-process allocation gate. A later read-only bridge identity accessor for codec validation must be recorded and tested as its own dependency change rather than silently changing this accepted source hash.
