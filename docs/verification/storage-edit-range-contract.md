# Native storage contract execution

Executed2026-09-09 on the current local macOS/AppKit runtime. No production changes or dirty candidate implementation. Commands: `bash .local/controller-latency-review/compile-contract.sh`, then `python3 .local/controller-latency-review/run-contract.py` with authorized native host execution. Wrapper owns exactly one child, waits60seconds, kills/reaps only that child on timeout. Final child exit0 after0.544seconds; no timeout or active child remains.

Final probe SHA256:2e295c348ad2444df8335001228c32ed3a3c5d5062b472e65534c58af9343cf2.

All assertions passed:31 processed character edits,72 dirty queries with pending character mask and37 stable queries. For each character notification, previous length + reported delta equalled current length. Prefix before reported location was unchanged. For aggregate delta zero, both prefix and suffix outside reported range were exact UTF16-equal. Every queried existing-production dirty result equalled independent full UTF16+metadata oracle.

Observed examples (location:length in current storage): clean EOF replacement14:1 delta0; distant same-length batch1:5 delta0 in both operation orders; insertion/deletion net-zero batches1:3 and1:4; EOF insertion15:1 delta+1 and native undo15:0 delta-1; empty deletion0:0 delta-2; willProcess delegate additional character mutation widened final aggregate range to0:5 delta0. Mixed character/attribute batch conservatively widened to entire15units.

Programmatic marked-text commit produced two character notifications (0:0 delta-2, then0:13 delta+2), both passing prefix/length assertions. Do not treat one marked API call as one mutation or assume all intermediate lengths align. This is not physical IME validation.

Observers were registered before/after document construction; those names describe registration order ONLY. Foundation callback delivery order was not asserted or promised. Pending oracle queries exercised conservative cache behavior but do not establish that production's normal onCharactersChanged callback queries dirty, or how often a future poison path will run.

Preserved failures: first compile used UIKit-style nested NSTextStorage.EditActions instead of this AppKit SDK's NSTextStorageEditActions. First runtime passed through native undo/redo, then raised NSUndoManager exception because fixture left groupsByEvent=false and began marked text without an explicit group. Corrected fixture by grouping its marked operations; no production behavior or contract assertion was weakened. Logs: contract-build-first.log, contract-run-first-undo-group-error.log, final contract-build.log and contract-run.log.

Limits: fixed adversarial sequences only; no seeded property run, dirty candidate proof transition test, actual controller100MB attribution or performance acceptance yet. Aggregate observations support the proposed conservative range/suffix contract on this runtime; they do not prove all possible edit histories or minimum-supported macOS behavior. Next implementation remains subject to root design approval and unchanged actual-controller work-bound red.
