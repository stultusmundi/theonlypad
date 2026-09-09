# Real checkpoint/edit smoke and repetition outcomes

This investigation changed no production checkpoint code. Copied source hashes verified against production before compile; only copied bridge/recovery tracing differs. Additive unrelated decoder source arrived later but is not used by this frozen workload. No three-pair performance success claimed.

## Preserved chronology

1. Initial compile passed. run.aisgzono writer performed eight validated edits but dirty checkpoint acknowledgement failed; restore did not run. Diagnostic JSON files contaminated the recovery directory and violated its0600-file validation. Source investigation identified the probe error. Original fixture retained, no quota or production guard changed.
2. Moved ALL evidence/markers to sibling evidence/ and added sanitized error classification; corrected compile passed. Fresh run.rs5cnnft writer exited0 in17.65s and separate restore exited0 in1.72s. Both actual store readback and fresh native SessionCoordinator restoration verified exact100MB text/selection; source file bytes unchanged. This is one successful smoke pair.
3. Authorized three unchanged-protocol repetitions run.binh_b7i: all three writers exited-5 before any edit record, elapsed5.78/5.87/5.77s. No restore child launched. Partial evidence contains no rows and last waiting-open stage. Duration matches the5s bounded activation settle before the initial strict native gate, but the optimized precondition emitted no exact gate reason. Therefore these are non-admitted setup/visibility failures, not measured edit failures or successful repetitions. No fourth attempt, no weaker admission or timing changes. All owned children reaped; slot released.

## Successful smoke only

Eight validated native undo/redo operations, all eight overlapped actual RecoveryStore.save intervals, not merely pending callbacks. Median26.61ms, maximum27.29ms. Largest recorded operation RSS1,261,109,248bytes; substantially above earlier noop-checkpoint workload, but this one-pair differing protocol is not a controlled memory delta.

Five real recovery saves took2150.79/2194.21/2182.98/2187.67/2178.44ms; six actual SessionStore saves took2.29ms initial then0.58–0.70ms. Capture intervals ranged0.014–0.112ms. Matching monotonic start/end checks passed; all six ack generations5/10/22/34/46/58 followed real SessionStore completion and matching commit return. Final acknowledged generation58 had exact on-disk recovery and metadata and passed separate-process native restoration as safe scratch.

Full100MB exact UTF16 oracle runs on MainActor outside edit timing, plus small diagnostic writes, contribute to inter-operation gaps and delayed completion/ack delivery. Do not attribute the~0.44–0.58s gaps after some session publications entirely to application code. Capture's short duration may defer copy costs through immutable/COW storage; no zero-copy proof. Edit timer includes subsequent native mutation/layout/display, but not physical key queuing during synchronous capture or oracle work.

Strict native geometry/state checks passed only the successful smoke: active/key/visible/nonminiaturized/occlusion/focused responder, stable native selection and full target viewport/screen geometry. No physical pixels, proof against partial occlusion, physical IME, cold launch, longline/bookmark/split or network-filesystem claim. Exactly100MB same-length operations avoid exceeding existing recovery quota; quotas unchanged.

## Next source-only retention work

Add explicit static-reason gate diagnostics before precondition termination and save initial admission state outside timers. Preserve unchanged strict gates. Retain portable harness/trace and guarded private-copy instrumentation, unique supervised state/evidence directories and source hashes. The source-only retention proposal is under review; no diagnostic rerun has occurred. Repetition failure remains unresolved until actual gate evidence exists.


## Retained tool diagnostic

`Tests/NativeIntegration/CheckpointPerformance/` and `scripts/benchmark-checkpoint-edits.sh` retain the protocol with private-source instrumentation, source/tool/linked-object hashes, unique state and evidence directories, and owned-child watchdogs. Shipping sources have no trace hooks. The wrapper performs a real debug build before compiling the optimized native harness; this mixed configuration is recorded rather than labeled a packaged Release measurement.

The retained default command was executed once (root session 90124). Debug build, guarded preparation and native compilation passed. The writer exited with signal 5 after 6.216 seconds; the wrapper correctly returned 1 and skipped restoration. Its explicit diagnostic was `VISIBILITY FAILURE: application inactive`, after bounded activation settling. There were no measured edits. Raw evidence is ignored under `.local/checkpoint-performance/run.zhgCGXW3/private-copy/runs/run.uykokx5f`. This identifies this run's gate; it does not prove the precise cause of the earlier opaque failures. No admission rule was weakened and no further attempt was made.
