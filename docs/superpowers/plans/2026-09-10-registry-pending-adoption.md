# Registry pending adoption execution plan

Scope: native view-free registry prerequisite only. No NativeIntake/AppDelegate registration, checkpoint switching or process adoption task is wired by this slice.

Reviewed contract: [registry-pending-adoption](../specs/registry-pending-adoption.md).

1. **Complete:** compile-only lease/readiness API plus behavioral red: 39 tests, 9 adoption failures; all 30 existing registration/close tests passed. Earlier test callback compile failure retained separately.
2. **Implemented/tested:** implement atomic pending insertion, strong ownership, exact failure/retry/activation, callback fences and group/publication-ready capture guards. Active status records readiness only; model/actor owns current recovery epoch.
3. **Implemented/tested:** expose the actual actor's existing immutable identity with one internal nonisolated declaration; prove actual adoption receipt matches it in a real temporary-store test. No dummy adoption in production setup.
4. **Complete, independent source review clear:** 41/0 in the combined runner; original runner30/0. Strict formatter and shell syntax passed. No material review findings remained; root integration verification is separate.
5. **Deferred:** NativeIntake process task retains pause/model/reservation and any returned receipt across awaits; actual application wiring and Retry UI follow separately. No generic post-registration unregister.

Retained command: `bash scripts/test-document-adoption.sh`. It snapshots actual core/registry/actor sources and all registry tests into a unique private directory, Swift 5/macOS 14, with a 180-second owned child watchdog. No AppKit activation or events.

Private evidence: red `run.VFyHj4jz`, first green `run.8IFp7P6E`, final41 `run.vi4sjnh9` under `.local/document-adoption-tests`; original runner30 `run.VRK6JSCk` under `.local/application-documents-tests`. No native intake activation or GUI was performed.
