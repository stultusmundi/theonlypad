# Exact incremental dirty candidate — design only

Status: independently reviewed design; fixed native contract probe passed on the current runtime (see ../../verification/storage-edit-range-contract.md). No optimized implementation, seeded proof testing or actual-controller performance acceptance yet. Unchanged controller baseline/work-bound red must precede implementation. Applying the brainstorming/design workflow to this bounded existing behavior; no production adoption is implied.

## API evidence and coordinate contract

Installed macOS SDK AppKit NSTextStorage.h lines51–74 says editedMask/editedRange/changeInLength describe pending edits, including outstanding beginEditing calls; editedRange is NSNotFound when no changes. The argument supplied to edited(_:range:changeInLength:) is PRE-edit. processEditing runs notifications/fixing/layout propagation after edits. The observer already used by EditorDocument runs on didProcessEditing; no custom text-storage subclass is needed.

Apple's method documentation distinguishes pre-edit input from accumulated query properties describing post-edit extent: https://developer.apple.com/documentation/appkit/nstextstorage/edited(_:range:changeinlength:). changeInLength is accumulated across a batch: https://developer.apple.com/documentation/appkit/nstextstorage/changeinlength. Do not interpret net delta zero as proof every constituent operation preserved length. The SDK's NSLayoutManager observing protocol explicitly calls its range final-string coordinates; it is not a reason to silently substitute layout invalidation range for storage character edits.

This design only uses both interval endpoints for final aggregate delta zero, where pre/post total coordinates coincide. For any nonzero delta it trusts only a validated earliest affected location and abandons suffix equality. The first native probe must record property values for insertion/deletion/replacement, nested batches and cancelling deltas, then assert the unchanged-complement property against before/after text. If coordinate behavior violates the claimed bounds, reject optimization for that case and keep the whole exact fallback.

## Representation and invariant

Keep savedText immutable and savedUTF16Length as today. Replace the unconditional text-cache invalidation strategy with a small proof state in addition to cachedTextDirty:

* aligned interval [low, high): current length equals baseline length, and EVERY UTF16 unit outside interval equals savedText at the same index.
* suffix from low: units before low equal baseline at identical indices; no equality assertion at/after low, and lengths may differ.
* unknown: no equality proof (equivalent to suffix from zero).

An empty aligned interval proves exact text equality. A nonempty interval does NOT itself prove dirty; query compares it exactly. No hashes, Unicode canonical equality, timers, revision/undo-position assumptions or deferred false-clean answers. Memory overhead is O(1) bounds and fixed-size comparison scratch buffers; retain no new document snapshot. Baseline setter starts unknown, even when caller says save succeeded. A subsequent full equality check can establish empty interval; never infer equality from matching length alone.

## Character notification transition

Run transition before any callback capable of querying dirty. Cache invalidated, editRevision/highlighter/recovery behavior preserved.

1. Ignore attribute-only notifications for text proof. Mixed masks use character path.
2. Reject NSNotFound, negative/overflowing/out-of-bounds range or inconsistent previousLength + delta == currentLength arithmetic: proof unknown. Track prior processed length only for validation; never as equality evidence.
3. If pending-query/reentrancy poison is set, keep unknown for this transaction; do not clear poison in that notification. A getter may execute AFTER this observer while editedMask still describes the same transaction. Poison survives notifications and clears only on a later getter with no pending character mask, after a full exact comparison against the current baseline. No partial-cache reuse.
4. For delta==0 and aligned proof, union the old uncertain interval with the storage aggregate editedRange. Outside that union, previous equality and the edit extent guarantee no changed units. Treat empty as mathematical empty, not an interval with endpoints at zero: empty union [a,b) is [a,b), never [0,b). Multiple sequential zero-delta notifications union idempotently. Net-zero insert/delete inside one batch is safe ONLY if the measured/documented aggregate range encloses their resulting changes; retained fixtures test both operation orders and disjoint positions.
5. For delta!=0, reduce to suffix(min(previous proof low, editedRange.location)); unknown stays unknown. This deliberately abandons all suffix alignment, including previous high. Deletions ending at EOF and empty final range are valid. Edits with aligned empty proof use the new edit location, not zero. This is essential to avoid making every clean EOF append a whole-suffix fallback.
6. If proof is already suffix, subsequent edits retain suffix(min(old low,new location)), regardless of delta. At equal lengths, exact suffix comparison can prove clean. At unequal lengths, text is immediately dirty but proof remains available for later undo/restoration.

