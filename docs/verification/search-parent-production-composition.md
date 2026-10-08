# Fixed production parent composition — 2026-10-09

Status: construction and packaged-helper test wiring are implemented, tested
and independently source/evidence-reviewed with no blockers. The scoped local
commit is approved. Native search routing remains outstanding.

## Implemented construction

`Sources/SearchExecution/SearchParentWireDriver+Production.swift` provides the
package bundle-only constructor and a shared internal collaborator recipe.
It uses the existing default launcher, monotonic clock, serial Dispatch timer
queue, child lifecycle and production response collector. Invalid URL forms
refuse structurally; missing helper files remain launch-time failures. It performs
no filesystem preflight or launch during construction. Both constructors share
one recipe, and all existing production sources remain unchanged.

Selected policy: 10 seconds per operation, 2 seconds of reap grace, 10 seconds
of idle time, eight completed requests per child, and cumulative completed
stream-I/O retirement at 268,435,456 bytes. The last value includes handshake traffic, permits an active
request to exceed it, and does not establish a payload or RSS cap. Per-job limits
remain explicit; no admission budget or editor limits are selected here.

## Task1 verification

Root ran exact frozen source sets under the checked-in owned-process watchdog.
The missing-constructor compiler RED is distinct from behavioral RED: zero test
methods executed during the expected missing API failure. A separately generated,
ignored constructor with wrong but valid policy values executed four unchanged
methods and failed nine intended assertions, with zero unexpected failures or
timeouts. No generated shell or changed existing production source was adopted.
The bounded RED selection covers policy, armed deadline, grace and premature
timeout; it does not claim an eager-filesystem mutation control or eight-request
recycling RED. All twelve final tests remain required and unchanged.

Final focused selection passes 12 tests with no failures; neighboring parent, wire,
lifecycle and resolver selection passes 331 unique tests with no failures. All exact
method identities, frozen input bytes/membership and direct watchdog receipts
were checked. Both runs are warning-free. The focused set has 80 adopted inputs
and one generated manifest; neighbors have 102 adopted inputs and one manifest.
A nonmatching LauncherState selector earns no extra launcher execution credit.

The new tests independently check literal policy values, six malformed bundle
forms, missing-bundle no-launch construction, normalized fixed path and deadline
arming before launch, exact Unicode through the real codec, response phase
refusal, ten-second operation/idle boundaries, two-second unconfirmed cleanup,
eight completed requests then a ninth on a new generation, and genuine joined
shutdown through an ordinary non-@testable package import. They use synthetic
injected child collaborators; these are not actual-helper or desktop tests.

Root preserved the author's original test bytes before strict-formatting. The
complete diff changes whitespace/line breaks and one array trailing comma only.
Independent test and implementation reviews approve both specification and
quality, with no blockers. Source review separately establishes concrete collector
binding and absence of constructor filesystem work; output tests alone do not
prove either source fact.

