# Bounded CI failure diagnostics

The first hosted macOS core-test step failed in runs 38744925024 and
38745131627. The owned watchdog retained its inner output, but that output was
not exposed in the job log. The diagnostic added at `88d4917` subsequently
identified compiler failures before XCTest in run
[38758075131](https://github.com/stultusmundi/theonlypad/actions/runs/38758075131).
The Swift version step reports Swift 6.1.2. The original core test command and
failure outcome remain unchanged.

`scripts/ci_owned_failure_diagnostics.py` reads only the fixed core watchdog
receipt and two bounded captures. It prints closed numeric summaries, category
counts and at most four verified tracked `Sources/` or `Tests/` locations. It
does not print raw logs, commands, test names, exception descriptions or absolute
paths. A report has at most ten lines and 2048 ASCII bytes, including its final
newline. Diagnostic success means an observation was produced, not that tests
passed. Missing or unsafe evidence produces a fixed unavailable reason.

Reads reject symlinks, FIFOs, unowned files, changed metadata, malformed JSON,
invalid types, inconsistent capture counts and oversized evidence. Locations
require exact tracked-file membership and owned nonsymlink files. The optional
fixed read-only Git query has a three-second query deadline and bounded output;
its additional kill/wait cleanup is best effort, not a guaranteed reap or a hard
three-second bound for the entire operation. No new dependency or action is
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
