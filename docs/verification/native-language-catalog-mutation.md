# Native catalog mutation and recovery ownership

The standalone production catalog owner now admits validated draft application,
inspection, repair, pending-publication validation and exact retry. A failed
attempt retains its original intent; a confirmed discard performs a fresh read.
Display publication, write receipt, inspection and unresolved recovery identities
remain separate. Validation alone does not acknowledge publication. Application
startup, the manager, picker and native language propagation remain outstanding.

## Reproduction

```sh
scripts/test-native-language-catalog.sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p 'test_*.py'
```

The native command directly owns five watchdog stages. Do not wrap it in another
session-owning watchdog. It freezes the current Core sources, both catalog owner
sources, four retained test files and the synthetic catalog fixture. It builds
once, binds the compiler artifacts, then invokes the original fourteen read
tests and the new 31 mutation tests separately. A failed original selection
prevents the mutation selection. No SwiftPM command runs after artifact capture.
The default application test suite does not include these hidden native tests.

## Behavioral evidence

The inert mutation baseline preserved the fourteen read tests and failed all
31 new methods with 54 ordinary assertions and zero unexpected failures. Most
failures stopped at admission; later assertions were not credited as reached.
The productive owner and a separate formatted retake each pass fourteen read
and 31 mutation tests, with independent actual-run review of both snapshots.

The maintained public command subsequently passes the same 45 tests with zero
failures, unexpected failures or skips. Its five direct stages finish naturally
with exit zero and complete captures; final postflight succeeds. Its inventory
contains 74 original inputs and 149 copied/generated rows, and its compiler
proof binds four modules and 107 artifacts. Tests use synthetic files and do not
show windows or launch a search helper.

Coverage includes actual store writes and readback, external replacement,
corrupt/unsupported inspection, repair identity, uncertain publication,
readback-unconfirmed results, failed-intent retry, exact-byte pending retry and
confirmed discard/reload. Invalidation retains late outcomes privately without
publishing new authority, and joining follows actual worker settlement. Local
quit reservations reject busy or unresolved state and preserve exact identity
through callback reentry. These component reservations do not implement
application quit integration.

A separate current-source application/helper dependency build passes all 1,203
unique default tests, with zero failures or skips and warnings treated as errors.
The 546 recorded input rows match between the pre-run and immediate post-run
snapshots. Four rows are ignored generated Python bytecode. A later Root review
import changed one of those bytecode files; all 542 source/test/support text rows
still match. The snapshots are preserved without rebinding that later change.
This run is separate from the hidden native selections; their counts are not
added together.
No clean-build or packaged-runtime claim follows.

## Runner regressions and retained failures

The original six runner contracts are preserved and expanded to thirteen.
The expanded twelve-method baseline produced eight failing methods and nine
ordinary assertions. A further regression exposed current-stage command-record
tampering: the runner had first pinned that record after the child returned.
It now pins the original record before execution and rejects any change without
rehashing it into authority. Earlier command, capture, input and artifact guards
remain in force. The thirteen checks pass privately, and full public Python
discovery passes 113 tests with zero failures or errors. These synthetic runner
checks do not compile Swift.

Initial system-temp runs failed before reaching the new tampering regression.
Case-insensitive filesystems aliased support directory `Toolchain` with stage
`toolchain`, then compiler scratch directory `Build` with stage `build`. The
retained diagnostic runs identify both exact directory aliases. Support and
scratch directories now use `ToolSupport` and `BuildProducts`; stage names,
method rosters and refusal guards are unchanged. After these fixture/layout
repairs, the regression reached one intended ordinary failure while the other
twelve methods passed; the command-record correction then passed all thirteen.
The earlier setup failures are not counted as behavioral RED results.

## Limits

No new dependency or asset is included; original source remains MIT-licensed.
Raw synthetic captures and machine-specific paths remain ignored locally. This
evidence establishes no visible manager/picker workflow, application activation,
packaged runtime, older-toolchain execution, performance, physical input, IME
or accessibility acceptance. The earlier read-owner results remain documented
in [read ownership](native-language-catalog-loading.md).
