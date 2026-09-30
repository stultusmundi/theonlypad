# Search text allocation preflight — reviewed design

Status: independently reviewed experimental design; allocation measurements and sink selection remain outstanding. Wire, lifecycle and worker-runtime components are implemented; the parent driver is implemented and independently verified; editor routing remains outstanding. The reservation formula rejects the earlier640MB active candidate without adopting a replacement budget. The original source-cost analysis used SearchService at28e2a9f; implementation must recheck current sources and record exact bindings. The September30 clarification below distinguishes measurable capacities from opaque framework storage.

## Concrete source costs to measure

SearchService.buildReplacement explicitly bridges original text to NSString, creates Foundation substrings for unmatched spans/captures, and appends into a growing Swift String. The one-enumeration result also retains NSTextCheckingResult objects and maps full ranges into an array. Merely streaming wire bytes does not remove these simultaneous allocations. Zero-match replacement can still construct a full-span substring/output. Do not change semantic code solely from estimated costs.

Parent holds original expected text for stale-result checks, a scalar-boundary bitset, bounded transport data and eventual replacement. Up to100M UTF16 units can occupy300MB UTF8 per String; original+output may600MB before capacity/bridges, arrays, allocator overhead or native storage. Helper owns its independent decoded input, regex bridge/checking results, replacement assembly and response chunks. Candidate640MB active and768MB retained ledgers are unmeasured; neither is total process RSS.

## Alternatives to compare before selecting sinks

1. Append each complete validated UTF8 scalar chunk into one String using a temporary bounded String. Minimal interface and no full Data, but growth peaks must be measured.
2. Reserve conservative3*expectedUTF16 capacity before appending. Reduces growth copies at the cost of waste for ASCII and uncertain Swift capacity/bridge behavior. Do not present reserveCapacity as strict allocator accounting.
3. A contiguous byte buffer followed by String decoding introduces a potentially full second copy; reject as default unless measurement and revised ledger justify it. Do not add a wire UTF8-count field or custom text engine merely to optimize a guessed cost.

## Bounded experiments and evidence

Use an isolated headless executable under the checked-in owned-child watchdog once available; benign patterns only. Fixtures: ASCII, three-byte BMP, supplementary pairs, decomposed combining sequences;1MB/10MB/100MB encoded file equivalents and the admitted100M-unit ceiling separately labeled. Do not call the latter100MB when its encoding is300MB. Include find/no matches, zero-match replace, many distributed matches up to existing caps, captured replacement near output cap and output-limit rejection. Fixed expected counts/hash or byte/unit equality must prevent a benchmark from silently dropping work.

Record source/toolchain/OS/architecture, exact bytes and UTF16 units, at least repeated fresh processes, monotonic stage timings, RSS/high-water observations, termination/reap outcomes, errors and source hashes. Stages: initial fixture loaded, decode started/finished, explicit String/NSString bridge, match result materialized, replacement assembled, response body drained, heavy scope exited/autorelease pool drained, terminal sent, retained parent result released. RSS is an observed process metric, not a proof of every allocation or a universal upper bound. No physical GUI latency or1GB editing claim. Raw logs private; sanitized aggregates public.

Use native system-supported measurement APIs after verifying actual SDK availability; do not fabricate counters. Keep measurement instrumentation out of protocol v1: the production wire forbids extra progress frames. A dedicated test harness can own stage observation without changing the production ABI. Keep process watchdog/control independent from instrumentation and codec work.

## Ownership accounting gates

Define exact credit transitions only after concrete sink choice. All retained data must have one ledger owner; transition active→retained atomically before publishing output. Cancelled queued work must hold metadata only; cancellation of active work retains its slot/credits until parent lanes actually quiesce and child is reaped. A timeout result does not imply memory was reclaimed. Bound queue metadata, input snapshot, bridge temporaries, output capacity, bitset and range arrays separately; document native text storage and helper-process RSS outside any narrower payload ledger.

Before routing: choose conservative supported-budget values using measurements, reserve before expensive snapshot/decoding, prove refusal leaves existing documents/results untouched, and cover lease cancellation/double-release/late-completion with deterministic tests. If a candidate budget fails supported100MB inputs, revise budget/implementation openly; do not silently lower scope. An OS-level memory-hard-limit claim requires its own verified mechanism and is not supplied by estimates.

## Subsequent implementation plan required

