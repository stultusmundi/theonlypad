# Search helper packaging implementation plan

> Status: the fixed resolver component is implemented and independently reviewed; focused64/0 and integrated738/0 pass. A private Python validator/SBOM/CLI subset passes32/0 but is not adopted. Default launcher forwarding now passes a combined83/0 selection including two actual child tests. Actual helper assembly and relocated protocol smoke remain outstanding. The current app-only package remains usable; it does not contain the planned helper. See [resolver evidence](../../verification/search-worker-resolver.md).

**Goal:** Package the reviewed `PadSearchWorker` at its fixed bundle path, validate the app/helper/SBOM/archive through one shared side-effect-free validator before promotion, and prove the relocated packaged helper can complete the real wire protocol under the owned lifecycle watchdog.

**Architecture:** `scripts/package_validation.py` becomes the only full bundle/archive/SBOM validator. The `check-package.py` CLI and the validation preflight in `promote-package.py` both call it; the promoter's existing lock, backup, rename, and rollback primitive remains unchanged. `package.sh` builds the app and helper explicitly with one release toolchain/configuration, strips both distribution copies, signs helper before outer app when requested, generates canonical SBOM entries from final bytes, archives, validates, runs the packaged-helper smoke, and only then promotes the same three artifacts. A package-internal fixed resolver supplies the extracted `Contents/Helpers/PadSearchWorker` URL to the existing lifecycle/driver; it has no PATH, working-directory, build-directory, download, or in-process fallback.

**Inputs:** approved packaging specification; completed helper/runtime, wire driver, lifecycle, and worker integration at their later gates; current package scripts and Package.swift. This plan does not own helper engine/runtime semantics, native application routing, release signing identities, notarization, or remote publication.

## Review and source inputs

Reviewed against the actual package/check/promote/SBOM scripts and the approved helper packaging, lifecycle, runtime and parent-driver plans. The generator is `scripts/sbom.py`; do not introduce a duplicate generator. Recheck source/interface hashes at dispatch.

Root and independent review resolved launch-lane filesystem validation, exact policy/signing-mode CLI propagation and truthful shutdown/EOF observations. The public packaging specification adopts the EOF clarification below. These are prospective implementation contracts, not packaged-helper evidence.

## Dependency stages without a cycle

1. Validator/SBOM/resolver unit work may be prepared from synthetic fixtures after this plan is approved. It builds or launches no helper.
2. The relocated actual-wire smoke waits for the reviewed parent driver, lifecycle Tasks 1–3, runtime Task 5's real helper integration runner, and the fixed resolver. Reuse the runtime integration source-freezing and owned-watchdog path; do not create another process supervisor.
3. Final package assembly waits for worker-runtime Task 4's real `PadSearchWorker` executable product and measured accumulator plus the relocated smoke component. Gate A therefore already depends on the reviewed parent driver and runtime Task 3. Packaging never selects an accumulator or reservation.
4. Only after Tasks 1–4 pass together may the stricter package/check/promoter entry points be committed and the established packaging command updated in AGENTS.md. Do not land an intermediate state in which the current `package.sh` produces an app-only bundle that the newly strict validator can no longer accept.
5. Native application search routing, packaged editor UI smoke, Developer ID/notarization, and publishing remain later independent gates. The packaging smoke launches the extracted helper directly through lifecycle; it never launches the app or proves editor integration.

## Exact file ownership

Packaging-owned files for Tasks 1–2:

- create `scripts/package_validation.py`
- create `scripts/test-package-validation.py`
- modify `scripts/check-package.py`
- modify `scripts/promote-package.py`
- modify `scripts/test-package-promotion.py`
- modify `scripts/sbom.py`
- create `Sources/SearchExecution/SearchWorkerBundleResolver.swift`
- create `Tests/SearchExecutionTests/SearchWorkerBundleResolverTests.swift`
- after lifecycle implementation is reviewed, make the smallest mechanical update to `Sources/SearchExecution/SearchChildLauncher.swift` so its existing spawn-lane filesystem-validation step calls `validateForLaunch`, plus the matching focused assertions in `Tests/SearchExecutionTests/SearchChildLifecycleTests.swift`

