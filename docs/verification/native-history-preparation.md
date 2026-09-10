# Native history preparation

The helper captures immutable source values under an exact registry history claim, validates the
reopened seed on a detached worker, and validates the claim again before returning. It preserves
pin metadata and binds a fresh replacement document ID; it does not consume history or create
an intake ID.

Seven hidden checks passed: empty history refusal, fresh correlated identity, pinned state,
Unicode saved content, exact original bytes/URL/BOM, nonconsumption, and changed-source refusal.
The initial behavior seam failed before implementation. No deterministic during-worker
invalidation test is claimed; the post-await guard uses the independently tested registry claim
validation. Full native owner Close/Reopen integration additionally passed.
