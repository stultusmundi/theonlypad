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

// Inspection is additive; original load/save semantics and hook order above stay unchanged.
private struct LanguageInspectionParent: Sendable {
  let identity: LanguageDirectoryIdentity
  let owner: uid_t
  let mode: mode_t
  init(_ info: stat) {
    identity = LanguageDirectoryIdentity(info)
    owner = info.st_uid
    mode = info.st_mode & 0o7777
  }
}

private struct LanguageInspectionLeaf: Equatable, Sendable {
  let identity: LanguageLeafIdentity
  let device: dev_t
  let inode: ino_t
  let owner: uid_t
  let mode: mode_t
  let links: nlink_t
  let size: off_t
  let modificationSeconds: Int
  let modificationNanos: Int
  let changeSeconds: Int
  let changeNanos: Int
  init(_ info: stat) {
    identity = LanguageLeafIdentity(info)
    device = info.st_dev
    inode = info.st_ino
    owner = info.st_uid
    mode = info.st_mode
    links = info.st_nlink
    size = info.st_size
    modificationSeconds = info.st_mtimespec.tv_sec
    modificationNanos = info.st_mtimespec.tv_nsec
    changeSeconds = info.st_ctimespec.tv_sec
    changeNanos = info.st_ctimespec.tv_nsec
  }
}

private struct LanguageInspectionRead: Sendable {
  let bytes: Data?
  let parent: LanguageInspectionParent?
  let leaf: LanguageInspectionLeaf?
}

public enum CustomLanguageCorruptionReason: Sendable {
  case invalidCatalog, invalidDefinition
}
public enum CustomLanguageUnsupportedReason: Sendable {
  case unclassifiedMalformed, unknownSchema
}

/// Issued only from a stable owned known-schema read; bytes cannot construct a capability.
public struct CustomLanguageRepairInspection: Sendable {
  public let rawBytes: Data
  public let reason: CustomLanguageCorruptionReason
  fileprivate let destination: URL
  fileprivate let parent: LanguageInspectionParent
  fileprivate let leaf: LanguageInspectionLeaf
  fileprivate init(
    inspectedBytes: Data, reason: CustomLanguageCorruptionReason,
    destination: URL, parent: LanguageInspectionParent, leaf: LanguageInspectionLeaf
  ) {
    self.rawBytes = inspectedBytes
    self.reason = reason
    self.destination = destination
    self.parent = parent
    self.leaf = leaf
  }
}

/// Bounded read-only export/display value, never a replacement capability.
public struct CustomLanguageUnsupportedInspection: Sendable {
  public let rawBytes: Data
  public let reason: CustomLanguageUnsupportedReason
  fileprivate init(inspectedBytes: Data, reason: CustomLanguageUnsupportedReason) {
    self.rawBytes = inspectedBytes
    self.reason = reason
  }
}

public enum LanguageCatalogInspection: Sendable {
  case loaded(LoadedLanguageCatalog)
  case corrupt(CustomLanguageRepairInspection)
  case unsupported(CustomLanguageUnsupportedInspection)
}

