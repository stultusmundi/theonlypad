# Owned search helper packaging — reviewed design

Status: planned; independently reviewed and approved after three acceptance corrections. No helper packaging implementation or verification yet. An executable implementation handoff follows the actual helper/runtime interface.

Source inspected: scripts/package.sh, scripts/check-package.py, scripts/sbom.py at78828ec. Current package builds only app product, strips its distribution copy, optionally ad-hoc signs outer bundle, archives exact files, and emits only app executable hash in metadata component. Archive equality is already enforced. No helper exists.

## Required future change

After actual PadSearchWorker target and launch contract are reviewed, build both explicit products with the same release configuration/toolchain and copy worker into Contents/Helpers/PadSearchWorker. Strip distribution copy before signing. Keep runtime lookup fixed to that bundle-relative path; development harness injects an explicit trusted URL. No PATH search or in-process fallback. Include helper as MIT application component in CycloneDX with unique bom-ref, version, executable SHA256 and dependency association; platform frameworks remain system-provided, not bundled MIT.

With --ad-hoc-sign, explicitly sign helper before outer app, then verify helper and outer app strictly. Do not use deep signing to conceal unspecified nested-code inventory. Deep verification can supplement explicit verification. Without signing flag preserve current unsigned development path; do not claim notarization. Exact archive inventory must include helper and signature resources; package checker requires expected helper path as regular non-symlink executable, verifies its SBOM digest and archive bytes, and rejects missing/duplicate helper component. Preserve app hash check.

## Acceptance tests to implement

Use synthetic temporary bundles/archives to prove missing helper, symlink helper, changed helper bytes, wrong helper SBOM hash, omitted archive helper, duplicate helper component and missing executable mode all fail. Successful tiny synthetic executable fixture may be used for inventory checks, but not as actual helper smoke proof. Preserve existing wrong app digest, unsafe archive path and private-path checks. Ensure errors print only safe relative fixture identifiers.

Actual release helper must complete bounded hello plus benign Unicode find/replace through exact packaged executable; validate exact ranges/output, EOF/reap and no extra children, under the lifecycle runner watchdog. This read-only process smoke does not require visible GUI and does not prove packaged editor integration. Once desktop unlock is granted, separately exercise packaged editor open/edit/search/replace/save/quit/reopen.

Keep promotion after all staged checks; existing rollback-aware three-artifact promoter remains adequate. Pin evidence to clean committed source and exact app/helper hashes. No remote publishing/signing credentials. Commands for new helper tests remain unproven until implementation.

## Dependencies and scope

Own scripts/package.sh, scripts/sbom.py, scripts/check-package.py and new focused packaging regression runner; helper target/runtime API owned by lifecycle implementation. Do not modify native routing. Read existing test conventions before choosing new test runner filenames. Retain current artifacts until replacement package verification passes.


## Independent review corrections

Before promotion, inspect both actual Mach-O executables and compare their architecture sets to the selected distribution architectures, and their encoded deployment minimum to Package.swift/Info.plist. Same build configuration alone is insufficient. Add incompatible-helper architecture and deployment-target refusal fixtures. Record inspection tools and actual output before accepting commands as proven; this check does not claim runtime testing on the minimum OS or Intel.

Validate ZIP helper entry Unix type/mode as a regular executable file, including explicit symlink refusal, independently of identical contents. Add byte-identical archive fixtures whose helper execution bits are removed or type changed. Extract the completed archive into a fresh relocated directory, verify signature/inventory there, and run the real fixed bundle resolver and lifecycle launcher with mandatory --generation <UUID> against the extracted helper. Use an isolated packaging worktree where the source build directory can be made unavailable reversibly during smoke; never rename the shared active build directory. No development resolver override may satisfy this acceptance. This proves relocated helper launch only, not a visible packaged editor workflow.

Canonical SBOM identity: use the packaged CFBundleIdentifier as application bom-ref and append ':search-worker' for the helper bom-ref. Require exactly one helper component at that reference, with property 'bundle-relative-path' exactly 'Contents/Helpers/PadSearchWorker', version exactly DevelopmentVersion, and SHA256 of final stripped/signed helper. The metadata application component carries its app bom-ref; a dependencies entry for that app reference must include the exact helper reference once. Require those associations in the checker. Tests cover wrong helper version/path/ref, duplicate component and missing/wrong dependency edge. Preserve current external-dependency inventory refusal. These metadata values are inventory correlation, not executable authentication or protocol compatibility versions.

## Packaging entry-point preflight

Later source inspection also found a separate `validate` function in `scripts/promote-package.py`: it checks the app digest and archive app/Info.plist bytes, independently of the full package checker. Preserve the rollback/rename algorithm, but share the strengthened, side-effect-free inventory validation between the package-check CLI and promotion preflight. Extend ownership to that validation integration and the affected fixtures in `scripts/test-package-promotion.py`. The helper requirements must hold when invoking the promoter directly as well as through `package.sh`; existing rename-fault tests do not prove them. Keep content validation in the CLI/preflight before the internal rename primitive, preserving mechanical fault fixtures. Consolidation must retain the union of current checks, including ZIP CRC, private-path scans and full inventory/bytes. Add a direct-promoter regression proving invalid helper metadata leaves all prior artifacts intact, not only a shared-function test. Independent review approved this planning correction; implementation remains outstanding.

Read-only inspection of the current55a7b1b artifact succeeded with `/usr/bin/lipo -archs dist/TheOnlyPad.app/Contents/MacOS/TheOnlyPad` (arm64) and `xcrun vtool -show-build dist/TheOnlyPad.app/Contents/MacOS/TheOnlyPad` (MACOS, minimum14.0, SDK26.5). These are usable inspection tools, not a tested helper validator. Future parsing must fail on malformed/conflicting/missing platform/version output, inspect each architecture, normalize numeric deployment versions and compare against declared distribution architectures and package/Info.plist minimums. No Intel or minimum-OS runtime validation follows from load-command inspection. Implementation still depends on the actual helper target and reviewed runtime interface.