Packaging smoke ownership after runtime Task 5 review:

- create `scripts/test-packaged-search-helper.sh`
- create `Tests/SearchWorkerIntegration/PackagedSearchWorkerIntegrationTests.swift`
- make the smallest reviewed extension to `scripts/test-search-worker-runtime.sh` and its ignored integration-package manifest so the existing frozen-source runner can select the packaged smoke and accept an extracted app bundle path

Task 4 owns only `scripts/package.sh` and focused assembly assertions in `scripts/test-package-validation.py`.

Do not modify `Package.swift`: runtime Task 4 owns the helper product/target. Do not modify `PadSearchWorkerRuntime`, driver/lifecycle semantics beyond the mechanical validation call site, AppDelegate/native controllers, other bundle-resolution callers, package promotion mechanics, or documentation in these tasks. Coordinate ownership before touching the runtime integration script because it is created by a separate earlier task.

## One shared package validator

Create an import-safe module with a narrow interface; names can adjust during compilation, but both entry points must call the same function:

```python
@dataclass(frozen=True)
class PackagePolicy:
    expected_architectures: frozenset[str]
    package_minimum_macos: tuple[int, ...]

@dataclass(frozen=True)
class PackageReceipt:
    file_count: int
    app_sha256: str
    helper_sha256: str
    architectures: tuple[str, ...]
    minimum_macos: str

def validate_package(
    bundle: pathlib.Path,
    archive: pathlib.Path,
    sbom: pathlib.Path,
    policy: PackagePolicy,
    inspect_macho: Callable[[pathlib.Path], MachOReceipt] = inspect_macho_with_system_tools,
) -> PackageReceipt: ...
```

`PackagePolicy` has no production defaults. `package.sh` passes the selected distribution architecture set and the minimum macOS value obtained from `swift package dump-package`; both check and promoter CLIs require the same explicit values. The command contracts are exact and use a repeated architecture option so no comma parsing or host inference can alter the policy:

```text
python3 scripts/check-package.py \
  --architecture ARCH [--architecture ARCH ...] \
  --minimum-macos VERSION \
  APP_BUNDLE ARCHIVE SBOM

python3 scripts/promote-package.py \
  --architecture ARCH [--architecture ARCH ...] \
  --minimum-macos VERSION \
  STAGE_DIRECTORY DIST_DIRECTORY APP_NAME ARCHIVE_NAME SBOM_NAME
```

Every option shown is required; each command rejects an empty architecture set, duplicate/unknown architecture tokens, duplicate/conflicting options, malformed minimum versions, and unsafe positional names. The shared module itself fixes `SEARCH_HELPER_PATH = "Contents/Helpers/PadSearchWorker"` and `SEARCH_HELPER_NAME = "PadSearchWorker"`; neither CLI accepts a path/name override. A general arbitrary-helper inventory or plugin system is outside scope.

The validator reads artifacts and invokes read-only inspection tools but never creates, chmods, extracts, signs, renames, or deletes them. It raises a typed `PackageValidationError(ValueError)` with safe logical labels such as `app executable`, `search helper`, `archive`, or `SBOM`. It never embeds absolute paths, bundle bytes, tool command lines containing temporary roots, or document-like contents in errors.

The shared function must retain the union of current checks and add the helper contract:

- parse Info.plist; require safe expected bundle structure and exact app executable;
- reject a missing, symlinked, nonregular, or nonexecutable bundle helper at exactly `Contents/Helpers/PadSearchWorker`;
- enumerate regular bundle files once, reject symlink substitution, and scan every file for the existing private machine-path patterns without printing matched bytes;
- open ZIP, fail CRC (`testzip`), reject duplicate/absolute/`..` names, require exact file inventory, and compare every archived file byte-for-byte with the bundle;
- independently inspect the helper ZIP entry's Unix external type/mode: regular file, not symlink/other type, and at least one execute bit. Identical payload bytes cannot rescue a wrong type/mode;
- preserve the app executable SBOM digest check;
- require canonical application/helper SBOM identity and dependency association described below;
- require both final Mach-O binaries to have exactly the selected architecture set and every architecture to encode macOS minimum equal to normalized Package.swift/Info.plist minimum;
- reject missing, malformed, duplicate, or conflicting architecture/platform/minimum records.

