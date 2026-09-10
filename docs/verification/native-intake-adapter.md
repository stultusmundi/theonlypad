# Native intake adapter verification

Initial compiled red: three tests, two failures; initial green: three tests, zero failures in 0.123 seconds. An earlier fixture compile failure used an unsupported SessionTab argument and omitted throwing factory calls; it is retained separately, not behavioral evidence.

Independent source review identified post-projection endpoint loss and reentrant endpoint reconciliation. Five-test regression run failed twice, then passed all five in 0.124 seconds after callback fences. Expanded six-test run passed in 0.128 seconds, including explicit tab insertion order. Logs: `.local/native-intake-adapter-compiled-red.log`, `.local/native-intake-adapter-green.log`, `.local/native-intake-callback-red.log`, `.local/native-intake-callback-green.log`, `.local/native-intake-expanded-green.log`. Each run retains source hashes. Initial snapshots used committed `2fd79bc` plus root adapter/tests; expanded snapshot used `51ce7d3` plus adapter/tests/routing boundary.

The tests instantiate actual EditorDocument models, process intake, registry, RecoveryCoordinator and paired publisher with synthetic files. They verify exact text/encoding and fresh recovery-store reads, same-model/same-authority retry, lost-endpoint retention, reentry refusal and explicit placement. Endpoint identity/projection callbacks are injected; no replacement controller or monitor is created. Final-ready acknowledgement is a fixture boundary, not a tested native quit freeze. No GUI is shown.

Independent final source review found no material issue in this scope. The full current-source runner and production process composition remain subsequent verification steps.

The full current-source runner subsequently passed six tests in 0.124 seconds against `.local/native-close-integrated`; the same snapshot built the app and passed 404 core and 21 controller tests. This includes the final status accessor and routing insertion-index boundary. See `native-close-adapters.md` for source provenance and compatibility evidence.
