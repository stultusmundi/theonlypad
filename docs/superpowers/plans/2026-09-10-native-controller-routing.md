# Native controller routing plan

1. Add required application routing boundary and empty application initializer. Implemented.
2. Route prepared creation paths through actual process intake; preserve legacy initializer. Implemented for scratch/open/backup/duplicate/restored/copy.
3. Project exact registry models and capture managed checkpoints; preserve no-op state and process observers. Implemented.
4. Exercise real hidden controller/registry/actor/publisher with synthetic fixtures. Eight tests passed independently; see verification record. Initial two-test behavioral red had eight failures.
5. Complete native close/user-admission adapters, endpoint and monitor rebinding, conditional selection and AppDelegate startup/quit integration. Outstanding; activation remains disabled.
6. Run real desktop and packaged workflows when console access is available. Blocked by GUI access; hidden tests are not desktop acceptance.

Commands: `scripts/test-editor-application-routing.sh`; `scripts/test-disk-action-coordinator.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`; `scripts/test-native-monitor-lifecycle.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`. Each retains an isolated private source/evidence snapshot. The GUI-bearing native integration runner dependency list was updated but was not executed.
