# Large-file byte service verification

Date: 2026-09-09. Scope is a synchronous byte-reader service, not a desktop large-file editor or viewer. No A/C/E/I requirement aggregate is complete solely from these results.

## Implemented and tested

`Sources/PadCore/LargeFileReader.swift` opens only regular files, owns a no-follow/nonblocking/close-on-exec descriptor and captures device, inode, size and nanosecond modification/change timestamps. Window reads use repeated `pread`, retry interrupted calls, reject premature EOF, validate identity before/after reading, and return exact bytes. They never decode binary data. Windows are limited to 1,048,576 bytes and clip at EOF; invalid ranges fail.

Streaming KMP literal search carries prefix state across chunks, returns overlapping Int64 byte offsets, and checks cancellation at chunk boundaries and every 65,536 input positions. Empty/overlarge patterns and invalid limits fail. Results beyond the caller limit throw rather than silently truncate. Changes during a search reject partial results. Caps are 1,000,000,000 file bytes, 1,048,576 pattern/chunk bytes and 1,000,000 result offsets (default result limit 100,000). Memory is proportional to chunk + pattern + bounded results, not total file size. The synchronous API must run on a worker.

Tests: `Tests/PadCoreTests/LargeFileTests.swift`. Fresh real-repository result at 12:24:57 local runner time: **8 tests passed, 0 failures**, 0.032 seconds. Coverage includes byte-exact binary windows; EOF/invalid ranges; empty files/patterns; long patterns and overlapping boundary matches; explicit result limits; early/mid-search cancellation; replaced/truncated/in-place modified files; directory/symlink refusal; sparse over-cap file refusal; mutation during scanning; and 40 seeded fixtures compared with independent sliding-window results. Seed: `0xC0FFEE`.

Initial TDD red used an isolated temporary Swift package with exact source/test copies because concurrent macro implementation temporarily prevented whole-repository compilation. Six tests failed against the API skeleton, then six passed after implementation. Final eight-test run used the actual repository. Sandbox compiler-cache access required the approved retry; tests were not weakened.

Proven commands from repository root:

```sh
scripts/swift.sh test --filter LargeFileTests --scratch-path .build/large
mkdir -p .build/large-benchmark .local/large-file-benchmarks
swiftc -O -module-cache-path .cache/swift Sources/PadCore/LargeFileReader.swift scripts/benchmark-large-files.swift -o .build/large-benchmark/benchmark-large-files
.build/large-benchmark/benchmark-large-files > .local/large-file-benchmarks/latest-results.json
```

The benchmark creates a new UUID directory beneath ignored `.local/large-file-benchmarks` on each run, generates four synthetic files by repeated fixed-chunk writes, and stores `results.json` alongside them. It refuses existing destinations through exclusive creation. Each run retains approximately 1.111 GB of synthetic data; only these explicitly generated directories should be removed when reclaiming benchmark space. An initial benchmark finished scanning but its Foundation atomic report write was blocked by the sandbox. Report creation now uses an exclusive private descriptor; the successful rerun below retained its results.

## Recorded reference machine and conditions

- Processor: Apple M4 Pro, 14 reported processors, arm64.
- RAM: 51,539,607,552 bytes (48 GiB).
- macOS: Version 26.6.2 (Build 25G83). Optimized standalone executable: `swiftc -O`.
- Report timestamp: 2026-09-09T09:24:12Z. Storage: current repository volume; no device-identity or hostname data collected.
- Files use decimal MB/GB. Chunk size is 1 MiB. Fixture contents are a single long run of ASCII `a` bytes with two 17-byte literal markers; the first marker spans a chunk boundary for 10 MB and larger files. No giant Swift String is created.
- Measurements follow streaming generation and synchronization. Filesystem caches were **not flushed**; these are cache-influenced repeated service measurements, not cold storage or cold app launch measurements. Other development work ran concurrently.
- Each full scan verifies exactly two known byte offsets. All twelve scans returned correct offsets. Window timing reads from the midpoint (500,000 bytes for the 1 MB file; 1,048,576 bytes otherwise).
- RSS is Darwin `getrusage(RUSAGE_SELF).ru_maxrss` in bytes: cumulative whole-process high-water including fixture generation and previous sizes. It is not a per-operation allocation delta, editor footprint, or proof of a universal memory ceiling.

## Retained individual measurements

