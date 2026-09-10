# Native close adapter plan

1. Reproduce registry lease/global gate failures in actual hidden controls. Completed.
2. Implement identity/user separation and controller mutation admission, using verified view/undo hooks. Completed.
3. Add exact close confirmation, scalar resource/drain checks and history-preserving projection. Completed.
4. Resolve independent callback findings: editing under projection, stale empty-close permit, hidden registry history availability and unrelated focus changes. Completed with behavioral regression evidence.
5. Run one frozen full-app/core/controller/intake snapshot and legacy compatibility. Completed; see verification record.
6. Compose process endpoint/detachment storage, async reopen, actual close receipts and AppDelegate startup/quit. Outstanding.
7. Exercise actual desktop and packaged workflows. Blocked by console access, not replaced by hidden tests.

Commands: `scripts/test-editor-application-routing.sh`, `scripts/test-native-document-intake.sh`, `scripts/test-native-monitor-lifecycle.sh <verified-debug-build>`, `scripts/swift.sh build`, `scripts/swift.sh test`. Use isolated scratch paths and private state; preserve source provenance.
