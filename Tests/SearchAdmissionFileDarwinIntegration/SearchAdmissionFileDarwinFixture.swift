import Darwin
import Foundation

@testable import SearchExecution

enum DarwinFixtureFailure: Error {
  case invalidRoot, invalidState, pathLimit, unexpectedResult
  case system(operation: String, errno: Int32)
}

struct DarwinFixtureUncertainty {
  let descriptor: Int32
  let errno: Int32
}

struct DarwinFixtureRead {
  let offset: Int64
  let requested: Int
  let result: SearchAdmissionFileReadResult
}

struct DarwinFixtureCleanup {
  let errors: [String]
  let violations: [String]
  let uncertainCloses: [DarwinFixtureUncertainty]
  let remainingOwned: Int
  let rescuedReaderDescriptors: Int
}

enum DarwinFixtureCall: Equatable {
  case open, descriptor, path, close
  case read(offset: Int64, count: Int)
}

// Constructing this caller-confined owner performs no IO. No deinit closes anything.
final class DarwinFileFixture {
  enum Kind: Equatable { case regular, symlink, fifo, sparse }
  enum Entry: String { case payload, link, missing }

  private var directory: String?
  private var entries: [String] = []
  private var setupOwned: Set<Int32> = []
  private var readerOwned: Set<Int32> = []
  private var cleanupResult: DarwinFixtureCleanup?
  private var kind: Kind?
  private(set) var calls: [DarwinFixtureCall] = []
  private(set) var violations: [String] = []
  private(set) var uncertainCloses: [DarwinFixtureUncertainty] = []
  private(set) var opened: [SearchAdmissionFileDescriptor] = []
  private(set) var readResults: [DarwinFixtureRead] = []
  private(set) var sampleResults: [SearchAdmissionFileSampleResult] = []
  private(set) var closeResults: [SearchAdmissionFileCloseResult] = []
  private(set) var openAttempts = 0
  private(set) var closeAttempts = 0
  private var adapterCalls = 0

  init() {}

  var liveReaderCount: Int { readerOwned.count }

  func violation(_ message: String) {
    if violations.count < 16 { violations.append(message) }
  }

