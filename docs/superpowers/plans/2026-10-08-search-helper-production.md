# Fixed search helper and nested packaging implementation plan

> Use the installed subagent-driven-development lifecycle for bounded tasks and
> independent specification/quality review. Root owns serial runtime.

**Goal:** Provide a fixed bundled search helper with genuine small protocol checks
and complete artifact validation. Editor routing remains subsequent work.

**Architecture:** Existing Program + Darwin channel + strict accumulator + checked
lifetime starter; fixed PadSearchWorker executable and nested bundle path. Shared
pure package validation serves both preflight and independent promotion.

**Tech stack:** Swift5 mode/macOS14, Foundation/Darwin, Python standard library;
no external dependency or asset.

**Spec:** `docs/superpowers/specs/2026-10-08-search-helper-production-design.md`.

## Global constraints

- Synthetic inputs and ignored raw evidence; no real documents or credentials.
- Root alone runs builds, children, packaging and GUI; no nested watchdogs.
- Delegate source tasks with exact ownership; preserve others' changes.
- Package/editor/helper/desktop/memory states remain distinct.
- Joined shutdown validates the original receipt and exact observed exit0 or
  SIGKILL with owned signal/reap facts; no competing waits/signals or PID checks.
- Real write fragmentation does not imply distinct reads/decoder callbacks.
- ZIP S_IFREG+execute bits and all-member types are independently validated;
  payload-identical external_attr mutations must fail.

## Executable tasks

### Task1: Fixed product and entry

Files: Package.swift, Sources/PadSearchWorker/PadSearchWorkerMain.swift; new bounded real-helper integration tests/runner and pure selection/inventory controls under Tests/SearchWorkerIntegration.

- [x] Complete independent specification/quality review of the adopted design and exact interfaces after lifetime checkpoint e076afa; record constraints and proceed autonomously.
- [ ] Author independent literal real-helper tests and coordinator controls first. Root records missing product/entry compiler or structural RED separately from behavioral failure; never relabel setup failure as a passing refusal.
- [ ] Add the executable product/target and the exact fixed entry above; retain existing runtime/engine/protocol/limits.
- [ ] Root builds `scripts/swift.sh build --configuration release --product PadSearchWorker` under the accepted direct owned watchdog; bind the immutable release artifact before further builds.
- [ ] Root runs the five small real-protocol cases and bad-argv case, plus accumulator/Program/lifetime/wire and parent-driver neighboring suites. The runner's new command is proposed, not proven until executed.
- [ ] Independent reviewer checks the entire actual entry and dependency graph, argument/FD/exit ownership and actual source/receipt/artifact bindings.

### Task2: Nested packaging and refusal controls

Files: scripts/package.sh, scripts/sbom.py, scripts/check-package.py, scripts/promote-package.py, proposed scripts/package_validation.py, existing scripts/test-package-promotion.py and proposed scripts/test-package-validation.py.

- [ ] Write synthetic helper validation/refusal tests and preserve original promotion assertions. Root observes behavioral RED for an app-only or substituted helper package before implementation.
- [ ] Build/copy/strip both products, sign helper before app when requested, extend final helper SBOM, and share complete validation with promotion.
- [ ] Root runs pure package tests, then actual `scripts/package.sh --ad-hoc-sign` under sole packaging ownership. Verify both code signatures, final app/helper/SBOM/ZIP bindings and retained compiler receipts.
- [ ] Root executes the five small real-protocol cases against the final resolver-selected nested copy, without rebuilding/replacing that copy between pinning and execution.
- [ ] Root performs independent negative artifact-copy controls (never mutate the accepted package), and verifies refusal precedes promotion while old distribution outputs remain intact.
- [ ] Independent source and actual-evidence review closes only production composition/packaging/representative protocol acceptance.

### Task3: Integrated local checkpoint

Files after verification: dated docs/verification record, AGENTS proven commands, continuation and adopted spec/plan states.

- [ ] Root runs the full app/core suite through the existing direct600s watchdog, package-target build, strict format lint, public-source check and scoped diff checks. Preserve every setup/failure receipt and exact frozen input set.
- [ ] Record planned/implemented/tested/blocked separately. The app remains on its existing search path; packaged helper availability is not editor containment or desktop acceptance.
- [ ] Make a scoped local commit only after reviews/checks pass; no remote push/merge/release. Continue with production parent binding and editor admission as a separately reviewed design.

