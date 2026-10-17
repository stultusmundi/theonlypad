# Transfer responder correction — 17 October 2026

Moving a document between windows could preserve its contents and registry ownership while leaving native keyboard focus on the previous editor. The unchanged-public-source comparison reproduces six failed transfer methods with 18 ordinary assertions; all original 68 native methods still pass. The failed support guards leave deeper refusal/retry/history checks unentered in that baseline.

The correction changes only `EditorWindowController.swift` and `EditorPaneHost.swift`. A transfer retains its original window, endpoint, registry, pane, storage and history identities through layout and native callouts. The host defers its incidental focus restoration during that scope. The controller makes one desired-editor responder request, independently checks its returned Bool and actual first responder, and restores its own temporary selectability change only while the original scope remains owned. Existing user edit admission and ordinary host focus policy remain unchanged. Completion is published after the original view and responder checks finish; existing owner rollback/retry remains responsible for recovery.

The maintained native approval runner now includes six transfer methods alongside all original coverage: 74 distinct methods/75 executions, zero failures or unexpected errors. It freezes current public sources, builds five modules in Swift 5 mode with warnings treated as errors, checks the actual compiler/object/link/bundle graph, and verifies full captures, strict owned-process receipts and empty application State. The same stored-Bool assertions precede support guards, preventing the earlier silent-success gap. Combined static control-flow review and zero-failure execution support the guarded native input/history/refusal/retirement/retry paths; the original output still does not provide an independent callback trace.

| Matching-source verification | Result |
| --- | --- |
| Maintained native approval suite | 74 distinct methods / 75 executions pass |
| Approval runner pure contracts | 48 pass |
| Shared native runner pure contracts | 53 pass |
| Full default Swift package | 1,228 pass, no skips |
| App/helper build with warnings as errors | Pass |
| Managed documents / projection / applied settings / transfer / admission | 73 / 20 / 24 / 12 / 4 pass |
| Matching-build close / factory / shared-pane controls | 106 / 198 / 1 pass |
| Strict recursive Swift formatting | Pass |

The full package and app were built from an isolated complete source layout with exactly the two productive overlays and six maintained-test/runner overlays. The same byte-identical files were then adopted. The close harness reused the verified matching Core debug build; this does not represent another cold-build result. Earlier cold-close inventory verification remains separate.

```sh
scripts/test-native-approval-regressions.sh
python3 -B -m unittest discover -s Tests/NativeApprovalIntegration -p 'test_*.py'
python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
python3 -B scripts/run-owned-search-tests.py --timeout 600 --output .local/transfer-focus-core -- scripts/swift.sh test --scratch-path .build/integrated
scripts/swift.sh build --scratch-path .build/application -Xswiftc -warnings-as-errors
scripts/test-managed-documents.sh
scripts/test-editor-transfer-projection.sh
scripts/test-document-applied-settings.sh
scripts/test-native-document-transfer.sh
scripts/test-native-close-model.sh .build/integrated/arm64-apple-macosx/debug
scripts/test-managed-admission.sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
```

The native coordinators already own their direct watchdogs; do not nest another session-owning watchdog around them. Root owns serial native execution, and all documents are synthetic.

A separate historical private candidate passes two focused native property-observation methods, plus its six transfer methods and positive control. It observes normal selectability restoration under the same original frame and genuine target closure followed by the retained transfer's exact retry. This is historical component evidence, not a current-public C3 test selection. Still-owned exceptional cleanup remains statically reviewed and unmeasured; post-close property writer attribution remains unknown. Neither result establishes universal KVO behavior.

The XML formatter's separate failed history requirements remain unresolved and its private implementation is not imported. This change adds no dependencies or assets. Current packaged desktop, physical keyboard/IME, VoiceOver, Intel/oldest-system and performance acceptance remain outstanding; the local distribution now contains reviewed source a4202be and passes signature, archive and SBOM checks, without a new desktop run. No release was published.
