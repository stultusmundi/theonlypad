// Read-only, synchronous folder replacement preview. Call off the main thread.
// Observed filesystem checks are not an immutable snapshot or authority to write.
import Darwin
import Foundation

public enum FolderReplacementPreviewError: Error, Equatable {
  case invalidRequest, invalidLimits, unsupportedInput, staleInput
  case sourceLimit, outputLimit, retainedLimit, matchLimit, cancelled
}

public struct FolderReplacementPreviewLimits {
  public let maxFiles: Int
  public let maxSourceFileBytes: Int
  public let maxOutputFileBytes: Int
  public let maxRetainedBytes: Int
  public let maxMatches: Int
  public let maxPatternUTF8Bytes: Int
  public let maxReplacementUTF8Bytes: Int

  public init(
    maxFiles: Int = 2,
    maxSourceFileBytes: Int = 1_048_576,
    maxOutputFileBytes: Int = 1_048_576,
    maxRetainedBytes: Int = 4_194_304,
    maxMatches: Int = 1_000,
    maxPatternUTF8Bytes: Int = 4_096,
    maxReplacementUTF8Bytes: Int = 4_096
  ) {
    self.maxFiles = maxFiles
    self.maxSourceFileBytes = maxSourceFileBytes
    self.maxOutputFileBytes = maxOutputFileBytes
    self.maxRetainedBytes = maxRetainedBytes
    self.maxMatches = maxMatches
    self.maxPatternUTF8Bytes = maxPatternUTF8Bytes
    self.maxReplacementUTF8Bytes = maxReplacementUTF8Bytes
  }
}

public struct FolderReplacementPreviewEntry {
  public let url: URL
  public let relativePath: String
  public let originalData: Data
  public let proposedData: Data
  public let ranges: [NSRange]
  public let hasBOM: Bool
  let snapshot: FolderReplacementFileSnapshot
  public var wouldChange: Bool { originalData != proposedData }
}

public struct FolderReplacementPreview {
  public let id: UUID
  public let entries: [FolderReplacementPreviewEntry]
  public let sourceBytes: Int
  public let outputBytes: Int
  public let matchCount: Int
  let rootSnapshot: FolderReplacementRootSnapshot
  private let observedComplete: Bool
  public var isComplete: Bool { observedComplete }

  // Only a successfully computed and revalidated selected set can construct a preview.
  fileprivate init(
    id: UUID, entries: [FolderReplacementPreviewEntry], sourceBytes: Int,
    outputBytes: Int, matchCount: Int, rootSnapshot: FolderReplacementRootSnapshot
  ) {
    self.id = id
    self.entries = entries
    self.sourceBytes = sourceBytes
    self.outputBytes = outputBytes
    self.matchCount = matchCount
    self.rootSnapshot = rootSnapshot
    self.observedComplete = true
  }
}

public struct FolderReplacementPreviewBuilder {
  private let reader: any FolderReplacementSnapshotReading

  public init() { reader = FolderReplacementDefaultSnapshotReader() }
  init(reader: any FolderReplacementSnapshotReading) { self.reader = reader }

