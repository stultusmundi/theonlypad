# Managed-documents runner repair

Verified 2026-10-14 on ARM64 macOS 26.6.2. This checkpoint repairs the
hidden native verification command; application production sources are unchanged.

```sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p 'test_*.py'
scripts/test-managed-documents.sh
```

The pure runner suite passed **62 tests, zero failures**. The actual fixed
native command passed **73 tests, zero failures, unexpected errors or skips**
across the original six Swift files and seven XCTest classes. The current routing
file includes two additional admission callback cases beyond the historical
71-case result. Every original Swift test body and assertion remains unchanged.

The earlier command stopped at compilation before running any tests: its copier
omitted the approved controller/history access extensions now required by the
routing tests. That failed build remains in private evidence. The repaired wrapper
uses the existing shared coordinator and its direct owned-process watchdog.
Do not wrap the command in another session-owning watchdog. It accepts no caller
source, test filter, skip-build or prebuilt-path selection.

The coordinator freezes the actual Core/search/native graph, excluding only the
application entry point, and verifies the exact fixed method roster. Four explicit
frozen-only access extensions are appended to their original declaring files:
AppDelegate, session restoration, editor controller and document history.
The controller extension includes the identical disk-conflict construction
forwarder needed by these tests; it replaces the obsolete broad monitor tail to
avoid a duplicate declaration. The entire extension is not described as readonly.
No dirty-getter counter, presentation suppression or production-body hook is added.

Independent source and actual-result reviews accepted the run. The evidence
contains 211 original and 189 generated rows, 189 compiled/linked objects,
five modules, 225 artifact hashes and four test-bundle leaves. Toolchain and test
stages each recorded natural completion and complete captures under the accepted
watchdog. Actual child arguments explicitly set synthetic state after environment
sanitization; the owned state directories are private. The test stage requests
warnings as errors. Authored modules use the declared Swift 5 language mode and
macOS 14 target; the standard generated package test entry has no explicit mode
flag. These targets do not prove execution on macOS 14 or Intel.

This is hidden native integration evidence. It does not show windows, exercise
Finder or physical input, or establish desktop close/quit acceptance, accessibility,
private custom-language/history integration or complete application scope. The
1,203 default tests and 38 preview contracts are separate suites.