The proof is induction over the unchanged prefix/complement, independent of editing intent, native undo target or focus. Deliberate whole-string assignments produce a whole range, so are correct but not fast. AppKit remains the text and undo engine.

## Getter, unfinished batches, callbacks and baseline changes

Metadata/pendingPublication semantics remain independent and unchanged: pending publication is dirty until resolved; encoding/BOM mismatch is dirty even with equal text. Proof bookkeeping must still observe character edits while metadata is dirty; don't clear a suspect interval merely because metadata already made the overall answer true.

At a query with storage.editedMask containing editedCharacters, conservatively compare current storage against baseline using CURRENT length/full exact comparator, never a cached result or narrowed interval. Mark proof unknown/poisoned before returning, including when metadata short-circuits. A getter after our didProcess observer can set poison for the transaction that is already being delivered. Therefore NO notification clears poison; only a stable (no pending mask) getter which completes a full exact comparison may clear it. Metadata-short-circuited getters leave poison set until that text comparison occurs. Do not advance processed-length state or reset proof clean during this transient query. Repeated reads/mutations within nested beginEditing are therefore exact regardless of whether the same pending range tuple recurs. Normal post-process reads can reuse cache; a test must establish that ordinary textDidChange refresh sees cleared editedMask, otherwise this fallback would erase the expected benefit without breaking correctness.

When no edits pending: mismatch length returns dirty; equal length compares only valid suspect interval/suffix (unknown compares full). Exact equality clears proof to empty aligned interval and caches clean. Inequality retains the conservative interval and caches dirty. Comparing the whole suspect region after undo to saved text proves clean; no undo-stack token is treated as identity. Attribute-only edits can preserve proof/cache.

savedText didSet (open, reload, successful save baseline adoption) resets proof to unknown and cached text result nil, updates baseline length. If assignment occurs during outstanding edits, poison remains until conservative processing. Saved text may equal current or an older immutable save snapshot: first exact query determines it. Encoding/BOM baseline updates don't manufacture text equality. A failed or uncertain save never adopts attempted savedText; existing pendingPublication wrapper remains authoritative. Clearing pendingPublication only unmasks the independently maintained text result.

## Exact range comparison

Use bounded native UTF16 reads on the storage NSMutableString facade and saved NSString bridge, compare code units exactly. No Array(text.utf16), whole substring copies or canonical compare. A fixed chunk buffer (e.g.4K UInt16 units per side) limits scratch memory; any optimized native literal-range API must first pass the same oracle fixtures. UTF16 code-unit equality is correct even if an editedRange touches a surrogate boundary because no text replacement or slicing into Swift Characters is performed. The test generator still uses valid scalar edit boundaries for actual user text, plus existing programmatic Unicode regressions. Native bridge materialization and chunk overhead must be measured; no speed claim follows from this design alone.

## Alternatives and review boundary

A single convex interval can grow across widely separated edits, causing conservative large scans. Prefer this simple exact state over a range tree initially. A bounded interval set may be a future optimization, not needed for first EOF regression. Always-full fallback is retained and unmodified as an oracle/control. A known-difference witness alone cannot prove restoration clean, and undo revision flags cannot capture direct storage changes; neither is proposed.

No tracked source changes until root reviews this proof and native aggregate-range probe is green. Tests must show unoptimized actual-controller work scales with full buffer (meaningful red) before candidate timing. Any ambiguous notification sequence takes unknown/full rather than weakening dirty equivalence.

## Callback evidence limit

Current onCharactersChanged callback schedules checkpoint state/widgets without an explicit dirty read. Whether AppKit or other observers reenter dirty during this phase is unmeasured. The conservative poison fallback is a correctness guard, not an established frequent path or performance benefit. The probe intentionally queries both before and after the document observer to validate behavior without claiming current app callbacks do so.
