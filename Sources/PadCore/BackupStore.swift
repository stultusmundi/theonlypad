import CryptoKit
import Darwin
import Foundation

public struct BackupRecord: Equatable, Sendable {
  public let id: UUID
  public let originalPath: String
  public let createdAt: Date
  public let byteCount: Int
  public let encoding: DocumentEncoding
}
public struct BackupSnapshot: Sendable {
  public let record: BackupRecord
  public let data: Data
}
public struct BackupLimits: Sendable {
  public let maxRecords: Int, maxRecordBytes: Int, maxTotalBytes: Int
  public init(
    maxRecords: Int = 100, maxRecordBytes: Int = 100_000_000, maxTotalBytes: Int = 500_000_000
  ) {
    self.maxRecords = maxRecords
    self.maxRecordBytes = maxRecordBytes
    self.maxTotalBytes = maxTotalBytes
  }
}
public enum BackupStoreError: Error, LocalizedError {
  case unsafeLocation, invalidLimits, invalidOriginalURL, capacity
  case missing(UUID)
  case corrupt(UUID)
  case incomplete(UUID)
  case unexpectedEntry, ioFailure
  case committedButNotSynced(UUID)
  public var errorDescription: String? {
    switch self {
    case .unsafeLocation:
      return "The backup store could not be accessed safely. Check its private permissions."
    case .invalidLimits: return "The configured backup limits are invalid."
    case .invalidOriginalURL: return "A backup requires a local file URL."
    case .capacity:
      return
        "The backup capacity limit was reached. Remove selected old backups before capturing more."
    case .missing(let id): return "Backup \(id.uuidString) is missing."
    case .corrupt(let id): return "Backup \(id.uuidString) is corrupt. No records were overwritten."
    case .incomplete(let id):
      return
        "Backup \(id.uuidString) is incomplete. Remove that record explicitly before continuing."
    case .unexpectedEntry:
      return "The backup directory contains an unexpected entry. No unrelated entry was changed."
    case .ioFailure: return "Backup I/O failed. Reload the backup list before continuing."
    case .committedButNotSynced(let id):
      return
        "Backup \(id.uuidString) was published, but directory durability could not be confirmed. Reload before retrying."
    }
  }
}
public struct BackupStore: Sendable {
  public let directory: URL
  private let limits: BackupLimits
  public static var defaultDirectory: URL {
    SettingsStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent(
      "Backups", isDirectory: true)
  }
  public init(directory: URL, limits: BackupLimits = .init()) {
    self.directory = directory
    self.limits = limits
  }
  private static let lock = NSLock()
  private struct Envelope: Codable {
    let version: Int
    let id: UUID
    let originalPath: String
    let createdAt: Double
    let byteCount: Int
    let encoding: DocumentEncoding
    let sha256: String
    let bytes: Data
    var record: BackupRecord {
      BackupRecord(
        id: id, originalPath: originalPath, createdAt: Date(timeIntervalSince1970: createdAt),
        byteCount: byteCount, encoding: encoding)
    }
  }
  public func capture(data: Data, originalURL: URL, encoding: DocumentEncoding = .utf8) throws
    -> BackupRecord
  {
    guard originalURL.isFileURL, originalURL.host == nil || originalURL.host == "localhost" else {
      throw BackupStoreError.invalidOriginalURL
    }
    let originalPath = originalURL.standardizedFileURL.path
    guard validPath(originalPath) else { throw BackupStoreError.invalidOriginalURL }
    return try withDirectory { fd in
      guard data.count <= limits.maxRecordBytes else { throw BackupStoreError.capacity }
      let records = try records(in: fd)
      let total = records.reduce(0) { $0 + $1.byteCount }
      guard records.count < limits.maxRecords, data.count <= limits.maxTotalBytes - total else {
        throw BackupStoreError.capacity
      }
      let id = UUID()
      let envelope = Envelope(
        version: 1, id: id, originalPath: originalPath, createdAt: Date().timeIntervalSince1970,
        byteCount: data.count, encoding: encoding, sha256: digest(data), bytes: data)
      let encoded = try encode(envelope)
      let pending = id.uuidString + ".pending"
      let target = id.uuidString + ".json"
      let output = openat(fd, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard output >= 0 else { throw BackupStoreError.ioFailure }
      var published = false
      defer {
        close(output)
        if !published { _ = unlinkat(fd, pending, 0) }
      }
      guard fchmod(output, 0o600) == 0 else { throw BackupStoreError.ioFailure }
      try encoded.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var position = 0
        while position < buffer.count {
          let written = Darwin.write(
            output, buffer.baseAddress!.advanced(by: position), min(65_536, buffer.count - position)
          )
          if written < 0 && errno == EINTR { continue }
          guard written > 0 else { throw BackupStoreError.ioFailure }
          position += written
        }
      }
      guard fsync(output) == 0 else { throw BackupStoreError.ioFailure }
      try verifyDirectory(fd)
      guard renameatx_np(fd, pending, fd, target, UInt32(RENAME_EXCL)) == 0 else {
        throw BackupStoreError.ioFailure
      }
      published = true
      guard fsync(fd) == 0 else { throw BackupStoreError.committedButNotSynced(id) }
      return envelope.record
    }
  }
  public func list() throws -> [BackupRecord] { try withDirectory { try records(in: $0) } }
  public func read(id: UUID) throws -> Data { try snapshot(id: id).data }
  public func snapshot(id: UUID) throws -> BackupSnapshot {
    try withDirectory { fd in
      let envelope = try load(id: id, directory: fd)
      return BackupSnapshot(record: envelope.record, data: envelope.bytes)
    }
  }
  /// Explicit deletion may remove malformed bytes or a torn pending record of
  /// this UUID. Unexpected names and unsafe filesystem objects are never removed.
  public func remove(id: UUID) throws {
    try withDirectory { fd in
      var existing: [String] = []
      for name in [id.uuidString + ".json", id.uuidString + ".pending"] {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          if errno == ENOENT { continue }
          throw BackupStoreError.ioFailure
        }
        try validateFile(info)
        existing.append(name)
      }
      guard !existing.isEmpty else { throw BackupStoreError.missing(id) }
      try verifyDirectory(fd)
      for name in existing {
        guard unlinkat(fd, name, 0) == 0 else { throw BackupStoreError.ioFailure }
      }
      guard fsync(fd) == 0 else { throw BackupStoreError.ioFailure }
    }
  }
  private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
    guard (0...100).contains(limits.maxRecords), (0...100_000_000).contains(limits.maxRecordBytes),
      (0...500_000_000).contains(limits.maxTotalBytes)
    else { throw BackupStoreError.invalidLimits }
    guard directory.isFileURL, !directory.path.utf8.contains(0) else {
      throw BackupStoreError.unsafeLocation
    }
    Self.lock.lock()
    defer { Self.lock.unlock() }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw BackupStoreError.unsafeLocation }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw BackupStoreError.unsafeLocation }
    }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw BackupStoreError.unsafeLocation }
    defer { close(fd) }
    try verifyDirectory(fd)
    guard flock(fd, LOCK_EX) == 0 else { throw BackupStoreError.ioFailure }
    defer { _ = flock(fd, LOCK_UN) }
    try verifyDirectory(fd)
    return try body(fd)
  }
  private func verifyDirectory(_ fd: Int32) throws {
    var info = stat()
    var path = stat()
    guard fstat(fd, &info) == 0, lstat(directory.path, &path) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
      path.st_mode & S_IFMT == S_IFDIR, path.st_dev == info.st_dev, path.st_ino == info.st_ino
    else { throw BackupStoreError.unsafeLocation }
  }
  private func validateFile(_ info: stat) throws {
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
      info.st_nlink == 1
    else { throw BackupStoreError.unsafeLocation }
  }
  private func records(in fd: Int32) throws -> [BackupRecord] {
    let duplicate = dup(fd)
    guard duplicate >= 0 else { throw BackupStoreError.ioFailure }
    guard let stream = fdopendir(duplicate) else {
      close(duplicate)
      throw BackupStoreError.ioFailure
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw BackupStoreError.ioFailure }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard names.count < limits.maxRecords else { throw BackupStoreError.capacity }
      names.append(name)
    }
    var result: [BackupRecord] = []
    var total = 0
    for name in names.sorted() {
      let pending = name.hasSuffix(".pending")
      guard pending || name.hasSuffix(".json") else { throw BackupStoreError.unexpectedEntry }
      let stem = String(name.dropLast(pending ? 8 : 5))
      guard let id = UUID(uuidString: stem), id.uuidString == stem else {
        throw BackupStoreError.unexpectedEntry
      }
      if pending {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw BackupStoreError.ioFailure
        }
        try validateFile(info)
        throw BackupStoreError.incomplete(id)
      }
      let record = try autoreleasepool { try load(id: id, directory: fd).record }
      guard record.byteCount <= limits.maxTotalBytes - total else {
        throw BackupStoreError.capacity
      }
      total += record.byteCount
      result.append(record)
    }
    return result.sorted {
      $0.createdAt == $1.createdAt
        ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
    }
  }
  private func load(id: UUID, directory fd: Int32) throws -> Envelope {
    let name = id.uuidString + ".json"
    let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else {
      if errno == ENOENT { throw BackupStoreError.missing(id) }
      throw BackupStoreError.unsafeLocation
    }
    defer { close(input) }
    var before = stat()
    guard fstat(input, &before) == 0 else { throw BackupStoreError.ioFailure }
    try validateFile(before)
    // Version 1 JSON escapes each slash in base64 as \/. FF-heavy input can
    // therefore double the base64 field; metadata also needs escaped-path room.
    let maximum = ((limits.maxRecordBytes + 2) / 3) * 4 * 2 + 32_768
    guard before.st_size >= 0, before.st_size <= maximum else { throw BackupStoreError.corrupt(id) }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      var position = 0
      while position < buffer.count {
        let count = Darwin.read(
          input, buffer.baseAddress!.advanced(by: position), min(65_536, buffer.count - position))
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw BackupStoreError.corrupt(id) }
        position += count
      }
    }
    var after = stat()
    var path = stat()
    guard fstat(input, &after) == 0, fstatat(fd, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, path)
    else { throw BackupStoreError.corrupt(id) }
    try validateFile(after)
    try verifyDirectory(fd)
    let envelope: Envelope
    do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
      throw BackupStoreError.corrupt(id)
    }
    guard envelope.version == 1, envelope.id == id, validPath(envelope.originalPath),
      envelope.createdAt.isFinite, (0...253_402_300_799).contains(envelope.createdAt),
      envelope.byteCount == envelope.bytes.count, envelope.byteCount <= limits.maxRecordBytes,
      envelope.sha256 == digest(envelope.bytes), try encode(envelope) == data
    else { throw BackupStoreError.corrupt(id) }
    return envelope
  }
  private func stable(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
  private func validPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= 4096 && !path.utf8.contains(0)
  }
  private func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  private func encode(_ envelope: Envelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do { return try encoder.encode(envelope) } catch { throw BackupStoreError.ioFailure }
  }
}
