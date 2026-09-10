# Regex execution review — 2026-09-10

Update: the internal-engine-error finding is fixed and independently approved at `9d54295`; [verification](search.md) records 412 passing committed-source core tests and actual hidden native catch coverage. The original assessment below describes its recorded pre-fix source. Hard execution containment and remaining scopes are still outstanding; the [supervised-search design](../superpowers/specs/2026-09-10-supervised-search.md) is planned, not implemented.


Read-only assessment of C-03/C-07/C-08/C-10 and I background/cancellation requirements in `docs/BUILD_PROMPT.md:94` and `docs/BUILD_PROMPT.md:163`. Production sources were not modified. No build, runtime test, pathological regex, GUI, or benchmark was executed in this review. Historical results below are attributed to existing records, not fresh verification.

## Findings

1. **No hard execution deadline or forced cancellation exists for ICU search.** `Sources/PadCore/SearchService.swift:22–40,43–54,142–199` uses a one-second default monotonic deadline checked before/after compilation and in `.reportProgress` callbacks. The callback can ask enumeration to stop, but only after Foundation calls it. Compilation, bridging/counting/scalar checks, result mapping, and individual replacement allocations cannot be interrupted by that callback. Input/pattern/output caps bound data dimensions, not elapsed time or process RSS. No independent supervisor watches these calls.

2. **Engine failure flags are discarded, potentially converting incomplete enumeration into successful partial/empty results.** `SearchService.swift:177–198` omits `.reportCompletion`, names the callback flags `_`, and returns accumulated results unless its own checks throw. The checked SDK explicitly documents `.internalError` as an engine failure that may occur before examining the entire range. The omission is a source-confirmed defect in failure handling; whether a particular pattern triggers it on this host has NOT been reproduced. It can affect Find All counts, folder completeness, and Replace All, which consumes the same collected results (`SearchService.swift:54,77–90`). Do not describe this as a measured corruption event.

3. **Native cancellation rejects delivery but does not prove execution stopped.** Document Find/Replace uses `Task.detached` and `Task.isCancelled` (`Sources/TheOnlyPad/SearchPanelController.swift:76–108`); folder uses a locked token and a detached task (`Sources/TheOnlyPad/FolderSearchController.swift:4–17,176–185,217–250`). Both invalidate generations before allowing further results. Document restart cancels an earlier task and immediately starts another; folder Cancel clears its token and permits another start even if the previous worker still runs. Neither has a process-wide active-worker/queue cap. Repeated cancel/restart can therefore retain multiple snapshots and consume workers while ICU has not returned. This is an architectural risk inferred from ownership and cancellation code, not a measured resource-exhaustion result.

4. **Budgets are per service invocation, not per visible request.** Replace All first calls `matches`, then `replacing`, which matches again; each gets a new one-second deadline (`SearchPanelController.swift:98–102`, `SearchService.swift:46,53`). Folder validates the query by searching empty text, then recompiles/searches every eligible file with a new default deadline (`Sources/PadCore/FolderSearch.swift:41,94–97`). It has no total-search deadline. Discovery/reads check cancellation between operations, but synchronous filesystem calls and sorting have no wall-clock bound (`Sources/PadCore/WorkspaceIndex.swift:43–72`; `FolderSearch.swift:60–97`). A regex watchdog alone would not establish a hard bound on entire folder I/O.

5. **Open-document search is absent.** The search panel snapshots exactly one originating document (`Sources/TheOnlyPad/EditorWindowController.swift:2591–2600`); selection scope exists in the core `matches` API but is not passed by this panel. No open-document query fan-out was found among all `SearchService` callers. `docs/requirements-matrix.md:61` agrees that selection/open-document scopes remain outstanding. Future aggregation must not treat disk reads as equivalent to dirty open-buffer snapshots.

6. **Large-file search is a different, literal-only service.** `Sources/PadCore/LargeFileReader.swift:91–138` uses byte matching with cancellation between chunks and every 65,536 bytes; it does not run ICU. Its native label/API must remain distinct from regex, Unicode case/word matching, and UTF-16 offsets. This review makes no new acceptance claim for that path.

## Exact evidence and current limits

The Foundation SDK header inspected locally is:

`<macOS SDK>/System/Library/Frameworks/Foundation.framework/Headers/NSRegularExpression.h`

