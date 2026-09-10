# Monitor ownership transition verification

Status: dependency implemented and tested in hidden/semantic harnesses; independent source review clear. Complete native document transfer, production process-port wiring and F-02 desktop acceptance remain pending. The registry remains the ownership-rotation authority; these helpers do not move assignments or write recovery.

## Retained chronology

- `run.mQe7ZNgs`: compiled bridge seam failed the ownership transition assertion (`unavailable`). First implementation `run.5oj4uqeN` passed127deterministic,25real-service and26application-monitoring checks.
- `run.UwCVdwwX`: native binding-store seam compiled and failed reservation. `run.jCi3XeeW` passed actual-model transfer/rollback plus original binding cases.
- `run.AjIYYPoG`: exact pre-stage same-ownership cancellation failed before its implementation. Separate action-generation fencing then allowed cancellation without reviving old actions.
- `run.NNfkbptI`: expanded fixture incorrectly expected a capacity failure after Check Again had already cleared it. The corrected assertion compares the actual pre-transfer error value; this was a fixture expectation correction, not a product failure or weakened preservation requirement. Subsequent `run.ofeApWDo` passed140/29/26.
- `run.CQ1OHWJN`: resolving one deferred invalidation erased a newer reentrant request. Exact invalidation request UUID comparison fixed the actual failure; `run.0OC6xkjn` passed141/29/26.
- `run.9zeUy9GM`: process-style rollback after validation refused before suspension effects could not restore a pure reservation. Explicit same-ownership restoration now suspends those callbacks under a valid lease first; no assumption that the failed suspension completed.
- Final bridge `run.84DIrGis`:142deterministic bridge assertions,29real-service assertions,26application-monitoring checks; all pass. Only comment placement changed afterward to satisfy strict lint.
- Final native binding `run.Yon6rcuk`:36checks,zero failures. Original23binding checks remain. Strict Swift formatter lint and diff checks pass.

## What the tests establish

Actual retained service registration survives move and rollback with unchanged service epoch and retained parent continuity. A synthetic equal-byte replacement under a retargeted parent still yields parentChanged and no reload authority. There is no re-registration, baseline adoption or manufactured observation token in the ownership transition.

Controlled bridge cases separately establish old/pre-suspend and during-suspend queued callback rejection with unchanged application delivery generation, native endpoint action fencing across same-ownership cancellation, second ownership rotation after target attachment, preserved dismissed facets/manual notice/error values, cancellation of an in-flight manual request, exact invalidation-resolution reentry, and explicit terminal disposal.

Actual hidden model/store cases retain the identical bridge across two model ownership rotations; the store buffers rendering until receipt consumption, rejects ordinary detach during transfer, resumes ordinary endpoint lifecycle/future baseline adoption, refuses nested transfer callbacks, survives a new reservation from final rendering without old cleanup erasing it, and disposes the registration when its weak model is released.

The validation closures in these dependency harnesses are controlled seams, not production registry transfer authorization. Actual process integration must supply `validateTransferSnapshot(lease)` and preserve the same opaque receipt. Diagnostic phase reads alone grant no permission. No GUI window is shown or activated; no events are posted and no physical keyboard/IME or desktop transfer claim is made.

## Commands used

```sh
scripts/test-file-state-bridge.sh .build/native-ownership-integrated/arm64-apple-macosx/debug
scripts/test-native-endpoint-bindings.sh .build/native-ownership-integrated/arm64-apple-macosx/debug
```

These runs used previously frozen debug PadCore objects on the tested host. The runners also support an omitted build path to create their own debug core build; that fallback was not rerun for this change. Native model tests use Swift5; the standalone Foundation bridge harness retains its existing Swift6 configuration. Unique ignored run directories preserve failures and source evidence.

Independent review confirmed the scoped receipt, continuity, delivery and invalidation safeguards. Integration must reserve the bridge receipt inside process `suspendMonitor`, after the process has latched monitorSuspended and retained its native receipt. Native `capture` must remain side-effect free: reserving there could leak a blocked bridge when capture returns and subsequent validation refuses before cleanup is enabled.
