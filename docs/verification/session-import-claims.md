# Session import claim verification

SessionCoordinator now issues opaque claims for exact unresolved records. Claims bind the coordinator, membership revision, window, document metadata, recovery presence and literal UTF-8 source path. Error prose may change without invalidating a claim. Resolution transfers in-memory recovery ownership before callbacks and does not remove recovery files.

The retained runner `scripts/test-session-import-claims.sh` passed nine XCTest cases on ARM64 macOS 26.6.2 with Swift 6.3.3 (Swift 5 mode). Final run took 0.008 seconds of test execution; raw output is ignored at `.local/session-import-claims-final.log`. Coverage includes foreign/replayed claims, stale membership, metadata/path differences, startup and preservation refusal, pending cleanup, callback reentry and actual temporary recovery-file preservation. The corrected behavioral red run had eight failures across nine tests; earlier fixture compilation failures are retained separately and are not behavioral red evidence.

Compatibility: `scripts/test-session-capacity.sh` passed seven tests and `scripts/test-session-presentation-flow.sh` passed nine tests. Scoped formatting and shell syntax checks passed. Independent review found no blocking issue.

This is provenance, not a reservation. Native import code must revalidate after callbacks and retain a model if subsequent reconciliation is required. The existing native restoration callback has not migrated to this API. No native ownership or packaged desktop acceptance is claimed here.

## Recovery-only extension

The expanded runner passed 11 tests in 0.011 seconds (`.local/recovery-import-green.log`). Its compiled red had three failures across 11 tests; earlier sandbox I/O and callback fixture compilation failures are retained separately. Added tests use actual corrupt session bytes and a recovery store to prove exact Unicode/encoding/BOM transfer, continued refusal of session capture/persist, retained recovery disk data, and foreign/stale/missing/pending-cleanup refusal. Independent review found no material issue. Native URL-less scratch binding remains an integration obligation, not a claim made by these tests.