After wire completion, split sink implementation/fixtures, benign helper engine driver integration, measured allocation experiments and parent reservation/publication into executable tasks with frozen interfaces. Process lifecycle owns launch/reap; memory work cannot introduce a competing child owner. Native UI snapshots/results and folder read-lane admission remain later integrations. Independent review approved the corrected preflight below. A reviewed executable task handoff and actual measurements are still required before production adoption.


## Review corrections — proposed experiment contract

The primary experiment is a real parent using the reviewed writer/reader and each candidate sink through the owned lifecycle connection to the actual helper, with exact parent PID, child PID and generation. Record parent/helper baselines and timestamped RSS samples plus separate OS high-water observations. Report sampled simultaneous combined peak explicitly as sampled, not a sum of independently timed maxima. Single-process microprobes are supporting diagnostics only. Native storage remains a separate later experiment.

The parent owns one incrementally constructed source String. Release fixture construction chunks before measured encoding; helper constructs input only from wire sink. Never retain whole expected output, wire Data or callback arrays for convenience. Validate streaming output against fixed unit/count assertions and independently precomputed fixture digests, with bounded hashing state. Any harness-only live copy must be separately itemized and disqualifies a comparison unless identical and charged in every candidate.

Run identical fixture matrices in at least three fresh processes and warm same-child sequences across32-request,512,000,000-wire-byte and idle recycle boundaries (each boundary separately reachable). Include healthy semantic failures as well as high-capture find, zero-match replacement and large successful output. Observe request start, heavy-scope exit, terminal/ready, idle recycle, exact reap and replacement launch. Do not infer returned allocator pages from released logical objects.

Freeze explicit semantic limits per fixture; never rely on SearchService defaults. Test100,000,000 input/output units where applicable, maxMatches100,000, and the existing aggregate1,000,000 retained capture-range cap. Include high-count/no-capture and near-cap many-group cases with both matched and unmatched groups; fixed expected match/group counts prevent cheaper early refusal masquerading as coverage. Use benign deterministic patterns within4,096 units. Report timeout policy separately: diagnostic allocation runs with larger finite budgets cannot establish success under candidate production deadlines.

Observe regex construction, checking-result retention, replacement assembly and public range mapping overlap. Where exact internal phase timing is unavailable, label it unobserved and retain explicit conservative overlap charges from source review. Any new internal phase hook requires a separately reviewed source task, emits only bounded numeric metadata and must not retain strings/results. Compare instrumented diagnostics with an uninstrumented control; do not fabricate production stage receipts from a transformed duplicate implementation. No extra v1 protocol messages.

### Parent ownership table

| Resource | Owner | Release/transfer predicate |
| --- | --- | --- |
| Queued bounded query metadata | admission job | removed/refused/cancelled before capture; no source snapshot retained |
| Captured expected source | active reservation | every parent lane retaining it quiesced; success atomically transfers its charge to retained result |
| Encoder, bitset, current chunks | codec reservation | actual codec/I/O completion and all callbacks returned; cancel request alone is insufficient |
| Partial ranges/output builder | response reservation | poisoned/error sink discarded and its lane quiesced, or exact successful terminal atomically transfers completed result |
| Prior consumer result | retained lease | explicit release, or successful new-job capture/admission transaction; failed reservation/capture preserves old result and credit |
| Child decoded input/regex/bridge/results/output | child request scope, separately observed | healthy success/error leaves heavy scope and drains its pool before terminal; on fatal paths exact child reap/channel closure ends process ownership |

A new capture must be affordable while the prior result remains retained. If not, refuse without discarding it. On successful capture/admission, retire prior result/credit atomically and publish new-job ownership; queue insertion alone is not that transaction. This refines the earlier phrase 'next search starts'. It does not authorize stale UI navigation or bypass native generation checks.

Local admission refusal has no active payload to release. Healthy semantic failure (including after partial replacement) uses validated error terminal after helper scope exit, followed by parent sink discard/quiescence. Success requires complete validated terminal plus atomic active-to-retained credit transfer. Protocol/sink poison, cancellation, deadline, launch failure, unexpected exit and shutdown cannot use the healthy-terminal shortcut: preserve parent credits until every retaining lane is quiescent, and retain the child physical slot until exact reap plus channel close. Pending launch remains owned even without PID.

### Candidate selection rules