  public func preview(
    root: URL,
    selectedURLs: [URL],
    query: SearchQuery,
    replacement: String,
    limits: FolderReplacementPreviewLimits = .init(),
    isCancelled: @escaping () -> Bool = { false }
  ) throws -> FolderReplacementPreview {
    try validate(limits)
    guard case .literal = query.mode,
      !query.pattern.isEmpty,
      query.pattern.utf8.count <= limits.maxPatternUTF8Bytes,
      replacement.utf8.count <= limits.maxReplacementUTF8Bytes,
      selectedURLs.count <= limits.maxFiles,
      FolderReplacementPathPolicy.valid(root, requiresDirectory: true),
      selectedURLs.allSatisfy(validURL)
    else { throw FolderReplacementPreviewError.invalidRequest }
    let urls = selectedURLs
    guard
      Set(urls.map { FolderReplacementPathPolicy.path(FolderReplacementPathPolicy.canonical($0)) })
        .count == urls.count
    else {
      throw FolderReplacementPreviewError.invalidRequest
    }
    try checkCancellation(isCancelled)
    let rootSnapshot = try reader.captureRoot(root, isCancelled: isCancelled)
    var entries: [FolderReplacementPreviewEntry] = []
    var sourceBytes = 0
    var outputBytes = 0
    var matchCount = 0
    var identities: Set<FolderReplacementFilesystemIdentity> = []
    for url in urls {
      try checkCancellation(isCancelled)
      let remaining = limits.maxRetainedBytes - sourceBytes - outputBytes
      let snapshot: FolderReplacementFileSnapshot
      do {
        snapshot = try reader.captureFile(
          url, within: rootSnapshot,
          maximumBytes: min(limits.maxSourceFileBytes, remaining), isCancelled: isCancelled)
      } catch let excess as FolderReplacementSourceBudgetExceeded {
        // Preserve the per-file-versus-aggregate distinction without reading over either budget.
        throw excess.advertisedBytes > Int64(limits.maxSourceFileBytes)
          ? FolderReplacementPreviewError.sourceLimit : FolderReplacementPreviewError.retainedLimit
      }
      try checkCancellation(isCancelled)
      guard snapshot.originalData.count <= limits.maxSourceFileBytes else {
        throw FolderReplacementPreviewError.sourceLimit
      }
      guard snapshot.originalData.count <= remaining else {
        throw FolderReplacementPreviewError.retainedLimit
      }
      guard identities.insert(snapshot.identity).inserted else {
        throw FolderReplacementPreviewError.invalidRequest
      }
      let original = snapshot.originalData
      let bom = original.starts(with: [0xef, 0xbb, 0xbf])
      let content = original.dropFirst(bom ? 3 : 0)
      guard !content.contains(0), let text = String(data: Data(content), encoding: .utf8) else {
        throw FolderReplacementPreviewError.unsupportedInput
      }
      let ranges: [NSRange]
      do {
        ranges = try SearchService(
          maxTextUTF16: limits.maxSourceFileBytes, maxMatches: limits.maxMatches - matchCount,
          isCancelled: isCancelled
        ).matches(query, in: text)
      } catch SearchError.cancelled {
        throw FolderReplacementPreviewError.cancelled
      } catch SearchError.matchLimit {
        throw FolderReplacementPreviewError.matchLimit
      }
      try checkCancellation(isCancelled)
      let proposed = try splice(
        text, original: original, hasBOM: bom, ranges: ranges, replacement: replacement,
        outputLimit: limits.maxOutputFileBytes,
        retainedOutputLimit: remaining - original.count, isCancelled: isCancelled)
      let relative = try FolderReplacementPathPolicy.relativeComponents(
        snapshot.url, within: rootSnapshot.url
      )
      .joined(separator: "/")
      entries.append(
        FolderReplacementPreviewEntry(
          url: snapshot.url, relativePath: relative, originalData: original, proposedData: proposed,
          ranges: ranges, hasBOM: bom, snapshot: snapshot))
      sourceBytes += original.count
      outputBytes += proposed.count
      matchCount += ranges.count
    }
    // No partial result escapes. All retained inputs are checked after every computation.
    for entry in entries {
      try checkCancellation(isCancelled)
      try reader.revalidate(
        entry.snapshot, within: rootSnapshot, maximumBytes: limits.maxSourceFileBytes,
        isCancelled: isCancelled)
    }
    try checkCancellation(isCancelled)
    let finalRoot: FolderReplacementRootSnapshot
    do {
      finalRoot = try reader.captureRoot(rootSnapshot.url, isCancelled: isCancelled)
    } catch FolderReplacementPreviewError.cancelled {
      throw FolderReplacementPreviewError.cancelled
    } catch {
      throw FolderReplacementPreviewError.staleInput
    }
    guard finalRoot == rootSnapshot else { throw FolderReplacementPreviewError.staleInput }
    try checkCancellation(isCancelled)
    return FolderReplacementPreview(
      id: UUID(), entries: entries, sourceBytes: sourceBytes, outputBytes: outputBytes,
      matchCount: matchCount, rootSnapshot: rootSnapshot)
  }

  private func validURL(_ url: URL) -> Bool { FolderReplacementPathPolicy.valid(url) }