  // The future frozen runner must use this exact layout and set this ONE named variable:
  // .local/search-admission-file-darwin/run.<UUID>/Package/Tests/
  // SearchAdmissionFileDarwinIntegration/<this file>, with sibling Fixtures (0700).
  // There is no temporary-directory fallback or caller-selected arbitrary root.
  static func selectedRoot() throws -> String {
    guard let pointer = Darwin.getenv("THEONLYPAD_FILE_DARWIN_FIXTURE_ROOT") else {
      throw DarwinFixtureFailure.invalidRoot
    }
    var bytes: [UInt8] = []
    var terminated = false
    for index in 0...4096 {
      let byte = UInt8(bitPattern: pointer[index])
      if byte == 0 {
        terminated = true
        break
      }
      bytes.append(byte)
    }
    guard terminated, let supplied = String(bytes: bytes, encoding: .utf8),
      supplied.first == "/", !supplied.contains("\0")
    else { throw DarwinFixtureFailure.invalidRoot }
    guard #filePath.first == "/" else { throw DarwinFixtureFailure.invalidRoot }
    let source = URL(fileURLWithPath: #filePath)
    let testDirectory = source.deletingLastPathComponent()
    let testsDirectory = testDirectory.deletingLastPathComponent()
    let package = testsDirectory.deletingLastPathComponent()
    let run = package.deletingLastPathComponent()
    let namespace = run.deletingLastPathComponent()
    guard testDirectory.lastPathComponent == "SearchAdmissionFileDarwinIntegration",
      testsDirectory.lastPathComponent == "Tests", package.lastPathComponent == "Package",
      namespace.lastPathComponent == "search-admission-file-darwin",
      namespace.deletingLastPathComponent().lastPathComponent == ".local",
      run.lastPathComponent.hasPrefix("run."),
      UUID(uuidString: String(run.lastPathComponent.dropFirst(4))) != nil,
      supplied == run.appendingPathComponent("Fixtures").path
    else { throw DarwinFixtureFailure.invalidRoot }
    // These checks corroborate the runner-owned layout; they do not prove ancestor confinement.
    for path in [run.path, supplied] {
      var raw = stat()
      let (result, saved) = path.withCString { pointer in
        let result = Darwin.lstat(pointer, &raw)
        let saved = errno
        return (result, saved)
      }
      guard result == 0 else {
        throw DarwinFixtureFailure.system(operation: "root-lstat", errno: saved)
      }
      guard raw.st_mode & S_IFMT == S_IFDIR, raw.st_mode & 0o777 == 0o700,
        raw.st_uid == Darwin.geteuid()
      else { throw DarwinFixtureFailure.invalidRoot }
    }
    return supplied
  }

  func setUp(root: String, kind: Kind) throws {
    guard directory == nil, cleanupResult == nil, self.kind == nil else {
      throw DarwinFixtureFailure.invalidState
    }
    guard root == (try Self.selectedRoot()) else { throw DarwinFixtureFailure.invalidRoot }
    self.kind = kind
    let child = root + "/case." + UUID().uuidString
    guard child.utf8.count + 8 <= 4096 else { throw DarwinFixtureFailure.pathLimit }
    let (created, saved) = child.withCString { pointer in
      let result = Darwin.mkdir(pointer, 0o700)
      let saved = errno
      return (result, saved)
    }
    guard created == 0 else {
      throw DarwinFixtureFailure.system(operation: "mkdir", errno: saved)
    }
    directory = child  // Register actual creation before any later throwing work.
    if kind == .fifo {
      let path = try path(.payload)
      let (result, saved) = path.withCString { pointer in
        let result = Darwin.mkfifo(pointer, 0o600)
        let saved = errno
        return (result, saved)
      }
      guard result == 0 else {
        throw DarwinFixtureFailure.system(operation: "mkfifo", errno: saved)
      }
      entries.append(path)
      return
    }
    try createRegular(sparse: kind == .sparse)
    if kind == .symlink {
      let link = try path(.link)
      let (result, saved) = link.withCString { destination in
        "payload".withCString { target in
          let result = Darwin.symlink(target, destination)
          let saved = errno
          return (result, saved)
        }
      }
      guard result == 0 else {
        throw DarwinFixtureFailure.system(operation: "symlink", errno: saved)
      }
      entries.append(link)
    }
  }

  private func createRegular(sparse: Bool) throws {
    let path = try path(.payload)
    let (fd, saved) = path.withCString { pointer in
      let result = Darwin.open(pointer, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      let saved = errno
      return (result, saved)
    }
    guard fd >= 0 else {
      throw DarwinFixtureFailure.system(operation: "writer-open", errno: saved)
    }
    setupOwned.insert(fd)
    entries.append(path)
    if sparse {
      let result = Darwin.ftruncate(fd, 10_000_001)
      let saved = errno
      guard result == 0 else {
        throw DarwinFixtureFailure.system(operation: "ftruncate", errno: saved)
      }
    } else {
      let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0x41, 0xF0, 0x9F, 0x98, 0x80, 0x42]
      var offset = 0
      for _ in 0..<9 {
        if offset == bytes.count { break }
        let (result, saved) = bytes.withUnsafeBufferPointer { buffer in
          let result = Darwin.write(
            fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
          let saved = errno
          return (result, saved)
        }
        guard result >= 0 else {
          throw DarwinFixtureFailure.system(operation: "writer-write", errno: saved)
        }
        guard result > 0, result <= bytes.count - offset else {
          throw DarwinFixtureFailure.invalidState
        }
        offset += result
      }
      guard offset == 9 else { throw DarwinFixtureFailure.invalidState }
    }
    setupOwned.remove(fd)  // Revoke fallback eligibility BEFORE the one close call.
    let closed = Darwin.close(fd)
    let closeError = errno
    guard closed == 0 else {
      uncertainCloses.append(.init(descriptor: fd, errno: closeError))
      throw DarwinFixtureFailure.system(operation: "writer-close", errno: closeError)
    }
  }

  func path(_ entry: Entry) throws -> String {
    guard let directory, cleanupResult == nil else { throw DarwinFixtureFailure.invalidState }
    return directory + "/" + entry.rawValue
  }

  func withPath<T>(_ entry: Entry, _ body: (UnsafeBufferPointer<CChar>) throws -> T) throws -> T {
    let bytes = try path(entry).utf8CString
    return try bytes.withUnsafeBufferPointer(body)
  }

  func acceptsPath(_ view: UnsafeBufferPointer<CChar>) -> Bool {
    guard let directory, cleanupResult == nil, view.count > 0, view.count <= 4097 else {
      violation("Invalid or inactive path view")
      return false
    }
    for entry in [Entry.payload, .link, .missing] {
      let expected = (directory + "/" + entry.rawValue).utf8CString
      if view.elementsEqual(expected) { return true }
    }
    violation("Path was not one of the three fixed fixture entries")
    return false
  }

  func begin(_ call: DarwinFixtureCall) -> Bool {
    guard cleanupResult == nil, adapterCalls < 32 else {
      violation("Call outside the finite adapter scope")
      return false
    }
    adapterCalls += 1
    calls.append(call)
    return true
  }

  func canOpen() -> Bool {
    openAttempts += 1
    guard openAttempts == 1, readerOwned.isEmpty else {
      violation("Unexpected additional native open")
      return false
    }
    return true
  }

  func recordOpen(_ result: SearchAdmissionFileOpenResult) {
    if case .opened(let fd) = result {
      // Provenance is the source-reviewed adapter's actual successful open, not the integer.
      readerOwned.insert(fd.rawValue)
      opened.append(fd)
    }
  }

  func owns(_ fd: SearchAdmissionFileDescriptor) -> Bool {
    guard cleanupResult == nil, readerOwned.contains(fd.rawValue) else {
      violation("Descriptor is not currently owned by this fixture")
      return false
    }
    return true
  }

  func permitsRead(_ fd: SearchAdmissionFileDescriptor, count: Int, offset: Int64) -> Bool {
    guard owns(fd), kind != .fifo, count > 0, count <= 65_536, offset >= 0 else {
      violation("Invalid bounded read or forbidden FIFO read")
      return false
    }
    return true
  }

  func beginClose(_ fd: SearchAdmissionFileDescriptor) -> Bool {
    closeAttempts += 1
    guard readerOwned.remove(fd.rawValue) != nil else {
      violation("Duplicate or unowned close refused without a syscall")
      return false
    }
    return true
  }

  func recordClose(
    _ result: SearchAdmissionFileCloseResult, descriptor: SearchAdmissionFileDescriptor
  ) {
    closeResults.append(result)
    if case .uncertain(let saved) = result {
      uncertainCloses.append(.init(descriptor: descriptor.rawValue, errno: saved))
    }
  }

  func recordRead(_ result: SearchAdmissionFileReadResult, offset: Int64, requested: Int) {
    readResults.append(.init(offset: offset, requested: requested, result: result))
  }

  func recordSample(_ result: SearchAdmissionFileSampleResult) { sampleResults.append(result) }

  func rawDescriptor(_ fd: SearchAdmissionFileDescriptor) throws -> stat {
    guard owns(fd) else { throw DarwinFixtureFailure.invalidState }
    var value = stat()
    let result = Darwin.fstat(fd.rawValue, &value)
    let saved = errno
    guard result == 0 else {
      throw DarwinFixtureFailure.system(operation: "oracle-fstat", errno: saved)
    }
    return value
  }

  func rawPath(_ entry: Entry) throws -> stat {
    var value = stat()
    let (result, saved) = try withPath(entry) { pointer in
      let result = Darwin.lstat(pointer.baseAddress!, &value)
      let saved = errno
      return (result, saved)
    }
    guard result == 0 else {
      throw DarwinFixtureFailure.system(operation: "oracle-lstat", errno: saved)
    }
    return value
  }

  func cleanup() -> DarwinFixtureCleanup {
    if let cleanupResult { return cleanupResult }
    var errors: [String] = []
    let rescued = readerOwned.count
    // Snapshot exact still-owned obligations, then revoke them before any close call.
    let writers = Array(setupOwned)
    let readers = Array(readerOwned)
    setupOwned.removeAll()
    readerOwned.removeAll()
    for fd in writers + readers {
      let result = Darwin.close(fd)
      let saved = errno
      if result != 0 {
        uncertainCloses.append(.init(descriptor: fd, errno: saved))
        errors.append("Independent once-close returned uncertainty")
      }
    }
    for entry in entries.reversed() {
      let (result, saved) = entry.withCString { pointer in
        let result = Darwin.unlink(pointer)
        let saved = errno
        return (result, saved)
      }
      if result != 0 { errors.append("Owned entry unlink failed: \(saved)") }
    }
    entries.removeAll()
    if let directory {
      let (result, saved) = directory.withCString { pointer in
        let result = Darwin.rmdir(pointer)
        let saved = errno
        return (result, saved)
      }
      if result != 0 { errors.append("Owned directory rmdir failed: \(saved)") }
    }
    directory = nil
    let report = DarwinFixtureCleanup(
      errors: errors, violations: violations, uncertainCloses: uncertainCloses,
      remainingOwned: setupOwned.count + readerOwned.count, rescuedReaderDescriptors: rescued)
    cleanupResult = report
    return report
  }
}

// A transparent test consumer boundary, not an alternative adapter or reader.
// EIO below is explicitly fixture-only refusal after a recorded contract violation.
final class ForwardingDarwinFileIO: SearchAdmissionFileIO {
  private let fixture: DarwinFileFixture
  private let actual = SearchAdmissionFileDarwinIO()
  var seedErrno: Int32?

  init(fixture: DarwinFileFixture) { self.fixture = fixture }

  func openReadOnlyNoFollowNonBlockingCloseOnExec(
    path: UnsafeBufferPointer<CChar>
  ) -> SearchAdmissionFileOpenResult {
    guard fixture.begin(.open), fixture.acceptsPath(path), fixture.canOpen() else {
      return .failed(errno: EIO)
    }
    if let seed = seedErrno {
      seedErrno = nil
      errno = seed
    }
    let result = actual.openReadOnlyNoFollowNonBlockingCloseOnExec(path: path)
    fixture.recordOpen(result)
    return result
  }

  func sampleDescriptor(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileSampleResult {
    guard fixture.begin(.descriptor), fixture.owns(fd) else { return .failed(errno: EIO) }
    let result = actual.sampleDescriptor(fd)
    fixture.recordSample(result)
    return result
  }

  func samplePath(_ path: UnsafeBufferPointer<CChar>) -> SearchAdmissionFileSampleResult {
    guard fixture.begin(.path), fixture.acceptsPath(path) else { return .failed(errno: EIO) }
    if let seed = seedErrno {
      seedErrno = nil
      errno = seed
    }
    let result = actual.samplePath(path)
    fixture.recordSample(result)
    return result
  }

  func read(
    _ fd: SearchAdmissionFileDescriptor, into: UnsafeMutableBufferPointer<UInt8>, offset: Int64
  ) -> SearchAdmissionFileReadResult {
    guard fixture.begin(.read(offset: offset, count: into.count)),
      fixture.permitsRead(fd, count: into.count, offset: offset)
    else { return .failed(errno: EIO) }
    let result = actual.read(fd, into: into, offset: offset)
    fixture.recordRead(result, offset: offset, requested: into.count)
    return result
  }

  func closeOnce(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileCloseResult {
    guard fixture.begin(.close), fixture.beginClose(fd) else { return .uncertain(errno: EIO) }
    let result = actual.closeOnce(fd)
    fixture.recordClose(result, descriptor: fd)
    return result
  }
}
