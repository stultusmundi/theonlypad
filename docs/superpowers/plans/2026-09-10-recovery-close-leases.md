# Recovery close lease implementation plan

- [x] Add immutable authority/lease/receipt/error values and compiled red tests.
- [x] Implement and test checked private deletion, exact identity/parent validation, fault evidence and FD cleanup in RecoveryStore; preserve legacy API behavior.
- [x] Add actor adoption, capture-time admission, non-destructive prepare, exact finalize/retire, and fresh atomic repair. Preserve legacy unmanaged behavior; reject managed legacy batches before mutations.
- [x] Test old and high-revision captures, mixed batch/checkpoint preflight, wrong leases, failure/uncertainty/readback, exact bytes and quota reinventory in a frozen Foundation projection.
- [ ] Independent review and repeatable retained evidence.
- [ ] Separate native/checkpoint-owner migration and actual admission/cancellation tests. Not implemented by this slice.

No stronger restart/discard contract than existing paired session checkpoints. No persistent journal or retirement cap. No passing core/actor test is native lifecycle acceptance.

Status: actor/store/value slice implemented, independently reviewed and tested (25 scoped tests; full core 404; existing native/session compatibility passed after a separately diagnosed harness wait correction). Native publisher and close activation remain outstanding. See docs/verification/recovery-close-leases.md.
