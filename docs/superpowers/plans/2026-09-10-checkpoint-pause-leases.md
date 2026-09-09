# Checkpoint pause lease plan

1. Add deterministic regression coverage for synchronous acquisition, overlapping tokens, preparation/publication drain, cancellation, invalid tokens, legacy isolation and final overlap.
2. Implement token ownership/drain state and effective pause without changing the single publisher or existing checkpoint receipt checks.
3. Run new tests and existing scheduler harness, obtain independent review, resolve findings.
4. Integrate into the process-owned close adapter only after recovery authority and native admission designs are verified. Native integration is not part of this primitive's completion claim.

Status: steps 1–3 implemented, tested and independently reviewed. Eight tests and the existing scheduler harness passed; see docs/verification/checkpoint-pause-leases.md. Step 4 remains outstanding.
