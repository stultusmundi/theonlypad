# Prepared UTF-8 decoder component

The internal synchronous decoder in `Sources/SearchExecution/SearchPreparedUTF8Decoder.swift` is implemented and tested. It is a prerequisite for bounded search input preparation; it is not connected to editor search. The caller must own any memory reservation before constructing it.

The decoder borrows each input window without retaining it, validates canonical UTF-8, strips only an initial UTF-8 BOM, rejects NUL and malformed input, and checks raw-byte, window, UTF-16 and output-byte limits. It uses a fixed UTF-16 builder and writes the final UTF-8 String directly. A failed decoder is poisoned; a finished decoder cannot return a cached result. The builder refuses a supplementary scalar before changing either storage slot when capacity is insufficient, and refuses mutation until its readonly storage callback returns.

## Executed evidence

On ARM64 macOS 26.6.2 with Swift 6.3.3 in Swift 5 language mode:

- The unchanged 17 synthetic component tests first produced an absent-API compiler failure, then passed with the implementation.
- A matching frozen public package passed 122 neighboring tests and the full 1,016-test suite. All 999 prior methods were retained; the decoder adds 17 methods. The public manifest built the app and helper executables without launching either.
- Three separately compiled copies of the implementation were deliberately changed. All 17 methods ran in each copy, with exactly one failed method and no unexpected failures: an early surrogate write caused one assertion, relaxed UTF-8 lead validation caused four, and removal of the output-byte guard caused two. The production source and tests were not changed by these controls.

The first mutation coordinator stopped after the intended failure because its result parser expected the plural `failures` for a single failed case. That infrastructure error is retained. The classifier was corrected to accept XCTest's exact count-dependent noun; the existing capture was authenticated, and the other two controls then ran. This correction did not change a test or turn an arbitrary nonzero exit into accepted evidence.

Each execution used the checked-in owned-process watchdog directly. Root verified consuming wait, complete captures, cleanup receipts, frozen source membership, source bytes and modes, and the relevant test artifacts. The 498 protected pre-existing source, test, script and manifest inputs remained unchanged. Private raw evidence stays under ignored `.local/search-prepared-utf8-component/`, `.local/search-prepared-utf8-component-controls/` and `.local/search-prepared-utf8-integrated/`.

The actual public-package command below also passed all 17 component tests, with the matching 409 source/provenance inputs and its XCTest artifact verified. It builds the public manifest; it does not show windows or launch a helper. Use a fresh output directory for another invocation:

```sh
python3 -B scripts/run-owned-search-tests.py --timeout 240 --output .local/search-prepared-utf8-public-command/owned -- scripts/swift.sh test --scratch-path .build/search-prepared-utf8-public-command --filter SearchPreparedUTF8DecoderTests
```

Independent final review accepts the bounded inactive component's specification, code quality, execution evidence and cleanup, with no blocking findings. The component remains an inactive prerequisite for the next producer slice.

## Limits and remaining work

These tests use tiny synthetic inputs. They do not establish allocator overhead, String alias bounds, RSS, typing latency, 100 MB or 1 GB behavior, hard regex containment, native file intake, or packaged desktop behavior. The proposed prepared-input accounting formula is not accepted by this component evidence. Producer admission, worker ownership, cancellation and result retirement still need implementation and integration. Editor search remains in-process.

The macOS 14 public deployment target is unchanged. This host does not establish macOS 14 or Intel runtime acceptance. No dependency or third-party asset was added; the implementation is original MIT-licensed project code.