`check-package.py` becomes a thin argparse CLI over this function and prints only the safe receipt. `promote-package.py.validate(stage,names,policy)` resolves the staged three artifact paths and invokes the same function before the existing `promote` primitive. Remove its duplicate hash/ZIP parser. Keep `promote`'s name checks, destination symlink refusal, lock, private backup, rename ordering, rollback, and retained-backup behavior byte-for-byte except mechanical imports/signatures needed to pass validated names.

The promoter continues to move exactly three outputs: app bundle, ZIP, SBOM. Policy/minimum/architectures are validation inputs, not promoted artifacts. `package.sh` invokes the checker first, then the promoter which independently invokes the same full validator again. This repeated call is deliberate defense at the mutation boundary; it is one implementation, not two validators.

## Mach-O inspection contract

The default inspector uses argv-only subprocess calls with capped stdout/stderr and no shell:

```sh
/usr/bin/lipo -archs BINARY
xcrun vtool -show-build -arch ARCH BINARY
```

Confirm exact `vtool` argument support on the implementation host before accepting this command as proven. `lipo` output is tokenized only into recognized architecture names. Run `vtool` for every returned architecture; require one unambiguous `platform MACOS` and `minos` record. Parse dotted numeric versions, normalize trailing zero components, and compare numerically. SDK values may be recorded but do not substitute for minimum OS. Any tool nonzero exit, capped-output overflow, unknown architecture, missing field, conflicting duplicate, non-MACOS platform, or malformed number fails closed.

Inspect app and helper after strip/sign and before promotion. Each architecture set must equal the selected distribution set; app and helper matching each other is insufficient. Their minimum must equal both the explicit package minimum and Info.plist `LSMinimumSystemVersion`. Synthetic tests inject `MachOReceipt` values into the shared validator to cover wrong helper architectures/minimums without pretending fixture bytes are Mach-O. Parser tests use sanitized fixed `lipo`/`vtool` outputs, including malformed/conflicting/missing records. The actual package task runs the real tools on both final binaries and records their output.

This is load-command evidence only. It does not execute Intel code, test macOS 14, prove code-signing identity, or establish runtime behavior on any architecture/OS not actually exercised.

## Canonical SBOM generation and validation

Keep `scripts/sbom.py` as the sole generator. It still consumes `package.json` and refuses any external Swift package dependency before writing output. It reads final bundle bytes only after all requested signing:

- application bom-ref = packaged `CFBundleIdentifier`;
- metadata application component has that exact `bom-ref`, name/version/license, existing development-distribution properties, normalized minimum macOS, platform frameworks, external-package-count zero, and SHA-256 of final app executable;
- helper bom-ref = `<CFBundleIdentifier>:search-worker`;
- exactly one helper component has type `application`, name `PadSearchWorker`, version exactly Info.plist `DevelopmentVersion`, MIT license, SHA-256 of final helper, and property `bundle-relative-path=Contents/Helpers/PadSearchWorker`;
- exactly one dependencies entry has `ref` equal to the app bom-ref and `dependsOn` containing the helper bom-ref exactly once;
- no duplicate bom-ref, duplicate helper component, undeclared external component, wrong dependency edge, or extra bundled framework entry is allowed.

The validator recomputes both executable digests and requires the exact component/reference/path/version/edge shape. These fields correlate inventory; they do not authenticate the executable or replace protocol semantic versioning.

## Fixed bundle resolver

Add a package-internal Foundation resolver, with no environment/default override. Its path construction and filesystem validation are deliberately separate:

```swift
package enum SearchWorkerBundleResolver {
  // Structural only; safe for lifecycle construction.
  package static func candidate(in applicationBundle: URL) throws -> URL

  // Synchronous lstat/access validation. Spawn/preparation lane only.
  package static func validateForLaunch(_ candidate: URL) throws -> URL
}
```

`candidate` requires an absolute file URL for the supplied application bundle and appends exactly `Contents/Helpers/PadSearchWorker` without existence/permission I/O. That standardized absolute candidate is supplied to `SearchChildLifecycle.init(executable:policy:)`, preserving the lifecycle constructor's structural-only rule.