  private func validate(_ limits: FolderReplacementPreviewLimits) throws {
    let values = [
      (limits.maxFiles, 2), (limits.maxSourceFileBytes, 1_048_576),
      (limits.maxOutputFileBytes, 1_048_576), (limits.maxRetainedBytes, 4_194_304),
      (limits.maxMatches, 1_000), (limits.maxPatternUTF8Bytes, 4_096),
      (limits.maxReplacementUTF8Bytes, 4_096),
    ]
    guard values.allSatisfy({ $0.0 >= 0 && $0.0 <= $0.1 }) else {
      throw FolderReplacementPreviewError.invalidLimits
    }
  }

  private func checkCancellation(_ isCancelled: () -> Bool) throws {
    if isCancelled() { throw FolderReplacementPreviewError.cancelled }
  }

  private func splice(
    _ text: String, original: Data, hasBOM: Bool, ranges: [NSRange], replacement: String,
    outputLimit: Int, retainedOutputLimit: Int, isCancelled: () -> Bool
  ) throws -> Data {
    // Resolve only scalar-valid, ascending nonoverlapping UTF-16 ranges to UTF-8 views.
    // No full output Data is allocated before both exact encoded-byte budgets pass.
    var segments: [Range<String.UTF8View.Index>] = []
    let utf16 = text.utf16
    let utf8 = text.utf8
    var cursor = utf8.startIndex
    var previousEnd = 0
    var total = hasBOM ? 3 : 0
    for range in ranges {
      try checkCancellation(isCancelled)
      guard range.location >= previousEnd, range.length > 0,
        range.location <= utf16.count, range.length <= utf16.count - range.location,
        let byteStart = utf16.index(utf16.startIndex, offsetBy: range.location).samePosition(
          in: utf8),
        let byteEnd = utf16.index(
          utf16.startIndex, offsetBy: range.location + range.length
        ).samePosition(in: utf8)
      else { throw FolderReplacementPreviewError.unsupportedInput }
      let segment = cursor..<byteStart
      total = try adding(total, utf8[segment].count)
      total = try adding(total, replacement.utf8.count)
      segments.append(segment)
      cursor = byteEnd
      previousEnd = range.location + range.length
    }
    let tail = cursor..<utf8.endIndex
    total = try adding(total, utf8[tail].count)
    guard total <= outputLimit else { throw FolderReplacementPreviewError.outputLimit }
    guard total <= retainedOutputLimit else { throw FolderReplacementPreviewError.retainedLimit }
    try checkCancellation(isCancelled)
    var output = Data()
    output.reserveCapacity(total)
    if hasBOM { output.append(contentsOf: original.prefix(3)) }
    for segment in segments {
      try checkCancellation(isCancelled)
      output.append(contentsOf: utf8[segment])
      output.append(contentsOf: replacement.utf8)
    }
    output.append(contentsOf: utf8[tail])
    guard output.count == total else { throw FolderReplacementPreviewError.unsupportedInput }
    return output
  }

  private func adding(_ a: Int, _ b: Int) throws -> Int {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw FolderReplacementPreviewError.outputLimit }
    return value
  }
}

struct FolderReplacementFilesystemIdentity: Equatable, Hashable {
  let device: UInt64
  let inode: UInt64
}

struct FolderReplacementRootSnapshot: Equatable {
  let url: URL
  let identity: FolderReplacementFilesystemIdentity
  let directoryBindings: [FolderReplacementDirectoryBinding]
}

struct FolderReplacementFileSnapshot: Equatable {
  let url: URL
  let root: FolderReplacementRootSnapshot
  let parentIdentity: FolderReplacementFilesystemIdentity
  let identity: FolderReplacementFilesystemIdentity
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64
  let mode: UInt32
  let owner: UInt32
  let linkCount: UInt64
  let originalData: Data
  let directoryBindings: [FolderReplacementDirectoryBinding]
}

protocol FolderReplacementSnapshotReading {
  func captureRoot(_ url: URL, isCancelled: @escaping () -> Bool) throws
    -> FolderReplacementRootSnapshot
  func captureFile(
    _ url: URL,
    within root: FolderReplacementRootSnapshot,
    maximumBytes: Int,
    isCancelled: @escaping () -> Bool
  ) throws -> FolderReplacementFileSnapshot
  func revalidate(
    _ snapshot: FolderReplacementFileSnapshot,
    within root: FolderReplacementRootSnapshot,
    maximumBytes: Int,
    isCancelled: @escaping () -> Bool
  ) throws
}

