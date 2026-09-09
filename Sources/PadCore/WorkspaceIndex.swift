import Foundation

public struct WorkspaceEntry: Equatable, Sendable {
  public let url: URL
  public let relativePath: String
  public init(url: URL, relativePath: String) {
    self.url = url
    self.relativePath = relativePath
  }
}
public enum WorkspaceIndexError: Error, Equatable {
  case invalidRoot, unsafeFile, outsideRoot, invalidLimit, pathLimit, cancelled
}
/// Synchronous metadata-only discovery. Call from a worker; no config is executed.
public enum WorkspaceIndex {
  public static func scan(
    root: URL, limit: Int = 50_000, isCancelled: () -> Bool = { false },
    onProgress: (Int) -> Void = { _ in }
  ) throws -> [WorkspaceEntry] {
    guard (0...50_000).contains(limit) else { throw WorkspaceIndexError.invalidLimit }
    if isCancelled() { throw WorkspaceIndexError.cancelled }
    let root = try canonicalRoot(root)
    let prefix = root.path == "/" ? "/" : root.path + "/"
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
    ]
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw WorkspaceIndexError.invalidRoot
    }
    let ignored: Set<String> = [".git", ".build", "node_modules"]
    var visited = 0
    var entries: [WorkspaceEntry] = []
    onProgress(0)
    for case let url as URL in enumerator {
      if isCancelled() { throw WorkspaceIndexError.cancelled }
      guard visited < limit else { throw WorkspaceIndexError.pathLimit }
      visited += 1
      if visited == 1 || visited.isMultiple(of: 128) { onProgress(visited) }
      let values = try url.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true || values.isHidden == true
        || url.lastPathComponent.hasPrefix(".")
      {
        enumerator.skipDescendants()
        continue
      }
      if values.isDirectory == true {
        if ignored.contains(url.lastPathComponent) { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true else { continue }
      let resolved = try validatedFile(url, within: root)
      guard resolved.path.hasPrefix(prefix) else { throw WorkspaceIndexError.outsideRoot }
      entries.append(
        WorkspaceEntry(url: resolved, relativePath: String(resolved.path.dropFirst(prefix.count))))
    }
    if let enumerationError { throw enumerationError }
    if isCancelled() { throw WorkspaceIndexError.cancelled }
    _ = try canonicalRoot(root)
    onProgress(visited)
    return entries.sorted {
      let order = $0.relativePath.localizedStandardCompare($1.relativePath)
      return order == .orderedSame ? $0.relativePath < $1.relativePath : order == .orderedAscending
    }
  }

  public static func filtered(_ entries: [WorkspaceEntry], query: String) -> [WorkspaceEntry] {
    guard !query.isEmpty else { return entries }
    return entries.filter { $0.relativePath.localizedCaseInsensitiveContains(query) }
  }

  /// Revalidate immediately before requesting document open. The URL handoff is
  /// not an atomic filesystem snapshot; the document owner must validate its read.
  public static func validatedFile(_ url: URL, within root: URL) throws -> URL {
    guard url.isFileURL else { throw WorkspaceIndexError.unsafeFile }
    let root = try canonicalRoot(root)
    let candidate = URL(fileURLWithPath: url.path).standardizedFileURL
    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw WorkspaceIndexError.unsafeFile
    }
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    let prefix = root.path == "/" ? "/" : root.path + "/"
    guard resolved.path.hasPrefix(prefix) else { throw WorkspaceIndexError.outsideRoot }
    // Enumeration provides canonical URLs; reject substituted parent symlinks too.
    guard candidate.path == resolved.path else { throw WorkspaceIndexError.unsafeFile }
    return resolved
  }

  private static func canonicalRoot(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw WorkspaceIndexError.invalidRoot }
    let fresh = URL(fileURLWithPath: url.path)
    let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw WorkspaceIndexError.invalidRoot
    }
    return fresh.resolvingSymlinksInPath().standardizedFileURL
  }
}
