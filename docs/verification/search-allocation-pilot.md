# Real search-helper allocation preflight

Date: 2026-09-30. One measurement-only parent/helper pilot passed. The editor still uses its existing in-process search service. No accumulator choice, production budget, repeated performance result or hard-regex containment acceptance follows from this run.

## Composition and observed result

The release-mode private package uses the actual parent driver, lifecycle, default launcher, channels, codec and sole reaper. Its helper runs the actual worker Program, Foundation engine, FD channel and dedicated parent-lifetime watcher. Both roles use experimental String-append accumulators (A/A); this is a baseline, not a selected implementation. No protocol frame, engine or reaper was replaced.

The synthetic input is250000 U+1F600 scalars:1000000 UTF8 bytes and500000 UTF16 units. Literal case-sensitive replacement Z→Ω has zero matches and preserves the complete input. Independent streaming-oracle SHA256 and the returned source/output digests all equal `53d0db412e3d322402ad213716ef6415b0adac0086dfe3f197efe24bcd3de18b`. The parent validates returned Strings in bounded chunks, without constructing another full expected document.

The actual run verifies one launch/generation, one accepted terminal, one intentional SIGKILL during shutdown, one exact consuming reap, closed channels, no remaining child slot, a settled parent lane and zero retained parent lanes. Original source and both copied executable hashes are bound to the exact build. Root independently verified93 source inputs, three generated inputs, four complete watchdog receipts, compiler diagnostics, artifact bytes and the result. All checks passed; stderr was empty.

Each process produced five ordered, valid self-memory samples. They bind kernel process-start identity and retain current RSS, RSS high-water and footprint fields separately. This is baseline self-counter evidence only: no paired simultaneous peak, full phase coverage, exact Swift String capacity or memory limit is claimed. The separate paired-counter companion has16 pure tests plus one self test; actual other-process query acceptance remains outstanding.

## Prerequisite evidence

| Component | Result | Scope |
| --- | --- | --- |
| Streaming fixture oracle | 14 tests passed | Small goldens and bounded arithmetic/stream controls |
| Helper A/B/C builders | 15 passed after behavioral RED | Tiny explicit allocations and Unicode/ownership checks |
| Parent A/B/C accumulators | 20 passed after RED20/117 | Tiny output/ranges, actual codec boundaries, failure cleanup and transfer |
| Native self-memory probe | 1 passed after RED1/14 | Actual self counter availability |
| Paired counter companion | 16 pure plus1 self passed | Validation/arithmetic and self identity; no remote query |
| Pilot binding controls | 6 passed after RED6/9 | Complete package membership and both-stream diagnostic refusal |
| Pilot cleanup predicate | 6 passed after RED6/2 | Absent final slot plus independently observed exact reap and settlement |

These private experimental sources and raw receipts remain ignored; they are not yet a public reproducible benchmark command or a shipped product. Their eventual adoption must retain reviewed source and reproducible commands. The public driver and its reproducible checks are described in [driver verification](search-parent-driver.md).

## Preserved failures and correction

The initial source freeze `run.a_97gemb` failed compilation because a measurement adapter's synthesized initializer was internal. Adding an explicit package initializer resolved that error and its cascading diagnostics in a fresh freeze; independent review approved the one-line change.

The next actual run, `run.oxg6zg50`, returned the correct complete result and observed exact reap/channel/lane cleanup, but failed overall. Its harness required a retained `.reaped` shutdown snapshot. The actual lifecycle clears its slot after reap and channel close, then truthfully reports `.noChild`. The original failed run remains a failure. A separately reviewed predicate now requires `.noChild` **and** the exact observed generation/PID/reap/signal/terminal records plus all channel/lane checks. Six regression tests reject missing authority and retained states; the original predicate fails two assertions. No production lifecycle behavior or test requirement was weakened.

The corrected actual run is `.local/search-allocation-preparation/pilot/run.tpwysw5k/`, with `root-verification.json`. Source-inventory SHA256: `45c9f7556e1d521c293dd08f876d6cbe7eee8ab6802ce15c98bde0e505f093af`. Parent executable SHA256: `d546010c6855a9d0f5e85ed966d79c448351fb3915361d031a01a44b4e567dce`. Helper executable SHA256: `83098269166a096c512ff1fca9c568f2f2651d5b31c74f6c462305e0cc1b54f5`.

Next work: verify owned-helper counter sampling, compare five fixed-counterpart A/B/C pairs with equal repeated fixtures, execute the full supported large-input/output and warm-recycle matrix, and verify actual cancellation/deadline isolation. Accumulator selection, production helper assembly, editor routing, packaged search workflows and performance acceptance remain outstanding.
