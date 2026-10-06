# Private Swift campaign journal checkpoints

2026-10-07. This records synthetic component verification. The publisher and
its new tests remain in ignored private packages; they are not adopted into the
application. The packaged desktop checkpoint remains source `f4d9207`.

The broader prerequisite chain is recorded in
[search-campaign-components-2026-10-06.md](search-campaign-components-2026-10-06.md).
Prepared input compatibility and published-output interoperability are separate
gates throughout this record.

## Initial publisher

The fixed publisher validates trusted synthetic input anchors, opens the selected
cell through protected directory handles, writes an exclusive journal and then
its canonical commit marker, and returns a final receipt only after acknowledged
cleanup. Repeated publication is consumed. Cached finish and close receipts are
historical facts, rather than a fresh certification of disk contents.

The genuine initial RED selected six XCTest methods and produced 76 explicit
assertion failures, with no unexpected errors, skips or timeout. Twenty-one
existing journal regressions were subsequently added unchanged. Verification
retains these intervening failures:

- The first GREEN build linked, but six publisher methods failed during fixture
  admission. Foundation had shortened the temporary-parent spelling through an
  intermediate symlink. The fixture was corrected to prepare the physical path
  using native `realpath`; the publisher's protected lookup was preserved.
- The next run completed 26 passing methods and one explicit assertion failure.
  Encoder rejection drained admitted handles through the general I/O error catch.
  A narrow encoder boundary now records the consumed failure without filesystem
  calls; explicit close retains responsibility for cleanup.
- Separate compiler/auditor setup failures remain recorded as infrastructure
  failures. They are not counted as behavioral RED.

The corrected frozen package passed a fresh build and all **27 methods**, with
zero failures, unexpected errors or skips. Root checked the 32 frozen compilation
units, 33 linked objects, actual test bundle, toolchain/SDK bindings and complete
owned-process receipts. Frozen Swift sources use Swift 5 language mode, target
ARM64 macOS 14 and the macOS 26.5 SDK under Swift 6.3.3. The verbose manifest
compiler command has a retained `warning:` prefix; no source/compiler warning
was reported.

The six initial publisher methods cover both cell indices, exact independent
journal/marker bytes, incomplete/invalid/pending diagnostics, consumed repetition,
encoder refusal before I/O, and an injected cleanup acknowledgment failure.
The directory-close control forwards successful native `closedir` and then
reports EIO. It does not demonstrate an actual operating-system close failure.

Eleven actual protected Swift input anchors were preserved. The unchanged Python
selector accepted both indices for each anchor, totaling 22 selections. These
are **input compatibility checks**, not a filesystem reader consuming the
publisher's journal/marker output.

Accepted manifest SHA256:
`1edbbcb68c00b4766e58b81dfba3e42a93c17d362286fd8ed005400957cee88b`.
Local evidence is under `.local/search-campaign-swift-journal-20261007/`, including
`root-initial-green-v3-gate-acceptance.json` and the preserved failure packets.

## First ownership group

A separate test observer adds bounded acquisition records, pre-forward handle
guards and explicit directory-reset counting. It reserves storage before native
acquisition, revokes raw ownership on successful DIR transfer, retires ownership
before the sole cleanup attempt, and provides no independent destructor cleanup.
Its sticky observation overflow refuses new work while preserving the caller's
ability to clean up known live resources.

The package preserves all 168 baseline inputs and adds only two test sources and
their Package entries. Independent source review preceded a fresh build of
34 frozen units and 35 linked objects. Root then executed three separate stages:

| Stage | Methods | Failures / unexpected / skips |
| --- | ---: | --- |
| Direct observer guards | 6 | 0 / 0 / 0 |
| Ordinary publication controls | 6 | 0 / 0 / 0 |
| Preserved regressions | 27 | 0 / 0 / 0 |

The 39 methods are a total across three runs. The direct guard gate passed before
the ordinary controls were selected. Actual assertions cover foreign and retired
FD/DIR rejection before forwarding, raw-close refusal after transfer, repeated
complete native scans after shared-offset exhaustion, and known-owner cleanup
after the observer reaches its attempt limit.

The ordinary controls cover both indices, four three-byte role streams with
12 received/accepted bytes and four zero-byte EOFs, explicit resets, unchanged
cached receipts/counters after a separately verified file mutation, consumed
repetition, and teardown that cannot promote provisional publication. They require
root depth at most 12, no forbidden observer calls, no overflow, acknowledged
cleanup and no live or uncertain observer ownership at completion.

The regression command reversed the two literal class alternatives relative to
its preflight. Root retained both commands and verified that only union-filter
order differed, the selected class set was identical, and all 27 named outcomes
matched. A separate auditor records that bounded transcription deviation; the
successful run was not repeated or relabeled an exact-command match.

Accepted manifest SHA256:
`7d91897dd17541188d77d1937fba771c72e18a8414f9f696a353b78a758d9b6c`.
`root-task2-first-group-acceptance.json` binds the independent runtime review and
each source/build/test audit in the same ignored evidence directory.

## Limits and next gates

Parent-only native observations matched before and after each stage: physical
temporary-parent spelling, directory identity, protected descriptor flags,
nonunion APFS and acknowledged probe close. Preserved 0400, single-link input
anchors bind immediate UUID-container/cells paths; temporary roots were absent
after teardown. This assumes no mount injection or replacement and does not
retrospectively observe removed fixture roots.

The observer's 512 acquisition records and 8192 normal attempts are test bounds
with a separate bounded cleanup allowance. Successful tiny full-progress cases
fit them under the stated depth restriction. They do not establish maximum
process/libc descriptors, allocation/RSS, arbitrary short-I/O/EINTR behavior or
concurrent atomic ledger observations. The initial recorder omitted the default
reset operation; new reset-aware tests do not retroactively change that evidence.

Planned next are finite invalid-anchor and oversized-input cases, followed by
separately reviewed writer/fault controls. Marker prefix faults require actual
proof that a new writer token starts with fresh counters after acknowledged
retirement of a writer with nonzero progress. Role-read totals do not provide that
proof; controlled numeric descriptor reuse remains a separate gate.

Full depth/reservation and byte-cap coverage, fault/race cases, guard mutants,
actual Swift-output ingestion by the unchanged Python filesystem reader, real
helper roles, the memory campaign and production editor routing remain incomplete.
No new packaged desktop, physical input, accessibility or performance acceptance
is established by these checkpoints.
