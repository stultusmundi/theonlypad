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

public enum RecoveryError: Error, Equatable, LocalizedError {
  case unsafeDirectory, invalidSnapshot, resourceLimit, invalidLimits
  public var errorDescription: String? {
    switch self {
    case .unsafeDirectory:
      return "The recovery directory must be private and owned by the current user."
    case .invalidSnapshot: return "A recovery snapshot is invalid."
    case .invalidLimits: return "The recovery resource limits are invalid."
    case .resourceLimit:
      return
        "Recovery exceeds its file, text, snapshot-count or directory-entry limit. Oversized and unprocessed originals were preserved. Keep a backup and split older recovery files into separate folders before retrying. Save active documents to ordinary files before quitting."
    }
  }
}
public struct RecoveryLimits: Sendable {
  public let maximumSnapshotUTF16: Int
  public let maximumEnvelopeBytes: Int
  public let maximumSnapshots: Int
  public let maximumDirectoryEntries: Int
  public let maximumRestoredUTF16: Int
  public init(
    maximumSnapshotUTF16: Int = 100_000_000, maximumEnvelopeBytes: Int = 600_032_768,
    maximumSnapshots: Int = 128, maximumDirectoryEntries: Int = 4_096,
    maximumRestoredUTF16: Int = 100_000_000
  ) {
    self.maximumSnapshotUTF16 = maximumSnapshotUTF16
    self.maximumEnvelopeBytes = maximumEnvelopeBytes
    self.maximumSnapshots = maximumSnapshots
    self.maximumDirectoryEntries = maximumDirectoryEntries
    self.maximumRestoredUTF16 = maximumRestoredUTF16
  }
}
public struct RecoveryLoadReport: Sendable {
  public let snapshots: [RecoverySnapshot]
  public let quarantinedCount: Int
  public init(snapshots: [RecoverySnapshot], quarantinedCount: Int) {
    self.snapshots = snapshots
    self.quarantinedCount = quarantinedCount
  }
}