`validateForLaunch` uses `lstat`/checked access metadata to reject missing, symlink, nonregular, or nonexecutable helper. Its synchronous API does not grant callers permission to block any executor. The lifecycle's existing delayed filesystem-validation step invokes it for the retained executable URL on the one retained blocking-capable spawn/preparation lane, after `begin` has stored the operation and armed its admission deadline. This mechanically replaces that launcher's equivalent generic filesystem check; it does not add a second check or change spawn ownership. Actual spawn failure remains authoritative if the entry changes after validation. The call never runs on MainActor, lifecycle control, the driver codec lane, a connection I/O queue, or a new unbounded async task. No pre-constructor call to `validateForLaunch` may move filesystem latency outside the deadline, and `SearchChildLifecycle.init(executable:policy:)` remains structural only.

The resolver returns no PATH/current-directory/build-product alternative and performs no launch, signature trust decision, download, fallback, or native routing. Production later passes the actual app bundle URL to `candidate`; development/runtime tests that need an unbundled helper inject their already reviewed absolute executable directly into lifecycle and receive the same delayed launch-lane filesystem validation. Do not force test executables to live at the bundle helper path.

Synthetic resolver tests cover structural exact candidate, missing path, directory, symlink-to-executable, no execute bit, relative/nonfile app URL, and a sibling/build-directory executable that must never be selected. A scheduling fixture arms admission, holds the retained preparation lane, and proves `validateForLaunch` is invoked there before launch while MainActor/control remain free. They use temporary bytes and do not claim Mach-O/helper execution.

## Package assembly and effect ordering

Once `PadSearchWorker` exists, update `package.sh` in this fixed order:

1. Validate its existing optional `--ad-hoc-sign` argument and create the private stage/trap as today. Existing `dist` artifacts are untouched.
2. Dump Package.swift, derive Info.plist and exact minimum, select the current distribution architecture set explicitly, and validate safe artifact components.
3. Build `TheOnlyPad` and `PadSearchWorker` as two explicit `--configuration release --product ...` invocations through the same `scripts/swift.sh` toolchain and scratch build. One successful product build is not evidence for the other.
4. Create `Contents/MacOS`, `Contents/Helpers`, and resources. Copy exact app and helper binaries from the one reported release bin path.
5. Strip `-S` from both distribution copies only; preserve original build outputs for diagnostics.
6. Install Info.plist/license/notices/icon and lint Info.plist.
7. If `--ad-hoc-sign`: sign the helper first, strictly verify the helper, sign the outer bundle second, then strictly verify the outer bundle and helper again. Do not use `--deep` as the signing operation. An optional deep verification may supplement the two explicit checks. Without the flag, keep the unsigned local-development path and make no signing/notarization claim.
8. Generate SBOM from the final stripped/signed bytes.
9. Create ZIP from the final bundle with the existing metadata exclusions and parent directory; do not postprocess permissions independently of bundle bytes.
10. Run the shared checker with explicit architecture/minimum policy. Run the relocated packaged-helper smoke described below against this exact staged ZIP/SBOM.
11. Invoke the promoter with the same explicit policy. Its full preflight reruns before any rename. Only then move the same three staged artifacts into `dist` under rollback protection.

Any build/copy/strip/sign/verify/SBOM/archive/validator/smoke failure exits before promotion. The stage trap may remove failed new artifacts; every previous `dist` artifact remains byte/mode-identical. A promotion validation failure also leaves all three staged inputs intact because validation occurs before the rename primitive. Existing mechanical rename-fault tests remain separate and continue to prove rollback after mutation begins.

Archive inventory naturally includes helper and any signature resources present in the final bundle. The validator compares the complete inventory and bytes, then checks helper ZIP Unix mode/type separately.

## Relocated actual-wire smoke

Create one packaging wrapper around the already reviewed runtime integration runner and `scripts/run-owned-search-tests.py`; do not implement another watchdog, launcher, driver, wire codec, or package validator.

The wrapper has this exact interface:

```text
scripts/test-packaged-search-helper.sh \
  --sign-mode unsigned|ad-hoc \
  --architecture ARCH [--architecture ARCH ...] \
  --minimum-macos VERSION \
  APP_BUNDLE ARCHIVE SBOM
```

All options and positional artifacts are required. It rejects an empty architecture set, duplicate/unknown architecture tokens, duplicate/conflicting options, an unsupported sign mode, malformed minimum version, and extra arguments. `package.sh --ad-hoc-sign` passes `--sign-mode ad-hoc`; the existing no-flag path passes `--sign-mode unsigned`. `package.sh` forwards the same derived architecture occurrences and minimum macOS value, in the same normalized form, to the checker, smoke wrapper, and promoter. The wrapper forwards those architecture/minimum arguments unchanged to each shared-checker invocation. It never infers policy from the host, archive name, Mach-O output, or signing state.

The wrapper then:

1. calls the shared checker;
2. extracts the ZIP with a metadata-preserving system tool into a new private relocated directory and requires exactly the expected top-level app;
3. reruns bundle/archive/SBOM validation using the extracted app;
4. for ad-hoc mode, strictly verifies the extracted helper and outer app explicitly; unsigned mode skips signature claims;
5. passes the extracted app URL to the real `SearchWorkerBundleResolver`, then passes only that returned helper URL to the actual lifecycle/driver integration fixture;
6. runs the fixture under the existing owned-process watchdog with capped diagnostics and exact source hashes.

The fixed benign oracle uses one helper PID/generation and two sequential lifecycle-issued ordinals. Find literal `😀` in `A😀 a😀` must return original UTF-16 ranges `(1,2)` and `(5,2)`. Replacing it with `β` must return the same ranges and exact output `Aβ aβ` (also verify fixed UTF-8 bytes and UTF-16 units). Require completed hello, exact success terminals, no second lifecycle launch/child, then explicit lifecycle shutdown with exact reap and `channelsClosed`. Any already-pending read must settle with its actual result before the fixture releases ownership. Record response EOF only if a read returns empty before local whole-connection close; a cancellation or channel error caused by `SearchChildConnection.close()` is not EOF. Never log source/output contents beyond fixed fixture labels.

### Reviewed EOF and shutdown observation

The earlier packaging specification compressed “EOF/reap” into one packaged-smoke requirement. The planned lifecycle exposes only whole-connection `close()`, which may cancel or fail a pending response read while closing its read descriptor. It has no response half-close or receipt proving the child closed stdout first. Consequently, the packaged smoke cannot soundly require an empty response read *after* local shutdown, and it must never relabel cancellation/channel failure as EOF.

The reviewed packaging specification now requires: “After both validated terminals, explicitly shut down/retire the lifecycle, settle any pending response read according to its real outcome, and require exact child reap plus `channelsClosed`. An empty read may be recorded as response EOF only when the channel observes it before local whole-connection close.” Do not add a half-close API or synthetic EOF receipt solely for packaging.

Actual parent-lifetime EOF remains independently observable and required in lifecycle Task 3, which closes the sole lifetime writer and reaps the directly owned fixture, and worker-runtime Task 5, which does the same to the fixed production helper while idle. The relocated smoke correlates those reviewed executable sources with the archive through exact helper bytes and SBOM hash, and proves shutdown/reap/channel closure for the relocated executable. It does not restate a locally manufactured channel outcome as response EOF. This is the bounded spec refinement chosen by this plan; it adds no special exit mode or separate process fixture.

For the final acceptance run, use an isolated clean packaging worktree. Let the existing runtime integration runner build/freeze its parent test executable under its own ignored scratch first. Then reversibly move only that isolated worktree's ordinary app/helper build directory out of its expected location under a trap before executing the prebuilt smoke against a freshly extracted archive. Never rename the shared active workspace build directory. Resolver output must stay inside the relocated app; no development URL can satisfy the fixture. Restore or discard only the isolated worktree afterward.

The package command's pre-promotion smoke and the isolated final run use the same wrapper. The isolated run supplies the stronger no-build-fallback evidence. Neither launches the editor app, shows UI, verifies minimum-OS execution, or proves packaged native routing.

