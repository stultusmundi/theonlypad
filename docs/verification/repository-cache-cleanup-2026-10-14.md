# Repository compiler-cache cleanup — 2026-10-14

At the user's request, Root removed obsolete ignored compiler outputs without
removing source worktrees, private candidates, frozen test inputs, verification
records, synthetic state, result bundles or distribution artifacts.

The completed cleanup removed 719 compiler-output directories: 534 obsolete
scratch directories in the active worktree, six idle checkout/worktree build
roots, and 179 individually inventoried nested SwiftPM/Xcode compiler-cache
directories. Five active or current-review scratch builds were retained.
Recorded free-space increases total approximately 202.86 GiB (217.82 decimal GB).
The subsequent repository disk-usage measurement is approximately 33.57 GiB;
these are filesystem observations, not an application performance benchmark.

Root verified ignored/untracked status before cache removal, scoped every
deletion to a concrete cache root, and retained the enclosing directories of
historical test runs. Nested SwiftPM outputs required actual compiler markers;
Xcode cleanup was limited to compiler products and caches, preserving Logs and
result bundles. No whole verification-run directory was removed.

After cleanup, the current 193-input history declaration graph and 197-input
external-command graph were rehashed. Artifact bindings for the productive
application-quit build, external-command build and historical 168-case
compatibility baseline also remain exact. Distribution artifacts remain present;
cleanup neither rebuilds them nor establishes fresh package acceptance.

Historical source, receipt, result and failure records remain evidence of their
original executions. Superseded compiler binaries were deliberately reclaimed:
their former scratch paths must be rebuilt before reuse or a new artifact audit.
Do not assume an old `--skip-build` command still has its original binary after
cleanup. Current retained builds were expressly protected for ongoing review.

Future work retires superseded compiler caches after their source and execution
reviews complete, while retaining frozen source/tests, commands, manifests,
captures, results and failures. Reuse an exact verified build for compatible
fresh-process test selections instead of creating a new scratch build per case.
Raw inventories and deletion journals remain ignored locally. No remote push,
merge or release occurred.
