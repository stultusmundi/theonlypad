import Darwin
import Foundation

public enum SaveFault: Sendable {
  case beforeWrite, afterWrite, beforeReplace, diskFull, partialWrite, fileSync, directorySync
}
public enum SaveBoundary: Sendable {
  case afterInitialCheck, beforeReplace, afterFinalCheck, afterReplace
}

/// Evidence of the inode published by this operation, not a durability acknowledgement.
/// Keep it with the exact attempted bytes. Identity is intentionally opaque to callers.
public struct FilePublicationEvidence: Sendable {
  public let destination: URL
  fileprivate let parent: FileIdentity
  fileprivate let file: FileIdentity
}
private struct FileIdentity: Sendable, Equatable {
  let device: dev_t
  let inode: ino_t
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}
public enum FileStoreError: Error, LocalizedError {
  case externalChange, unsafeTarget, readOnly, injectedFailure
  case publicationUncertain(FilePublicationEvidence)
  public var errorDescription: String? {
    switch self {
    case .externalChange:
      return
        "The file or its containing folder changed on disk. Reload or save your edits to a different file."
    case .unsafeTarget: return "The destination must be a regular file, not a symbolic link."
    case .readOnly: return "The file is read-only. Save your edits to a different file."
    case .injectedFailure: return "The save was interrupted before replacing the original."
    case .publicationUncertain:
      return
        "The new file may have been written, but its location or durability could not be confirmed. Keep your edits and verify the destination before retrying."
    }
  }
}

/// Synchronous I/O. Call off the main thread. Existing files are checked twice;
/// arbitrary external writers can still race the last check and POSIX rename.
public struct AtomicFileStore: Sendable {
  public init() {}
  public func save(
    _ data: Data, to url: URL, expected: Data?, fault: SaveFault? = nil,
    boundaryHook: (@Sendable (SaveBoundary) throws -> Void)? = nil
  ) throws {
    guard url.isFileURL else { throw FileStoreError.unsafeTarget }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw posixError() }
    defer { close(directory) }
    let parentIdentity = FileIdentity(try metadata(directory))
    let name = url.lastPathComponent
    func check() throws -> mode_t {
      let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      if descriptor < 0 {
        if errno == ENOENT && expected == nil { return 0o600 }
        if errno == ELOOP { throw FileStoreError.unsafeTarget }
        if errno == ENOENT { throw FileStoreError.externalChange }
        throw posixError()
      }
      defer { close(descriptor) }
      let info = try metadata(descriptor)
      guard info.st_mode & S_IFMT == S_IFREG else { throw FileStoreError.unsafeTarget }
      guard info.st_mode & 0o222 != 0 else { throw FileStoreError.readOnly }
      guard let expected else { throw FileStoreError.externalChange }
      try compareBytes(descriptor, info: info, expected: expected)
      return info.st_mode & 0o777
    }
    try validateParent(url, identity: parentIdentity)
    let mode = try check()
    try boundaryHook?(.afterInitialCheck)
    if fault == .beforeWrite { throw FileStoreError.injectedFailure }
    let temporary = ".theonlypad-" + UUID().uuidString
    let descriptor = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    defer {
      close(descriptor)
      unlinkat(directory, temporary, 0)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    if fault == .diskFull { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
    if fault == .partialWrite {
      try handle.write(contentsOf: data.prefix(max(1, data.count / 2)))
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
    try handle.write(contentsOf: data)
    if fault == .afterWrite { throw FileStoreError.injectedFailure }
    guard fchmod(descriptor, mode) == 0 else { throw posixError() }
    if fault == .fileSync { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
    try handle.synchronize()
    try boundaryHook?(.beforeReplace)
    try validateParent(url, identity: parentIdentity)
    _ = try check()
    try boundaryHook?(.afterFinalCheck)
    if fault == .beforeReplace { throw FileStoreError.injectedFailure }
    // The still-owned temporary descriptor identifies our publication even if its pathname
    // is replaced immediately after rename. Never infer evidence from a later pathname open.
    let evidence = FilePublicationEvidence(
      destination: url, parent: parentIdentity, file: FileIdentity(try metadata(descriptor)))
    if expected == nil {
      guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
        throw posixError()
      }
    } else {
      guard renameat(directory, temporary, directory, name) == 0 else { throw posixError() }
    }
    do {
      try boundaryHook?(.afterReplace)
      if fault == .directorySync { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
      guard fsync(directory) == 0 else { throw posixError() }
      try validateParent(url, identity: parentIdentity)
      var published = stat()
      guard fstatat(directory, name, &published, AT_SYMLINK_NOFOLLOW) == 0,
        published.st_mode & S_IFMT == S_IFREG, FileIdentity(published) == evidence.file
      else { throw FileStoreError.externalChange }
    } catch {
      throw FileStoreError.publicationUncertain(evidence)
    }
  }

  /// Bounded, exact readback of the attempted publication. This is not a sync or a save;
  /// callers must perform a fresh successful save before reporting acknowledged durability.
  public func validatePublication(_ evidence: FilePublicationEvidence, expected: Data) throws {
    let url = evidence.destination
    try validateParent(url, identity: evidence.parent)
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw posixError() }
    defer { close(directory) }
    guard FileIdentity(try metadata(directory)) == evidence.parent else {
      throw FileStoreError.externalChange
    }
    let descriptor = openat(
      directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw FileStoreError.externalChange }
    defer { close(descriptor) }
    let before = try metadata(descriptor)
    guard before.st_mode & S_IFMT == S_IFREG, FileIdentity(before) == evidence.file else {
      throw FileStoreError.externalChange
    }
    try compareBytes(descriptor, info: before, expected: expected)
    let after = try metadata(descriptor)
    var path = stat()
    guard fstatat(directory, url.lastPathComponent, &path, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, path)
    else { throw FileStoreError.externalChange }
    try validateParent(url, identity: evidence.parent)
  }

  private func validateParent(_ url: URL, identity: FileIdentity) throws {
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw FileStoreError.externalChange }
    defer { close(descriptor) }
    guard FileIdentity(try metadata(descriptor)) == identity else {
      throw FileStoreError.externalChange
    }
  }
  private func compareBytes(_ descriptor: Int32, info: stat, expected: Data) throws {
    guard info.st_size == expected.count, expected.count < Int.max else {
      throw FileStoreError.externalChange
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard try (handle.read(upToCount: expected.count + 1) ?? Data()) == expected else {
      throw FileStoreError.externalChange
    }
  }
  private func metadata(_ descriptor: Int32) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    return info
  }
  private func stable(_ a: stat, _ b: stat) -> Bool {
    FileIdentity(a) == FileIdentity(b) && a.st_mode == b.st_mode && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