## Task 1 — Shared validation and direct promoter protection

**Files:** create `package_validation.py` and `test-package-validation.py`; modify `check-package.py`, `promote-package.py`, and `test-package-promotion.py`. Do not edit the rename/rollback algorithm beyond its validation call boundary.

- [ ] Principal red: construct valid old dist artifacts plus staged artifacts whose helper SBOM path/ref/digest is wrong. Invoke the promoter's actual main/preflight path, not only `validate_package`. Assert failure occurs before any rename; all old artifact bytes/modes are unchanged and all staged artifacts remain.
- [ ] Implement one shared validator and migrate both entry points. Add an equivalence test that the checker and promoter reject the same invalid helper fixture while the mechanical `promote` fault tests still cover all six rename positions and rollback-backup behavior.
- [ ] Synthetic full-matrix tests: success; missing/symlink/directory/nonexecutable helper; changed helper bytes; wrong/missing helper digest; omitted archive helper; duplicate ZIP path/component; helper ZIP symlink/other Unix type; missing execute bits with identical bytes; wrong version/path/bom-ref/dependency edge; wrong app digest; changed archive byte; CRC failure; unsafe archive path; machine-path marker; unexpected external component; wrong/missing/conflicting architecture/platform/minimum.
- [ ] Exercise both checker and promoter CLIs with repeated architecture arguments and an explicit minimum. Assert missing/empty/duplicate/unknown architectures, malformed or repeated minimum, unsafe names, and extra arguments fail before validation or mutation; assert the accepted normalized policy reaches the shared validator unchanged.
- [ ] Assert every failure message uses safe logical fixture labels and contains no temporary absolute root, embedded marker, or executable contents.
- [ ] Run proposed `python3 scripts/test-package-validation.py` and `python3 scripts/test-package-promotion.py`; syntax-check only the touched Python files. Retain genuine behavioral red/green and obtain independent review.

## Task 2 — Canonical SBOM and fixed resolver

**Dependencies:** lifecycle implementation review is required before the mechanical launcher integration. **Files:** modify `sbom.py`; create `SearchWorkerBundleResolver.swift` and `SearchWorkerBundleResolverTests.swift`; mechanically update `SearchChildLauncher.swift` and only its focused lifecycle assertions; extend only validation fixtures needed for generated SBOM.

- [ ] Red-test one generated synthetic bundle: exact app/helper bom-refs, versions, hashes, path property, dependency edge, and no extra component. Add external package dependency refusal before output mutation.
- [ ] Implement helper inventory in the existing generator only. Validate generation through the shared checker with an injected Mach-O receipt; do not duplicate checker logic in SBOM tests.
- [ ] Red-test resolver symlink/nonregular/nonexecutable/missing and sibling-build fallback cases, then implement the fixed relative lookup. Add a focused lifecycle red proving filesystem validation starts only on the retained spawn lane after admission/deadline arm; replace the launcher's existing generic check with the shared routine without changing constructor or spawn state-machine behavior.
- [ ] Run proposed Python validation/promotion tests and `scripts/swift.sh test --scratch-path .build/search-helper-packaging --filter SearchWorkerBundleResolverTests`; scope-format/public/diff checks and independent review.

## Task 3 — Relocated packaged helper smoke component

**Dependencies:** reviewed driver/lifecycle, runtime Task 5 integration runner, Tasks 1–2. **Files:** create packaged smoke script/test and make only the narrow runner/manifest extension listed in ownership. Exercise it against a synthetic/explicit candidate path first; it does not promote artifacts.

