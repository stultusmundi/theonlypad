import Darwin
import Foundation

public struct SessionTab: Equatable, Sendable {
  public let id: UUID
  public let originalPath: String?
  public let pinned: Bool
  public let encoding: DocumentEncoding
  public let manualLanguage: DocumentLanguage?
  public let selection: NSRange
  public let bookmarks: [Int]
  public init(
    id: UUID = UUID(), originalPath: String? = nil, pinned: Bool = false,
    encoding: DocumentEncoding = .utf8, manualLanguage: DocumentLanguage? = nil,
    selection: NSRange = NSRange(location: 0, length: 0), bookmarks: [Int] = []
  ) {
    self.id = id
    self.originalPath = originalPath
    self.pinned = pinned
    self.encoding = encoding
    self.manualLanguage = manualLanguage
    self.selection = selection
    self.bookmarks = bookmarks
  }
}
public struct SessionWindow: Equatable, Sendable {
  public let id: UUID
  public let tabs: [SessionTab]
  public let selectedTabID: UUID?
  public init(id: UUID = UUID(), tabs: [SessionTab], selectedTabID: UUID?) {
    self.id = id
    self.tabs = tabs
    self.selectedTabID = selectedTabID
  }
}
public struct EditorSession: Equatable, Sendable {
  public let windows: [SessionWindow]
  public let recentPaths: [String]
  public init(windows: [SessionWindow], recentPaths: [String] = []) {
    self.windows = windows
    self.recentPaths = recentPaths
  }
}
public enum SessionStoreError: Error, LocalizedError {
  case invalidMetadata, limit, corrupt
  case unsupportedVersion(Int)
  case unsafeLocation, ioFailure, committedButNotSynced
  public var errorDescription: String? {
    switch self {
    case .invalidMetadata:
      return "Session metadata has invalid IDs, paths, selections or bookmark positions."
    case .limit:
      return
        "Session limits were exceeded. At most 32 windows, 128 tabs and 10,000 bookmarks per tab are supported."
    case .corrupt: return "The session record is corrupt. Existing data was left unchanged."
    case .unsupportedVersion(let version):
      return "Session version \(version) is unsupported. Existing data was left unchanged."
    case .unsafeLocation:
      return "Session storage could not be accessed safely. Check its private permissions."
    case .ioFailure:
      return "Session I/O failed before publication. Existing data was left unchanged."
    case .committedButNotSynced:
      return
        "The session was published, but directory durability could not be confirmed. Reload before retrying."
    }
  }
}
public struct SessionStore: Sendable {
  public let directory: URL
  public static var defaultDirectory: URL {
    SettingsStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent(
      "Session", isDirectory: true)
  }
  public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
  private static let lock = NSLock()
  private static let maximumBytes = 16_777_216
  private struct Wire: Codable {
    let version: Int
    let windows: [Window]
    let recentPaths: [String]?
    struct Window: Codable {
      let id: UUID
      let tabs: [Tab]
      let selectedTabID: UUID?
    }
    struct Tab: Codable {
      let id: UUID
      let originalPath: String?
      let pinned: Bool
      let encoding: DocumentEncoding
      let manualLanguage: DocumentLanguage?
      let location: Int
      let length: Int
      let bookmarks: [Int]
    }
    init(_ session: EditorSession) {
      version = 1
      recentPaths = session.recentPaths.isEmpty ? nil : session.recentPaths
      windows = session.windows.map { window in
        Window(
          id: window.id,
          tabs: window.tabs.map {
            Tab(
              id: $0.id, originalPath: $0.originalPath, pinned: $0.pinned,
              encoding: $0.encoding, manualLanguage: $0.manualLanguage,
              location: $0.selection.location, length: $0.selection.length, bookmarks: $0.bookmarks)
          }, selectedTabID: window.selectedTabID)
      }
    }
    var session: EditorSession {
      EditorSession(
        windows: windows.map { window in
          SessionWindow(
            id: window.id,
            tabs: window.tabs.map {
              SessionTab(
                id: $0.id, originalPath: $0.originalPath, pinned: $0.pinned,
                encoding: $0.encoding, manualLanguage: $0.manualLanguage,
                selection: NSRange(location: $0.location, length: $0.length),
                bookmarks: $0.bookmarks)
            }, selectedTabID: window.selectedTabID)
        }, recentPaths: recentPaths ?? [])
    }
  }
  private func validate(_ session: EditorSession) throws {
    guard session.windows.count <= 32 else { throw SessionStoreError.limit }
    guard session.recentPaths.count <= 50 else { throw SessionStoreError.limit }
    guard Set(session.recentPaths).count == session.recentPaths.count else {
      throw SessionStoreError.invalidMetadata
    }
    for path in session.recentPaths { try validatePath(path) }
    var ids = Set<UUID>()
    var count = 0
    for window in session.windows {
      guard ids.insert(window.id).inserted else { throw SessionStoreError.invalidMetadata }
      count += window.tabs.count
      guard count <= 128 else { throw SessionStoreError.limit }
      guard
        window.tabs.isEmpty
          ? window.selectedTabID == nil
          : window.tabs.contains(where: { $0.id == window.selectedTabID })
      else { throw SessionStoreError.invalidMetadata }
      for tab in window.tabs {
        guard ids.insert(tab.id).inserted else { throw SessionStoreError.invalidMetadata }
        if let path = tab.originalPath { try validatePath(path) }
        guard tab.selection.location >= 0, tab.selection.location <= 100_000_000,
          tab.selection.length >= 0, tab.selection.length <= 100_000_000 - tab.selection.location
        else { throw SessionStoreError.invalidMetadata }
        guard tab.bookmarks.count <= 10_000 else { throw SessionStoreError.limit }
        var previous = -1
        for mark in tab.bookmarks {
          guard mark > previous, mark <= 100_000_000 else {
            throw SessionStoreError.invalidMetadata
          }
          previous = mark
        }
      }
    }
  }
  private func validatePath(_ path: String) throws {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4096,
      !path.utf8.contains(0),
      URL(fileURLWithPath: path).standardizedFileURL.path.utf8.elementsEqual(path.utf8)
    else { throw SessionStoreError.invalidMetadata }
  }
  private func encoded(_ wire: Wire) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(wire)
  }
  private func decoded(_ data: Data) throws -> EditorSession {
    struct Header: Decodable { let version: Int }
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard header.version == 1 else { throw SessionStoreError.unsupportedVersion(header.version) }
      let wire = try decoder.decode(Wire.self, from: data)
      guard try encoded(wire) == data else { throw SessionStoreError.corrupt }
      let session = wire.session
      try validate(session)
      return session
    } catch let error as SessionStoreError {
      if case .unsupportedVersion = error { throw error }
      throw SessionStoreError.corrupt
    } catch { throw SessionStoreError.corrupt }
  }
  private func withDirectory<T>(create: Bool, _ body: (Int32?) throws -> T) throws -> T {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    guard directory.isFileURL else { throw SessionStoreError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw SessionStoreError.unsafeLocation }
      if !create { return try body(nil) }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw SessionStoreError.ioFailure }
    }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw SessionStoreError.unsafeLocation }
    defer { close(fd) }
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
      info.st_mode & S_IFMT == S_IFDIR
    else { throw SessionStoreError.unsafeLocation }
    guard flock(fd, LOCK_EX) == 0 else { throw SessionStoreError.ioFailure }
    defer { flock(fd, LOCK_UN) }
    try verifyDirectory(fd)
    return try body(fd)
  }
  private func verifyDirectory(_ fd: Int32) throws {
    var a = stat()
    var b = stat()
    guard fstat(fd, &a) == 0, lstat(directory.path, &b) == 0,
      a.st_dev == b.st_dev, a.st_ino == b.st_ino, b.st_mode & S_IFMT == S_IFDIR,
      b.st_uid == geteuid(), b.st_mode & 0o777 == 0o700
    else { throw SessionStoreError.unsafeLocation }
  }
  private func readBytes(_ directoryFD: Int32) throws -> Data? {
    let fd = openat(directoryFD, "Session.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return nil }
      throw SessionStoreError.unsafeLocation
    }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_mode & 0o777 == 0o600, before.st_nlink == 1
    else { throw SessionStoreError.unsafeLocation }
    guard before.st_size >= 0, before.st_size <= Self.maximumBytes else {
      throw SessionStoreError.corrupt
    }
    var data = Data(count: Int(before.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(
          fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SessionStoreError.ioFailure }
        offset += count
      }
    }
    var after = stat()
    var path = stat()
    guard fstat(fd, &after) == 0,
      fstatat(directoryFD, "Session.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
      before.st_dev == path.st_dev, before.st_ino == path.st_ino,
      before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw SessionStoreError.unsafeLocation }
    return data
  }
  public func load() throws -> EditorSession? {
    try withDirectory(create: false) { fd in
      guard let fd, let data = try readBytes(fd) else { return nil }
      return try decoded(data)
    }
  }
  public func save(_ session: EditorSession, fault: SaveFault? = nil) throws {
    try validate(session)
    let data = try encoded(Wire(session))
    guard data.count <= Self.maximumBytes else { throw SessionStoreError.limit }
    try withDirectory(create: true) { directoryFD in
      guard let directoryFD else { throw SessionStoreError.ioFailure }
      let previous = try readBytes(directoryFD)
      if let previous { _ = try decoded(previous) }
      if fault == .beforeWrite { throw SessionStoreError.ioFailure }
      let name = ".session-\(UUID().uuidString).tmp"
      let fd = openat(
        directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw SessionStoreError.ioFailure }
      var published = false
      defer {
        close(fd)
        if !published { unlinkat(directoryFD, name, 0) }
      }
      guard fchmod(fd, 0o600) == 0 else { throw SessionStoreError.ioFailure }
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.write(
            fd, bytes.baseAddress!.advanced(by: offset),
            min(fault == .diskFull ? 16 : 65_536, bytes.count - offset))
          if count < 0 && errno == EINTR { continue }
          guard count > 0 else { throw SessionStoreError.ioFailure }
          offset += count
          if fault == .diskFull { throw SessionStoreError.ioFailure }
        }
      }
      if fault == .afterWrite { throw SessionStoreError.ioFailure }
      guard fsync(fd) == 0 else { throw SessionStoreError.ioFailure }
      try verifyDirectory(directoryFD)
      guard try readBytes(directoryFD) == previous else { throw SessionStoreError.unsafeLocation }
      if fault == .beforeReplace { throw SessionStoreError.ioFailure }
      let result =
        previous == nil
        ? renameatx_np(directoryFD, name, directoryFD, "Session.json", UInt32(RENAME_EXCL))
        : renameat(directoryFD, name, directoryFD, "Session.json")
      guard result == 0 else { throw SessionStoreError.ioFailure }
      published = true
      guard fsync(directoryFD) == 0 else { throw SessionStoreError.committedButNotSynced }
    }
  }
}
