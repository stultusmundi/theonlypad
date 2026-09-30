# Fixed worker resolver verification

Date: 2026-09-30. Component evidence only; production search still does not use a helper.

`Sources/SearchExecution/SearchWorkerBundleResolver.swift` provides structural lookup at `Contents/Helpers/PadSearchWorker` and a separate launch-lane filesystem check. Lookup accepts explicit local absolute file URLs and lexically normalizes dot components. It rejects relative URLs, remote authorities, query/fragment data and embedded NUL. There is no PATH, working-directory or development-build fallback.

Validation checks the final directory entry with `lstat`, regular-file/execute bits and `access(X_OK)`, preserving filesystem errno. It does not establish ancestor trust, race-free identity, Mach-O validity or code-signature authenticity. Default Darwin launcher forwarding is still a reviewed proposal, not adopted behavior.

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