- [ ] Principal red: place a valid helper in the source build directory but omit it from the relocated app. The fixed resolver/smoke must refuse without a lifecycle launch; no development override may rescue it.
- [ ] Add the fixed Unicode two-request oracle and exact lifecycle receipts. After both acknowledged terminals, assert explicit lifecycle shutdown, exact reap and `channelsClosed`; settle any pending read by its real outcome and never treat local close cancellation/error as EOF. Then add archive helper mode/type corruption, executable-byte corruption, wrong SBOM hash, wrong architecture/minimum inspector receipts, immediate helper exit, and extra lifecycle-launch attempt. Synthetic validator failures do not count as actual helper smoke.
- [ ] Exercise the smoke CLI in both `unsigned` and `ad-hoc` modes. Capture the checker invocation and require every architecture occurrence and normalized minimum to pass through unchanged; reject missing, duplicate/conflicting, malformed, unsupported, or extra arguments before extraction or launch.
- [ ] Run the proposed packaged smoke through the existing owned watchdog. Then perform the isolated-worktree/build-unavailable run described above and require the same exact source/app/helper hashes. A watchdog timeout is a test failure even if cleanup succeeds.
- [ ] Re-run direct promoter invalid-metadata preservation, focused validator/resolver tests, shell/Python syntax, scoped format/public/diff checks, and independent review. This task supplies the callable smoke; package effect ordering is Task 4.

## Task 4 — Build, strip, sign, archive, validate, smoke, preserve

**Dependencies:** reviewed runtime Task 4 executable product plus Tasks 1–3. **Files:** modify `package.sh`; add only focused assembly assertions to `test-package-validation.py` if needed.

- [ ] Behavioral red from a staged synthetic/real candidate: app-only package, helper copied to the wrong path, helper omitted from explicit build, signing outer before helper, SBOM created before final signing, or promotion before full validation/smoke must fail an ordering/inventory oracle. Capture checker/smoke/promoter argv and require the same derived architecture occurrences and normalized minimum at all three calls, plus `ad-hoc` or `unsigned` smoke mode matching the package flag.
- [ ] Implement the exact effect ordering above, now calling the reviewed Task 3 smoke before the promoter. Keep current unsigned mode. Record shell syntax and actual `swift build --show-bin-path`, `strip`, `codesign`, `lipo`, `vtool`, `ditto`, SBOM, validator, and smoke outputs when first run; a source-order assertion alone is insufficient.
- [ ] Run proposed focused Python tests, `sh -n scripts/package.sh`, then in the later isolated packaging checkpoint run `scripts/package.sh --ad-hoc-sign`. Verify final bundle helper and ZIP type/mode/bytes, both binary digests/architectures/minimums, canonical SBOM, relocated smoke, and preservation of prior dist artifacts on injected pre-promotion failure.
- [ ] Only after staged validation and smoke pass may promoter run. Do not promote or commit an app-only intermediate. Scope-check exact scripts/resolver changes and obtain independent review.

## Proposed commands and claim limits

All commands remain proposed until their tasks implement and prove them:

```sh
python3 scripts/test-package-validation.py
python3 scripts/test-package-promotion.py
python3 -m py_compile scripts/package_validation.py scripts/check-package.py scripts/promote-package.py scripts/sbom.py scripts/test-package-validation.py scripts/test-package-promotion.py
scripts/swift.sh test --scratch-path .build/search-helper-packaging --filter SearchWorkerBundleResolverTests
sh -n scripts/package.sh scripts/test-packaged-search-helper.sh
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py --architecture arm64 --minimum-macos 14.0 dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
scripts/test-packaged-search-helper.sh --sign-mode ad-hoc --architecture arm64 --minimum-macos 14.0 dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
python3 scripts/promote-package.py --architecture arm64 --minimum-macos 14.0 PRIVATE_STAGE dist TheOnlyPad.app TheOnlyPad-0.1.0-dev-arm64.zip TheOnlyPad.sbom.json
```

The architecture/minimum arguments shown reflect the current checkpoint only; `package.sh` must pass values it derives from the selected distribution and package manifest rather than hard-code them. Update artifact names from centralized identity/version. Never add credentials, remote push/publish, Developer ID/notarization, or a broad release orchestrator to these commands.

Passing Tasks 1–2 proves the synthetic validator/SBOM/resolver contracts. Task 3 adds the reusable relocated helper protocol/reap smoke component. Task 4 proves local package effect ordering, inventory/correlation, archive fidelity, mode/type, load-command inspection, and one benign relocated smoke for the binaries actually checked. None proves native editor search, visible desktop behavior, minimum-OS runtime, Intel runtime, universal hard cancellation, OS sandboxing, allocator/RSS bounds, Developer ID/notarization, or release publication.
