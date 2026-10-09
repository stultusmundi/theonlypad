# Prepared file reader verification

The internal synchronous reader prepares a bounded UTF-8 file through an injected I/O contract. It uses the accepted real decoder, checks the planned file identity before reading and after text materialization, and exposes uncertain descriptor ownership without forwarding prepared text. No production caller activates this reader yet.

## Implemented contract

The input validates an absolute UTF-8 path of at most4,096 bytes, seven identity fields, a file size of at most10MB and a window of1...65,536 bytes before opening. The synchronous operation owns one initialized path buffer, one initialized read window and the decoder. The decoder's fixed builder holds at most U UTF-16 units, and normalized UTF-8 output is limited to checked3U bytes; neither is a complete allocator or RSS formula.

Each read requests only the remaining declared bytes within the window and consumes only the actual returned count. Early EOF, negative results including EINTR, invalid returned counts, invalid UTF-8 and binary input have distinct refusal paths. Reads are not retried, and declared completion does not probe an additional byte. Metadata comparisons include device, inode, size, modification and change timestamps; identity validation allows signed seconds and observed growth for comparison rather than silently applying the input admission limit to observations.

Opened descriptors have one explicit close attempt on ordinary return paths. Final identity checks occur while the descriptor remains open. If close is uncertain, the return carries primitive descriptor/identity/error ownership and the prior failure, with no prepared text or path. There is no destructor, close retry or automatic authority transfer. The finite Darwin fixture cases below cover successful native close; uncertain native close and integration with an asynchronous owner remain separate work.

## Tested evidence

Root ran serial checks on ARM64 macOS26.6.2, Swift6.3.3 in Swift5 language mode. The public deployment floor remains macOS14; neither that runtime nor Intel was tested.

- Genuine absent-API compiler RED retained229 diagnostics:82 missing API,140 contextual cascades, four expression-limit errors and three diagnostic-production errors. The seven material secondary compiler errors disappeared with the unchanged sixteen-test/helper GREEN; they were not counted as clean missing-API diagnostics.
- The original minimal package passed all16 scripted tests with the real accepted decoder. Fake descriptor tokens never reached Darwin. Exact metadata sequencing, short reads, cancellation, typed decoder errors, refusal and close ownership were covered.
- The matching frozen public package passed141 affected tests and the full1,041-test suite. Every prior1,025 test method was preserved, and exactly16 new methods were added. The actual app/helper build passed without launching either executable. All416 input bindings, source membership, artifact and complete direct-watchdog receipts were checked.
- The actual contributor command below passed16/0 with no warnings, skips or unexpected failures. Recursive strict formatting of the matching whole candidate passed.

Three source-reviewed copies of the actual reader were compiled against the unchanged original sixteen-test bytes. All16 methods finished in every case, with zero unexpected failures, warnings or skips.

| Deliberate fault | Failed methods | Assertion failures |
|---|---:|---:|
| Remove final identity sample pair |6|52|
| Forward text/failure despite uncertain close |1|2|
| Consume requested count instead of actual count |2|13|

The finite scripted fixture deliberately refuses incorrect early closes when literal operations remain. That produces ownership uncertainty and related sequence/quarantine assertions in the first and third controls. The original oracles and fixture were preserved. Failed methods and assertion failures are separate counts.

The first whole-candidate freeze failed before compilation on a duplicated readonly provenance wrapper. The partial snapshot remains retained, and the corrected fresh snapshot uses a separate Driver directory. Two Root inert capture classifiers initially rejected legitimate successful test names and SwiftPM's stdout build progress; both were corrected against the existing complete captures without repeating tests or builds. Original style failures are retained separately from fresh formatting-only test copies. None of these infrastructure observations is credited as intentional behavioral RED.

