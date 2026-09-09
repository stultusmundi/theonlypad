import Darwin
import Foundation

public struct LargeFileIdentity: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let size: Int64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64
  public let changedSeconds: Int64
  public let changedNanoseconds: Int64
}
public enum LargeFileError: Error, Equatable {
  case unsafeFile, fileTooLarge, changed, invalidWindow, invalidPattern, invalidLimit, resultLimit,
    cancelled
}
/// Byte-oriented, synchronous reader. Use from a worker. Metadata checks detect
/// ordinary changes, but do not constitute an immutable filesystem snapshot.
public final class LargeFileReader {
  public static let maximumFileSize: Int64 = 1_000_000_000
  public static let maximumWindowSize = 1_048_576
  public let identity: LargeFileIdentity
  private let descriptor: Int32
  private let url: URL
  private let chunkSize: Int

  public init(url: URL, chunkSize: Int = 1_048_576) throws {
    guard url.isFileURL else { throw LargeFileError.unsafeFile }
    guard (1...Self.maximumWindowSize).contains(chunkSize) else {
      throw LargeFileError.invalidWindow
    }
    let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(
      url.lastPathComponent)
    let fd = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ELOOP { throw LargeFileError.unsafeFile }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let captured: LargeFileIdentity
    do {
      var info = stat()
      guard fstat(fd, &info) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      guard info.st_mode & S_IFMT == S_IFREG else { throw LargeFileError.unsafeFile }
      guard info.st_size >= 0, info.st_size <= Self.maximumFileSize else {
        throw LargeFileError.fileTooLarge
      }
      captured = Self.identity(info)
      var pathInfo = stat()
      guard lstat(resolved.path, &pathInfo) == 0, pathInfo.st_mode & S_IFMT == S_IFREG,
        Self.identity(pathInfo) == captured
      else { throw LargeFileError.changed }
    } catch {
      close(fd)
      throw error
    }
    self.descriptor = fd
    self.identity = captured
    self.url = resolved
    self.chunkSize = chunkSize
  }

  deinit { close(descriptor) }

  public func readWindow(offset: Int64, length: Int) throws -> Data {
    guard offset >= 0, offset <= identity.size,
      (0...Self.maximumWindowSize).contains(length)
    else { throw LargeFileError.invalidWindow }
    try verifyIdentity()
    let count = Int(min(Int64(length), identity.size - offset))
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      var received = 0
      while received < count {
        let result = pread(
          descriptor, buffer.baseAddress!.advanced(by: received), count - received,
          offset + Int64(received))
        if result < 0 {
          if errno == EINTR { continue }
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard result > 0 else { throw LargeFileError.changed }
        received += result
      }
    }
    try verifyIdentity()
    return data
  }

  /// Returns overlapping byte offsets, never text/UTF-16 positions. Throws on
  /// result overflow so callers cannot mistake a truncated list for all matches.
  public func searchLiteral(
    _ pattern: Data, limit: Int = 100_000,
    cancellation: () -> Bool = { false }
  ) throws -> [Int64] {
    guard !pattern.isEmpty, pattern.count <= Self.maximumWindowSize else {
      throw LargeFileError.invalidPattern
    }
    guard (0...1_000_000).contains(limit) else { throw LargeFileError.invalidLimit }
    if cancellation() { throw LargeFileError.cancelled }
    try verifyIdentity()
    let needle = Array(pattern)
    var prefix = [Int](repeating: 0, count: needle.count)
    var matched = 0
    if needle.count > 1 {
      for index in 1..<needle.count {
        if index & 0xFFFF == 0, cancellation() { throw LargeFileError.cancelled }
        while matched > 0, needle[index] != needle[matched] { matched = prefix[matched - 1] }
        if needle[index] == needle[matched] { matched += 1 }
        prefix[index] = matched
      }
    }
    var offsets: [Int64] = []
    var offset: Int64 = 0
    matched = 0
    while offset < identity.size {
      if cancellation() { throw LargeFileError.cancelled }
      let data = try readWindow(offset: offset, length: chunkSize)
      try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for index in 0..<bytes.count {
          if index & 0xFFFF == 0, cancellation() { throw LargeFileError.cancelled }
          let byte = bytes[index]
          while matched > 0, byte != needle[matched] { matched = prefix[matched - 1] }
          if byte == needle[matched] { matched += 1 }
          if matched == needle.count {
            guard offsets.count < limit else { throw LargeFileError.resultLimit }
            offsets.append(offset + Int64(index + 1 - needle.count))
            matched = prefix[matched - 1]
          }
        }
      }
      try verifyIdentity()
      offset += Int64(data.count)
    }
    if cancellation() { throw LargeFileError.cancelled }
    try verifyIdentity()
    return offsets
  }

  private func verifyIdentity() throws {
    var descriptorInfo = stat()
    var pathInfo = stat()
    guard fstat(descriptor, &descriptorInfo) == 0,
      lstat(url.path, &pathInfo) == 0,
      pathInfo.st_mode & S_IFMT == S_IFREG,
      Self.identity(descriptorInfo) == identity,
      Self.identity(pathInfo) == identity
    else { throw LargeFileError.changed }
  }

  private static func identity(_ info: stat) -> LargeFileIdentity {
    LargeFileIdentity(
      device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
      size: info.st_size,
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
  }
}
