# Explicit Locate transaction

Status: reviewed coordinator and bridge are integrated; native Locate control is implemented and actual hidden controller verification passed. Desktop acceptance remains outstanding. This implements the remaining external-file Locate requirement without changing saved-byte authority.

Use the existing process action lease and two shared-worker `checkOnce` jobs. Capture the source document's full bridge action context, original saved bytes, baseline revision and explicitly chosen candidate URL. Reject pending publication, recording, composition, closed/quit and busy contexts. Revalidate after the native chooser returns; a suggested moved path is only a chooser hint.

The first check requires exact saved-byte equality, a regular supported local target, metadata and no location problem. The second check uses the first candidate identity and requires exact bytes and full metadata equality again. A different-byte file, equal-byte inode replacement or parent retarget cannot redirect the document. All filesystem work stays in existing guarded workers; there is no candidate decode or new worker queue. Cancellation and request/operation/generation fencing follow the reviewed disk-action coordinator, including predicates that reenter.

Successful adoption changes URL/binding acknowledgement only. Preserve originalBytes, savedText, current/saved encoding and BOM, dirty text, pending-free disposition, undo, bookmarks, pane identities/selections/axis and focus. Notify MRU/session for the actual change. Do not use reload or create a new saved baseline from candidate bytes. Different bytes produce an actionable refusal; the user can separately open that file or use Save As.

The bridge gains an optional validated identity on baseline adoption. A supplied identity forces a fresh registration seeded through existing `register(boundIdentity:)`, rather than the ordinary rebind path that clears identity. Registration failure retains the identity for manual checks and retry. Ordinary nil-identity open/save/reload behavior stays covered by existing tests.

This is point-in-time validation, not a lock against external writers. The candidate parent identity must survive the gap before the first new observation, so a retarget reports conflict rather than silently establishing a new parent. Same-parent replacements remain normal external changes; existing safe-save expected-byte checks remain authoritative.

## Required evidence

1. Coordinator red–green tests: exact candidate, byte difference, equal-byte inode replacement, parent retarget, stale/duplicate/inline callbacks, close/quit/reentry, shared lease and cleanup.
2. Bridge red–green tests: supplied identity uses fresh registration; failure/manual/retry preserve it; no old-source identity import; default behavior compatibility.
3. Hidden actual controller tests: explicit chooser/captured tab, dirty text and undo preservation, two panes, pending refusal, second-change refusal, exact URL/baseline acknowledgement and MRU/session behavior.
4. Independent review, fresh core/native checks, then packaged desktop acceptance when GUI access is available. Hidden controller tests do not validate native picker interaction or physical accessibility.

Run commands are added only after the retained harnesses execute successfully. Existing baseline checks: `scripts/swift.sh test`, `scripts/test-file-state-bridge.sh <debug-bin>`, and `scripts/test-native-monitor-lifecycle.sh <debug-bin>`.


## Implemented components and evidence

The retained coordinator command `scripts/test-locate-coordinator.sh .build/native-monitor-integration/arm64-apple-macosx/debug` passed31 assertions in run.2FF7eITd after behavioral red run.gkqgB0Vq. Real service cases reject byte changes, equal-byte inode replacement and parent retarget between checks. Independent source review found no material issue; no decoding, writes or new worker queue is used.

The optional validated-identity bridge entry passed111 semantic +20 real-service +26 application checks in run.yHgc0QfP. Reds demonstrated accidental registration reuse and real post-validation parent replacement acceptance. Default nil adoption retains existing behavior; failure/manual/retry retain the supplied identity.

Native controller compilation49935 and the command-registry test passed. Root wired explicit chooser, exact captured context, source-preserving URL adoption and lifecycle cancellation. Independent source review found no material issue. Actual hidden controller tests remain the acceptance gate; an initial test incorrectly required replacing the bridge object rather than its registration. That test contract is being corrected to assert old registration cancellation, new epoch/revision/identity and matching observation; no product change is justified by the allocation assertion.


Final retained combined native run.r0rwjt2e passed all prior lifecycle/action and new Locate phases with no warnings. It proves Cancel/different-byte refusal, dirty text/saved-byte/encoding/bookmark/undo/pane/focus preservation, exact baseline acknowledgement, old registration cancellation/new identity, pending-publication exclusion, and one session plus one recent-file notification on actual adoption (zero on Cancel/refusal). The intentional chooser tab switch is measured separately from adoption notifications. The initial allocation-only assertion failure remains retained as run.ns2um9yt; no product change was made for it. Full core13575 passed328 tests in14.613seconds.

Real native chooser/accessibility/desktop interaction remains unverified. Two new desktop Reload/Copy workflows compile with build-for-testing but have not run; the real Locate chooser desktop test still needs implementation.
