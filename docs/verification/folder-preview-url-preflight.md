# Folder replacement URL preflight — 2026-10-16

Hosted run [38877082192](https://github.com/stultusmundi/theonlypad/actions/runs/38877082192)
at `fa758e1` fails the original core step. The source-bound finer diagnostic
observes31 ordered records: phase5 has entered the eleventh of twelve requests
without its end marker. That request contains a filesystem NUL. The preceding
ten request pairs completed. This interval includes preview admission, assertions
and fixture preservation; it does not identify an exact accessor, OS signal or
root cause. URL construction had already returned.

The path policy now scans the serialized URL before requesting decoded Foundation
path metadata. It refuses raw or percent-encoded NUL in the filesystem portion.
It stops at query/fragment delimiters, does not decode recursively and retains
the original file-scheme, host, absolute-path, directory, decoded-length and
C-string consistency checks. A filename containing literal `%00` is serialized
as `%2500` and remains valid. No filesystem read is added.

Eight focused tests cover rejection before decoded-path access, root URLs,
constructed URLs, literal-percent filenames, query/fragment data, Unicode,
nonzero escapes and non-file rejection. The inert baseline compiles and runs all
eight: three ordinary call-count assertions fail and five tests pass. The same
tests pass after the guard. The test callback on NUL inputs returns fixed text,
so the baseline does not call the suspected Foundation decoding path.
Independent Source and actual review accept this bounded regression evidence.

The formatted two-file public adoption passes the complete local suite:
**1,211 unique tests, zero failures**, with warnings treated as errors. This
includes all eight new tests and all eight original folder-preview tests.
All499 saved source/test/support inputs still match after execution. Strict
formatting and public-source checks also pass. Reproduction:

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 300 --output .local/folder-preview-full-check -- scripts/swift.sh test --scratch-path .build/folder-preview-check -Xswiftc -warnings-as-errors
```

Use a fresh output directory. The watchdog directly owns this invocation; do not
nest another session-owning watchdog. Synthetic raw evidence stays ignored.

These results establish local input admission and regression coverage on ARM64
macOS26 / Swift6.3.3. Hosted run38882522572 still stops in the same eleventh-request interval; the guard does not clear that observed failure. The helper-boundary diagnostic was then implemented and locally verified without another production change; its later hosted observation is recorded below.
This conservative guard is not proof of the hosted root cause, desktop
acceptance, memory/performance bounds or overall feature completeness.

The helper-boundary diagnostic passes twelve pure protocol tests and one
actual local selected Swift test with42 outer plus314 inner records. It changes
only a private frozen Test projection, not this Core guard or the original Test.
The subsequent hosted observation is recorded below; see
[diagnostic evidence](ci-failure-diagnostics.md). No hosted cause or fix is claimed.

Hosted run38890331512 at `893d6c6`, repeated by run38895105449 at `a1e29bc`, narrows the interruption to the
request11 marker immediately before the preview-builder call (31 outer/241 inner
records). No builder-body entry, exact getter, signal or cause is established.
The guard is unchanged; see [latest diagnostic observation](ci-failure-diagnostics.md).

The later private Core/Test dual projection passes15 protocol checks and the
actual selected Swift test locally (42 outer/314 helper/25 Core records).
Public diagnostic discovery passes48 separately. Production Core and the
original Test remain unchanged. Hosted verification was pending at that
checkpoint; its subsequent incomplete-evidence observation is recorded below.
See [Core-boundary diagnostic evidence](ci-failure-diagnostics.md).

Hosted run38901443160 at `285105d` still fails core, while the Core diagnostic
refuses incomplete evidence125; no accepted Core horizon follows. Its new
privacy-bounded availability record passes19 private protocol checks and52 public
checks; current local selected Swift1/0 retains42/314/25 and579/580 exact file
facts. Production Core and original Swift Test remain unchanged. New hosted
availability-code observation is recorded below; see [diagnostic evidence](ci-failure-diagnostics.md).

Hosted run38907406926 at `2584f66` subsequently identifies only attempted Python
parser boundary17 before diagnostic refusal125; no accepted Core/PATH report or
production cause follows. The reviewed first-parser-refusal observation now
passes22 focused and55 public Python controls plus the actual selected Swift
case (580 Original/581 frozen facts). Its optional closed group code remains a
diagnostic rejection label, never a production fix or relaxed parser acceptance.
New hosted group observation is pending. Production Core and original Swift Test
remain unchanged; see [current diagnostic evidence](ci-failure-diagnostics.md).
