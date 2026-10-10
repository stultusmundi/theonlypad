# Native regression runner verification

The transfer, projection and close-model runners now use one same-process instance of the accepted owned-process watchdog. Each stage freezes its inputs and validates complete wait, capture and process-group cleanup receipts. No nested session owner was added.

Compiler input trees have exact file and directory inventories, checked before and after every stage. Added Swift sources, versioned package manifests, objects/modules or symlinks refuse further execution. Direct native compiler arguments come from the manifest. Receipt fields require explicit keys and exact scalar types, including nullable singleton-query errors and capture counts.

Independent specification/code review approved both corrections. Final verification on the current ARM64 macOS development host:

| Control | Actual result |
|---|---|
| Pure coordinator contracts | 26 passed |
| Native document transfer | 12 passed |
| Native controller projection | 9 passed |
| Native close model | 106 checks passed |
| Document factory | 133 checks passed |
| Shared pane ownership | 1 complete scenario passed |

The new negative controls first produced16 failures across24 tests against the original implementation. They prove malformed receipts and unexpected inputs cannot advance to later stages. The final26-case suite expands alternate-manifest/module and zero-byte numeric-alias coverage.

A concurrent source edit was captured coherently in one full-build attempt and caused a Swift syntax failure. The coordinator stopped before native execution; that failed result is retained. A separate stable-source run subsequently passed all nine close stages, with complete receipts, source/core inventories and binary hashes independently checked. Its full-app build took10.685s; this is build evidence, not application performance.

Proven commands:

```sh
python3 -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
scripts/test-native-document-transfer.sh
scripts/test-editor-transfer-projection.sh
scripts/test-native-close-model.sh
```

The zero-argument close command builds its own frozen full application first. The optional existing-debug-build argument requires a caller-verified matching source build; copied object hashes alone cannot prove source equivalence. All state and raw evidence remain private, synthetic and ignored. These hidden native tests do not replace packaged desktop testing or establish the planned pane-restoration remedy.

## SearchExecution dependency repair, 2026-10-10

The shared coordinator and eleven standalone native runners now copy the actual SearchExecution sources and declare the module dependency required by the application sources. Local source checkpoints are `df22899` and `e1305be`. Original native clients and their access instrumentation remain unchanged.

The shared coordinator's 42 pure tests pass, including two additive cases that first failed against the missing dependency. Its existing native search-replacement selection passes 32 tests. The eleven standalone runners also pass:

| Proven command | Passed tests |
|---|---:|
| `scripts/test-managed-documents.sh` | 71 |
| `bash scripts/test-appdelegate-documents.sh` | 9 |
| `bash scripts/test-native-new-window-transfer.sh` | 44 |
| `bash scripts/test-native-document-intake.sh` | 6 |
| `bash scripts/test-native-application-document-transfer.sh` | 12 |
| `bash scripts/test-native-application-open.sh` | 10 |
| `bash scripts/test-document-move-destination.sh` | 15 |
| `bash scripts/test-native-application-close.sh` | 5 |
| `bash scripts/test-editor-application-routing.sh` | 32 |
| `bash scripts/test-native-application-documents.sh` | 9 |
| `bash scripts/test-shortcut-application.sh` | 20 |

These eleven invocations executed 233 tests with no failures, unexpected failures, warnings or skips. The managed selection overlaps 71 standalone cases, so there are 162 distinct named tests. Independent review and Root verification checked frozen sources, actual compiler output maps, source/object/dependency/link bindings and exact test rosters. The host was ARM64 macOS 26.6.2 with Swift 6.3.3; the packages use Swift 5 language mode and a macOS 14 deployment target. This does not establish execution on macOS 14.

The managed runner and nine standalone runners retain their existing process ownership and narrow `exit: 0, timedOut: false` receipts. They do not provide the shared coordinator's strict cleanup evidence. The shortcut runner uses the unchanged direct owned-process watchdog and retains separate toolchain and test wait/capture receipts. Do not add a second session-owning watchdog around these commands.

This checkpoint verifies compatibility of the dependency repair. The new native search factory's separate failing diagnostics, production supervised-search routing, current packaged desktop acceptance, and memory/performance acceptance remain outstanding.
