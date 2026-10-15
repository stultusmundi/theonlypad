# Bounded CI failure diagnostics

The first hosted macOS core-test step failed in runs 38744925024 and
38745131627. The owned watchdog retained its inner output, but that output was
not exposed in the job log. The cause is still unknown. This change adds a Swift
version step and a conditional diagnostic without changing the core test command
or turning its failure into success.

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

Raw evidence remains ignored locally. The next hosted run must establish the
actual core failure before a corrective application change is made.
