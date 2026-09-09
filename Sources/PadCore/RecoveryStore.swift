import CryptoKit
import Darwin
import Foundation

public struct RecoverySnapshot: Codable, Equatable, Sendable {
  public var id: UUID
  public var text: String
  public var encoding: DocumentEncoding
  public var hasBOM: Bool
  public var originalPath: String?
  public init(
    id: UUID, text: String, encoding: DocumentEncoding, hasBOM: Bool, originalPath: String? = nil
  ) {
    self.id = id
    self.text = text
    self.encoding = encoding
    self.hasBOM = hasBOM
    self.originalPath = originalPath
  }
}

public enum RecoveryError: Error { case unsafeDirectory, invalidSnapshot }

/// Local checksums detect accidental corruption, not tampering by the same user.
/// Call synchronously from a serial background owner, never from the UI thread.
public struct RecoveryStore: Sendable {
  public let directory: URL
  private struct Envelope: Codable {
    var version: Int
    var snapshot: RecoverySnapshot
    var checksum: String
  }
  public init(directory: URL) throws {
    guard directory.isFileURL else { throw RecoveryError.unsafeDirectory }
    self.directory = directory.standardizedFileURL
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RecoveryError.unsafeDirectory }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), fchmod(descriptor, 0o700) == 0
    else {
      throw RecoveryError.unsafeDirectory
    }
  }
  public func save(_ snapshot: RecoverySnapshot) throws {
    try validateDirectory()
    let file = url(snapshot.id)
    let previous = try readIfPresent(file)
    let envelope = Envelope(version: 1, snapshot: snapshot, checksum: try checksum(snapshot))
    try AtomicFileStore().save(try encoder().encode(envelope), to: file, expected: previous)
  }
  public func loadAll() throws -> [RecoverySnapshot] {
    try validateDirectory()
    var snapshots: [RecoverySnapshot] = []
    for file in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json"
    {
      do {
        guard let bytes = try readIfPresent(file) else { continue }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1,
          file.deletingPathExtension().lastPathComponent == envelope.snapshot.id.uuidString,
          envelope.checksum == (try checksum(envelope.snapshot))
        else { throw RecoveryError.invalidSnapshot }
        snapshots.append(envelope.snapshot)
      } catch {
        // Preserve the original corrupt bytes for explicit recovery; do not silently delete them.
        try FileManager.default.moveItem(
          at: file, to: directory.appendingPathComponent(UUID().uuidString + ".corrupt"))
      }
    }
    return snapshots
  }
  public func remove(id: UUID) throws {
    try validateDirectory()
    if try readIfPresent(url(id)) != nil { try FileManager.default.removeItem(at: url(id)) }
  }
  private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
  private func encoder() -> JSONEncoder {
    let value = JSONEncoder()
    value.outputFormatting = [.sortedKeys]
    return value
  }
  private func checksum(_ snapshot: RecoverySnapshot) throws -> String {
    SHA256.hash(data: try encoder().encode(snapshot)).map { String(format: "%02x", $0) }.joined()
  }
  private func validateDirectory() throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw RecoveryError.unsafeDirectory }
  }
  private func readIfPresent(_ file: URL) throws -> Data? {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw RecoveryError.invalidSnapshot
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw RecoveryError.invalidSnapshot }
    return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
  }
}