Lines 52–65 define progress/completion options and internal-error flags. Lines 80–82 document completion delivery and engine failure before the whole range is examined. Lines 84–86 document transparent/anchoring bounds and immutable-regex thread safety. No document content or SDK source was copied into this report. The corresponding [Apple enumeration API](https://developer.apple.com/documentation/foundation/nsregularexpression/enumeratematches(in:options:range:using:)) documents periodic progress callbacks and caller-requested stopping; it does not provide a maximum callback interval. The [ICU performance guide](https://unicode-org.github.io/icu/userguide/strings/regexp.html#performance-tips) describes catastrophic backtracking and match limits. Direct ICU limits would require an integration change; they do not establish Foundation's actual runtime configuration or a universal compilation deadline.

| Path | Implemented resource limits | Cancellation/time scope |
| --- | --- | --- |
| Core default | 10M UTF-16 input; 4,096-unit pattern/template; 100K matches; 1M aggregate match/capture ranges; 20M UTF-16 output | One second per matches/replacing call; cooperative |
| Native document | Overrides input/output to 100M UTF-16; retains other core caps | Find: one core call; Replace All: two independent calls; generation rejection |
| Folder | 50K visited paths; 10MB per file; 10K total hits; 100MB source-byte snapshots | One core budget per validation/file; cooperative I/O/discovery checks; generation rejection |

Core limits: `SearchService.swift:31–40,55,151–159,184–188`. Folder limits: `FolderSearch.swift:4–14,31–33,94–107`. Snapshot-byte accounting does not measure String overhead/RSS. A capture limit is enforced after Foundation has produced an individual result.

`Tests/PadCoreTests/SearchTests.swift:85–100` tests pre-cancelled calls, zero budget, and `(a+)+$` against 200 `a` plus `!` with a 20ms budget and a post-return assertion below two seconds. The latter assertion is NOT an outer watchdog: a nonreturning call hangs the test before the assertion. `docs/verification/search.md:20,33` records approximately 20ms interruption and nine historical passing tests. The current source has ten tests, including a later aggregate capture test whose assertion accepts any error (`SearchTests.swift:7–10`); the old nine-test record does not establish that latest test's pass or exact error.

`Tests/PadCoreTests/FolderSearchTests.swift:39–56` checks immediate cancellation/malformed input/caps, mostly without typed error assertions. It does not cancel an in-flight regex or measure termination. `Tests/NativeIntegration/SearchHarness.swift:24–39` verifies find/wrap/stale snapshot, not cancellation. `Tests/NativeIntegration/FolderSearchHarness.swift:68–70` checks immediate cancelled UI status after Cancel, not worker exit. Hidden/visible desktop execution was not attempted here.

## Small independent fix before process isolation — proposed, not implemented

Add `SearchError.engineFailure`, request `.reportCompletion` alongside existing matching options, and inspect every callback's `.internalError` before accepting any result as success. Preserve first terminal failure and stop enumeration; completion must never clear an earlier cancellation/timeout/limit. Treat `.progress`, `.completed`, `.hitEnd`, and `.requiredEnd` alone as nonerrors. Propagate the typed failure through folder search (do not count it as unreadable or return partial hits), and give both native panels an actionable retry/narrow-pattern message.

Small test seam: keep compilation and production `NSRegularExpression.enumerateMatches` intact behind an internal enumeration adapter accepting text/options/range and the normal result/flags/stop callback. A test adapter emits scripted Foundation result/flag sequences. Tests must drive public `matches` and `replacing` through that adapter, verifying: nil-result internal error; a valid early match then completion+internalError; internalError attached to a result; ordinary completed/hitEnd/requiredEnd success; and preservation of an earlier cancellation/limit. Assert `.engineFailure` and no successful partial replacement. Also assert the adapter receives `.reportCompletion`; a reducer-only test would miss the option omission. Use a real benign Foundation enumeration control and existing semantic tests. Synthetic flag injection proves propagation, not real ICU exhaustion. A future real-engine exhaustion regression must live behind an outer process watchdog.

For folder propagation, an internal search-executor parameter defaulting to the production adapter can supply an engine failure on the second synthetic file after one earlier hit; assert the entire request fails and exposes no complete report. No AppDelegate/controller ownership refactor is required for this fix.

## Smallest architecture for enforced regex termination — proposed, not implemented

Retain Foundation and the current `SearchService` semantics in a small bundled helper executable. Add a supervised async executor shared by document, folder, and future open-document coordinators. Compared with merely adding more callbacks, it can terminate a stuck engine; compared with changing regex engines/direct ICU bindings, it preserves the current dialect and minimizes semantic migration. Avoid expression rewriting, rejection heuristics, line/chunk subdivision, or a different linear-time engine as substitutes: these can change backreferences, lookarounds, anchors, zero-length advancement, or Unicode matching.

Proposed interfaces:

- `SearchExecutionRequest`: request/document IDs, immutable full-text snapshot, optional UTF-16 scope, query/options, operation (find or replace), replacement, explicit existing size/match/output caps, policy. Successful replace response contains both count/ranges and replacement from ONE enumeration.
- `SearchExecutionPolicy`: cooperative engine budget, parent deadline, cancellation/reap grace, maximum live helpers and queued snapshot bytes. Validate finite bounds. Use a monotonic clock injected into supervisor tests.
- `SearchExecuting.execute(request) async throws -> SearchExecutionResult`, with cancellation tied to request ownership. Typed outcomes distinguish malformed query, engine failure, timeout, cancellation, resource/protocol/helper failure. Partial responses cannot become success.

Keep the helper alive sequentially for a folder batch, with one request in flight; kill/recreate it on timeout/cancel/failure. Start with one live helper process across the application and bounded admission, retaining that slot until the prior child is reaped. The supervisor must stay outside the blocked engine/serialization actor and race launch/input transfer/output reception against its own timer; an async task group awaiting an uncooperative child task is insufficient. Only the helper compiles queries, including empty-text validation. Use a versioned length-prefixed bounded pipe protocol, stream input/output off MainActor, validate all lengths/ranges/IDs before allocation/publication, and pass documents through pipes rather than argv/logs/recovery files. No shell, network, arbitrary executable, or filesystem-writing authority is needed. The parent only signals its owned helper. Process separation alone is not an OS security sandbox or a proven RSS cap.

Candidate policy for review/testing: retain a one-second cooperative engine budget, add a two-second per-operation supervisor envelope covering launch/transfer/compile/match/replace/response, and initiate forced termination immediately on cancellation or envelope expiry. Target supervisor reaction within 50ms and observe child exit within 250ms on the supported reference host. These numbers are proposed acceptance targets, NOT measurements or real-time OS guarantees; if child exit cannot be confirmed, quarantine the slot, report failure, and avoid indefinitely blocking a UI caller. Test 100MB transport before adopting these defaults; do not silently shrink supported inputs. Folder/open-document orchestration should expose processed-file/document progress and per-item limits; a total batch deadline should be a separately documented policy, not reset silently at every file. Filesystem stalls outside the helper remain a separate cancellation limitation unless discovery/read operations are also supervised.

Future open-document inputs must be captured once per logical document with stable IDs and revision tokens, preserve dirty content and original UTF-16 coordinates, and reject stale delivery after edits/close/transfer. Each document is searched independently; concatenating documents changes regex semantics. This wiring is additional feature work and does not become implemented by adding the executor.

## Bounded synthetic acceptance plan

1. Run existing semantic tests plus direct-service/helper differential fixtures: literal metacharacters, escaped text/NUL, Unicode case/word boundaries, emoji/combining sequences, selection transparency, lookarounds, pattern backreferences, multiline/dot-all, zero-length EOF, optional captures, `$0`/numeric replacement and invalid templates. Assert exact UTF-16 ranges/output and current errors. State Foundation/ICU on the tested macOS version; never claim Boost/Windows parity or infer the installed ICU version from upstream docs.
2. Deterministic injected-clock supervisor tests for cancellation before launch, during upload, stalled compile/match, partial result delivery, replacement, and completion/deadline races. Assert exactly one terminal result, no late publication, capped live children and queue bytes. Include a fake helper that ignores graceful cancellation; prove escalation without needing ICU to misbehave.
3. Real owned-child integration under an OUTER independent watchdog: nonreading child, no-progress infinite compute, output flood, malformed/truncated/oversized frames, early exit, and ignored SIGTERM. Terminate/reap only test-owned processes. Record supervisor reaction and child-exit observations separately. If outer watchdog fires, fail explicitly and clean up; do not hang the runner or weaken the timeout assertion.
4. Run several small bounded adversarial regex fixtures (nested quantifiers, ambiguous alternation, failing backreferences/lookarounds) inside the helper. Accept semantic success only where expected; otherwise require typed timeout/engine failure. Include cancellation AFTER an entered-engine handshake. No adversarial invocation directly in the test runner.
5. Synthetic folder batch: easy first file, stalled/failed second file, later file. Assert failure/cancel yields no complete report, coherent progress, released helper after confirmed exit, no stale results after immediate restart, and no partial replacement. Inject discovery/read stalls separately so regex coverage is not mislabeled full filesystem coverage.
6. Hidden adapter tests with injected executor: cancel/restart/close/change root during search; verify old success/error/progress cannot alter current UI or invoke replacement. Keep actual physical keyboard, desktop responsiveness and packaged helper location/signing/launch tests outstanding until executed with allowed GUI access. Add package validation for the helper and its protocol/version; test relocation/offline launch, not just a SwiftPM executable path.

No new command is claimed proven. Existing command for the small status fix is `scripts/swift.sh test --filter SearchTests --scratch-path .build/search`; a new supervisor runner must first be implemented and then documented with actual results.

## Reviewed source fingerprints (SHA-256)

```text
833ffd1119242779f0cbbc10694000c2180eeb72165c72d79c2ba8a7b583c65e  Sources/PadCore/SearchService.swift
74a95e770adaaa8faccbd92ce19c908c254a6061fda7ed77bb548a6e36283060  Sources/PadCore/FolderSearch.swift
bc01751ad8ba0ffe3917b0d8b48feb9ec0bf6aa6dfba0c140b1dd128ee627c7c  Sources/TheOnlyPad/SearchPanelController.swift
551b8e8c2793852882e132f29e3d71fb7365eeae7d861bb8b13bac5cae449787  Sources/TheOnlyPad/FolderSearchController.swift
58c2b14ad81c9931d5d9497fc0db0828d1c698fa71194860983d2da78bdd23d4  Tests/PadCoreTests/SearchTests.swift
51a4b1af198cc8af6b14a75429b9cf1b492884721ff9c5041410cb3789fbb41d  Tests/PadCoreTests/FolderSearchTests.swift
```
