import Darwin
import Foundation

private struct LanguageDirectoryIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}
private struct LanguageLeafIdentity: Equatable, Sendable {
  let device: dev_t
  let inode: ino_t
  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}

/// An exact stable read, not caller-created publication or lifecycle authority.
public struct LoadedLanguageCatalog: Sendable {
  public let snapshot: LanguageCatalogSnapshot
  fileprivate let destination: URL
  fileprivate let rawBytes: Data?
  fileprivate let directoryIdentity: LanguageDirectoryIdentity?
  fileprivate let leafIdentity: LanguageLeafIdentity?
}
public enum CustomLanguageStoreError: Error, Equatable {
  case unsafeLocation, tooLarge, unreadable, changed, receiptMismatch, invalidCatalog,
    generationExhausted, revisionExhausted, unimplemented
}
public struct CustomLanguagePublicationUncertain: Error, LocalizedError, Sendable {
  public let evidence: FilePublicationEvidence
  public let attemptedBytes: Data
  public var errorDescription: String? {
    "The language catalog may have been written, but its location or durability could not be confirmed. Keep your changes and reload before retrying."
  }
}
/// Atomic publication succeeded, but a current stable read receipt could not be confirmed.
public struct CustomLanguageReadbackUnconfirmed: Error, LocalizedError, Sendable {
  public let attemptedBytes: Data
  public let underlyingError: any Error
  public var errorDescription: String? {
    "The language catalog was written, but a current read receipt could not be confirmed. Keep your changes and reload before retrying."
  }
}
struct CustomLanguageStoreHooks: Sendable {
  var read: @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = {
    pread($0, $1, $2, $3)
  }
  var afterRead: @Sendable () throws -> Void = {}
  var beforeWrite: @Sendable () throws -> Void = {}
  var fault: SaveFault?
}

/// Synchronous bounded file I/O. Callers must dispatch off the UI thread.
public struct CustomLanguageStore: Sendable {
  public static let maximumBytes = 1_048_576
  public let directory: URL
  private let hooks: CustomLanguageStoreHooks

  public init(directory: URL) {
    self.directory = directory
    hooks = CustomLanguageStoreHooks()
  }
  init(directory: URL, hooks: CustomLanguageStoreHooks) {
    self.directory = directory
    self.hooks = hooks
  }
  private var file: URL { directory.appendingPathComponent("Profiles.json") }
  private var destination: URL { file.standardizedFileURL }