/// Local checksums detect accidental corruption, not tampering by the same user.
/// Call synchronously from a serial background owner, never from the UI thread.
public struct RecoveryStore: Sendable {
  public let directory: URL
  private let limits: RecoveryLimits
  private struct Envelope: Codable {
    var version: Int
    var snapshot: RecoverySnapshot
    var checksum: String
  }
  public init(directory: URL, limits: RecoveryLimits = RecoveryLimits()) throws {
    let bounds = [
      limits.maximumSnapshotUTF16, limits.maximumEnvelopeBytes, limits.maximumSnapshots,
      limits.maximumDirectoryEntries, limits.maximumRestoredUTF16,
    ]
    guard bounds.allSatisfy({ $0 > 0 && $0 < Int.max }),
      limits.maximumEnvelopeBytes <= 600_032_768, limits.maximumSnapshotUTF16 <= 100_000_000,
      limits.maximumSnapshots <= 128, limits.maximumDirectoryEntries <= 4_096,
      limits.maximumRestoredUTF16 <= 100_000_000
    else { throw RecoveryError.invalidLimits }
    self.limits = limits
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
  public func save(_ snapshot: RecoverySnapshot, fault: SaveFault? = nil) throws {
    try validateDirectory()
    try validate(snapshot)
    let file = url(snapshot.id)
    let previous = try readIfPresent(file)
    let envelope = Envelope(version: 1, snapshot: snapshot, checksum: try checksum(snapshot))
    let encoded = try encoder().encode(envelope)
    guard encoded.count <= limits.maximumEnvelopeBytes else { throw RecoveryError.resourceLimit }
    try validateSaveCapacity(id: snapshot.id, encodedBytes: encoded.count)
    try AtomicFileStore().save(encoded, to: file, expected: previous, fault: fault)
  }
  /// Validate this exact attempted envelope without acknowledging a successful save.
  public func validatePublication(_ evidence: FilePublicationEvidence, snapshot: RecoverySnapshot)
    throws
  {
    try validateDirectory()
    try validate(snapshot)
    guard evidence.destination.standardizedFileURL == url(snapshot.id).standardizedFileURL else {
      throw RecoveryError.invalidSnapshot
    }
    let envelope = Envelope(version: 1, snapshot: snapshot, checksum: try checksum(snapshot))
    let encoded = try encoder().encode(envelope)
    guard encoded.count <= limits.maximumEnvelopeBytes else { throw RecoveryError.resourceLimit }
    try AtomicFileStore().validatePublication(evidence, expected: encoded)
  }
  public func loadAll() throws -> [RecoverySnapshot] { try loadReport().snapshots }
  public func loadReport() throws -> RecoveryLoadReport {
    try validateDirectory()
    let files = try inventory().files
    var snapshots: [RecoverySnapshot] = []
    var totalUnits = 0
    var quarantined = 0
    var remainingReadBytes = limits.maximumEnvelopeBytes
    for file in files {
      do {
        guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
          file.deletingPathExtension().lastPathComponent == id.uuidString
        else { throw RecoveryError.invalidSnapshot }
        guard let bytes = try readIfPresent(file, maximumBytes: remainingReadBytes) else {
          continue
        }
        remainingReadBytes -= bytes.count
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        // Budget checks precede checksum re-encoding, which can expand control characters sixfold.
        guard envelope.version == 1, id == envelope.snapshot.id, envelope.checksum.utf8.count == 64
        else { throw RecoveryError.invalidSnapshot }
        try validate(envelope.snapshot)
        let count = envelope.snapshot.text.utf16.count
        guard count <= limits.maximumRestoredUTF16 - totalUnits else {
          throw RecoveryError.resourceLimit
        }
        guard envelope.checksum == (try checksum(envelope.snapshot)) else {
          throw RecoveryError.invalidSnapshot
        }
        totalUnits += count
        snapshots.append(envelope.snapshot)
      } catch RecoveryError.resourceLimit {
        // Capacity is not corruption. Original data and all later files stay in place.
        throw RecoveryError.resourceLimit
      } catch {
        try FileManager.default.moveItem(
          at: file, to: directory.appendingPathComponent(UUID().uuidString + ".corrupt"))
        quarantined += 1
      }
    }
    return RecoveryLoadReport(snapshots: snapshots, quarantinedCount: quarantined)
  }
  public func remove(id: UUID) throws {
    try validateDirectory()
    let file = url(id)
    // Explicit discard needs metadata only, never a potentially large content read.
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return }
      throw RecoveryError.invalidSnapshot
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw RecoveryError.invalidSnapshot }
    try FileManager.default.removeItem(at: file)
  }
  private func inventory() throws -> (files: [URL], entries: Int) {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RecoveryError.unsafeDirectory }
    var directoryInfo = stat()
    guard fstat(descriptor, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
      directoryInfo.st_mode & 0o077 == 0
    else {
      close(descriptor)
      throw RecoveryError.unsafeDirectory
    }
    guard let stream = fdopendir(descriptor) else {
      close(descriptor)
      throw RecoveryError.unsafeDirectory
    }
    defer { closedir(stream) }
    var files: [URL] = []
    var count = 0
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 { throw RecoveryError.unsafeDirectory }
        break
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(
          to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
        ) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      count += 1
      guard count <= limits.maximumDirectoryEntries else { throw RecoveryError.resourceLimit }
      if name.hasSuffix(".json") {
        guard files.count < limits.maximumSnapshots else { throw RecoveryError.resourceLimit }
        files.append(directory.appendingPathComponent(name))
      }
    }
    return (files.sorted { $0.lastPathComponent < $1.lastPathComponent }, count)
  }
  private func validateSaveCapacity(id: UUID, encodedBytes: Int) throws {
    let inventory = try inventory()
    let files = inventory.files
    let destination = url(id)
    let replacing = files.contains(destination)
    guard
      replacing
        || (files.count < limits.maximumSnapshots
          && inventory.entries < limits.maximumDirectoryEntries)
    else { throw RecoveryError.resourceLimit }
    var remaining = limits.maximumEnvelopeBytes - encodedBytes
    for file in files where file != destination {
      let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw RecoveryError.invalidSnapshot }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == geteuid(), info.st_mode & 0o077 == 0
      else { throw RecoveryError.invalidSnapshot }
      guard info.st_size >= 0, info.st_size <= remaining else { throw RecoveryError.resourceLimit }
      remaining -= Int(info.st_size)
    }
  }
  private func validate(_ snapshot: RecoverySnapshot) throws {
    guard snapshot.text.utf16.count <= limits.maximumSnapshotUTF16,
      (snapshot.originalPath?.utf16.count ?? 0) <= 4_096
    else { throw RecoveryError.resourceLimit }
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
  private func readIfPresent(_ file: URL, maximumBytes: Int? = nil) throws -> Data? {
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
    let maximum = maximumBytes ?? limits.maximumEnvelopeBytes
    guard info.st_size >= 0, info.st_size <= maximum else { throw RecoveryError.resourceLimit }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var result = Data()
    while let chunk = try handle.read(upToCount: min(1_048_576, maximum - result.count + 1)),
      !chunk.isEmpty
    {
      guard chunk.count <= maximum - result.count else { throw RecoveryError.resourceLimit }
      result.append(chunk)
    }
    return result
  }
}
