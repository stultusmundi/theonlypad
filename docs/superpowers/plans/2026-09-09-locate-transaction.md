# Explicit Locate transaction

Status: reviewed design; implementation and tests active in isolated candidates. No native Locate control is shipped yet. This implements the remaining external-file Locate requirement without changing saved-byte authority.

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
