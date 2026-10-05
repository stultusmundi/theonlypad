# Parent search driver verification

Date: 2026-09-30. The driver is implemented and independently reviewed. The editor does not yet route searches through it.

`SearchParentWireDriver` connects the accepted lifecycle, codec session, bridge and byte counter. It owns one request coordinator, one persistent response reader and one codec lane. It records command cancellation separately from detachable result observers, transfers successful results once, and preserves lifecycle error classification. Read-sequence exhaustion reserves cleanup rather than leaving a reader stranded. Metadata observation is package-internal and optional; blocking test hooks and seeded counters exist only in frozen test copies.

## Verification

| Check | Result | Scope |
| --- | --- | --- |
| Exact uninstrumented driver | 27 tests, 0 failures | Ordinary injected behavior |
| Combined driver/components | 142 tests, 0 failures | 44 driver, 20 bridge, 21 codec, 51 lifecycle, 6 counter |
| Reusable runner in isolated repository layout | 44 tests, 0 failures | 27 ordinary plus 17 explicitly instrumented cases |
| Runner contract tests after adoption | 19 tests, 0 failures | Frozen-source integrity, exact test accounting and direct-source Python loading |
| Fresh integrated application | 765 tests, 0 failures | Complete default suite; application linked successfully; no compiler warnings |

The independent review checked exact source/manifest/log bindings and complete watchdog receipts. Root separately verified the reusable runner's 79 input records, original-to-instrumented relationship and retained test bundle. That manifest has SHA256 `fcd9450a03904955811ca2904b107f9c50fd15a34f2e6c3d08a6ca9e9eee1afc`. The integrated run binds 690 public-source inputs; manifest SHA256 `c8194fa745f01886d11b0881358dd33fce5d7401ad4d708d47e9bcf964c67fd0`.

Discriminating mutants fail explicit assertions: premature publication 1 test/2 failures, removed atomic observer claim 1/2, and premature response consumption before `expect` 1/3. The partial-response sequence-exhaustion regression first failed 1/1, then asserted protocol failure before cleanup shutdown after the fix. Other reproduced defects covered compact-result retention on refused admission, exact codec reservation ownership, and EOF/cancel/shutdown arbitration. Timeouts do not count as successful negative tests.

## Reproduction and retained failures

```sh
python3 -m unittest discover -s Tests/SearchParentDriverIntegration -p 'test_*.py'
scripts/test-search-parent-driver.sh
```

The runner freezes actual production sources, the separate instrumented tests and the exact-count transformation module. It retains original and compiled hashes, verifies compiler-input membership before/after each stage, executes verified Python source rather than cached bytecode, and requires all named tests to start and pass. Its watchdog is invoked directly in the coordinator process. Do not wrap this script in another session-owning watchdog; obtain serial build ownership first. CI includes these commands and now places the ordinary core suite under the existing watchdog as well. Hosted CI execution is not claimed.

Raw driver evidence remains ignored under `.local/search-parent-driver-task3/`; runner proof is under `.local/search-parent-driver-runner-candidate/repository/.local/search-parent-driver-integration/run.13ysm8ro/`; integrated evidence is under `.local/driver-integrated-20260930/`.

Preserved unsuccessful setup attempts include an impossible write-count gate, an expect-gate observer that captured handshake eligibility, and a test-only variable compilation error. A terminal-exhaustion probe passed because terminal coordination already resumed cleanup; it is explicitly a preservation control, not RED evidence. The distinct partial-response test reproduced the stranded state. Runner development also retained failures for missing instrumentation, stale bytecode execution and incomplete evidence acceptance. No failing check was disabled.

These are component and ownership checks with synthetic connections/accumulators. They do not measure allocator capacity, RSS, UI responsiveness, a real search helper, hard regex containment or packaged editor search. Experimental A/B/C builders and an independent oracle have separate private small-test evidence; sink selection, real two-process allocation measurements, helper assembly and application routing remain outstanding.

## Nonterminal admission settlement — 2026-10-05

Implemented and independently reviewed: a bounded latest-handle query observes whether request ownership has settled without shutting down a healthy reusable child. It checks handle identity and session epoch around the lifecycle control-lane observation, and refuses readiness while a receipt, source scope, codec work, reap or channel close remains owned. Observation introduces no signal, poll, close or timer operation. Launcher pre-adoption quarantine is outside this receipt.

Final matching frozen driver tests pass54/0 (33 ordinary and21 instrumented); lifecycle passes57/0; runner contracts pass23/0. Separate held-reap and held-close cases resume admission after exact cleanup without terminal shutdown. Existing byte-retirement/read/codec gates now assert settlement. A suspended observation cannot certify a newer submission or retired session. Removing only the post-observation handle check produces one explicit stale-observation failure in54 tests, with no timeout. Compiling behavioral RED was driver50 tests/11 assertions and lifecycle4/4.

Root independently reran evidence verification for all three final source inventories, transformation relationships and strict owned-watchdog receipts. Driver manifest: `8eedae82486ecdbf1aad64992f42c35b75065263385e9a45800c7c962c5b1994` (80 entries); lifecycle: `5bbce5ca8df93ab312c17504fcce56cde25083904609ceffb6f94ed532475c0f` (78 entries). The final ordinary suite includes a positive reader-entry wait added after initial review; the matching rerun passed. Independent review's two coverage requests were addressed before acceptance.

Reproduce with the commands above and `scripts/test-search-child-lifecycle.sh`. Each coordinator directly owns its watchdog; do not nest another. Private evidence remains under `.local/search-settlement-task1/`, `.local/search-parent-driver-integration/run.b9cxd2_f/` and `.local/search-child-integration/run.tah97f2w/`. These runs use injected children, not actual helper execution. Admission controller, policy defaults, allocation bounds, native routing and packaged acceptance remain outstanding.