// Extra internal ancestry evidence detects substituted intermediate directories, not merely
// root/deepest-parent changes. No directory timestamps are treated as immutable content facts.
struct FolderReplacementDirectoryBinding: Equatable {
  let url: URL
  let identity: FolderReplacementFilesystemIdentity
}

private struct FolderReplacementSourceBudgetExceeded: Error {
  let advertisedBytes: Int64
}

enum FolderReplacementPathPolicy {
  static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

  // Reject serialized filesystem NUL before requesting decoded metadata from Foundation.
  // A literal percent00 filename is serialized as percent2500 and is not decoded twice.
  // Query and fragment data do not belong to the filesystem path.
  private static func serializedPathContainsNUL(_ url: URL) -> Bool {
    var previous: UInt8?
    var beforePrevious: UInt8?
    for byte in url.absoluteString.utf8 {
      if byte == 0x3f || byte == 0x23 { break }
      if byte == 0 || (beforePrevious == 0x25 && previous == 0x30 && byte == 0x30) {
        return true
      }
      beforePrevious = previous
      previous = byte
    }
    return false
  }

  static func valid(
    _ url: URL, requiresDirectory: Bool = false,
    decodedPath: (URL) -> String = FolderReplacementPathPolicy.path
  ) -> Bool {
    guard !serializedPathContainsNUL(url),
      url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost"
    else {
      return false
    }
    let decoded = decodedPath(url)
    // Check NUL before any C-string conversion can hide or truncate it.
    guard !decoded.contains("\0"), decoded.utf8.count <= 4_096, decoded.hasPrefix("/") else {
      return false
    }
    // Selected regular-file inputs cannot silently shed directory-only terminal semantics.
    if !requiresDirectory, url.hasDirectoryPath || decoded.hasSuffix("/") { return false }
    // A URI with conflicting decoded/actual filesystem views cannot choose between two files.
    return url.withUnsafeFileSystemRepresentation { pointer in
      guard let pointer else { return false }
      guard let filesystem = String(validatingCString: pointer) else { return false }
      if filesystem.utf8.elementsEqual(decoded.utf8) { return true }
      // Foundation omits one terminal directory slash in its C representation. Only a caller
      // requiring an actual directory can reconcile that syntax; no-follow opens still decide.
      return requiresDirectory && url.hasDirectoryPath && decoded != "/"
        && decoded.hasSuffix("/") && filesystem.utf8.elementsEqual(decoded.dropLast().utf8)
    }
  }

  static func components(_ url: URL) -> [String] {
    path(url).split(separator: "/").map(String.init)
  }

  // Lexical normalization only. Every representation and syscall derives from decoded POSIX text.
  static func canonical(_ url: URL) -> URL {
    var parts: [String] = []
    for component in components(url) {
      if component == "." { continue }
      if component == ".." {
        if !parts.isEmpty { parts.removeLast() }
      } else {
        parts.append(component)
      }
    }
    return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: false)
  }

  static func parent(_ url: URL) -> URL {
    let decoded = path(url)
    guard let separator = decoded.lastIndex(of: "/"), separator != decoded.startIndex else {
      return URL(fileURLWithPath: "/", isDirectory: false)
    }
    return URL(fileURLWithPath: String(decoded[..<separator]), isDirectory: false)
  }

  static func relativeComponents(_ url: URL, within root: URL) throws -> [String] {
    let rootParts = components(canonical(root))
    let parts = components(canonical(url))
    guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    return Array(parts.dropFirst(rootParts.count))
  }
}

struct FolderReplacementDefaultSnapshotReader: FolderReplacementSnapshotReading {

  func captureRoot(_ url: URL, isCancelled: @escaping () -> Bool) throws
    -> FolderReplacementRootSnapshot
  {
    guard FolderReplacementPathPolicy.valid(url, requiresDirectory: true) else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    let canonical = FolderReplacementPathPolicy.canonical(url)
    // If dot components normalize away, still observe every original directory component
    // first, so a symlink followed by ".." cannot disappear from admission.
    try verifyOriginalTraversal(url, canonical: canonical, isCancelled: isCancelled)
    let opened = try openDirectory(canonical, isCancelled: isCancelled)
    defer { close(opened.descriptor) }
    try verifyDirectoryBindings(opened.bindings, isCancelled: isCancelled)
    let info = try descriptorStat(opened.descriptor)
    guard let final = opened.bindings.last, final.identity == identity(info) else {
      throw FolderReplacementPreviewError.staleInput
    }
    return FolderReplacementRootSnapshot(
      url: canonical, identity: identity(info), directoryBindings: opened.bindings)
  }

