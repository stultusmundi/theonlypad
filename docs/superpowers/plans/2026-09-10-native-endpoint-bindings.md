# Endpoint binding retention implementation

Root reviewed the bounded design before implementation; routine approvals follow BUILD_PROMPT. Own only the endpoint table, dedicated harness/runner and these documents.

1. Compile an inert table against actual EditorDocument, monitor bridge and service; record valid detachment behavioral failure.
2. Retain weak model/exact bridge/receipt with 448-record ceiling, idempotent detach, failure retention, transition fencing and explicit blocked reconciliation.
3. Defer rendering until successful record removal; validate pure context before/after callbacks without retaining entry cycles.
4. Exercise actual bridge failure/retry, capacity, callback reentry, baseline continuity and weak model/bridge release. Preserve the later-baseline regression before applying the transition-only fence.
5. Format and run the dedicated frozen-source harness; independent root review precedes process integration.

Steps 1–4 implemented and tested; final source review and downstream process wiring remain separate. No controller/model/bridge changes belong to this slice.
