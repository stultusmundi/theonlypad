import Foundation
import Darwin

// Compile together with Sources/PadCore/LargeFileReader.swift using swiftc -O.
// Generates only synthetic files in a new private directory under ignored .local.
@main
struct LargeFileBenchmark {
    struct Measurement: Codable {
        let bytes: Int64
        let run: Int
        let openSeconds: Double
        let windowBytes: Int
        let windowSeconds: Double
        let searchSeconds: Double
        let matches: [Int64]
        let processPeakRSSBytes: Int64
    }
    struct Report: Codable {
        let generatedAt: String
        let operatingSystem: String
        let architecture: String
        let processor: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let optimization: String
        let chunkBytes: Int
        let patternBytes: Int
        let cacheConditions: String
        let rssScope: String
        let measurements: [Measurement]
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/large-file-benchmarks", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let chunkSize = 1_048_576
        let marker = Data("THEONLYPAD-MATCH!".utf8)
        var measurements: [Measurement] = []
        for size: Int64 in [1_000_000, 10_000_000, 100_000_000, 1_000_000_000] {
            let file = directory.appendingPathComponent("synthetic-\(size).bin")
            let expected = [min(Int64(chunkSize - 8), size / 2), size - Int64(marker.count)]
            try generate(file: file, size: size, chunkSize: chunkSize, marker: marker, positions: expected)
            for run in 1...3 {
                let started = ProcessInfo.processInfo.systemUptime
                let reader = try LargeFileReader(url: file, chunkSize: chunkSize)
                let opened = ProcessInfo.processInfo.systemUptime
                let window = try reader.readWindow(offset: size / 2, length: chunkSize)
                let windowed = ProcessInfo.processInfo.systemUptime
                let matches = try reader.searchLiteral(marker, limit: 10)
                let searched = ProcessInfo.processInfo.systemUptime
                guard matches == expected else { throw BenchmarkError.wrongMatches }
                var usage = rusage()
                guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw posixError() }
                measurements.append(Measurement(bytes: size, run: run, openSeconds: opened - started,
                    windowBytes: window.count, windowSeconds: windowed - opened,
                    searchSeconds: searched - windowed, matches: matches, processPeakRSSBytes: Int64(usage.ru_maxrss)))
                fputs("Measured \(size) bytes, run \(run): search \(String(format: "%.3f", searched - windowed)) s\n", stderr)
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "other"
        #endif
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture, processor: processorName(), processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, optimization: "swiftc -O",
            chunkBytes: chunkSize, patternBytes: marker.count,
            cacheConditions: "Fresh streaming generation followed by three repeated reads; filesystem caches not flushed. Concurrent development activity may affect results.",
            rssScope: "Darwin getrusage ru_maxrss bytes: cumulative process high-water including fixture generation and earlier sizes, not isolated per-operation allocation.",
            measurements: measurements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(report)
        let reportURL = directory.appendingPathComponent("results.json")
        let reportDescriptor = open(reportURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard reportDescriptor >= 0 else { throw posixError() }
        let reportHandle = FileHandle(fileDescriptor: reportDescriptor, closeOnDealloc: true)
        try reportHandle.write(contentsOf: bytes)
        try reportHandle.synchronize()
        try reportHandle.close()
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func generate(file: URL, size: Int64, chunkSize: Int, marker: Data, positions: [Int64]) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x61, count: chunkSize)
        var written: Int64 = 0
        while written < size {
            let count = Int(min(Int64(chunkSize), size - written))
            try handle.write(contentsOf: count == chunkSize ? chunk : chunk.prefix(count))
            written += Int64(count)
        }
        for position in positions {
            try handle.seek(toOffset: UInt64(position))
            try handle.write(contentsOf: marker)
        }
        try handle.synchronize()
    }

    private static func processorName() -> String {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private enum BenchmarkError: Error { case wrongMatches }
}