Define N=input UTF16 ceiling, M=output UTF16 ceiling, R=max match count. For comparison reserve parent source payload3N, output work capacity6M (two worst-case UTF8 copies during growth), bitset ceil((N+1)/8), range payload16R, six bounded65,568-byte parent transport/codec staging credits, and1MiB bounded metadata. Add25% explicit reservation headroom. Retained-result candidate reserves3N+3M+16R+1MiB, also with25% headroom. These are conservative logical reservation proposals, not proven allocator/RSS bounds; opaque String/Array capacities and framework objects must still be observed and any additional owned live copy charged separately. Helper costs are measured separately and do not fit into the parent ledger.

This formula already exceeds the earlier640MB active candidate at maximum N/M; that candidate is therefore not adopted. Do not reduce100M-unit support to force it to fit. Experiments may use an explicitly larger provisional parent reservation to observe the full supported matrix; choose the eventual ledger only after measurements and review.768MB retained remains a candidate, not a conclusion.

A sink is eligible only if every supported fixture completes under the separately stated policy, exact output validates, no full-size intermediate is uncharged, and ownership tests show no lease leak/double release on every terminal path. Compare equal cases/repetitions; choose the lowest conservative charged peak among eligible candidates, using wall-time as the tie-breaker. Additional String growth copies invalidate the formula and require revision, not silent absorption into sampled RSS. If no sink qualifies, revise implementation/budget in reviewed records and repeat affected cases. RSS/combined peak and warm retention inform operational suitability/recycle policy but never become exact ledger credits. Production routing remains gated until those decisions are made.


## Parent codec staging correction — 2026-09-10

Reviewed [parent-driver plan](../plans/2026-09-10-search-parent-wire-driver.md) accounts for request chunks retained during writes, bounded read staging, copied and retained frame payload capacity, range callback temporaries, and both emitted UTF-8 and next reserved decoder output buffers. Its phase ledger raises the provisional fixed term from four to six65,568-byte credits (393,408 bytes). Candidate accumulator growth and any additional observed copies remain separately chargeable. Helper costs remain outside this parent ledger.

At N=M=100,000,000 and R=100,000, the corrected arithmetic is915,541,985 active logical bytes, or1,144,427,482 after ceiling25% headroom. This is arithmetic over an unmeasured proposal, not an adopted budget or RSS result. The correction does not change supported input limits or the rejected status of the640MB candidate. Gate A must verify actual capacities and ownership; increase the formula if the implementation has further live copies.

## Measurement clarification — 2026-09-30

Independent review distinguishes measurable explicit capacities from opaque framework storage. Record requested and owned byte-buffer capacities, observable array capacities, and source-reviewed simultaneous String/NSString representations and overlap. Swift String spare capacity and transient allocator bookkeeping are not exposed by the selected APIs; label them unknown rather than inventing exact values or inspecting borrowed interior pointers with allocator APIs. Native RSS, high-water observations and optional allocation traces test operational suitability; they never provide exact ledger credits or an OS-enforced memory bound. The two-copy output term remains a hypothesis. Any known additional full copy requires a revised ledger, and unresolved uncertainty stays visible in the selection record. This clarification permits bounded experiments; it does not select a sink or budget, or waive supported-size and ownership acceptance.

Compare helper candidates with one fixed parent candidate, then parent candidates with one fixed helper candidate: A/A, B/A, C/A, A/B and A/C. Use equal supported fixtures and repetitions for each comparison. Run the complete cold/warm matrix and uninstrumented controls for the selected pair; repeat affected comparisons if that pairing changes eligibility or charged ownership. A mandatory nine-pair Cartesian matrix is not required for independent sink selection.

The first proposed composition pilot is a 1 MB supplementary-Unicode zero-match replacement over the actual parent driver, lifecycle and worker program, within the existing 60-second per-operation diagnostic ceiling. It is not allocator selection or large-file acceptance. A successful driver `wait` consumes its receipt: release the external outcome afterwards; `discard` applies only to an unconsumed retained receipt. The first actual parent/helper pilot passed on September30; see [pilot evidence](../../verification/search-allocation-pilot.md). Five self samples per role do not establish paired peak or candidate selection. The subsequent benign owned-child counter test and one actual-helper paired-sampling run also passed; see the pilot evidence for exact scope, testing-enabled build provenance and unavailable shutdown samples. Repeated full-size comparison, full phase coverage and sink/budget selection remain outstanding.