extension CustomLanguageStore {
  public func inspect() throws -> LanguageCatalogInspection {
    let read = try readForInspection()
    guard let bytes = read.bytes else {
      return .loaded(try loaded(nil, directoryIdentity: read.parent?.identity, leafIdentity: nil))
    }
    let tree: BoundedProfileJSON.Value
    do {
      tree = try BoundedProfileJSON.parse(
        bytes,
        limits: .init(maximumBytes: Self.maximumBytes, maximumDepth: 16, maximumValues: 100_000))
    } catch BoundedProfileJSON.Failure.invalid {
      return .unsupported(
        CustomLanguageUnsupportedInspection(
          inspectedBytes: bytes,
          reason: .unclassifiedMalformed))
    } catch BoundedProfileJSON.Failure.duplicateKey {
      return .unsupported(
        CustomLanguageUnsupportedInspection(
          inspectedBytes: bytes,
          reason: .unclassifiedMalformed))
    }
    // Parser and shape budgets always throw. No early decoder invalidity can bypass
    // the complete known-shape check and turn an unknown sibling into repair authority.
    var classifier = LanguageInspectionShape()
    try classifier.catalog(tree)
    if classifier.unsupported {
      return .unsupported(
        CustomLanguageUnsupportedInspection(inspectedBytes: bytes, reason: .unknownSchema))
    }
    guard let parent = read.parent, let leaf = read.leaf else {
      throw CustomLanguageStoreError.changed
    }
    do {
      return .loaded(
        try loaded(
          bytes, directoryIdentity: parent.identity,
          leafIdentity: leaf.identity))
    } catch CustomLanguageStoreError.invalidCatalog {
      return .corrupt(
        CustomLanguageRepairInspection(
          inspectedBytes: bytes, reason: .invalidCatalog,
          destination: destination, parent: parent, leaf: leaf))
    } catch LanguageProfileError.invalid {
      return .corrupt(
        CustomLanguageRepairInspection(
          inspectedBytes: bytes, reason: .invalidDefinition,
          destination: destination, parent: parent, leaf: leaf))
    }
  }

  // Deliberately separate from load() in this slice: its decoder timing and both save
  // reads remain byte-identical. Only inspection additionally retains full leaf metadata.
  private func readForInspection() throws -> LanguageInspectionRead {
    let descriptor = try openDirectory(create: false)
    guard descriptor >= 0 else {
      return LanguageInspectionRead(bytes: nil, parent: nil, leaf: nil)
    }
    defer { close(descriptor) }
    let identity = try validateDirectory(descriptor)
    var directoryInfo = stat()
    guard fstat(descriptor, &directoryInfo) == 0 else {
      throw CustomLanguageStoreError.unreadable
    }
    guard LanguageDirectoryIdentity(directoryInfo) == identity,
      directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o7777 == 0o700
    else {
      throw CustomLanguageStoreError.changed
    }
    let parent = LanguageInspectionParent(directoryInfo)
    let leaf = openat(descriptor, "Profiles.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard leaf >= 0 else {
      guard errno == ENOENT else { throw CustomLanguageStoreError.unsafeLocation }
      _ = try validateDirectory(descriptor, matching: identity)
      return LanguageInspectionRead(bytes: nil, parent: parent, leaf: nil)
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
    return LanguageInspectionRead(bytes: data, parent: parent, leaf: LanguageInspectionLeaf(after))
  }
}

/// Finite schema-position walk, separate from unchanged strict validation.
/// It never treats an unrecognized container or discriminator as a default.
private struct LanguageInspectionShape {
  private typealias Value = BoundedProfileJSON.Value
  private(set) var unsupported = false
  private var work = 0

  private mutating func reserve() throws {
    guard work < 100_000 else { throw BoundedProfileJSON.Failure.limit }
    work += 1
  }
  private mutating func fields(_ value: Value?, allowed: Set<String>) throws -> [String: Value]? {
    try reserve()
    guard case .object(let object) = value else {
      unsupported = true
      return nil
    }
    if !Set(object.keys).isSubset(of: allowed) { unsupported = true }
    return object
  }
  private mutating func scalar(_ value: Value?) throws {
    try reserve()
    switch value {
    case .object?, .array?: unsupported = true
    default: break  // Known missing/wrong scalar types are checked by the unchanged decoder.
    }
  }
  private mutating func version(_ value: Value?) throws {
    try reserve()
    guard case .number("1") = value else {
      unsupported = true
      return
    }
  }
  private mutating func items(_ value: Value?, maximum: Int) throws -> [Value]? {
    try reserve()
    switch value {
    case .array(let array):
      guard array.count <= maximum else { throw LanguageProfileError.limit }
      return array
    case .object?:
      unsupported = true
      return nil
    default: return nil  // A known absent/wrong scalar array is strict validation's concern.
    }
  }

