import Darwin
import Foundation

private struct ShortcutDirectoryIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
  }
}
public struct ShortcutReceipt: Equatable, Sendable {
  public let rawBytes: Data?
  fileprivate let destination: URL
  fileprivate let directoryIdentity: ShortcutDirectoryIdentity?
}
public struct ShortcutStoreRead: Sendable {
  public let receipt: ShortcutReceipt
  public let decoded: Result<ShortcutProfile, Error>
}
public enum ShortcutStoreError: Error, Equatable {
  case unsafeLocation, tooLarge, unreadable, changed, receiptMismatch
}
public struct ShortcutPublicationUncertain: Error, Sendable {
  public let evidence: FilePublicationEvidence
  public let attemptedBytes: Data
}
struct ShortcutStoreHooks: Sendable {
  var read: @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = {
    pread($0, $1, $2, $3)
  }
  var afterRead: @Sendable () throws -> Void = {}
  var beforeWrite: @Sendable () throws -> Void = {}
  var fault: SaveFault?
}
/// Synchronous bounded I/O; callers must dispatch off the UI thread.
public struct ShortcutStore: Sendable {
  public let directory: URL
  private let hooks: ShortcutStoreHooks
  public static var defaultDirectory: URL { SettingsStore.defaultDirectory }
  public init(directory: URL = Self.defaultDirectory) {
    self.directory = directory
    hooks = ShortcutStoreHooks()
  }
  init(directory: URL, hooks: ShortcutStoreHooks) {
    self.directory = directory
    self.hooks = hooks
  }
  private var file: URL { directory.appendingPathComponent("Shortcuts.json") }
  private var destination: URL { file.standardizedFileURL }

  public func read() throws -> ShortcutStoreRead {
    let descriptor = try openDirectory(create: false)
    guard descriptor >= 0 else {
      return result(nil, identity: nil)
    }
    defer { close(descriptor) }
    let identity = try validateDirectory(descriptor)
    let leaf = openat(descriptor, "Shortcuts.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard leaf >= 0 else {
      guard errno == ENOENT else { throw ShortcutStoreError.unsafeLocation }
      _ = try validateDirectory(descriptor, matching: identity)
      return result(nil, identity: identity)
    }
    defer { close(leaf) }
    var before = stat()
    guard fstat(leaf, &before) == 0 else { throw ShortcutStoreError.unreadable }
    guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
      before.st_mode & 0o177 == 0, before.st_mode & 0o400 != 0
    else { throw ShortcutStoreError.unsafeLocation }
    guard before.st_size >= 0, before.st_size <= ShortcutProfile.maximumBytes else {
      throw ShortcutStoreError.tooLarge
    }
    var data = Data()
    data.reserveCapacity(Int(before.st_size))
    var scratch = [UInt8](repeating: 0, count: 16_384)
    while true {
      let amount = min(scratch.count, ShortcutProfile.maximumBytes + 1 - data.count)
      let count = scratch.withUnsafeMutableBytes {
        hooks.read(leaf, $0.baseAddress!, amount, off_t(data.count))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw ShortcutStoreError.unreadable
      }
      guard count <= amount else { throw ShortcutStoreError.unreadable }
      if count == 0 { break }
      data.append(contentsOf: scratch.prefix(count))
      guard data.count <= ShortcutProfile.maximumBytes else { throw ShortcutStoreError.tooLarge }
    }
    try hooks.afterRead()
    var after = stat()
    var path = stat()
    guard fstat(leaf, &after) == 0,
      fstatat(descriptor, "Shortcuts.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, path), data.count == before.st_size
    else { throw ShortcutStoreError.changed }
    _ = try validateDirectory(descriptor, matching: identity)
    return result(data, identity: identity)
  }

  public func write(_ profile: ShortcutProfile, matching receipt: ShortcutReceipt) throws
    -> ShortcutReceipt
  {
    guard receipt.destination == destination else { throw ShortcutStoreError.receiptMismatch }
    let bytes = try exportData(profile)
    guard bytes.count <= ShortcutProfile.maximumBytes else { throw ShortcutStoreError.tooLarge }
    let descriptor = try openDirectory(create: receipt.directoryIdentity == nil)
    guard descriptor >= 0 else { throw ShortcutStoreError.changed }
    defer { close(descriptor) }
    let identity = try validateDirectory(descriptor, matching: receipt.directoryIdentity)
    let current = try read().receipt
    guard current.directoryIdentity == identity else { throw ShortcutStoreError.changed }
    guard current.rawBytes == receipt.rawBytes else { throw FileStoreError.externalChange }
    try hooks.beforeWrite()
    _ = try validateDirectory(descriptor, matching: identity)
    do {
      try AtomicFileStore().save(
        bytes, to: file, expected: receipt.rawBytes, fault: hooks.fault,
        boundaryHook: { _ in _ = try validateDirectory(descriptor, matching: identity) })
    } catch FileStoreError.publicationUncertain(let evidence) {
      throw ShortcutPublicationUncertain(evidence: evidence, attemptedBytes: bytes)
    }
    return ShortcutReceipt(rawBytes: bytes, destination: destination, directoryIdentity: identity)
  }
  public func importData(_ data: Data) throws -> ShortcutProfile {
    try ShortcutProfile.decode(data)
  }
  public func exportData(_ profile: ShortcutProfile) throws -> Data { try profile.encode() }

  private func result(_ bytes: Data?, identity: ShortcutDirectoryIdentity?) -> ShortcutStoreRead {
    ShortcutStoreRead(
      receipt: ShortcutReceipt(
        rawBytes: bytes, destination: destination, directoryIdentity: identity),
      decoded: bytes.map { data in Result { try ShortcutProfile.decode(data) } }
        ?? .success(.defaults))
  }
  private func openDirectory(create: Bool) throws -> Int32 {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), !directory.path.utf8.contains(0),
      directory.path.utf8.count < 4096
    else { throw ShortcutStoreError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw ShortcutStoreError.unsafeLocation }
      if !create { return -1 }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw ShortcutStoreError.unsafeLocation }
    }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ShortcutStoreError.unsafeLocation }
    do {
      _ = try validateDirectory(descriptor)
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }
  private func validateDirectory(
    _ descriptor: Int32, matching identity: ShortcutDirectoryIdentity? = nil
  ) throws -> ShortcutDirectoryIdentity {
    var opened = stat()
    var path = stat()
    guard fstat(descriptor, &opened) == 0, lstat(directory.path, &path) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), path.st_uid == geteuid(),
      opened.st_mode & 0o777 == 0o700, path.st_mode & 0o777 == 0o700
    else { throw ShortcutStoreError.unsafeLocation }
    let current = ShortcutDirectoryIdentity(opened)
    guard current == ShortcutDirectoryIdentity(path), identity == nil || current == identity else {
      throw ShortcutStoreError.changed
    }
    return current
  }
  private func stable(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
      && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
