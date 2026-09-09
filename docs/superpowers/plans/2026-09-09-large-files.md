# Large-file byte reader implementation plan

> **For agentic workers:** Execute this assigned subsystem inline with the installed TDD and verification skills. Routine review approvals are replaced by documented review under BUILD_PROMPT.md.

**Goal:** Provide bounded byte windows and literal byte search through a synthetic 1 GB regular file without whole-file allocation.

**Architecture:** A descriptor-owning synchronous reader uses `pread` loops, a captured device/inode/size/mtime/ctime identity and pathname revalidation. KMP searches fixed chunks with persistent prefix state so overlapping and boundary-spanning matches work without concatenating the full file. No text decoding, editing or UI capability is implied.

**Tech stack:** Swift Foundation and Darwin; no new dependency.

**Spec:** [BUILD_PROMPT.md](../../BUILD_PROMPT.md), partial I-01–I-06/E-06/C-07 and the assigned bounded reader scope.

## Constraints and design review

- Ownership: `Sources/PadCore/LargeFileReader.swift`, `Tests/PadCoreTests/LargeFileTests.swift`, `scripts/benchmark-large-files.swift`, this plan and `docs/verification/large-files.md`. Do not modify other agents' files or commit.
- File cap 1,000,000,000 bytes (decimal GB). Window/pattern cap 1,048,576 bytes. Search-result hard cap 1,000,000 offsets; caller defaults to 100,000. Chunk defaults to 1,048,576; tests may use smaller chunks.
- Alternatives considered: whole-file `Data` violates memory goals; mapping can fault or crash when externally truncated; descriptor-based chunked reads provide explicit bounded failures. Chosen KMP avoids backtracking and retains only pattern/prefix/chunk/results.
- `public final class LargeFileReader` exposes `init(url: URL, chunkSize: Int = 1_048_576) throws`, `identity: LargeFileIdentity`, `readWindow(offset: Int64, length: Int) throws -> Data`, and `searchLiteral(_ pattern: Data, limit: Int = 100_000, cancellation: () -> Bool = { false }) throws -> [Int64]`.
- Window at EOF returns empty; past EOF/negative offset/negative or over-cap length fail. Windows crossing EOF clip. Empty pattern fails. Search returns overlapping offsets. Result overflow throws instead of truncating. Cancellation occurs at chunk boundaries and bounded byte intervals.
- Open uses no-follow/nonblocking/close-on-exec flags and validates regular descriptor. Compare path and descriptor metadata against captured identity around reads. This detects ordinary changes; it is not an immutable filesystem snapshot or cryptographic integrity proof.
- All work is synchronous and must be called off the main thread. Data remains bytes; binary input never undergoes lossy string decoding.

## Task 1: Safe windows

- [x] Write real temporary-file tests for exact binary windows, clipped EOF, empty files, invalid ranges, directory/symlink refusal, changed/truncated/replaced files and size caps.
- [x] Run `scripts/swift.sh test --filter LargeFileTests --scratch-path .build/large`; establish observable red against minimal API skeleton.
- [x] Implement descriptor ownership, identity capture/checks and repeated `pread` (retry EINTR; reject premature EOF).
- [x] Rerun same filtered command and inspect all results.

## Task 2: Streaming literal search

- [x] Add tests for a match split across 4-byte chunks, pattern longer than a chunk, overlapping matches, cancellation before/during work, empty patterns and explicit result overflow.
- [x] Implement KMP prefix construction and scan bounded chunks. Check cancellation at least every 65,536 bytes; check file identity around every chunk.
- [x] Rerun meaningful tests and resolve failures without weakening assertions.

## Task 3: Reproducible synthetic measurements

- [x] Create a standalone `@main` benchmark compiled with LargeFileReader.swift using `swiftc -O`; print machine OS/architecture/CPU/memory and per-run open/window/scan timings and peak RSS.
- [x] Stream 1 MB, 10 MB, 100 MB and 1 GB synthetic files to `.local/large-file-benchmarks` using fixed chunks; do not materialize a whole-file string. Use explicit named synthetic files only and refuse to overwrite existing unknown files.
- [x] Run three scans per size, validate known match offsets, retain sanitized JSON results locally, and summarize actual measurements in verification documentation.
- [x] Record exact proven commands, cache/storage conditions, limitations and outstanding desktop validation. Do not infer launch, editing latency or UI performance from reader timings.

Final subsystem state: implementation complete for the bounded API; eight tests passed in the actual repository; twelve synthetic scans retained in verification/large-files.md. No UI integration or whole-product performance completion is claimed. Concurrent-build and sandbox report-writing obstacles were resolved.

## Task 4: Bounded native viewer (new integration scope)

Ownership: `Sources/TheOnlyPad/LargeFileWindowController.swift` plus this plan and large-files verification. Root owns routing from existing editor/AppDelegate; do not edit those files.

Design review: AppKit window presents a selectable, noneditable UTF-8 rendering of at most 65,536 source bytes. A permanent explanation discloses invalid/split UTF-8 replacement and that the original is unchanged. Previous/next/validated byte-offset navigation fetches worker pages. A UTF-8 literal query scans via the bounded reader on a cancellable worker; a popup lists real match offsets and navigates on selection. The progress label says Searching without fabricated percentages. File identity failures clear stale content and disable further use until reopened. Independent worker request generations prevent stale page/search completions updating a closed or newer view.

Public integration interface: `@MainActor final class LargeFileWindowController: NSWindowController`, `init(url: URL)`, optional `onClose: (() -> Void)?`. It exposes no save/edit method.

- [x] Build a temporary real-AppKit harness around view accessibility identifiers; verify read-only content, page navigation, invalid offset rejection, search-result navigation, cancellation and changed-file handling.
- [x] Observe the harness fail against a minimal controller shell, implement the controller, and rerun using the actual PadCore objects.
- [x] Build integrated repository and document native controller test scope separately from real GUI automation and large-file service benchmarks.
