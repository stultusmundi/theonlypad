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
