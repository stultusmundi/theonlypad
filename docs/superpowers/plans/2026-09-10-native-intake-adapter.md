# Native intake adapter plan

1. Implement the real native factory/read-state/authority adapter over the existing process intake. Implemented.
2. Retain one seed/model/task across endpoint loss and explicit same-assignment reconciliation. Implemented; original model and actor authority preserved by tests.
3. Revalidate callback boundaries and forward explicit placement. Implemented and independently reviewed.
4. Run retained full-source integration runner, then commit together with required routing boundary. Completed: six tests pass in the frozen full-source integration.
5. Integrate process endpoint table, monitor receipts, startup claims, close/reopen and AppDelegate lifecycle. Outstanding; no activation claim.

Command: `scripts/test-native-document-intake.sh`. Hidden native models and real actor/store/publisher; separate real-controller recreation/desktop acceptance remains required.