| File bytes | Run | Open seconds | Window seconds | Full literal scan seconds | Cumulative peak RSS bytes |
| --- | --- | --- | --- | --- | --- |
| 1,000,000 | 1 | 0.000067375 | 0.000100417 | 0.000928542 | 8,929,280 |
| 1,000,000 | 2 | 0.000042792 | 0.000032250 | 0.000861833 | 9,027,584 |
| 1,000,000 | 3 | 0.000032167 | 0.000025250 | 0.000840833 | 9,027,584 |
| 10,000,000 | 1 | 0.000080917 | 0.000098375 | 0.008834833 | 9,863,168 |
| 10,000,000 | 2 | 0.000054875 | 0.000084583 | 0.009588000 | 10,928,128 |
| 10,000,000 | 3 | 0.000065792 | 0.000081167 | 0.008697208 | 12,009,472 |
| 100,000,000 | 1 | 0.000079958 | 0.000093167 | 0.088101875 | 12,042,240 |
| 100,000,000 | 2 | 0.000065292 | 0.000100125 | 0.086951125 | 12,058,624 |
| 100,000,000 | 3 | 0.000061917 | 0.000078167 | 0.087341125 | 12,091,392 |
| 1,000,000,000 | 1 | 0.000124542 | 0.000100792 | 0.832750750 | 12,124,160 |
| 1,000,000,000 | 2 | 0.000051333 | 0.000091750 | 0.824283375 | 12,124,160 |
| 1,000,000,000 | 3 | 0.000090958 | 0.000083833 | 0.825221167 | 12,124,160 |

Median scan times: 1 MB: 0.000862 s, 10 MB: 0.008835 s, 100 MB: 0.087341 s, 1000 MB: 0.825221 s.

## Outstanding and limitations

- The byte service measurements alone do not verify native viewing, editing, line indexing, encoding-aware window rendering, or folder-search integration. A bounded viewer was subsequently added and checked separately below. These figures do not satisfy the 100 MB usable-editor target, ordinary p95 typing latency, 2-second cold launch target, or 1 GB desktop responsiveness requirement. Root routing, packaged-app validation and full large-file requirements remain separate integration obligations.
- Cancellation is cooperative; a blocked kernel read cannot be preempted by the closure. KMP fallback work is bounded by pattern size but elapsed cancellation latency is not benchmarked here. No separate process or hard I/O deadline is claimed.
- Metadata comparison detects ordinary mutation/replacement/rename/removal. It does not create an immutable snapshot, coordinate other writers, cryptographically hash content, or defeat every concurrent-write race/metadata-granularity limitation. The underlying filesystem controls timestamp fidelity.
- Reading symlink targets is deliberately refused at the leaf; normal parent-directory symlinks resolve before opening. Permissions are left unchanged. No writes or saves occur through the reader.
- Native platform integrations, VoiceOver, IME, scaled display, cold-cache storage behavior, maximal result/pattern peak-memory measurements and Intel execution are not covered. No benchmarks or results are invented for unavailable environments.

## Bounded native viewer follow-up

Implementation: `Sources/TheOnlyPad/LargeFileWindowController.swift`. Interface: `@MainActor init(url: URL)` with optional `onClose` callback. Root integration owns file-size routing and application menu behavior.

The controller displays at most 65,536 source bytes in a selectable, noneditable AppKit text view. A persistent warning explicitly states that UTF-8 display may replace split or invalid characters and that the original file is unchanged. A first-16-byte hexadecimal header provides a byte-level reference. Previous/next and validated zero-based offset navigation fetch pages on workers. Literal UTF-8 search uses the streaming reader, a cancellation token and a 1,000-result cap. Results contain actual byte offsets and selecting one requests the corresponding page. Search state reports Searching with no fabricated percentage. Request generations suppress stale completion after cancellation, closure or failure. Detected mutation clears stale content and disables controls until reopened. There is no save/edit API.

Observed TDD red: minimal controller shell failed with “Missing accessible control: large.text”. Observed green at 12:32:40 local runner time: a real-AppKit, programmatic native harness passed initial 64 KiB rendering (including a synthetic invalid UTF-8 byte), read-only/selectable state, next-page content, negative-offset rejection, literal search, correct byte offset 70000, result navigation, immediate cancellation, changed-file rejection, stale-content removal and unchanged on-disk bytes. This harness instantiated real controls and invoked target-actions; it did not drive physical mouse/keyboard events, Finder routing or accessibility automation. Its fixture was 70,011 bytes, chosen to cross the viewer page boundary. The separate service benchmark exercised the 1 GB file; no 1 GB interactive usability claim follows.

