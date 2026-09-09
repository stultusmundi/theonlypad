import Darwin
import Foundation

public enum SaveFault: Sendable { case beforeWrite, afterWrite, beforeReplace, diskFull }
public enum FileStoreError: Error, LocalizedError {
  case externalChange, unsafeTarget, readOnly, injectedFailure
  public var errorDescription: String? {
    switch self {
    case .externalChange:
      return "The file changed on disk. Reload or save your edits to a different file."
    case .unsafeTarget: return "The destination must be a regular file, not a symbolic link."
    case .readOnly: return "The file is read-only. Save your edits to a different file."
    case .injectedFailure: return "The save was interrupted before replacing the original."
    }
  }
}

/// Synchronous I/O. Call off the main thread. Existing files are checked twice;
/// arbitrary external writers can still race the last check and POSIX rename.
public struct AtomicFileStore: Sendable {
  public init() {}
  public func save(_ data: Data, to url: URL, expected: Data?, fault: SaveFault? = nil) throws {
    guard url.isFileURL else { throw FileStoreError.unsafeTarget }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    let destination = parent.appendingPathComponent(url.lastPathComponent)
    let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw posixError() }
    defer { close(directory) }
    let name = destination.lastPathComponent
    func check() throws -> mode_t {
      let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      if descriptor < 0 {
        if errno == ENOENT && expected == nil { return 0o600 }
        if errno == ELOOP { throw FileStoreError.unsafeTarget }
        if errno == ENOENT { throw FileStoreError.externalChange }
        throw posixError()
      }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0 else { throw posixError() }
      guard info.st_mode & S_IFMT == S_IFREG else { throw FileStoreError.unsafeTarget }
      guard info.st_mode & 0o222 != 0 else { throw FileStoreError.readOnly }
      guard let expected else { throw FileStoreError.externalChange }
      guard info.st_size == expected.count, expected.count < Int.max else {
        throw FileStoreError.externalChange
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      // An external writer may grow the file after fstat. Never read unbounded
      // data merely to decide whether the original bytes are unchanged.
      guard try (handle.read(upToCount: expected.count + 1) ?? Data()) == expected else {
        throw FileStoreError.externalChange
      }
      return info.st_mode & 0o777
    }
    let mode = try check()
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
    try handle.write(contentsOf: data)
    if fault == .afterWrite { throw FileStoreError.injectedFailure }
    guard fchmod(descriptor, mode) == 0 else { throw posixError() }
    try handle.synchronize()
    _ = try check()
    if fault == .beforeReplace { throw FileStoreError.injectedFailure }
    if expected == nil {
      // Exclusive rename avoids overwriting a file created after the check.
      guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
        throw posixError()
      }
    } else {
      guard renameat(directory, temporary, directory, name) == 0 else { throw posixError() }
    }
    // A post-rename sync error is intentionally not reported as an untouched-original failure.
    _ = fsync(directory)
  }
  private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