  func captureFile(
    _ url: URL, within root: FolderReplacementRootSnapshot,
    maximumBytes: Int, isCancelled: @escaping () -> Bool
  ) throws -> FolderReplacementFileSnapshot {
    try checkCancellation(isCancelled)
    guard FolderReplacementPathPolicy.valid(url), (0...1_048_576).contains(maximumBytes) else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    guard !FolderReplacementPathPolicy.path(url).hasSuffix("/") else {
      // A directory-only terminal slash must not be stripped into a regular-file request.
      throw FolderReplacementPreviewError.unsupportedInput
    }
    let canonical = FolderReplacementPathPolicy.canonical(url)
    _ = try FolderReplacementPathPolicy.relativeComponents(canonical, within: root.url)
    try verifyOriginalTraversal(
      FolderReplacementPathPolicy.parent(url),
      canonical: FolderReplacementPathPolicy.parent(canonical),
      isCancelled: isCancelled)
    let parent = FolderReplacementPathPolicy.parent(canonical)
    let directory = try openDirectory(parent, isCancelled: isCancelled)
    defer { close(directory.descriptor) }
    guard directory.bindings.count >= root.directoryBindings.count,
      Array(directory.bindings.prefix(root.directoryBindings.count)) == root.directoryBindings,
      directory.bindings.contains(where: {
        FolderReplacementPathPolicy.path($0.url) == FolderReplacementPathPolicy.path(root.url)
          && $0.identity == root.identity
      })
    else { throw FolderReplacementPreviewError.staleInput }
    let parentInfo = try descriptorStat(directory.descriptor)
    guard let name = FolderReplacementPathPolicy.components(canonical).last else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    let descriptor = openat(
      directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { try throwOpenFailure() }
    defer { close(descriptor) }
    let before = try descriptorStat(descriptor)
    try validateFilePolicy(before)
    guard before.st_size >= 0 else { throw FolderReplacementPreviewError.unsupportedInput }
    guard before.st_size <= Int64(maximumBytes) else {
      throw FolderReplacementSourceBudgetExceeded(advertisedBytes: before.st_size)
    }
    let pathBefore = try entryStat(directory.descriptor, name: name)
    guard sameFileMetadata(before, pathBefore) else {
      throw FolderReplacementPreviewError.staleInput
    }
    try verifyDirectoryBindings(directory.bindings, isCancelled: isCancelled)
    try checkCancellation(isCancelled)
    // Stat and remaining aggregate budget have passed before the bounded source allocation.
    let count = Int(before.st_size)
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      var received = 0
      while received < count {
        try checkCancellation(isCancelled)
        let window = min(65_536, count - received)
        let result = pread(
          descriptor, buffer.baseAddress!.advanced(by: received), window, Int64(received))
        if result < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        guard result > 0 else { throw FolderReplacementPreviewError.staleInput }
        received += result
      }
    }
    try checkCancellation(isCancelled)
    let after = try descriptorStat(descriptor)
    let pathAfter = try entryStat(directory.descriptor, name: name)
    guard sameFileMetadata(before, after), sameFileMetadata(before, pathAfter),
      identity(try descriptorStat(directory.descriptor)) == identity(parentInfo)
    else { throw FolderReplacementPreviewError.staleInput }
    try verifyDirectoryBindings(directory.bindings, isCancelled: isCancelled)
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    return FolderReplacementFileSnapshot(
      url: canonical, root: root, parentIdentity: identity(parentInfo), identity: identity(before),
      size: before.st_size, modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec),
      changedSeconds: Int64(before.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(before.st_ctimespec.tv_nsec),
      mode: UInt32(before.st_mode), owner: UInt32(before.st_uid),
      linkCount: UInt64(before.st_nlink),
      originalData: data, directoryBindings: directory.bindings)
  }

