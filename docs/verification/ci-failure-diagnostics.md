# Bounded CI failure diagnostics

The first hosted macOS core-test step failed in runs 38744925024 and
38745131627. The owned watchdog retained its inner output, but that output was
not exposed in the job log. The diagnostic added at `88d4917` subsequently
identified compiler failures before XCTest in run
[38758075131](https://github.com/stultusmundi/theonlypad/actions/runs/38758075131).
The Swift version step reports Swift 6.1.2. The original core test command and
failure outcome remain unchanged.

`scripts/ci_owned_failure_diagnostics.py` reads the fixed core watchdog receipt
and two bounded captures. Strict mode may also query the tracked public roster
and read bounded owned Swift Test sources for an event observation; summary-only
mode omits those reads. It prints closed numeric summaries, category
counts and at most four verified tracked `Sources/` or `Tests/` locations. It
does not print raw logs, commands, test names, exception descriptions or absolute
paths. A report has at most ten lines and 2048 ASCII bytes, including its final
newline. Diagnostic success means an observation was produced, not that tests
passed. Missing or unsafe evidence produces a fixed unavailable reason.

Reads reject symlinks, FIFOs, unowned files, changed metadata, malformed JSON,
invalid types, inconsistent capture counts and oversized evidence. Locations
require exact tracked-file membership and owned nonsymlink files. The optional
fixed read-only Git query has a ten-second query deadline and bounded output;
its additional kill/wait cleanup is best effort, not a guaranteed reap or a hard
ten-second bound for the entire operation. No new dependency or action is
introduced, and workflow permissions remain `contents: read`.

The inert baseline produced ten ordinary failing test methods. A separate benign
Darwin-summary regression then failed one assertion against the first productive
candidate. Source review caught and retained an intermediate missing-function
defect before execution. The corrected source passed all thirteen unchanged
tests; independent actual review accepts that result (GO ab83975c). The public
import adapter was separately exercised in a frozen repository layout: thirteen
passed, zero failures or errors. The source module is unchanged from the reviewed
candidate, and all test class bodies are preserved.

The suite covers synthetic credential suppression, real temporary Git membership,
Darwin summary parsing, assertion totals exceeding method counts, unsafe evidence,
an 802817-byte repeated-prefix input, and an exact output-budget boundary. These
are finite contract checks, not a general performance benchmark, proof of Git
timeout cleanup, or evidence that hosted core tests now pass.

The workflow invokes the contract with its own direct watchdog:

```sh
env NSUnbufferedIO=YES python3 scripts/run-owned-search-tests.py --timeout 30 --output .local/ci-diagnostics-test -- python3 -B -m unittest discover -s Tests/CIDiagnostics -p 'test_*.py'
```

## Swift compiler compatibility follow-up

The hosted diagnostic identified four locations declaring `weak let`. That
feature was [implemented in Swift 6.3](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0481-weak-let.md).
A repository-wide source check found eight such declarations across five test
files: six in default search tests and two in Foundation integration tests.
There are no affected production declarations. Each now uses `weak let` with
`#if compiler(>=6.3)` and `weak var` on earlier compilers, preserving the original
initializer and all assertions, lifetime checks and cleanup. The modern branch
reconstructs the original source apart from directive indentation.

Local Swift 6.3.3 verification passed the actual app/helper build and all 1,203
default tests. Separate frozen Foundation packages passed twenty closing tests
and two transfer-publisher tests. Those packages use the existing wrappers'
exact source mappings and Package definitions, run directly under the owned
watchdog; the legacy wrappers themselves were not invoked. Full strict Swift
formatting passed. These are separate invocations with synthetic state, complete
captures and input checks, not visible-window tests or an older-toolchain result.
The unchanged lifetime assertions provide regression coverage; no new test
mirrors the conditional declarations.

Hosted Swift 6.1 verification of this patch remains pending. The observed
locations explain a concrete compiler incompatibility; they do not establish
that every reported compiler error or later CI step is resolved. Raw evidence
remains ignored locally.


## Explicit numeric fallback after roster refusal

The compatibility checkpoint `b543cf3` was pushed and read back exactly. Hosted
run [38763372775](https://github.com/stultusmundi/theonlypad/actions/runs/38763372775)
then failed at the core step with natural exit1 and no watchdog timeout or
truncation. Its diagnostic refused with `invalid-roster`. That reason does not
identify the new core failure or establish a Git timeout; no hosted compiler or
test pass is credited.

The conditional diagnostic now tries the unchanged strict mode first, then the
single explicit `--summary-only` option if strict diagnostics fail. This option
uses the same fixed evidence reader and closed numeric report with an empty
roster. It performs no Git query and emits no file locations. Unsafe or
inconsistent evidence still refuses. No arbitrary file, command, source or
filter argument is accepted. The original core command, failure outcome and
workflow permissions are unchanged.

The original thirteen tests remain intact. Two new methods first produced three
ordinary failing assertions, with zero errors; the corrected source then passed
all fifteen tests in the frozen layout and separately through public discovery.
The new checks exercise a real strict roster refusal, zero Git calls in summary
mode, numeric totals exceeding method counts, suppression of paths and synthetic
secrets, and independent symlink/capture-count refusals. An unexecuted fixture
cleanup defect was corrected before the recorded baseline; that candidate is
retained privately. These finite checks establish diagnostic behavior only. The
next hosted run must reveal the actual core outcome.


## Error locations before warning locations

Hosted run [38765750449](https://github.com/stultusmundi/theonlypad/actions/runs/38765750449)
at `a7e08d4` still failed the core step. Strict diagnostics succeeded with complete
captures; the summary-only fallback was unentered. Its last recognized XCTest
summary was five tests and zero failures, and its coarse `error:` category count
was one. Neither establishes a full-suite result or a compiler-specific cause.
The first four reported locations were Undo callbacks; the projection omitted
their severity and cannot identify the actual failing message.

The candidate scanner now prioritizes exact immediate `error:` severity before
its existing 32-candidate limit, preserving stable ordering and deduplication.
Warning or note message text containing `error:` receives no priority. All
tracked-file, descriptor, numeric and output-budget checks remain unchanged.
The implementation matches severity at the existing string position without
copying an unbounded suffix. It makes no general timing or memory claim.

Two added regressions first failed ordinary location-order assertions while all
fifteen prior tests passed. The reviewed correction passes all seventeen tests
in the private layout and separately through public discovery. They cover a
later error beyond forty warnings, repeated locations, exact severity, both
capture streams and an untracked error file. No raw message is exposed. Error
priority may reveal a later verified location; an error without an admissible
file location can still leave the cause unknown. A new hosted run is required.


## Bounded roster-query budget follow-up

Hosted run [38769088912](https://github.com/stultusmundi/theonlypad/actions/runs/38769088912)
at `6077fec` failed core again. Strict diagnostics refused `invalid-roster`;
the explicit numeric fallback succeeded with complete captures. Its last
recognized class summary was five tests and zero failures, with coarse
error-category count one. Error-priority location reporting was not reached,
and the actual core cause remains unknown.

The fixed read-only Git query budget increases from three to ten seconds.
Repeated roster refusals after roughly three to four seconds motivate this
bounded robustness adjustment, but do not prove a Git timeout caused either
roster refusal or core failure. The tradeoff is a longer possible wait before
numeric fallback. Output caps, closed environment, tracked-file validation,
unsafe-evidence refusals and the original failing core command are unchanged.
Kill/wait cleanup remains best effort; no guaranteed reap or whole-operation
ten-second limit is claimed.

All seventeen existing diagnostic tests pass against the exact private
candidate and separately through public discovery. Source review confirms
that only the query-budget constant changed. This is finite local regression
evidence, not a hosted pass or a fix for the unidentified core failure.


## Bounded XCTest event observations

Hosted run [38773116543](https://github.com/stultusmundi/theonlypad/actions/runs/38773116543)
at `1b6fc56` still failed core. Strict diagnostics succeeded and the numeric
fallback was unentered. The last recognized class summary remained five tests
with zero failures, with coarse error-category count one and the same four Undo
callback locations. This does not identify the cause or establish a full-suite
result. The longer roster-query budget does not prove a historical timeout.

The reporter now recognizes a closed ASCII XCTest event grammar within one
capture stream. It can report either a single paired failed terminal event with
no unfinished starts, or a single unfinished start with no failed terminals.
Both require an observed, waited, natural positive child exit and complete,
nontruncated captures without timeout, interruption or watchdog/wait failure.
Malformed, duplicate, ambiguous, cross-stream or over-limit events remain
`unknown`. An unfinished event is an observation at exit, not a diagnosis.

Only a unique method-shaped physical text line in the verified tracked Swift
Test roster can supply the relative source location. The output explicitly says
`source-text-candidate`: comments and string contents count, and no Swift lexer,
class association, compiled-test membership or failure-cause claim is made.
Raw event identities, messages and source text are never printed. One lazy,
verified roster supplies both identity and ordinary location checks. Explicit
summary-only mode still queries neither Git nor Swift sources.

The scan admits at most512 Test files,256KiB per file and8MiB aggregate source
content. Remaining aggregate allowance reaches the existing owned, no-follow,
stable reader before content reads. That reader can probe one overflow byte to
detect growth; this is not a strict total-I/O, allocation or RSS bound. Event
limits are8,192 records,4,096 distinct identities,64 active starts,4,096 bytes per
event record and128 bytes per identifier. Only LF separates records, and only
ASCII space/tab count as horizontal whitespace. Identity uses one of the four
location slots; the complete report remains at most ten ASCII lines and2,048
bytes including final newlines.

The original seventeen tests remain byte-exact. Sixteen added methods reached a
genuine baseline of ten failing methods and thirteen ordinary assertions, with
zero errors; all original seventeen passed. The reviewed productive candidate
then passed all33 methods under the owned watchdog with complete captures and
unchanged input identities. Tests cover positive and negative event grammar,
receipt eligibility, safe reads, source ambiguity, exact per-file and aggregate
limits, file-count limits, whitespace, shared location budgeting and summary
mode. The event/identity overflow case exercises the limits jointly; the
malformed overlong record does not isolate its byte cap. These are synthetic
local diagnostic contracts, not a hosted core pass. Separate public discovery also passes all33 methods with unchanged public
input identities and a complete owned-process receipt. A new hosted observation
is still required.

Contributor check (benign Python contracts only):

```sh
python3 -B -m unittest discover -s Tests/CIDiagnostics -p 'test_*.py'
```

## Hosted observation — 2026-10-16

Run [38861487152](https://github.com/stultusmundi/theonlypad/actions/runs/38861487152)
at development source `47d98d9` still fails core with natural SwiftPM exit1,
complete captures and no watchdog timeout. Strict diagnostics succeed and identify
a sole unfinished source-text candidate at
`Tests/PadCoreTests/FolderReplacementPreviewTests.swift:102`, the admission/budget
test. This is an observed event horizon, not a compiled declaration, root cause
or descendant-signal diagnosis. The downstream diagnostic contracts and native
checks were skipped after core failure; no hosted passing test suite is claimed.

The same method passes locally in the full default suite. A bounded same-method
phase trace is undergoing test review before implementation. No constructor or
production behavior is changed on this observation alone.

## Same-method phase diagnostic — 2026-10-16

The repeated hosted failure at development source `5a1cd57` is retained in
[run38866824760](https://github.com/stultusmundi/theonlypad/actions/runs/38866824760).
It still supplies only the unfinished admission/budget test candidate. The new
failure-only workflow step uses:

```sh
python3 -B scripts/ci_folder_preview_trace.py
```

This fixed command freezes current sources, tests, examples and required tools
into ignored synthetic state. It inserts exactly ten constant writes into the
frozen admission/budget test: fixture entry, the invalid-limits loop, the long
URL constructor, the NUL URL constructor and the remaining request/budget work
through fixture cleanup. Removing the ten statements reconstructs the complete
original test. Existing calls, assertions and public Swift source remain unchanged.
One direct600-second owned watchdog runs the exact selected test; do not nest
another session-owning watchdog around this command.

The first local actual run passes the Swift test but reports unavailable. SwiftPM
forwards all ten stderr writes into its owned stdout, exposing an incorrect
decoder premise. That run remains retained. Two ordinary contract failures then
reproduce the missing route with no test errors. The reviewed correction accepts
one ordered prefix from either single owned stream and refuses markers split
across both. All record grammar, ordering, capture, source and privacy checks
remain active. The six updated contracts pass; separate public discovery passes
all39, preserving the previous33. These pure tests substitute only the child
boundary and do not establish hosted behavior.

The corrected command now also completes one actual local Swift test under its
own watchdog with natural exit zero. All ten markers arrive in order on owned
stdout; the output reports phase4/end and all intervals ended. The saved result
retains557 original and558 copied input facts, input authority, command and full
capture facts. The console prints only three closed numeric/enum lines. This
validates the local diagnostic path, not the hosted cause, a selected-test OS
signal, complete application build provenance or performance. Independent final
audit accepts these separate scopes. The original core CI command and its failure remain
unchanged; the new conditional step cannot turn a failing core run into success.

Raw synthetic captures remain ignored under `.local/ci-folder-preview-trace/`.
A hosted phase result must be inspected before changing any URL constructor or
production validation behavior.

## Hosted phase observation — 2026-10-16

Run [38872057688](https://github.com/stultusmundi/theonlypad/actions/runs/38872057688)
at `e40142e` still fails the original core step. The separate failure-only
instrumented selection reports nine ordered markers: phases0–3 complete, then
phase4 begins without its end marker. SwiftPM exits naturally with1; the selected
test's signal is unavailable. The diagnostic step succeeds as an observation,
not as a test pass. Later normal workflow steps are skipped.

Both long-path and NUL URL constructors returned before phase4. The remaining
interval includes request preflight, exact/rejected budgets, Unicode boundary
checks, the synthetic large-file mutation and fixture verification/cleanup. No
individual operation is identified as the cause. The accepted local retake
reaches all ten markers; it does not resolve this hosted failure. Preserve all
assertions and the original core failure when adding narrower observation.

## Finer request and cleanup observation — 2026-10-16

Run [38874745958](https://github.com/stultusmundi/theonlypad/actions/runs/38874745958)
at `be6ec6f` reproduces the same nine-marker phase4 interruption and natural
SwiftPM exit1. No individual operation or selected-test signal is identified.

The next fixed projection keeps the same original test and selector. It adds20
literal marker statements to its frozen copy and emits42 records: phases0–3
retain their original boundaries; phase4 constructs requests; phase5 brackets
each of twelve requests and its zero-I/O assertions; phase6 covers budgets and
zero matches; phase7 covers Unicode boundaries; phase8 covers synthetic mutation
and source-limit refusal; phase9 covers fixture verification/cleanup. Its final
marker follows the actual withFixture return. Repeated phase5 pairs provide
ordinal progress under an exact source guard, not distinct request identities.
The complete request array and loop are bound before relying on twelve pairs.
Removing the20 statements reconstructs every original byte. No production
validation, test assertion or original core-step failure is changed.

The unchanged nine contracts first expose12 ordinary failure entries with zero
errors against the earlier ten-marker script; two inherited methods pass.
After the reviewed narrow implementation, all nine pass. Public diagnostic
discovery separately passes42 checks (the previous33 plus the updated nine).
One actual local selected Swift test passes with all42 ordered records and
phase9 end;565 original/566 copied facts and the original captured authority
remain matched, with complete natural zero-exit owned receipt/captures. These
are separate scopes, not additive totals or a full application test run.

Closed output stays within512 ASCII bytes. Single-stream, malformed-prefix,
source-drift, receipt/capture/custody and split-stream refusal checks remain
active. The accepted watchdog/verifier are unchanged. Do not nest this command
under another session-owning watchdog. The finer hosted observation is recorded below; local success alone does not
establish its cause, child signal, compiler artifact graph, desktop behavior
or performance acceptance. Earlier ten-record results
remain historical and are not relabeled as42-record runs.

## Finer hosted request observation — 2026-10-16

The reviewed finer diagnostic is published at `fa758e1`.
[Run38877082192](https://github.com/stultusmundi/theonlypad/actions/runs/38877082192)
still fails core and reports31 ordered records: phase5 entered without its end.
Under the exact twelve-case source binding, ten request pairs complete and the
eleventh NUL-containing request begins. The interval includes preview admission,
assertions and fixture preservation. Both URL constructors returned earlier.
This is ordinal progress, not an exact failing accessor or child-signal finding.

A reviewed serialized-path NUL guard and eight regression tests now pass the
local1,211-test suite. Older hosted verification of the guard remains pending;
see [preflight evidence](folder-preview-url-preflight.md). The core failure and
all original assertions remain unchanged. No hosted cause or pass is inferred.
