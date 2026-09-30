# Fixed worker resolver verification

Date: 2026-09-30. Component evidence only; production search still does not use a helper.

`Sources/SearchExecution/SearchWorkerBundleResolver.swift` provides structural lookup at `Contents/Helpers/PadSearchWorker` and a separate launch-lane filesystem check. Lookup accepts explicit local absolute file URLs and lexically normalizes dot components. It rejects relative URLs, remote authorities, query/fragment data and embedded NUL. There is no PATH, working-directory or development-build fallback.

Validation checks the final directory entry with `lstat`, regular-file/execute bits and `access(X_OK)`, preserving filesystem errno. It does not establish ancestor trust, race-free identity, Mach-O validity or code-signature authenticity. Default Darwin launcher forwarding is covered by the subsequent integration record below.

## Evidence

- Initial compiling contract RED:63 tests,21 failures; initial GREEN63/0.
- Independent review found relative URLs with an absolute base were being resolved before validation. Regression RED64/2; final64/0 after validating unresolved URL components.
- Final selection:12 resolver tests,1 retained preparation-queue/deadline collaboration test and51 lifecycle regressions. Synthetic temporary files include regular files, permissions, symlinks and an unopened FIFO. No child is launched.
- Root verified independent review, exact input inventories and process receipts, then adopted the three source/test files unchanged.
- Full frozen application suite:738 tests,0 failures. The application also builds. All681 frozen input hashes and complete owned-watchdog receipts were checked. Input-manifest SHA256: `d75503a9ea9170697ee9b033b10b521378aa8bee42fa2bce41e923ff7b08ca6d`.

Focused reproduction uses the established wrapper under the owned watchdog:

```sh
python3 scripts/run-owned-search-tests.py --timeout 180 \
  --output .local/resolver-verification \
  -- scripts/swift.sh test --scratch-path .build/search-worker-runtime-task1 \
  --filter 'SearchWorkerBundleResolverTests|SearchWorkerResolverLaneTests|SearchChildLifecycleTests'
```

Choose an unused output directory and obtain serial build ownership first. Raw candidate evidence is ignored under `.local/search-helper-packaging-candidate/`; integrated evidence is under `.local/resolver-integrated-20260930/`. The queue test injects launch operations and verifies validation follows admission/deadline arming on the actual retained preparation queue. It fails before descriptor allocation or spawn. It does not prove production forwarding, helper packaging, real protocol integration, memory bounds or desktop behavior.

## Default launcher integration

The subsequent reviewed change connects `DarwinLaunchOperations.validateExecutable` to the resolver. Absolute/NUL-free String validation happens before `URL(fileURLWithPath:)`, which otherwise normalizes relative strings. The launcher's earlier URL guard now inspects unresolved components and requires an explicit file scheme. Relative URLs with an attached absolute base are rejected before filesystem work; explicit absolute URLs with a base remain accepted. Filesystem errno and existing startup ordering are preserved.

The new tests against the unchanged launcher ran80 cases with5 explicit failed assertions. The initial fixed candidate passed80/0 but exposed two existing weak-local compiler warnings. Those preliminary results remain private with diagnostic acceptance marked false. Typed weak declarations followed by assignment preserve the weak-reference assertions without suppressing diagnostics. A focused final81/0 includes the changed channel-release check; a separate actual-child selection passed2/0. Formatting then required two line breaks in the added tests.

The final formatted live source passed the combined83-case selection with0 failures and no compiler warnings. It includes6 default resolver/filesystem tests,23 injected launcher tests,51 lifecycle tests,1 weak channel-release control and2 actual child tests. Actual fixtures verify bootstrap/descriptor state, exact64-byte echo and exit0 cleanup, plus exit17 and the sole lifecycle reaper. No search helper or GUI was launched.

```sh
scripts/test-search-child-lifecycle.sh --filter 'SearchChildLauncherResolverTests|SearchChildLauncherStateTests|SearchChildLifecycleTests|SearchChildChannelStateTests/testFacadeLossRetainsCloseAndStaleHandlersCannotUseConsumedFD|SearchChildLauncherTests'
```

The established coordinator directly owns each watchdog stage; do not wrap it in another session-owning watchdog. Final evidence: ignored `.local/search-child-integration/run.uc8xvi4c/`. Root verified all77 frozen sources against live files, complete toolchain/build/binpath/test receipts, both fixture bindings and the four retained test-bundle files. Source-manifest SHA256: `709d00ce79ae66faa7db54ec7e290e0b557790389beb3fcd02a3b7496c049a26`.

This supersedes the earlier forwarding limitation above. Fixed app-bundle lookup is not yet used by a shipped helper, and production editor search remains in process. Helper packaging, actual search-wire integration, allocation selection, hard regex containment and desktop search acceptance remain outstanding.
