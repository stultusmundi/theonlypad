import Darwin
import Foundation

// Read-only observations of stable local regular files.
// Synchronous filesystem work: caller must run this off the main/control queue.
public struct FileTargetIdentity: Sendable, Equatable {
  public let parentDevice: UInt64
  public let parentInode: UInt64
  public let fileDevice: UInt64
  public let fileInode: UInt64
}
public struct FileMetadata: Sendable, Equatable {
  public let identity: FileTargetIdentity
  public let byteCount: Int64
  public let mode: UInt32
  public let flags: UInt32
  public let modificationSeconds: Int64
  public let modificationNanoseconds: Int64
  public let changeSeconds: Int64
  public let changeNanoseconds: Int64
}
public enum DiskContentRelation: Sendable, Equatable {
  case matchesBaseline, differsFromBaseline, unavailable
}
public enum DiskLocationProblem: Sendable, Equatable {
  case missing, inaccessible, symbolicLink, nonregular, parentChanged
  case changedDuringRead, unsupportedVolume, tooLarge, checkDelayed
}
public struct DiskObservation: Sendable {
  public let metadata: FileMetadata?
  public let content: DiskContentRelation
  public let locationProblem: DiskLocationProblem?
  public let readOnlyHint: Bool
  public let movedCandidate: URL?
}
public struct DiskRead: Sendable {
  public let bytes: Data
  public let observation: DiskObservation
}
public enum ExternalFileProbeError: Error, Equatable {
  case observationChanged
}
enum ProbeBoundary: Sendable, Equatable {
  case afterOpen, beforeRead, afterRead, beforeRevalidate, beforeParentReopen
}
struct ProbeHooks: Sendable {
  var boundary: @Sendable (ProbeBoundary) throws -> Void = { _ in }
  var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
  var isLocalVolume: @Sendable (Int32) throws -> Bool = { descriptor in
    var volume = statfs()
    guard fstatfs(descriptor, &volume) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return volume.f_flags & UInt32(MNT_LOCAL) != 0
  }
  var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
}
private enum ProbeFailure: Error { case location(DiskLocationProblem) }
public struct ExternalFileProbe: Sendable {
  private static let maximum = 100_000_000
  private let hooks: ProbeHooks
  public init() { hooks = ProbeHooks() }
  init(hooks: ProbeHooks) { self.hooks = hooks }