The harness compiled against actual PadCore objects. macOS emitted hiservices XPC connection diagnostics, but all assertions passed. GUI permission/accessibility, VoiceOver, screenshots, user-driven input, scaled layouts and packaged-app large-file workflow remain unverified by this test. The integrated application build passed in 1.88 seconds without compiler warnings. The command is:

```sh
scripts/swift.sh build --scratch-path .build/large
```

For reproducibility, save the harness below to an ignored local file, then compile/run from repository root after building:

```sh
swiftc -module-cache-path .cache/swift -parse-as-library -I .build/large/arm64-apple-macosx/debug/Modules Sources/TheOnlyPad/LargeFileWindowController.swift .local/large-viewer-harness.swift .build/large/arm64-apple-macosx/debug/PadCore.build/*.o -o .build/large-benchmark/viewer-harness
.build/large-benchmark/viewer-harness
```

The recorded module path is the tested arm64 host path, not an Intel compatibility claim. Adapt it to the actual Swift build output on another host.

<details>
<summary>Reproducible native controller harness (synthetic fixtures only)</summary>

```swift
import AppKit
import PadCore

@main
struct ViewerHarness {
    enum Failure: Error { case failed(String) }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-large.bin")
        var bytes = Data([255])
        bytes.append(Data(repeating: 97, count: 69_999))
        bytes.append(Data("tail-marker".utf8))
        try bytes.write(to: url)
        let controller = LargeFileWindowController(url: url)
        func find<T: NSView>(_ id: String, as type: T.Type) throws -> T {
            func descend(_ view: NSView) -> T? {
                if view.identifier?.rawValue == id { return view as? T }
                for child in view.subviews { if let found = descend(child) { return found } }
                return nil
            }
            guard let content = controller.window?.contentView, let view = descend(content) else { throw Failure.failed("Missing accessible control: \(id)") }
            return view
        }
        func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else { throw Failure.failed(description) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<250 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw Failure.failed("Timed out waiting for controller state")
        }
        let text = try find("large.text", as: NSTextView.self)
        let status = try find("large.status", as: NSTextField.self)
        let offset = try find("large.offset", as: NSTextField.self)
        let next = try find("large.next", as: NSButton.self)
        let go = try find("large.go", as: NSButton.self)
        let query = try find("large.query", as: NSTextField.self)
        let search = try find("large.search", as: NSButton.self)
        let cancel = try find("large.cancel", as: NSButton.self)
        let results = try find("large.matches", as: NSPopUpButton.self)
        let searchStatus = try find("large.searchStatus", as: NSTextField.self)
        try await wait { next.isEnabled }
        try require(!text.isEditable && text.isSelectable, "Viewer must be selectable and read-only")
        try require(text.string.utf16.count == 65_536 && text.string.hasPrefix("�"), "Bounded first page must render invalid bytes explicitly")
        next.performClick(nil)
        try await wait { offset.stringValue == "65536" && go.isEnabled }
        try require(text.string.hasSuffix("tail-marker"), "Next page must contain tail")
        offset.stringValue = "-1"
        go.performClick(nil)
        try require(status.stringValue.contains("Invalid byte offset"), "Invalid offset must be actionable")
        query.stringValue = "tail-marker"
        search.performClick(nil)
        try await wait { results.numberOfItems == 1 }
        try require(results.itemTitle(at: 0).contains("70000"), "Result must use source byte offset")
        if let action = results.action { _ = NSApp.sendAction(action, to: results.target, from: results) }
        try await wait { offset.stringValue == "70000" && go.isEnabled }
        try require(text.string == "tail-marker", "Selecting result must navigate")
        query.stringValue = "not present"
        search.performClick(nil)
        cancel.performClick(nil)
        try await wait { searchStatus.stringValue == "Search cancelled." }
        try Data("changed".utf8).write(to: url, options: .atomic)
        offset.stringValue = "0"
        go.performClick(nil)
        try await wait { status.stringValue.contains("File changed") }
        try require(text.string.isEmpty && !go.isEnabled, "Changed file must clear stale view and disable navigation")
        let preserved = try Data(contentsOf: url)
        try require(preserved == Data("changed".utf8), "Viewer must not rewrite original")
        controller.close()
        print("PASS: bounded native viewer controls, read-only bytes, navigation, search, cancellation and mutation rejection")
    }
}
```

</details>
