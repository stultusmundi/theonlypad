# Dirty-cache regression retention

Scope: retain native semantic fixtures for the dirty-state optimization without changing production controller or integration scripts in this task. Performance measurements remain separate in `docs/verification/native-editor-performance.md`.

## Planned interface and coverage

The controller exposes read-only `currentDocumentIsDirty`, evaluating the real document getter. This is necessary to query an unfinished storage batch or provisional marked text without fabricating textDidChange notifications or refreshing presentation. The root agent added the accessor alongside the reviewed optimization; the harness has no writable test hooks.

`Tests/NativeIntegration/DirtyStateHarness.swift` uses real controller open/save actions, native NSTextView edits, and encoding-sheet actions. Its assertions cover:

- Successful open/save baseline changes and restoration of exact saved text.
- Direct `.string` and NSTextStorage replacement, without manual textDidChange callbacks.
- Normalization-only edits, including equal-length canonically equivalent combining-mark order.
- Dirty reads before endEditing, including restoration inside the same batch.
- Attribute-only changes, native grouped undo/redo, and programmatic marked-text commit/restoration.
- Encoding-only and BOM-only changes, their undo, and undo after saving new metadata.

There are no performance acceptance assertions. The ten-second asynchronous-operation deadline only detects a stalled harness; the measured benchmark remains separate. Fixtures and recovery state use a unique synthetic temporary directory, with cleanup on normal completion. No user documents, private paths, or raw UI logs are tracked.

## Implemented and tested

The retained harness passed in a supervised 30-second child against the isolated dirty-cache candidate plus the accessor. It exercised actual native encoding sheets and file persistence. An initial sandboxed invocation failed native XPC interaction; rerunning the same binary with native UI permissions completed with exit zero and all semantic assertions passing. This is not physical IME, keyboard, or accessibility validation.

At handoff, root had applied the candidate hunk/accessor to production after the bookmark fix. The harness run above used the isolated copy; current production's SessionStore/SessionRestoration had subsequently changed, so current combined integration validation remained with root. Do not substitute the old full controller copy for newer production edits.

## Script inclusion proposal

After `native_sources` is populated in `scripts/test-native-integration.sh`, add the following, using its existing build path/module cache. The script was not edited by this task.

```sh
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/DirtyStateHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/dirty-state-test
.local/native-integration/dirty-state-test
```

Root should run this against the combined current source before recording production regression success. Keep the performance findings, including costly same-length cache misses and long lines, visible until separately addressed and remeasured.