Reproduction (the retained runs supply absolute frozen package/scratch paths):

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 --output .local/parent-production-focused -- scripts/swift.sh test --scratch-path .build/parent-production --filter SearchParentProduction
```

## Actual packaged constructor and integrated verification

Pure runner controls pass 32 tests, preserving all 20 original methods and adding
12 checks for case selection, missing-bundle refusal, capture scope, canonical
generation, logical cleanup fields and malformed or cross-scope records. Initial
RED executed 32 methods with 15 assertion failures and 47 missing API/selector
errors; the latter are setup failures, not behavioral sensitivity. A separate
unchanged old-API method produces ten intended assertion failures and no errors.
The corrected validator consumes every relevant raw marker rather than silently
ignoring malformed rows. Built mode retains five cases; packaged mode selects six.

All six actual final nested-helper methods pass, with exact selected XCTest
identities and no failures or skips. The original five preserve every literal,
source, request/ordinal, live PID, pre-result empty signal/reap and joined-cleanup
assertion while using the shared construction recipe in packaged mode. Each of
these five controlled shutdowns records one successful owned SIGKILL, one sole
consuming reap and actual session release. These are observed cleanup facts,
not adversarial-regex deadline evidence.

The sixth method calls only the ordinary package constructor. Four actual jobs
check supplementary Unicode find, regex capture replacement, invalidPattern and
subsequent healthy same-generation/next-ordinal reuse. Source, UUID, ordinal,
ranges and replacement text have independent exact oracles. Its genuine joined
receipt records admitted ownership, acknowledged lane stop, stopped child,
closed channels, noChild, settled parent and zero retained lanes. It has no PID,
signal, consuming-reap or session-release fields; the observed five counts are
not attributed to this ordinary path. Both paths verify artifacts before/after
and always join cleanup when the body throws.

The eleven direct watchdog stages and complete 91-source/two-generated-input
inventory, final application/helper artifacts and entire test bundle remain
exactly bound after execution. The fresh public app/core suite passes 939 unique
methods with no failures, warnings or skips and links both app and helper.
All 382 declared inputs and its direct watchdog receipt match. Fresh packaging
uses 176 unchanged inputs; standalone archive/SBOM verification accepts seven
members, and helper/application strict signatures each verify successfully.
Recursive strict formatting, public-source pattern and whitespace checks pass.
Independent combined test-wiring source review approves specification/quality.
Final independent checkpoint evidence review approves with no blockers.

Reproduction:

```sh
python3 -m unittest discover -s Tests/SearchWorkerIntegration -p 'test_*.py'
scripts/package.sh --ad-hoc-sign
scripts/test-search-worker.sh --application-bundle "$PWD/dist/TheOnlyPad.app"
python3 scripts/run-owned-search-tests.py --timeout 600 --output .local/parent-production-integrated-owned -- scripts/swift.sh test --scratch-path .build/parent-production-integrated
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

The helper coordinator owns each watchdog directly; do not wrap it in another
session-owning watchdog. The retained Root pure runs freeze their actual three
Python inputs and never launch a compiler/helper. Raw diagnostics and original
artifacts remain ignored locally, using synthetic documents only.

## Retained setup and source history

Root's first pure coordinator failed before test execution because two adopted
files shared an already-created parent directory. Only the private coordinator
was corrected; the failed directory and a new RED run are preserved separately.
Root's first additional helper-receipt verifier misclassified the administrative
test-binpath stage as a selected method. Its corrected explicit case-stage set
then verified all eleven receipts; no source, outcome or receipt was changed.
Neither event is relabeled as an application/test failure or successful run.

Strict formatting of the new Swift fixture repaired eight long lines with only
whitespace changes; original author bytes remain preserved. A sealed source
handoff omitted a promised full test-report digest. Independent review bound the
exact report and retained the original seal; no source change was needed.

## Exact current pins

| Item | Bytes | SHA256 |
| --- | ---: | --- |
| Production constructor | 1751 | `b0db33acbb2a9ccb3f8c62d095e7cdfb421989a8d123743f23a0696ff2290946` |
| Actual helper fixture | 24211 | `9de4a31eab5a70b068b97464cc2796d224bc42cde076d5bc0a0ee8f97f6f2b63` |
| Main executable | 6734560 | `ee6b3187071f29f146690bebb476465766a3876f28978e410dede667b9f01829` |
| Nested helper | 3392320 | `3786081fd2c03802ba02523558643b34d959a6c040a7c1531f4a2f013095f820` |
| ZIP | 3485598 | `c2a4425c28abd4bc90fe0743fa17729f4d0a12b138e6930aecce2ee32aaefbcc` |
| SBOM | 1786 | `ac9b9d9d8daa0e4579ac204e34b2105f07af09adbcce101983fc7eb8441e2f57` |

## Limits and continuation

The editor still uses in-process search. Production admission accounting, retry
ownership and native document/folder routing remain outstanding. No adversarial
regex containment, physical allocator release, memory/performance, current GUI,
physical keyboard/IME/VoiceOver, Intel or macOS14 runtime acceptance follows.
Desktop UI Automation authentication remains user-owned and pending. Continue
independent implementation; no remote push, merge or release is authorized.
