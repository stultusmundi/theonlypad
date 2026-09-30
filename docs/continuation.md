# Continuation

## Active resumption, 2026-09-30

The user explicitly requested resumption. The September10 pause is superseded. Continue the full `docs/BUILD_PROMPT.md`; this is an incomplete product, not a release candidate. Routine local implementation, tests, independent agents and scoped commits are authorized. No remote publication, credentials or system-security changes are authorized.

Branch: `build/native-editor`. Current accepted resumption commits:

- `b3851ff`: checked launcher and actual exit17/bootstrap/echo/exit0 evidence.
- `20a6bd3`: sequential worker runtime/collector,21 tests and public target build.
- `d7262a8`: monotonic timer and independent busy-child parent EOF,60 injected tests and one actual child test.
- `219ede9`: exact per-request Foundation engine adapter,42 combined tests.
- `c065153`: bootstrap and bounded FD-channel component,60 combined injected tests.
- `363f5fd`: independently reviewed shared spawn-gate design/plan, implementation not yet accepted.

Read `docs/verification/search-child-lifecycle.md` and `docs/verification/search-worker-runtime.md` for exact source hashes, failed attempts, proof boundaries and reproduction. The helper executable, production search routing and hard regex containment remain outstanding.

## Current ownership and next actions

Root owns actual child/GUI runs, layout diagnostics, public records and commits. No root GUI or child test is currently active. Serialize builds and reserve exclusive CPU/GUI ownership for performance measurements.

- `worker_engine_adapter` completed the pure `SearchWorkerProgram.swift` and matching tests; independent review pending. Frozen `.local/search-worker-program-task3/green-final` has72/0 (12 new+60 prior), behavioral RED12/35. Red/green dependencies are identical; later concurrent gate changes are deliberately excluded. No actual thread/FD/helper was executed.
- `search_lifetime_timer` implements shared spawn-gate Task1 under the reviewed September30 spec/plan. It owns new PadCore gate/tests, ExternalCommand consumer and search launcher/injected tests. Build slot belongs to this worker. Require exact-lock contention and poison mutants, matching inventories and independent review before any actual peer test.
- `worker_runtime_review` reconciles the already reviewed September10 parent-wire-driver plan against current source, then reviews Program. The existing driver plan must be reused; no competing second architecture.

Exact next integration actions: review Program and shared-gate implementation, then add the separately reviewed actual unrelated-child EOF test. Do not expose public lifecycle construction before these gates. Program composition candidate follows accepted bootstrap/channel/lifetime interfaces. The parent synchronous-codec/asynchronous-channel driver needs a separately reviewed bounded rendezvous design before the allocation GateA matrix. No production accumulator or helper executable before that matrix qualifies.

## Accepted runtime evidence

Accepted direct process owner: `scripts/run-owned-search-tests.py`, SHA256 `d5bd867e4a65b4ee053209fe0a5822867b8d0878fd6d059f474c9b28a0f6286d`. It owns one new process group, observes leader exit before group cleanup and consuming wait, bounds captures, and verifies its narrow EPERM/exited-leader-only fallback. Never nest another session-owning watchdog around a coordinator that already imports it. Strict command/wait/capture/group receipts and positive XCTest counts are mandatory.

Launcher review required a gate-only behavioral mutant:1 test/seven explicit failures, then14 injected launcher tests and36 lifecycle tests pass. Root reused frozen `run.zfhadph_` for actual exit17 and benign descriptor/64-byte echo/exit0 tests, each1/0; full source/fixture/test-bundle bindings verified. Private `.local/search-child-lifecycle-task-2/launcher/gate-review-repair/` retains review and mutation evidence.

Timer/lifetime freeze `.local/search-child-integration/run.e279qdnw` passes60 injected tests. Root actual `actual-lifetime-absolute` passes1/0 with exact child exit0/reap/channel closure while main is occupied. Initial `actual-lifetime` failed before XCTest because the wrapper changes directory; preserve it. Reusing `--skip-build` requires verified matching sources, fixture and test bundle; supply absolute package/scratch paths with a frozen wrapper.

Runtime Task1 evidence `.local/search-worker-runtime-task1/`: compiling RED12/31, final21/0, actual public-target build and independent approval. Task2 `.local/search-worker-engine-task2/`: compiling default-limit RED21/19, final42/0,62 matching frozen inputs and independent approval. These are no-process protocol/semantic/ownership checks, not memory or helper acceptance.

## Disk and build constraints

The external volume reached32MiB free and a diagnostic invocation refused125 before creating a result directory. Root removed only eight obsolete, reproducible, ignored `.build/search-*` scratch directories; exact receipt `.local/cache-reclamation-20260930.json`. Sources, `.local` evidence and distribution artifacts were retained. Historical commands using those scratches require rebuilding. Freed space was approximately2.3GiB immediately; later APFS accounting showed3.7GiB. Continue reusing scratch and serializing builds. Do not delete verification evidence or unrelated external-volume data.