## Reproduce focused public tests

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/search-prepared-file-reader-public-command/owned -- scripts/swift.sh test --scratch-path .build/search-prepared-file-reader-public-command --filter SearchAdmissionFileReaderTests
```

Choose a fresh output directory when repeating the command. The watchdog owns its process group directly and must never be nested inside another session-owning watchdog. Ignored raw synthetic evidence remains under `.local/search-prepared-file-reader-component/`, `.local/search-prepared-file-reader-integrated/` and `.local/search-prepared-file-reader-public-command/`. No machine paths or raw documents are published.

## Concrete Darwin adapter checkpoint (2026-10-09)

The internal Darwin adapter now implements read-only open with `O_NOFOLLOW`, `O_NONBLOCK` and `O_CLOEXEC`, descriptor/path metadata, bounded `pread`, and one explicit close attempt. Failed native calls capture errno immediately. The adapter has no default factory or editor caller.

The actual repository command passed nine tests with zero failures, unexpected failures, skips or compiler warnings:

```sh
scripts/test-search-admission-file-darwin.sh
```

Eight tests use isolated synthetic file fixtures; one checks initialized native-stat normalization without a file. They cover Unicode path/descriptor identity, descriptor flags, bounded reads with guard bytes and unchanged file position, missing-path errno, final symlink refusal, peerless FIFO metadata without reading it, sparse-file growth, and BOM/supplementary Unicode text through the real reader. The eight fixture cleanup defers returned successfully and the owned fixture directory was empty; successful source-mapped close assertions were checked separately from registry removal.

The runner freezes actual sources in a fresh ignored package and invokes the checked-in owned-process watchdog directly. Do not nest it inside another session or process-group watchdog. Source inventories, compiled modules, objects, link lists, test bundle, complete captures and consuming-wait receipts were independently checked. An earlier source-only archive passed the same nine clients; that remains separate archive evidence.

Fresh public runner verification also passed all35 cases:

```sh
/usr/bin/python3 -B -m unittest discover -s Tests/SearchAdmissionFileDarwinIntegration -p test_runner.py
```

The nonverbose run reports the35-test aggregate; individual method names are bound through the reviewed source roster. Runner controls cover duration overflow and a nonregular final header without weakening the native tests.

A separate fresh public full suite passed1,041 Swift tests with zero failures. Its app/helper build, strict formatting of the three new Swift files, shell syntax and public source-pattern checks also passed. The full suite does not include the nine separately packaged native clients. Independent review verified current source membership, complete watchdog receipts and physical compiler/object/link bindings: the test stage compiled nine modules/270 objects; the ordinary build compiled five production modules/174 objects. Four test-module plans in ordinary build metadata were physically unbuilt and receive no test credit. Neither app nor helper executable was launched by these build checks. The initial whitespace check covered tracked files; final adoption must also check whitespace in the new files.

The adapter and harness are original MIT code using system APIs and the Python standard library. No dependency, asset, credential or real user document was added. Raw synthetic evidence stays ignored under `.local/search-admission-file-darwin/`, `.local/search-file-darwin-public-verification-preparation/` and matching ignored build directories. Two inert Root metadata inspections and two independent-review classifiers were corrected over unchanged evidence without repeating runtime checks; these are not behavioral RED results.

This checkpoint does not establish native EINTR handling, uncertain-close behavior, descriptor exhaustion, arbitrary filesystem races, asynchronous ownership, helper/editor activation, hard regex cancellation, a producer memory formula, allocation/RSS or desktop acceptance. It was tested on ARM64 macOS26.6.2 with Swift6.3.3; the macOS14 deployment target does not establish runtime coverage for macOS14 or Intel.

## Planned and outstanding

Admitted worker/producer ownership, actual task return and quarantine policy, helper/facade routing and editor activation remain outstanding. The synchronous reader and concrete adapter do not establish file/root capability, race-free path authority, hard cancellation, a producer charge formula, allocation/RSS acceptance or progress delivery. The native tests above cover their stated finite fixture cases.

Editor search remains in-process. No visible desktop, physical input, IME, VoiceOver, packaged runtime,100MB/1GB performance or additional-platform acceptance follows. Distribution artifacts remain unchanged; no release was published.
