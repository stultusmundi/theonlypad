# Shared process spawn protection

2026-09-30. This is component verification, not complete helper/search or desktop acceptance. Design and execution plan: `docs/superpowers/specs/2026-09-30-shared-spawn-gate.md` and corresponding plans file.

## Implemented behavior

The package-level `ProcessSpawnGate` coordinates raw search-pipe creation/protection with both app-owned launch sites. Search adopts both pipe endpoints before any fallible flag operation, verifies each close-on-exec fact, and settles failure inside the gate. Uncertain closure of an unprotected endpoint commits permanent shared refusal before unlock. Verified-protected uncertainty still retains the separate search ownership quarantine without unnecessarily disabling external commands. Search spawn is gated separately; channel adoption and completion remain outside the gate. The gate stores refusal metadata, never descriptor ownership or retry authority.

External commands use the same gate and report an actionable restart message through centralized app identity on shared refusal. A cancellation query after healthy gate admission prevents a command cancelled during contention from launching later. The query briefly reads the runner lock; no runner-lock holder acquires the gate, and the state lock is released before Process.run. Cancellation after this query can still race with spawn and follows the existing termination path.

Production gate locking has no observation callback. Fresh test gates can observe an actual failed try on the exact lock, which proves contention before a held owner is released. This avoids an outside-submission signal masquerading as exclusion evidence. The internal cancellation query is the only bounded state-query exception; no public command callback executes inside the gate.

## Automated evidence

- Compiling behavioral core RED:10 tests/16 failed assertions. Launcher RED:22 tests/124 failed assertions.
- Root review identified the delayed-admission cancellation gap; its dedicated RED produced1 test/two failed assertions before repair.
- Final lock-removal mutant:1 test/four explicit failures. Final poison-commit mutant:1 test/two explicit failures. Neither uses a watchdog timeout as the expected result.
- Final gate/external-admission tests:11/0. Final launcher/lifecycle/timer controls:68/0, preserving existing ownership and ancillary-cleanup gates.
- Root separately executed the unchanged six actual external-command regressions against the frozen core bundle:6/0. Literal argument expansion, dual-stream draining/nonzero exit, output cap, TERM-resistant cancellation, prelaunch refusal and timeout all passed.
- Root separately executed existing actual launcher/lifetime filters on the matching frozen build:3/0, covering descriptor bootstrap/echo, exact exit17, and occupied-main parent EOF exit0 with lifecycle reap/channel closure.

The endpoint flag-stage matrix uses scripted get/set/verification failures in the launcher collaborator; it is not actual Darwin fcntl fault injection. Core admission tests construct real Foundation Pipe objects but replace Process.run with a throwing subclass, so those tests create no child. Initial test-setup compilation and Foundation abstract-property failures are retained separately and are not behavioral RED. Concrete Process regression tests were run only by root under the accepted direct owned-process watchdog.

Independent source review found no remaining material issue in this bounded Task1 slice. Root verified55 core and70 launcher frozen source bindings, generated manifests, exact test-bundle hashes, positive XCTest counts, and strict expected-code/watchdog/capture/group/wait receipts, including mutants. Scoped formatting, public-source and whitespace checks pass.

## Reproducible records

Private evidence: `.local/search-spawn-gate-task1/{handoff.md,handoff.json,core-final,core-final-run,actual-external-regressions,actual-launcher-regressions,root-verification.json}`. Final launcher freeze: `.local/search-child-integration/run.g03w4c_v`.

Core source manifest SHA256: `446c721fb8596c4de2e46583c87568c7f66c51280d11c7c9e89c3c38c9a76b5a`; launcher manifest: `175caa76f8a201f4d9226b86f5fa20ecb813c2f85890084447e03d917cdfb125`.

| Production file | SHA256 |
| --- | --- |
| ProcessSpawnGate.swift | `8edfd65581d83ab301a48ef25eed3b5597b1e7270668107c17bcc85beff9dc16` |
| ExternalCommand.swift | `b6e34a84c53c60670ec38e1b8ff851c9061ce3b86fc5d9af7e18a034b51d9c23` |
| SearchChildLauncher.swift | `36ae04a8b42c25a43a49458ccf64c839099aeb9aaf9d51a73e8ccbe466b26802` |

The accepted self-owned launcher harness ran:

```sh
scripts/test-search-child-lifecycle.sh --filter 'SearchChildLauncherStateTests|SearchChildLifecycleTests|SearchChildDispatchTimerTests|SearchChildLifetimeStateTests'
```

Core tests used a frozen minimal package and reusable `.build/spawn-gate` scratch under the direct watchdog. Root's actual six tests used `xcrun xctest -XCTest PadCoreTests.ExternalCommandTests` on the hash-pinned copied bundle in `core-final/FrozenTestBundle`; XCTest wrote its positive counts to stderr. Root's actual three tests used the matching launcher package with absolute package/scratch paths, `--skip-build` and filter `SearchChildLauncherTests|SearchChildLifetimeProcessTests`. Exact argv and receipts are retained privately. Do not reuse a compiled artifact without verifying its source/bundle binding or nest another process-group owner around the coordinator.

## Remaining gates

The controlled actual unrelated-Foundation-child overlap and helper EOF test in Task2 is not yet executed. The existing six command and three launcher tests do not establish that overlap by themselves. The shared gate protects the two audited application-owned launch sites, not arbitrary framework/plugin spawning. No strict spawn latency, process sandbox, descendant containment, public lifecycle construction, full helper, parent driver, allocation budget, packaged routing or complete C-08/G-03 acceptance is claimed. The new code has not yet been packaged into the development app.
