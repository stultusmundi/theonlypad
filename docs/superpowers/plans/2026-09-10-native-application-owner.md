# Native process owner integration

Design: compose existing tested ownership components rather than introducing another writer or document store.

1. Implement actual registry, endpoints, intake, close and paired publisher composition. Implemented.
2. Restore prepared seeds with unresolved provenance retained until adoption; empty startup uses the same intake. Implemented; hidden startup and real-file tests pass.
3. Reopen clean history with detached preparation and new model/recovery identity. Implemented; native command integration passes.
4. Fence concurrent startup retries and preserve retained operations through endpoint recreation. Implemented; concurrency regression passes; more failure-path tests remain.
5. Freeze actual native windows and commit one final paired checkpoint; preserve gates on veto. Implemented on tested success paths; complete fault/veto coverage outstanding.
6. Connect launch FIFO, asynchronous session-panel intake, and every AppDelegate window/quit route. Implemented; nine hidden AppDelegate tests pass.
7. Frozen integrated build/core404, combined native71, monitor compatibility and independent reviews pass. Public checks pass; scoped local integration commit follows.
8. Actual desktop and packaged validation. Blocked by console access.

Verification commands: `scripts/test-native-application-documents.sh`,
`scripts/test-native-application-close.sh`, `scripts/test-editor-application-routing.sh`,
`scripts/test-native-history-preparation.sh <verified-debug-build>` and the existing full build/core suites.
Raw evidence stays private; public records distinguish hidden native tests from desktop acceptance.
