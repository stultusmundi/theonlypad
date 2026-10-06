# Joined parent shutdown

Scope: one additive package API on the concrete parent wire driver. This is an
ownership prerequisite for supervised search; it grants no cold measurement or
user-facing search acceptance. Independent review replaces routine human approval
under the build prompt.

`shutdownJoined(after:)` returns either a compact committed completion or a
caller refusal. The existing driving protocol remains unchanged. Completion
contains the original child shutdown result, first-entry ownership disposition
and lane-stop disposition. Its constructor stays internal to SearchExecution.

## Ownership and ordering

The actor selects unused, legacy-started or joined-started mode synchronously.
Legacy-first permanently refuses joined mode. Joined-first owns one retained
uncancelled task; later matching joined calls, legacy shutdown and abandonment
join it without issuing another child shutdown. Later mismatched handles refuse
without changing the owner. Legacy-only snapshot behavior remains intact.

First-entry ownership priority is abandoned, stale handle, existing observer,
active request, unconsumed receipt, then admitted. Nil matches only a never-admitted
driver. Refusal remains latched while diagnostic cleanup proceeds. Submission is
closed, the upload bridge closed and the session marked retiring before owner task
creation or suspension.

The owner retains its sole child invocation result unchanged. It joins mechanical
readiness (`operation`, `session`, lane owner and upload bridge absent) using a
dedicated actor continuation, then requests and awaits the existing codec-lane stop
once. Predicate check and wait installation share an actor turn; actual retirement
transitions wake it. Observer and payload receipt state are excluded from that
mechanical predicate. Lane failure remains a typed failure with conservative
parent-settlement fields. Identity and readiness are checked before committing.

Cancellation of a caller never cancels the retained owner. Joined abandonment
preserves an installed observer's existing claim/cancellation arbitration before
discarding unclaimed remainder and rejects later observer registration. Source
and external result release remain the caller's independent obligations.

## Validation and limits

Keep every existing driver test. Add ordinary mode/admission tests and frozen-only
holds for owner startup, reader exit, codec body/completion return/lane loop, close
acknowledgment and consuming reap. Preserve original pending child evidence after
later cleanup. Exercise observer delivery/cancellation and failed-lane normalization.
Exact mutants must fail assertions with finite fixture rescue and complete owned
watchdog receipts. A timeout is incomplete evidence.

No new timer, signal, reaper, process query or polling is added. Test transforms
apply only to frozen copies, require unique anchors and are checked against pinned
originals. Actual helper processes, allocation release, memory budgets, finalizer,
packaging and editor routing remain separate acceptance gates.
