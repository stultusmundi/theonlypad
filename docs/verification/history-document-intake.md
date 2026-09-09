# History intake verification

Implemented process intake provenance; native menu/application activation is not claimed.

- Setup attempt: isolated build denied filesystem access in its scratch output; no behavioral conclusion. Preserved separately.
- Compiled behavioral red: 20 tests, 5 failures. New history cases detected missing consumption, stale-source admission and replacement-identity admission. Existing 16 tests remained.
- Initial green: 20 tests, zero failures.
- Expanded final green: 23 tests, zero failures; XCTest execution 0.033 seconds (suite aggregate 0.040 seconds). Command: `scripts/test-application-document-intake.sh` in an environment permitting isolated Swift build and synthetic file operations.
- Strict Swift formatting and `git diff --check`: passed.

The final suite retains all original intake tests plus real registry/recovery actor close-to-history and replacement-adoption workflows. New cases cover exact consumption, pre-factory stale source and wrong replacement refusal, failed installation preserving history, projection retry after one consumption, eviction refusal, fresh aggregate capacity at 128 unresolved documents, and activation-notification source mutation retaining history and the active replacement without projection.

Private unique run identifiers: red `run.yBtz94UF`, initial green `run.MY9oE36v`, expanded green `run.snNsaLRX`. Logs and synthetic state remain ignored. Source review by the root agent found no material issue; independent root execution passed all 23 tests in 0.038 seconds (`.local/history-intake-root.log`).

Limits: synthetic model handles, real actor/store/registry APIs, no native window or physical input. The tests do not prove application menu routing, exact native seed capture or GUI behavior. Missing/evicted history and mutated source are refused; there is no fallback to an unrelated history item and no unsafe unregister after actor adoption.
