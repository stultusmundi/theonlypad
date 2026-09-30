# Cumulative wire-byte recycling prerequisite

Existing supervised-search specification requires healthy recycling after32
completed requests,512,000,000 input/output wire bytes, or10s idle. Existing
lifecycle already handles injected request count and idle policy, but not bytes.
The allocation gate must reach each boundary independently. Do not simulate byte
recycling with rejectedProtocol/cancel/shutdown, which changes failure semantics
or permanently closes the owner.

Three approaches reviewed locally:
1. Count wire bytes in lifecycle: requires a control-queue event per chunk and
   couples lifecycle to transport accounting it cannot independently observe.
2. Count in exclusive parent driver, ask lifecycle for honest idle retirement:
   preferred. The driver already exclusively owns one write/read stream; lifecycle
   remains sole process cleanup/admission authority.
3. Force failure/shutdown at threshold: rejected, as healthy accepted result and
   next admission would have incorrect semantics.

Proposed narrow lifecycle method:
`requestIdleRetirement(generation: UUID) async -> Bool` (internal).
Returntrue only after accepting stop for matching owned healthy generation with
NO active operation and an accepted handshake. Returnfalse for launching/absent/stale/stopping/reaped or
unconfirmed child, or any active operation (including reserved next generation).
True means stop requested, never reap/close confirmed. Use existing stop; retain
prior outcome. No extra timer, queue, public factory, arbitrary reason/error.

Driver takes explicit nonzero maximumWireBytesPerChild policy; no default or
active/retained memory-budget selection is introduced. GateA uses512,000,000 from
existing specification, unit tests use small limits. Count all request+response
stream bytes including wire headers and hello, once per successful whole write
and once per nonempty completed read. Do not count logical characters or attempted
failed writes. Partial failed write always retires connection already. Count is
saturating UInt64; subtraction-safe addition, no array of per-chunk records.
Old-generation/duplicate callback must not debit replacement counter. Driver's
exclusive one-write/one-read scopes establish exactly-once accounting.

Threshold crossing marks retirement pending monotonically; false retirement acceptance never authorizes reuse of that generation. it never interrupts active valid
request. After accepted terminal and parent upload/codec settlement, request idle
retirement. Arm the plan's sole idle read BEFORE requesting retirement; settle its actual result afterward. Never relabel a close-caused cancellation/error as EOF. None can replace accepted success/semantic result, and result delivery does not wait for reap or a replacement read. No next same-generation
request may be submitted between crossing and retirement; driver owns admission.
The later request waits/refuses while lifecycle owns cleanup, then receives a new
generation only after reap AND channel close. Reset counter only on new generation.

Lifecycle tests: healthy idle retirement preserving success and semantic terminal;
active refusal preserving request; held reap/close blocking replacement; stale and
launching refusal; repeated request no duplicate signal; reserved replacement
operation refused. Pure counter tests: before/equal/after threshold, headers both
directions, overflow saturation, generation reset/fence. Driver integration tests:
threshold crossed during upload/read does not cancel active request; terminal
accepted then retirement, preserved result, next fresh generation, close-held busy.
Actual GateA must separately observe byte boundary; deterministic tests cannot
establish allocator/RSS behavior. Independent review precedes implementation; implementation and actual boundary measurements remain separately recorded.

Independent source review approved this direction with the clarifications above.
Immediate result-observer resubmission and held read/reap must prove the monotonic
retirement gate. Count/idle/byte triggers may race but cannot double-signal.
This is a narrow amendment to the existing driver plan's recycle-policy exclusion:
implement accounting/explicit policy injection, not a new production memory budget.
