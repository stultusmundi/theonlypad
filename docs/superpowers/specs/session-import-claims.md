# Unresolved session import claims

Reviewed narrow prerequisite for registry integration. An opaque SessionImportClaim proves that an exact unresolved document/window record belonged to this SessionCoordinator at a particular capacity revision. It is validation, not a reservation or authorization to bypass ordinary registry identity checks.

`claimImport(_:)` and `validateImport(_:)` require completed, unblocked restoration, no pending removals, exact coordinator/revision and current semantic entry. Semantic equality includes metadata and hasRecovery, with literal UTF-8 source-path comparison (nil differs from a path); mutable error prose does not affect provenance. Current public post-startup APIs cannot mutate unresolved semantic metadata in place: membership changes rotate capacityRevision and prevent membership ABA. Future semantic update APIs must rotate that authority too; current-value equality alone would not detect semantic A→B→A.

`resolveImport(_:)` revalidates and clears recoveryByID and recoveryIDs ownership before assigning the unresolved array and triggering its callbacks. It does not delete or rewrite disk recovery. The removed entry and changed revision reject replay. Foreign/stale claims refuse without mutation. The application bridge must validate around native callbacks and retain an installed model for reconciliation if final resolution refuses.

Legacy resolved(entry) remains available until the actual application migration. This primitive does not activate registry ownership, change current UI flows or reserve capacity.

## Recovery-only preservation path

A separate `SessionRecoveryImportClaim` supplies the exact immutable retained recovery snapshot after restoration completes. It checks the same owner/revision/entry provenance and pending-cleanup exclusion, but permits recovering validated content while `preservationError` continues to block every session capture/write and all ordinary import claims. It cannot authorize an arbitrary file or clear preservation errors. Resolution clears unresolved recovery ownership before callbacks without deleting disk data. Native callers must create a URL-less scratch document from this snapshot, including when its originalPath is populated. Native activation remains unimplemented.
