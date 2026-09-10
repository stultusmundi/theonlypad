# Transfer and paired publisher interaction

Implemented tests only; no production behavior changed. Run `scripts/test-application-document-transfer-publisher.sh`.

Two synthetic Foundation tests use the actual ApplicationDocumentTransfer, ApplicationDocuments, SessionCheckpointCoordinator, RecoveryCoordinator, SessionStore and RecoveryStore. Native projection ports are semantic no-ops; these tests do not establish native layout, monitor transfer, GUI, or process-activation acceptance.

- Before capture: hold the actual prepareCapture callback, reserve transfer and acquire its real scheduler pause, assert no native transfer capture or placement change, then release preparation. Registry preflight refuses while reserved; scheduler drains without waiting on the transfer. The transfer completes and a real final paired publication succeeds.
- After capture: hold the actual commit callback after it received old-placement metadata and an authorized recovery item. Transfer waits on the scheduler pause drain. Release commit, verify actual old-placement SessionStore publication, then complete the move and publish again. Fresh store readers see one document UUID in the target, preserved pin and exact normalization-sensitive Unicode/CRLF recovery text. The registry retains the same handle and recovery authority.

The runner snapshots production sources and hashes into an ignored private package and uses a 180-second owned-child watchdog. Private initial `transfer-publisher-first.log` contains a test fixture compile error (omitted RecoverySnapshot encoding/BOM arguments), not a behavioral red. Corrected `transfer-publisher-green.log` passed two tests with zero failures in 0.019 seconds. No product defect was observed and no invented red is claimed. The following review refinement addresses test lifetime only.

Final formatted run `transfer-publisher-final.log`: two tests passed, zero failures in 0.018 seconds. Strict formatter lint, shell syntax and diff checks passed. Independent review found the publication assertions sound and identified a fixture callback retention cycle. All runs used private synthetic documents and no visible native windows.

Fixture lifetime regression `transfer-publisher-lifetime-red.log` reproduced two weak-release assertion failures after explicit transfer/scheduler drains. Fixture-owned callbacks now borrow the fixture with unowned captures; every success and error path drains owned tasks before releasing it. `transfer-publisher-lifetime-green.log` passed both original publication cases and weak-release assertions (two tests, zero failures, 0.019 seconds), with no compiler warnings. Strict formatter lint, shell syntax and scoped diff checks passed. No production code changed.

Independent review cleared the paired-publication evidence. The fixture lifetime correction was then reviewed against explicit success/error task drains and weak-release assertions; no remaining finding was identified. Native composition remains outside this test scope.
