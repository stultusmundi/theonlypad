import Darwin
import Foundation

public struct FolderSearchLimits: Sendable {
  public let maxFiles: Int, maxFileBytes: Int, maxMatches: Int, maxSnapshotBytes: Int
  public init(
    maxFiles: Int = 50_000, maxFileBytes: Int = 10_000_000, maxMatches: Int = 10_000,
    maxSnapshotBytes: Int = 100_000_000
  ) {
    self.maxFiles = maxFiles
    self.maxFileBytes = maxFileBytes
    self.maxMatches = maxMatches
    self.maxSnapshotBytes = maxSnapshotBytes
  }
}
public struct FolderSearchHit: Sendable {
  public let url: URL, relativePath: String, range: NSRange, originalText: String
}
public struct FolderSearchProgress: Sendable { public let filesProcessed: Int, filesTotal: Int }
public struct FolderSearchReport: Sendable {
  public var hits: [FolderSearchHit] = []
  public var skippedBinary = 0, skippedUnreadable = 0, skippedSize = 0, skippedGlob = 0
}
public enum FolderSearchError: Error { case invalidLimit, invalidGlob, snapshotLimit, cancelled }
public enum FolderSearch {
  public static func search(
    root: URL, query: SearchQuery, includes: [String] = ["*"], excludes: [String] = [],
    limits: FolderSearchLimits = .init(), isCancelled: @escaping () -> Bool = { false },
    onProgress: (FolderSearchProgress) -> Void = { _ in }
  ) throws -> FolderSearchReport {
    guard (0...50_000).contains(limits.maxFiles), (0...10_000_000).contains(limits.maxFileBytes),
      (0...10_000).contains(limits.maxMatches), (0...100_000_000).contains(limits.maxSnapshotBytes)
    else { throw FolderSearchError.invalidLimit }
    guard includes.count <= 32, excludes.count <= 32,
      (includes + excludes).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
      })
    else { throw FolderSearchError.invalidGlob }
    func check() throws { if isCancelled() { throw FolderSearchError.cancelled } }
    try check()
    _ = try SearchService(isCancelled: isCancelled).matches(query, in: "")
    let entries = try WorkspaceIndex.scan(
      root: root, limit: limits.maxFiles, isCancelled: isCancelled)
    var report = FolderSearchReport()
    var snapshotBytes = 0
    func matchesGlob(_ glob: String, _ entry: WorkspaceEntry) -> Bool {
      let target = glob.contains("/") ? entry.relativePath : entry.url.lastPathComponent
      return fnmatch(glob, target, FNM_PATHNAME) == 0
    }
    onProgress(.init(filesProcessed: 0, filesTotal: entries.count))
    for (index, entry) in entries.enumerated() {
      try check()
      defer { onProgress(.init(filesProcessed: index + 1, filesTotal: entries.count)) }
      guard includes.isEmpty || includes.contains(where: { matchesGlob($0, entry) }),
        !excludes.contains(where: { matchesGlob($0, entry) })
      else {
        report.skippedGlob += 1
        continue
      }
      let bytes: Data
      do {
        let url = try WorkspaceIndex.validatedFile(entry.url, within: root)
        let reader = try LargeFileReader(url: url)
        guard reader.identity.size <= limits.maxFileBytes else {
          report.skippedSize += 1
          continue
        }
        var data = Data()
        var offset: Int64 = 0
        while offset < reader.identity.size {
          try check()
          let window = try reader.readWindow(
            offset: offset, length: min(1_048_576, Int(reader.identity.size - offset)))
          data.append(window)
          offset += Int64(window.count)
        }
        _ = try reader.readWindow(offset: offset, length: 0)
        _ = try WorkspaceIndex.validatedFile(entry.url, within: root)
        bytes = data
      } catch FolderSearchError.cancelled { throw FolderSearchError.cancelled } catch LargeFileError
        .fileTooLarge
      {
        report.skippedSize += 1
        continue
      } catch {
        report.skippedUnreadable += 1
        continue
      }
      guard !bytes.contains(0), let text = try? DocumentCodec.decode(bytes, encoding: .utf8).text
      else {
        report.skippedBinary += 1
        continue
      }
      let ranges = try SearchService(
        maxTextUTF16: limits.maxFileBytes, maxMatches: limits.maxMatches - report.hits.count,
        isCancelled: isCancelled
      ).matches(query, in: text)
      if !ranges.isEmpty {
        guard bytes.count <= limits.maxSnapshotBytes - snapshotBytes else {
          throw FolderSearchError.snapshotLimit
        }
        snapshotBytes += bytes.count
        report.hits.append(
          contentsOf: ranges.map {
            FolderSearchHit(
              url: entry.url, relativePath: entry.relativePath, range: $0, originalText: text)
          })
      }
    }
    try check()
    return report
  }
}