  public func observe(
    _ url: URL, expected: Data, boundIdentity: FileTargetIdentity?,
    forceContents: Bool, previous: DiskObservation?,
    isCancelled: @Sendable () -> Bool
  ) throws -> DiskObservation {
    let deadline = hooks.clock() + 2
    func check() throws {
      if isCancelled() { throw CancellationError() }
      if hooks.clock() >= deadline { throw ProbeFailure.location(.checkDelayed) }
    }
    do {
      try check()
      guard expected.count <= Self.maximum else { throw ProbeFailure.location(.tooLarge) }
      return try inspect(url, boundIdentity: boundIdentity, check: check) {
        directory, descriptor, before in
        try hooks.boundary(.afterOpen)
        let content: DiskContentRelation
        // A previous observation does not carry proof that its expected baseline equals
        // this call's Data. Conservatively compare rather than cache a false clean result.
        if before.byteCount != expected.count {
          content = .differsFromBaseline
        } else {
          content =
            try compare(descriptor, expected: expected, check: check)
            ? .matchesBaseline : .differsFromBaseline
        }
        try validate(
          url, directory: directory, descriptor: descriptor, before: before, check: check)
        var parent = stat()
        guard fstat(directory, &parent) == 0 else { throw posixError() }
        return DiskObservation(
          metadata: before, content: content, locationProblem: nil,
          readOnlyHint: before.mode & 0o222 == 0 || parent.st_mode & 0o222 == 0
            || before.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0,
          movedCandidate: nil)
      }
    } catch ProbeFailure.location(let problem) {
      return DiskObservation(
        metadata: nil, content: .unavailable, locationProblem: problem,
        readOnlyHint: false, movedCandidate: nil)
    }
  }
  public func read(
    _ url: URL, matching: DiskObservation,
    isCancelled: @Sendable () -> Bool
  ) throws -> DiskRead {
    let deadline = hooks.clock() + 2
    func check() throws {
      if isCancelled() { throw CancellationError() }
      if hooks.clock() >= deadline { throw ProbeFailure.location(.checkDelayed) }
    }
    try check()
    guard matching.locationProblem == nil, matching.content != .unavailable,
      let offered = matching.metadata
    else { throw ExternalFileProbeError.observationChanged }
    do {
      return try inspect(url, boundIdentity: offered.identity, check: check) {
        directory, descriptor, before in
        guard before == offered else { throw ExternalFileProbeError.observationChanged }
        try hooks.boundary(.afterOpen)
        var bytes = Data()
        bytes.reserveCapacity(Int(before.byteCount))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
          try check()
          try hooks.boundary(.beforeRead)
          let requested = min(buffer.count, Int(before.byteCount) - bytes.count + 1)
          let count = buffer.withUnsafeMutableBytes {
            hooks.read(descriptor, $0.baseAddress!, requested)
          }
          if count < 0 {
            if errno == EINTR { continue }
            throw posixError()
          }
          guard count <= requested else { throw ExternalFileProbeError.observationChanged }
          try hooks.boundary(.afterRead)
          if count == 0 {
            guard bytes.count == before.byteCount else {
              throw ExternalFileProbeError.observationChanged
            }
            break
          }
          guard count <= Int(before.byteCount) - bytes.count else {
            throw ExternalFileProbeError.observationChanged
          }
          bytes.append(contentsOf: buffer.prefix(count))
        }
        try validate(
          url, directory: directory, descriptor: descriptor, before: before, check: check)
        return DiskRead(bytes: bytes, observation: matching)
      }
    } catch is ProbeFailure {
      throw ExternalFileProbeError.observationChanged
    }
  }

  private func inspect<T>(
    _ url: URL, boundIdentity: FileTargetIdentity?, check: () throws -> Void,
    operation: (Int32, Int32, FileMetadata) throws -> T
  ) throws -> T {
    guard url.isFileURL, url.host == nil || url.host == "localhost", url.path.hasPrefix("/"),
      !url.path.utf8.contains(0), url.path.utf8.count < Int(PATH_MAX),
      !url.lastPathComponent.isEmpty
    else { throw ProbeFailure.location(.nonregular) }
    try check()
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    try check()
    let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw mappedError() }
    defer { close(directory) }
    var parentInfo = stat()
    guard fstat(directory, &parentInfo) == 0 else { throw posixError() }
    if let boundIdentity {
      guard probeDeviceIdentifier(parentInfo.st_dev) == boundIdentity.parentDevice,
        UInt64(parentInfo.st_ino) == boundIdentity.parentInode
      else { throw ProbeFailure.location(.parentChanged) }
    }
    guard try hooks.isLocalVolume(directory) else {
      throw ProbeFailure.location(.unsupportedVolume)
    }
    var pathInfo = stat()
    guard fstatat(directory, url.lastPathComponent, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0
    else { throw mappedError() }
    try regular(pathInfo)
    try check()
    let descriptor = openat(
      directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw mappedError() }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw posixError() }
    try regular(info)
    let before = metadata(info, parent: parentInfo)
    guard before == metadata(pathInfo, parent: parentInfo) else {
      throw ProbeFailure.location(.changedDuringRead)
    }
    guard info.st_size >= 0, info.st_size <= Self.maximum else {
      throw ProbeFailure.location(.tooLarge)
    }
    return try operation(directory, descriptor, before)
  }

  private func compare(_ descriptor: Int32, expected: Data, check: () throws -> Void) throws -> Bool
  {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var offset = 0
    var equal = true
    while true {
      try check()
      try hooks.boundary(.beforeRead)
      let requested = min(buffer.count, expected.count - offset + 1)
      let count = buffer.withUnsafeMutableBytes {
        hooks.read(descriptor, $0.baseAddress!, requested)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError()
      }
      guard count <= requested else { throw ProbeFailure.location(.changedDuringRead) }
      try hooks.boundary(.afterRead)
      if count == 0 {
        guard offset == expected.count else { throw ProbeFailure.location(.changedDuringRead) }
        return equal
      }
      guard count <= expected.count - offset else {
        throw ProbeFailure.location(.changedDuringRead)
      }
      equal =
        expected.withUnsafeBytes { bytes in
          buffer.withUnsafeBytes {
            memcmp(bytes.baseAddress!.advanced(by: offset), $0.baseAddress!, count) == 0
          }
        } && equal
      offset += count
    }
  }

  private func validate(
    _ url: URL, directory: Int32, descriptor: Int32,
    before: FileMetadata, check: () throws -> Void
  ) throws {
    try check()
    try hooks.boundary(.beforeRevalidate)
    var info = stat()
    var pathInfo = stat()
    var parentInfo = stat()
    guard fstat(descriptor, &info) == 0, fstat(directory, &parentInfo) == 0,
      fstatat(directory, url.lastPathComponent, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0
    else {
      throw revalidationError(.changedDuringRead)
    }
    guard metadata(info, parent: parentInfo) == before,
      metadata(pathInfo, parent: parentInfo) == before
    else {
      throw ProbeFailure.location(.changedDuringRead)
    }
    try hooks.boundary(.beforeParentReopen)
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    try check()
    let fresh = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fresh >= 0 else { throw revalidationError(.parentChanged) }
    defer { close(fresh) }
    var freshInfo = stat()
    guard fstat(fresh, &freshInfo) == 0 else { throw revalidationError(.parentChanged) }
    guard probeDeviceIdentifier(freshInfo.st_dev) == before.identity.parentDevice,
      UInt64(freshInfo.st_ino) == before.identity.parentInode
    else {
      throw ProbeFailure.location(.parentChanged)
    }
    try check()
  }
  private func revalidationError(_ fallback: DiskLocationProblem) -> ProbeFailure {
    .location(errno == EACCES || errno == EPERM ? .inaccessible : fallback)
  }
  private func regular(_ info: stat) throws {
    if info.st_mode & S_IFMT == S_IFLNK { throw ProbeFailure.location(.symbolicLink) }
    guard info.st_mode & S_IFMT == S_IFREG else { throw ProbeFailure.location(.nonregular) }
  }
  private func metadata(_ info: stat, parent: stat) -> FileMetadata {
    FileMetadata(
      identity: FileTargetIdentity(
        parentDevice: probeDeviceIdentifier(parent.st_dev),
        parentInode: UInt64(parent.st_ino), fileDevice: probeDeviceIdentifier(info.st_dev),
        fileInode: UInt64(info.st_ino)),
      byteCount: Int64(info.st_size), mode: UInt32(info.st_mode), flags: UInt32(info.st_flags),
      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changeSeconds: Int64(info.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(info.st_ctimespec.tv_nsec))
  }
  private func mappedError() -> Error {
    switch errno {
    case ENOENT, ENOTDIR: return ProbeFailure.location(.missing)
    case EACCES, EPERM: return ProbeFailure.location(.inaccessible)
    case ELOOP: return ProbeFailure.location(.symbolicLink)
    default: return posixError()
    }
  }
  private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

// Darwin dev_t is signed; identity preserves all32 identifier bits without signed overflow.
func probeDeviceIdentifier(_ device: dev_t) -> UInt64 { UInt64(UInt32(bitPattern: device)) }