  func revalidate(
    _ snapshot: FolderReplacementFileSnapshot,
    within root: FolderReplacementRootSnapshot,
    maximumBytes: Int, isCancelled: @escaping () -> Bool
  ) throws {
    try checkCancellation(isCancelled)
    let fresh: FolderReplacementFileSnapshot
    do {
      fresh = try captureFile(
        snapshot.url, within: root, maximumBytes: maximumBytes, isCancelled: isCancelled)
    } catch FolderReplacementPreviewError.cancelled {
      throw FolderReplacementPreviewError.cancelled
    } catch is FolderReplacementSourceBudgetExceeded {
      throw FolderReplacementPreviewError.staleInput
    } catch FolderReplacementPreviewError.unsupportedInput {
      throw FolderReplacementPreviewError.staleInput
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain
      && [ENOENT, ENOTDIR, ELOOP].contains(Int32(error.code))
    {
      throw FolderReplacementPreviewError.staleInput
    }
    guard fresh == snapshot, snapshot.root == root else {
      throw FolderReplacementPreviewError.staleInput
    }
    try checkCancellation(isCancelled)
  }

  private func checkCancellation(_ isCancelled: () -> Bool) throws {
    if isCancelled() { throw FolderReplacementPreviewError.cancelled }
  }

  private func identity(_ info: stat) -> FolderReplacementFilesystemIdentity {
    FolderReplacementFilesystemIdentity(
      device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
  }

  private func descriptorStat(_ descriptor: Int32) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    return info
  }

  private func entryStat(_ directory: Int32, name: String) throws -> stat {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
    return info
  }

  private func validateFilePolicy(_ info: stat) throws {
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
      info.st_mode & 0o222 != 0
    else { throw FolderReplacementPreviewError.unsupportedInput }
  }

  private func sameFileMetadata(_ a: stat, _ b: stat) -> Bool {
    identity(a) == identity(b) && a.st_size == b.st_size && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }

  private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  private func throwOpenFailure() throws -> Never {
    let code = errno
    if code == ELOOP || code == ENOTDIR { throw FolderReplacementPreviewError.unsupportedInput }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }

  private func verifyDirectoryBindings(
    _ bindings: [FolderReplacementDirectoryBinding], isCancelled: () -> Bool
  ) throws {
    for binding in bindings {
      try checkCancellation(isCancelled)
      var info = stat()
      guard lstat(FolderReplacementPathPolicy.path(binding.url), &info) == 0 else {
        throw posixError()
      }
      guard info.st_mode & S_IFMT == S_IFDIR, identity(info) == binding.identity else {
        throw FolderReplacementPreviewError.staleInput
      }
    }
  }

  private func verifyOriginalTraversal(
    _ original: URL, canonical: URL, isCancelled: () -> Bool
  ) throws {
    guard FolderReplacementPathPolicy.path(original) != FolderReplacementPathPolicy.path(canonical)
    else { return }
    let opened = try openDirectory(original, isCancelled: isCancelled)
    defer { close(opened.descriptor) }
    try verifyDirectoryBindings(opened.bindings, isCancelled: isCancelled)
  }

  private func openDirectory(
    _ url: URL, isCancelled: () -> Bool
  ) throws -> (descriptor: Int32, bindings: [FolderReplacementDirectoryBinding]) {
    try checkCancellation(isCancelled)
    // Walk from the actual filesystem root. Every component is opened relative to its
    // observed parent with O_NOFOLLOW; resolvingSymlinksInPath never authorizes admission.
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { try throwOpenFailure() }
    do {
      var bindings = [
        FolderReplacementDirectoryBinding(
          url: URL(fileURLWithPath: "/", isDirectory: false),
          identity: identity(try descriptorStat(descriptor)))
      ]
      var currentPath = "/"
      for component in FolderReplacementPathPolicy.components(url) {
        try checkCancellation(isCancelled)
        let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { try throwOpenFailure() }
        do {
          let opened = try descriptorStat(next)
          let named = try entryStat(descriptor, name: component)
          guard opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
            identity(opened) == identity(named)
          else { throw FolderReplacementPreviewError.staleInput }
          currentPath += (currentPath == "/" ? "" : "/") + component
          bindings.append(
            FolderReplacementDirectoryBinding(
              url: URL(fileURLWithPath: currentPath, isDirectory: false), identity: identity(opened)
            ))
        } catch {
          close(next)
          throw error
        }
        close(descriptor)
        descriptor = next
      }
      try verifyDirectoryBindings(bindings, isCancelled: isCancelled)
      return (descriptor, bindings)
    } catch {
      close(descriptor)
      throw error
    }
  }
}
