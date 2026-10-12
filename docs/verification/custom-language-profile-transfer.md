# Standalone language profile file transfer

Status: Core component implemented and tested. Native manager and application activation remain outstanding.

`LanguageProfileTransfer` imports a strict standalone definition through the existing materialization/file-probe policy. It checks observed metadata against the 65,536-byte limit before the matching payload read. The read revalidates file and parent identities. The existing codec preserves stable UUIDs and raw UTF-16 content and rejects unsupported versions, unknown/duplicate fields and invalid definitions.

Export uses the actual atomic create-only file operation. Existing destinations, symlinks and directories are refused. A competitor created after the final check cannot be overwritten. Cancellation before starting prevents the save; cancellation arriving during a completed save cannot replace its actual result. Genuine publication uncertainty retains the original opaque evidence and exact attempted bytes. Evidence validation is not publication acknowledgement or catalog mutation. The synchronous service must run away from the main/control queue.

The unadoptable forwarding baseline completed three tests with five ordinary failures and zero unexpected failures: oversized content was read before rejection, and late cancellation replaced both real publication success and real uncertainty. The accepting implementation passed those same three tests, then all fourteen unchanged tests. The returned uncertainty-capability branch genuinely reached independent atomic evidence validation. Earlier test-source compile-review holds were corrected before execution and remain in private evidence; they are not behavioral RED.

The formatted current application candidate passed 1,190 unique tests with zero failures, unexpected errors or skips, preserving all 1,176 existing methods. The app/helper dependency build and following incremental build passed with warnings treated as errors. Source inventories, compiler source/object pairing, 300 objects, 36 module companions, application/helper/test links, test bundle contents, complete captures and owned-process receipts were verified by Root and independently audited. No runtime dependency or third-party asset was added; this is original MIT code.

The fourteen cases cover independent import/export JSON and Unicode oracles; exact size boundaries; invalid/unsafe/materialization refusal; real inode and parent replacement, growth and shrink; cancellation before and during actual reading; exclusive export and a real competing writer; prepublication faults; joined late success; and genuine directory-sync uncertainty. Tests use private synthetic files, run I/O off the main thread, join workers and report cleanup failures.

Exact adopted source SHA256:

- `Sources/PadCore/LanguageProfileTransfer.swift`: `769869a53d3ca5fada21a8ae632bb525f13538f51c2030bf4022efb9b6ff3609`.
- `Tests/PadCoreTests/LanguageProfileTransferTests.swift`: `892e75364d15a1a497db307dbcca764d55a4e6fd16258e7eebbe2cec54c01d1c`.

This establishes standalone Core transfer behavior only. It does not establish the manager UI, application catalog-owner activation, native custom-language editing, modal lifetime/quit behavior, packaged desktop workflows or memory/performance acceptance. Distribution artifacts are unchanged.

Proven public-source focused command (14 tests, zero failures or warnings):

```sh
scripts/swift.sh test --scratch-path .build/profile-transfer-integration --filter LanguageProfileTransferTests -Xswiftc -warnings-as-errors
```

Broad suites containing adversarial regex use the checked-in owned-process watchdog directly. Raw synthetic evidence remains ignored locally. The focused contributor run is separate from the independently audited frozen full-app result.
