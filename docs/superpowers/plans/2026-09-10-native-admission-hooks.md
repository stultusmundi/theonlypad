# Native admission implementation plan

1. Agree separate selection and undo predicates and a throws owner installation scope with the controller owner. Completed before implementation.
2. Add compiling inactive seams and hidden real NSTextView/UndoManager tests. Observe direct setter/undo rejection failures before enforcing guards.
3. Enforce selection before/after callbacks; use an actual guarded manager without history cleanup. Verify compiler-supported isolation and native selection, text/bookmark undo and redo behavior.
4. Reproduce in-flight undo/redo close-state admission and add the model busy guard. Preserve existing close state and repair checks.
5. Run focused tests plus unchanged close-model/factory/shared-ownership compatibility. Independently review before controller activation; do not claim keyboard/IME/desktop tests from this hidden harness.

Commands: `scripts/test-native-admission-hooks.sh <existing-debug-build-path>` and `scripts/test-native-close-model.sh <existing-debug-build-path>`. Both freeze sources and hash linked core inputs; all generated binaries/logs remain private. No windows are shown and no input events are posted.