## Unicode layout diagnosis

The original262144-UTF16 shaping fixture times out with wrap enabled in both debug and optimized current-controller paths; wrap-disabled passed. No production threshold/default/guard was adopted. The separately reviewed presentation-subphase probe now ran: initial15-second attempt timed out with no captured test start; separately labeled60-second diagnostic passed1/0 in38.964s, all22 phases and four positive1059×616 geometries. This weakens zero host geometry as the explanation; it is not target acceptance.

Root's timing-only variant `.local/pane-layout-cost/unicode-controller-phase-timing-20260930/` passed1/0 after the disk cleanup. Watchdog41.718633s; `host.before`0.741323s to `host.after`37.276419s isolates36.535096s inside scroll-view host presentation. Later layout/wrap calls were milliseconds. No native operation order changed. Source manifest `848f9e155b2b2877184a4c144349d19b4c0e9232154941a4d4119d70281d9ab8`; binary `dec53cc896e9713354ef90dc9ff725e5cb77721a985db643f23f81ec70b0d8e9`; strict receipts/four bundle hashes verified. Read-only disk inventory overlapped this diagnostic, so no controlled benchmark claim.

The minimal native comparison is now executed in `.local/textkit-comparison-20260930/`: both65,536-unit cases completed; at262,144 units TK1 timed out during undo after60.077s, while TK2 completed exact content/undo checks in54.544s but spent27.527s in initial layout/raster and26.903s in insertion. One hidden run per case, no post-edit paint or latency acceptance; all receipts/source/binary bindings verified. No engine replacement is justified by these results. A paragraph-segmented control and prior Scintilla Unicode gates remain next investigations. Avoid touching legacy `.layoutManager` on the TextKit2 branch because that can force compatibility fallback. Prior Scintilla/CodeMirror and engine licensing results remain in architecture records/private engine memo; do not treat another probe as a selected replacement. UI, IME, multi-selection, undo, recovery, shared panes and accessibility remain required adoption gates.

## Package and desktop state

Current bundle still source `9231fc352d5ba31c1d90ffeb0710a5c94712d1a0`, ARM64/ad-hoc, with no DeveloperID signing, notarization or publication:

- `dist/TheOnlyPad.app`
- `dist/TheOnlyPad-0.1.0-dev-arm64.zip`
- `dist/TheOnlyPad.sbom.json`

Launch with `open dist/TheOnlyPad.app`. Executable SHA256 `8f5fe6c898b4c60ceff367fefc3ccdd2ad67ef3b89e1b0ce9ea414d5057613de`. Packaging evidence `.local/shortcut-modifier-integrated-evidence/`. Subsequent settings, focus, launcher and runtime changes are **not** in this package.

Ordinary XCUITest works. Packaged `.local/desktop-ui/shortcut-production-5aq_v27w/` passed customization/persistence/reset, open/edit/save/quit/relaunch/reopen and Option-held File/New. Private pane candidate passed both desktop orientations but does not establish current production remedy. Actual Locate still has an unresolved intermittent stale-context failure; preserve it rather than retrying to hide it.

Separate AXPress remains incomplete. The original probe received trust and File/New presses succeeded, but its following query failed before the two-tab postcondition. A new diagnostic signature was denied on repeated user-requested attempts. Filtered TCC logs confirmed the saved old cdhash does not match that diagnostic. Last retry `run.NhHkpg` ended77/missingAccess, no target launched; no permission calls occurred during this resumption. Diagnostic path pointer `.local/ax-native-probe/query-diagnostic/relocated-root.txt`. Preserve its signature/location. A bundle-specific `tccutil reset Accessibility org.theonlypad.accessibility-check` is a possible remediation but **has not been authorized or performed**; resumption is not authorization to change privacy settings. Never reset all Accessibility grants.

## Verification commands and remaining scope

See AGENTS for proven commands and their precise scopes. Current pure harness/watchdog suite passed50:

```sh
python3 -m unittest discover -s Tests/SearchChildIntegration -p 'test_*.py'
python3 scripts/check-public.py
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
git diff --check
```

Native runner pure suite's last accepted count is30; not rerun in this resumption. Native transfer/projection/close runners own their watchdog directly. Historical application-shortcut runner still needs the previously identified late-kill/provenance repair. Never disable hooks or tests. Hosted CI is not claimed executed. No new dependency or asset was adopted; original licensing remains MIT.

The requirements matrix remains authoritative. Advanced editing/multiple cursors/rectangles/overwrite, save failures/autosave, folder replacement preview/backups, languages, workspace/minimap, automation/extensions, accessibility/localization/IME, repeated launch/input/100MB/1GB performance, security, final packaging and full parity remain applicable outstanding work. Preserve exact checkpoints on interruption; do not claim background work continues after the session ends.