  mutating func catalog(_ value: BoundedProfileJSON.Value) throws {
    guard
      let root = try fields(
        value,
        allowed: ["version", "generation", "profiles", "overrides"])
    else { return }
    try version(root["version"])
    try scalar(root["generation"])
    if let records = try items(root["profiles"], maximum: 64) {
      for record in records {
        guard let entry = try fields(record, allowed: ["revision", "definition"]) else { continue }
        try scalar(entry["revision"])
        try definition(entry["definition"])
      }
    }
    if let overrides = try items(root["overrides"], maximum: DocumentLanguage.allCases.count) {
      for value in overrides { try builtInOverride(value) }
    }
  }

  private mutating func definition(_ value: Value?) throws {
    guard
      let entry = try fields(
        value,
        allowed: [
          "version", "id", "name", "fileExtensions", "keywords", "lineComment",
          "blockComment", "quotes", "highlightDecimalNumbers", "indentation",
        ])
    else { return }
    try version(entry["version"])
    for key in ["id", "name", "lineComment", "highlightDecimalNumbers"] { try scalar(entry[key]) }
    if let extensions = try items(entry["fileExtensions"], maximum: 16) {
      for value in extensions { try scalar(value) }
    }
    if let keywords = try items(entry["keywords"], maximum: 1024) {
      var units = 0
      for value in keywords {
        try scalar(value)
        if case .string(let string) = value {
          let amount = string.utf16.prefix(32769 - units).count
          guard amount <= 32768 - units else { throw LanguageProfileError.limit }
          units += amount
        }
      }
    }
    try pair(entry["blockComment"], nullable: true)
    if let quotes = try items(entry["quotes"], maximum: 4) {
      for value in quotes {
        guard
          let quote = try fields(
            value,
            allowed: ["opening", "closing", "escape", "multiline"])
        else { continue }
        for key in ["opening", "closing", "escape", "multiline"] { try scalar(quote[key]) }
      }
    }
    try indentation(entry["indentation"])
  }

  private mutating func pair(_ value: Value?, nullable: Bool) throws {
    if case .none = value {
      try reserve()
      return
    }  // Known missing field, no hidden future subtree.
    if nullable, case .null? = value {
      try reserve()
      return
    }
    guard let pair = try fields(value, allowed: ["opening", "closing"]) else { return }
    try scalar(pair["opening"])
    try scalar(pair["closing"])
  }

  private mutating func indentation(_ value: Value?) throws {
    guard let entry = try fields(value, allowed: ["kind", "width"]) else { return }
    guard case .string(let kind) = entry["kind"] else {
      unsupported = true
      return
    }
    switch kind {
    case "legacy":
      if Set(entry.keys) != ["kind"] { unsupported = true }
    case "spaces", "tabs": try scalar(entry["width"])
    default: unsupported = true
    }
  }

  private mutating func builtInOverride(_ value: Value?) throws {
    guard
      let entry = try fields(
        value,
        allowed: ["language", "lineComment", "blockComment", "indentation"])
    else { return }
    try reserve()
    if case .string(let language) = entry["language"],
      DocumentLanguage(rawValue: language) != nil
    {
      // Actual current built-in discriminator only; never infer a future language identity.
    } else {
      unsupported = true
    }
    try policy(entry["lineComment"], block: false)
    try policy(entry["blockComment"], block: true)
    try indentation(entry["indentation"])
  }

  private mutating func policy(_ value: Value?, block: Bool) throws {
    guard let entry = try fields(value, allowed: ["kind", "value"]) else { return }
    guard case .string(let kind) = entry["kind"] else {
      unsupported = true
      return
    }
    switch kind {
    case "inherit", "disabled":
      if Set(entry.keys) != ["kind"] { unsupported = true }
    case "literal":
      if block { try pair(entry["value"], nullable: false) } else { try scalar(entry["value"]) }
    default: unsupported = true
    }
  }
}
