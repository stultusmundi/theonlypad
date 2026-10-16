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
macOS26 / Swift6.3.3. Older hosted Foundation verification remains pending.
This conservative guard is not proof of the hosted root cause, desktop
acceptance, memory/performance bounds or overall feature completeness.
