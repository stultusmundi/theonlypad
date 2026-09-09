# Checkpoint pause leases

Reviewed architectural slice for recovery-safe close integration. Root and independent native integration review agree on an owner-bound token set within the existing SessionCheckpointCoordinator. No second writer or new durability contract.

`acquirePause()` synchronously prevents new captures and cancels a waiting debounce, returning an opaque token; it refuses while final publication is active. `drainPause(_:)` validates ownership before and after awaiting the existing worker and marks only that token drained. Cancellation never releases a token. `releasePause(_:)` requires an exact drained token, consumes it once and requests resumed work only when all leases and the independent legacy pause have cleared. Final publication refuses active leases. Existing pauseAndDrain/resumeAfterVeto maintain their separate latch and cannot release a close lease.

A token can be acquired before restoration starts. Starting restoration must respect effective pause. Publication already admitted may finish and acknowledge before drain returns; preparation already admitted must finish but may not capture after pause acquisition. No callback or suspension precedes acquisition. Foreign, duplicate and undrained tokens fail without mutation.

Native integration must never put managed closes into the legacy pending-close queue awaited by prepareCapture: doing so would make close wait for its own checkpoint drain. Preparation/capture instead refuse promptly while managed closes exist. This slice provides scheduler semantics only; actual registry, recovery, quit and native mutation integration remain separate work.

Verification uses deterministic suspended preparation/publication and explicit release controls against actual scheduler source, plus retained existing scheduler regression coverage. It does not exercise desktop behavior.
