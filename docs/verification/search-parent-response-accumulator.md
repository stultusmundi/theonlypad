# Production parent response accumulator — 2026-10-09

Implemented and tested as an internal component on the isolated
`feat/search-parent-response-accumulator` branch, based on helper checkpoint
`7e63d4d`. Independent specification and quality reviews approve the class and
the real-helper factory change. Independent final checkpoint evidence review
also approves the scope for a local commit. The editor's search remains in-process; this checkpoint does not
activate supervised native search.

## Implementation

`Sources/SearchExecution/SearchParentResponseAccumulator.swift` implements the
existing response sink/take/discard contract. It retains its creating thread,
compact request metadata, bounded ranges and strict UTF8 replacement bytes.
Throwing foreign-thread calls reject before mutable access; discard requires the
owner. Invalid owner calls clear payload and poison the instance. Failure
terminals release partial output; success detaches one returned value.

Range count/input/scope/order and complete identity are checked. The existing
response reader authenticates source scalar boundaries; the collector retains no
source, pattern or template. Each replacement append accepts at most65,536
scalar-complete UTF8 bytes, with maintained UTF16 and3*N content bounds. Take
strictly revalidates the complete buffer without imposing the append chunk cap,
preserving FEFF, NUL, supplementary/decomposed Unicode and line endings. Find's
nil replacement remains distinct from a successful empty replacement. No eager
reservation, callbacks, counters exposed for tests, locks or new dependencies
are introduced.

The genuine helper fixture now constructs this production collector. Its private
collector was removed; every other fixture byte, including all five literal
oracles, identity/reuse checks, observers and cleanup assertions, is unchanged.
Worker, wire, codec, driver, Package graph and native source remain unchanged.

## Executed evidence

Reference host: ARM64 macOS26.6.2, Swift6.3.3 in Swift5 language mode; deployment
target remains macOS14. Synthetic documents only. Root exclusively owned serial
builds/runtime. Raw captures and frozen inputs remain ignored under `.local/`.

| Check | Actual result | Qualification |
| --- | --- | --- |
| Absent-API compiler RED | exit1, zero methods | Missing declarations; not behavioral evidence |
| Ignored naive-conformer RED | 32 methods,156 assertion failures,0 unexpected | Direct24 methods discriminate missing validation/state; all8 real-codec controls already pass |
| Frozen production direct/codec | 32/0 | 78 adopted inputs plus derived manifest; exact watchdog receipt |
| Frozen collector/codec/wire neighbors | 173/0 | 99 adopted inputs plus derived manifest; original assertions retained |
| Current public app/core | 927/0 | 379 unchanged input pins; app/helper link and exact watchdog receipt |
| Current final nested helper | 5/0 | Ten direct-watchdog stages; actual source/helper/test-bundle bindings |
| Local ad-hoc package | pass | 175 stable packaging inputs; seven archive/SBOM members verified |
| Explicit helper and application signatures | pass | Separate strict verification of both |

All GREEN builds are warning-free. The sole direct-test declaration correction
from `weak var` to `weak let` removes a compiler style warning; all other bytes
remain exactly the preserved behavioral RED source. Original author sources,
missing-API history and the naive shell remain separate ignored evidence. The
shell is not production code or a shipped test substitute.

Actual helper methods cover supplementary Unicode ranges, real regex capture
replacement, exact FEFF/NUL/decomposed/newline preservation, invalidPattern then
healthy same-generation reuse, and empty then fragmented supplementary
replacement. Fragmentation credits actual outbound writes; pipes may coalesce
them. Result credit requires exact positive owned PID/generation/request/ordinal
and no prior signals/reaps. Each subsequent controlled shutdown recorded one
actual successful owned SIGKILL, one consuming reap, closed channels, one session
release and an acknowledged zero-retained-lane joined shutdown. These are
cleanup outcomes, not proof of hard catastrophic-regex containment.

The final nested selection is recorded under
`.local/search-worker-integration/run.83kadeiu/`; component history is under
`.local/parent-response-component/`. Root revalidated every stage receipt,
immutable input inventory and whole helper/test-bundle binding after completion.
Prior helper-checkpoint artifacts were preserved before fresh local packaging.

## Commands and artifact bindings

Executed whole-package command (the private Root coordinator also pinned every
input before/after):

```sh
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/parent-response-integrated-owned -- scripts/swift.sh test --scratch-path .build/parent-response-integrated
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
codesign --verify --strict --verbose=2 dist/TheOnlyPad.app/Contents/Helpers/PadSearchWorker
codesign --verify --strict --verbose=2 dist/TheOnlyPad.app
scripts/test-search-worker.sh --application-bundle "$PWD/dist/TheOnlyPad.app"
```

The helper coordinator directly owns each watchdog; never nest it under another
session-owning watchdog. Focused RED/GREEN/neighbor runs used immutable minimal
packages preserving the actual PadCore/SearchExecution test dependency edges,
macOS14 and Swift5. The public full suite independently exercised the same new
32 methods alongside unchanged app/core tests.

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| Main executable | 6,734,560 | `3bf77ca1355fb428d62f3f559240b91c14bd5cbefd061fb7c399bb2fae5642ad` |
| Final nested helper | 3,361,280 | `f4782f4ebe42a9d690794f70cc3fa4fc0ec5faa33ae00fdce19a78a43279840c` |
| Archive | 3,475,676 | `3e96c42f04192dd37df708ef778504e71cd25990350c43dbcf556738eb2cee6b` |
| SBOM | 1,786 | `e4508f9d15726946c9b1d02258ce0a05be828aec7d8e28d8515a7b2876e343b3` |

Nested run source manifest:
`3b3bb7f69db99b632a93d07f8c257f94776d377b1c969a2589e7fca4beb2b8e5`.
Test bundle binding:
`d454f899f78a5ce530d23ccbbff4e1e05b5ba06b7239428b0a4f02901e925bf4`.
Collector source:6,977 bytes,
`8949472e8624ccaf33eadb29a5750fb3ad8321080e2dc0d0f1cbf2a0f5208747`.

## Outstanding acceptance

Default production driver/policy, admission accounting/retry and native document
and folder search routing remain unimplemented. Logical content bounds do not
measure spare capacity, temporary Data/String overlap, allocator release,
allocation/RSS, throughput or UI latency. No private allocation campaign is
adopted as a product gate and no universal memory-fit claim follows.

Current GUI acceptance awaits user-owned UI Automation authentication. Physical
keyboard/IME/VoiceOver, Intel and macOS14 runtime, adversarial containment and
large-file performance remain separate acceptance work. The local bundle/archive
is ad-hoc signed, not notarized or published. No remote push, merge or release has
been performed.
