# Clean closed-document history claims

## Scope and status

The view-free registry owns retained clean history and provides opaque claims for a fresh-ID replacement. Implementation and isolated tests are present; independent review and native intake/controller integration remain separate. This does not implement the Reopen Closed Tab UI or promise native teardown preserves history yet.

The existing ten-entry per-window history cap remains. Successful clean close stores the source handle, immutable original document UUID, metadata, and exact confirmed close state. The source UUID stays retired for the registry lifetime. Eviction and consumption release the registry's object identity reservation, but a claim strongly retains its source for process-owned work. A retained object does not remain authorized after eviction.

## API

- `peekHistory(windowID:replacementID:)` returns the newest actual entry or nil. The requested replacement UUID must be unreserved at claim creation. The claim privately binds registry, entry, source object, original UUID, exact state/metadata and requested replacement UUID.
- `validateHistory(_:)` checks the exact retained entry and current clean source state. Unrelated history additions or workspace revisions do not invalidate a still-retained entry. Foreign, consumed, evicted, removed-window, changed-ID or changed-state claims refuse.
- `withHistorySource(_:read:)` supports synchronous immutable native seed capture, validating before and after the callback under the registry's read-only mutation exclusion. The callback must not mutate the source; any observed semantic mutation refuses its result.
- `consumeHistory(_:replacementID:)` requires the exact prebound replacement UUID, a different model already registered and active, no close lease, and the original source window. It removes the exact history entry before notification. Replay refuses. The old UUID remains reserved.

Claims are provenance, not an exclusive reservation or an adoption receipt. Process intake must serialize accepted work and retain post-registration failures. It must never unregister an already-adopted replacement because its source history was subsequently evicted. A second claim does not authorize consumption after the first has consumed the entry. No filesystem work or recovery publication occurs in these methods.

## Native integration obligation

Presentation teardown after a clean close must not invalidate the retained semantic state merely by detaching panes or projecting their removal. Current model pane hooks are incomplete, so this is not yet proven in the actual controller. If later pane hooks rotate semantic state during teardown, integrate an immutable history seed or an exact, validated post-projection settlement. Never blindly refresh a claim from a mutated source. Real native close → teardown → reopen must test preserved bytes, encoding, bookmarks, views and fresh recovery identity before claiming end-to-end completion.

## Evidence

Run `scripts/test-document-history.sh`. The runner freezes actual PadCore, registry, recovery actor and all 41 existing registry tests alongside the new history tests in a private package, hashes inputs and propagates an independent 180-second watchdog failure. It uses synthetic handles/files; no windows, native input or application activation.

Initial compiling API refusal seam: private run.QGFvqupF, 46 tests with ten workflow failures; 41 existing tests passed. First implementation: run.0zZQYaIS, 46 passed. Added changed-source-UUID regression: run.8ws4jewG, 47 tests with one expected assertion failure. The fix stores the original UUID at close, independently of the mutable protocol handle. Final formatted source: run.cUmfaeJ5, all 49 tests passed (41 unchanged registry tests and eight focused history tests), strict Swift lint passed. No native acceptance is inferred from them.
