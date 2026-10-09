# Prepared file reader verification

The internal synchronous reader prepares a bounded UTF-8 file through an injected I/O contract. It uses the accepted real decoder, checks the planned file identity before reading and after text materialization, and exposes uncertain descriptor ownership without forwarding prepared text. No production caller activates this reader yet.

## Implemented contract

The input validates an absolute UTF-8 path of at most4,096 bytes, seven identity fields, a file size of at most10MB and a window of1...65,536 bytes before opening. The synchronous operation owns one initialized path buffer, one initialized read window and the decoder. The decoder's fixed builder holds at most U UTF-16 units, and normalized UTF-8 output is limited to checked3U bytes; neither is a complete allocator or RSS formula.

Each read requests only the remaining declared bytes within the window and consumes only the actual returned count. Early EOF, negative results including EINTR, invalid returned counts, invalid UTF-8 and binary input have distinct refusal paths. Reads are not retried, and declared completion does not probe an additional byte. Metadata comparisons include device, inode, size, modification and change timestamps; identity validation allows signed seconds and observed growth for comparison rather than silently applying the input admission limit to observations.

Opened descriptors have one explicit close attempt on ordinary return paths. Final identity checks occur while the descriptor remains open. If close is uncertain, the return carries primitive descriptor/identity/error ownership and the prior failure, with no prepared text or path. There is no destructor, close retry or automatic authority transfer. Actual native close behavior and integration with an asynchronous owner remain separate work.

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

## Planned and outstanding

Concrete Darwin I/O, admitted worker/producer ownership, actual task return and quarantine policy, helper/facade routing and editor activation remain outstanding. The synchronous reader does not establish file/root capability, race-free path authority, hard cancellation, a producer charge formula, allocation/RSS acceptance or progress delivery. Native descriptor tests are being prepared separately.

Editor search remains in-process. No visible desktop, physical input, IME, VoiceOver, packaged runtime,100MB/1GB performance or additional-platform acceptance follows. Distribution artifacts remain unchanged; no release was published.
