# Unresolved session panel

Status: planned. Parent owns application integration.

The native panel retains immutable window/tab metadata plus an actionable error per entry. Retry and Locate read through asynchronous injected callbacks. A synchronous result callback runs only after generation and closed-state checks; callback failure retains the entry. Remove requires a native confirmation sheet and a successful removal callback. No errors become editor text. A single operation disables reentrant actions; replacement entry lists and window closure invalidate pending results.

TDD: retain an AppKit harness exercising Retry failure/success, Locate cancellation and read failure, removal cancellation/confirmation, reentrant action suppression, and late completion after close or replacement. Use synthetic metadata and decoded text. Async callbacks must read/validate only; integration owns persistent unresolved metadata and document import. Physical keyboard and packaged restoration remain separate acceptance work.

Implemented: native panel and callbacks, stable original metadata on failure, selection preserved after Retry failure, native Locate and removal confirmation sheets, explicit main-actor commit boundary, disabled controls during operations, generation invalidation on replacement and close. `SessionResolvedFile` contains URL, original bytes and decoded text for the coordinator's safe import. Read callbacks must move blocking file I/O off-main and must not import documents themselves.

Tested: expected missing-type compile failure before implementation; first native run exposed Retry selection loss, fixed and retained. Final formatted source compiled and harness passed with Retry failure/success; Locate cancellation, read failure and success; import callback failure; Remove cancellation, callback failure and success; reentrant Retry suppression; and late completion after list replacement or close. Synthetic callbacks use real DocumentCodec decoding. Actual sheet actions are exercised; successful Locate uses the same controller action with a supplied synthetic URL. No original files are written.

Verified command (after existing PadCore debug build):

```sh
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library -I .build/arm64-apple-macosx/debug/Modules Sources/TheOnlyPad/SessionRestorationController.swift Tests/NativeIntegration/SessionRestorationHarness.swift .build/arm64-apple-macosx/debug/PadCore.build/*.o -o .local/session-panel/test
.local/session-panel/test
```

Application wiring, metadata persistence, real file read validation, multi-window restoration and packaged restart remain parent integration work. This panel test is not complete session restoration acceptance.

Integration update: SessionResolvedFile now permits nil URL/originalBytes for recovery scratch content and carries off-main resolved view state plus UTF-16 count. Unresolved entries disclose whether a recovery snapshot exists. Locate requires an additional explicit warning before replacing recovered unsaved text. Remove callbacks are async; confirmed deletion owns its authoritative commit after panel closure, while late UI delivery remains suppressed. Removal warning explicitly discloses discarding unsaved recovery text. Updated native harness passed these confirmation and late-removal paths.