  public func load() throws -> LoadedLanguageCatalog {
    let descriptor = try openDirectory(create: false)
    guard descriptor >= 0 else { return try loaded(nil, directoryIdentity: nil, leafIdentity: nil) }
    defer { close(descriptor) }
    let identity = try validateDirectory(descriptor)
    let leaf = openat(descriptor, "Profiles.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard leaf >= 0 else {
      guard errno == ENOENT else { throw CustomLanguageStoreError.unsafeLocation }
      _ = try validateDirectory(descriptor, matching: identity)
      return try loaded(nil, directoryIdentity: identity, leafIdentity: nil)
    }
    defer { close(leaf) }
    var before = stat()
    guard fstat(leaf, &before) == 0 else { throw CustomLanguageStoreError.unreadable }
    try validateLeaf(before)
    var data = Data()
    data.reserveCapacity(Int(before.st_size))
    var scratch = [UInt8](repeating: 0, count: 16_384)
    while true {
      let amount = min(scratch.count, Self.maximumBytes + 1 - data.count)
      let count = scratch.withUnsafeMutableBytes {
        hooks.read(leaf, $0.baseAddress!, amount, off_t(data.count))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw CustomLanguageStoreError.unreadable
      }
      guard count <= amount else { throw CustomLanguageStoreError.unreadable }
      if count == 0 { break }
      data.append(contentsOf: scratch.prefix(count))
      guard data.count <= Self.maximumBytes else { throw CustomLanguageStoreError.tooLarge }
    }
    try hooks.afterRead()
    var after = stat()
    var path = stat()
    guard fstat(leaf, &after) == 0,
      fstatat(descriptor, "Profiles.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
      stable(before, after), stable(after, path), data.count == before.st_size
    else { throw CustomLanguageStoreError.changed }
    try validateLeaf(after)
    _ = try validateDirectory(descriptor, matching: identity)
    return try loaded(data, directoryIdentity: identity, leafIdentity: LanguageLeafIdentity(after))
  }

  public func save(_ candidate: LanguageCatalogSnapshot, expected: LoadedLanguageCatalog) throws
    -> LoadedLanguageCatalog
  {
    guard expected.destination == destination else {
      throw CustomLanguageStoreError.receiptMismatch
    }
    guard candidate.generation == expected.snapshot.generation else {
      throw CustomLanguageStoreError.changed
    }
    guard expected.snapshot.generation < UInt64.max else {
      throw CustomLanguageStoreError.generationExhausted
    }
    var revisions: [UUID: UInt64] = [:]
    for definition in candidate.definitions {
      if let previous = expected.snapshot.definitions.first(where: { $0.id == definition.id }) {
        guard
          let revision = expected.snapshot.resolve(
            selection: .manual(.custom(definition.id)), filename: "", builtinDetected: .plainText
          ).definitionRevision, revision > 0
        else { throw CustomLanguageStoreError.invalidCatalog }
        if definition == previous {
          revisions[definition.id] = revision
        } else {
          guard revision < UInt64.max else { throw CustomLanguageStoreError.revisionExhausted }
          revisions[definition.id] = revision + 1
        }
      } else {
        revisions[definition.id] = 1
      }
    }
    let next = try LanguageCatalogSnapshot(
      definitions: candidate.definitions, overrides: candidate.overrides,
      generation: expected.snapshot.generation + 1, definitionRevisions: revisions)
    let bytes = try LanguageCatalogCodec.encode(next)
    guard bytes.count <= Self.maximumBytes else { throw CustomLanguageStoreError.tooLarge }
    let descriptor = try openDirectory(create: expected.directoryIdentity == nil)
    guard descriptor >= 0 else { throw CustomLanguageStoreError.changed }
    defer { close(descriptor) }
    let identity = try validateDirectory(descriptor, matching: expected.directoryIdentity)
    let current = try load()
    guard current.directoryIdentity == identity, current.leafIdentity == expected.leafIdentity
    else {
      throw CustomLanguageStoreError.changed
    }
    guard current.rawBytes == expected.rawBytes else { throw FileStoreError.externalChange }
    try hooks.beforeWrite()
    _ = try validateDirectory(descriptor, matching: identity)
    try validateExpectedLeaf(descriptor, matching: expected.leafIdentity)
    do {
      try AtomicFileStore().save(
        bytes, to: file, expected: expected.rawBytes, fault: hooks.fault,
        boundaryHook: { boundary in
          _ = try validateDirectory(descriptor, matching: identity)
          switch boundary {
          case .afterInitialCheck, .beforeReplace, .afterFinalCheck:
            try validateExpectedLeaf(descriptor, matching: expected.leafIdentity)
          case .afterReplace:
            var info = stat()
            guard fstatat(descriptor, "Profiles.json", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
              throw CustomLanguageStoreError.changed
            }
            try validateLeaf(info)
          }
        })
    } catch FileStoreError.publicationUncertain(let evidence) {
      throw CustomLanguagePublicationUncertain(evidence: evidence, attemptedBytes: bytes)
    }
    // AtomicFileStore acknowledged its own write. This separate stable read binds the
    // returned receipt to current bytes/identities; it is not fabricated write-inode evidence.
    do {
      let readback = try load()
      guard readback.directoryIdentity == identity, readback.rawBytes == bytes,
        readback.leafIdentity != nil
      else { throw CustomLanguageStoreError.changed }
      return readback
    } catch {
      throw CustomLanguageReadbackUnconfirmed(attemptedBytes: bytes, underlyingError: error)
    }
  }

  private func loaded(
    _ bytes: Data?, directoryIdentity: LanguageDirectoryIdentity?,
    leafIdentity: LanguageLeafIdentity?
  ) throws -> LoadedLanguageCatalog {
    let snapshot: LanguageCatalogSnapshot
    if let bytes {
      snapshot = try LanguageCatalogCodec.decode(bytes)
    } else {
      snapshot = try LanguageCatalogSnapshot(definitions: [], overrides: [], generation: 0)
    }
    return LoadedLanguageCatalog(
      snapshot: snapshot, destination: destination, rawBytes: bytes,
      directoryIdentity: directoryIdentity, leafIdentity: leafIdentity)
  }

  private func openDirectory(create: Bool) throws -> Int32 {
    guard directory.isFileURL,
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      directory.path.hasPrefix("/"), !directory.path.utf8.contains(0),
      directory.path.utf8.count < 4096
    else { throw CustomLanguageStoreError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw CustomLanguageStoreError.unsafeLocation }
      if !create { return -1 }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw CustomLanguageStoreError.unsafeLocation }
    }
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CustomLanguageStoreError.unsafeLocation }
    do {
      _ = try validateDirectory(descriptor)
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private func validateDirectory(
    _ descriptor: Int32, matching identity: LanguageDirectoryIdentity? = nil
  ) throws -> LanguageDirectoryIdentity {
    var opened = stat()
    var path = stat()
    guard fstat(descriptor, &opened) == 0, lstat(directory.path, &path) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, path.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), path.st_uid == geteuid(),
      opened.st_mode & 0o7777 == 0o700, path.st_mode & 0o7777 == 0o700
    else { throw CustomLanguageStoreError.unsafeLocation }
    let current = LanguageDirectoryIdentity(opened)
    guard current == LanguageDirectoryIdentity(path), identity == nil || current == identity else {
      throw CustomLanguageStoreError.changed
    }
    return current
  }

  private func validateLeaf(_ info: stat) throws {
    let mode = info.st_mode & 0o7777
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
      mode == 0o400 || mode == 0o600
    else { throw CustomLanguageStoreError.unsafeLocation }
    guard info.st_size >= 0, info.st_size <= Self.maximumBytes else {
      throw CustomLanguageStoreError.tooLarge
    }
  }

  private func validateExpectedLeaf(
    _ descriptor: Int32, matching identity: LanguageLeafIdentity?
  ) throws {
    var info = stat()
    if fstatat(descriptor, "Profiles.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT, identity == nil else { throw CustomLanguageStoreError.changed }
      return
    }
    try validateLeaf(info)
    guard identity == LanguageLeafIdentity(info) else { throw CustomLanguageStoreError.changed }
  }

  private func stable(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
      && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
      && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
      && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
      && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
      && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
