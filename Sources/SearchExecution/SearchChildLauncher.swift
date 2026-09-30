import Darwin
import Dispatch
import Foundation
import PadCore

struct LaunchError: Error { let code: Int32 }
enum LaunchFlag: Equatable { case closeOnExec, nonblocking, noSigPipe }
enum LaunchAttribute: Equatable { case flags, emptyMask, defaultSignals }
enum LaunchReaperPolicy { case standard, ignored, custom, noChildWait }
struct LaunchSpawnResult {
  let code: Int32
  let pid: Int32
}
struct LaunchWaitResult {
  let value: Int32
  let status: Int32
  let error: Int32
}

/// Optional observation for injected ownership controls; never drives cleanup.
enum LaunchCloseEvent: Sendable, Equatable {
  case closeRequested, ancillaryWaitInstalled, closeTaskFinished
}

protocol LaunchSpawnOperations: AnyObject {
  func initializeActions() throws
  func initializeAttributes() throws
  func duplicate(_ fd: Int32, to: Int32) throws
  func closeInChild(_ fd: Int32) throws
  func configure(_ attribute: LaunchAttribute) throws
  func spawn(path: String, arguments: [String], environment: [String]) -> LaunchSpawnResult
  func destroyActions()
  func destroyAttributes()
}

/// Confined to the shared spawn lane. No destructor retries a consumed integer.
private final class LaunchDescriptor {
  enum State {
    case owned, transferred, closed
    case uncertain(Int32)
  }
  let fd: Int32
  private var state = State.owned
  private(set) var closeOnExecConfirmed: Bool
  init(_ fd: Int32, protected: Bool = false) {
    self.fd = fd
    closeOnExecConfirmed = protected
  }
  func confirmCloseOnExec() { closeOnExecConfirmed = true }
  var isOwned: Bool {
    if case .owned = state { return true }
    return false
  }
  var uncertainError: Int32? {
    if case .uncertain(let error) = state { return error }
    return nil
  }
  func transfer() -> Int32 {
    precondition(isOwned)
    state = .transferred
    return fd
  }
  func close(using operations: any LaunchOperations) -> Int32 {
    guard isOwned else { return uncertainError ?? 0 }
    state = .closed  // Consume authority BEFORE the syscall; never retry EINTR/EBADF.
    let error = operations.close(fd)
    if error != 0 { state = .uncertain(error) }
    return error
  }
}

private final class LaunchQuarantine: @unchecked Sendable {
  let cells: [LaunchDescriptor]
  let error: Int32
  let primaryError: Int32?
  init(cells: [LaunchDescriptor], error: Int32, primaryError: Int32?) {
    self.cells = cells
    self.error = error
    self.primaryError = primaryError
  }
}

/// Actual channel cleanup continues independently. The ancillary ownership proof is
/// permanently uncertain, so one retained task/gate cannot acknowledge full closure.
private final class LaunchUnconfirmedConnection: SearchChildConnection, @unchecked Sendable {
  private let channel: any SearchChildConnection
  private let quarantine: LaunchQuarantine
  private let observe: (@Sendable (LaunchCloseEvent) -> Void)?
  private let lock = NSLock()
  private var closeTask: Task<Void, Never>?
  private var retainedGate: CheckedContinuation<Void, Never>?
  init(
    _ channel: any SearchChildConnection, quarantine: LaunchQuarantine,
    observe: (@Sendable (LaunchCloseEvent) -> Void)?
  ) {
    self.channel = channel
    self.quarantine = quarantine
    self.observe = observe
  }
  func write(_ bytes: Data) async throws { throw SearchChildFailure.launchFailed(quarantine.error) }
  func read(maxBytes: Int) async throws -> Data {
    throw SearchChildFailure.launchFailed(quarantine.error)
  }
  func close() async {
    let shared = task()
    observe?(.closeRequested)
    await shared.value
  }
  private func task() -> Task<Void, Never> {
    lock.lock()
    defer { lock.unlock() }
    if let closeTask { return closeTask }
    let task = Task { [self] in
      defer { observe?(.closeTaskFinished) }
      await channelAfterTaskPublication().close()
      await withCheckedContinuation { retain($0) }
    }
    closeTask = task
    return task
  }
  private func channelAfterTaskPublication() -> any SearchChildConnection {
    // A newly scheduled task may run immediately. Cross this lock once so no
    // collaborator is invoked until the creating critical section has ended.
    lock.lock()
    lock.unlock()
    return channel
  }
  private func retain(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    retainedGate = continuation
    lock.unlock()
    observe?(.ancillaryWaitInstalled)
  }
}

private struct DarwinLaunchOperations: LaunchOperations {
  func validateExecutable(_ path: String) throws {
    // URL(fileURLWithPath:) normalizes relative strings; it is not input validation.
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw LaunchError(code: EINVAL) }
    do {
      _ = try SearchWorkerBundleResolver.validateForLaunch(
        URL(fileURLWithPath: path, isDirectory: false))
    } catch SearchWorkerBundleResolverError.filesystem(let code) {
      throw LaunchError(code: code)
    } catch {
      throw LaunchError(code: EINVAL)
    }
  }
  func reaperPolicy() throws -> LaunchReaperPolicy {
    var action = sigaction()
    guard sigaction(SIGCHLD, nil, &action) == 0 else { throw LaunchError(code: errno) }
    if action.sa_flags & SA_NOCLDWAIT != 0 { return .noChildWait }
    // Darwin stores either handler variant in this union; inspect only its address.
    let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self)
    if handler == unsafeBitCast(SIG_DFL, to: UInt.self) { return .standard }
    if handler == unsafeBitCast(SIG_IGN, to: UInt.self) { return .ignored }
    return .custom
  }
  func pipe() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    guard Darwin.pipe(&fds) == 0 else { throw LaunchError(code: errno) }
    return (fds[0], fds[1])
  }
  func openNull() throws -> Int32 {
    let fd = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { throw LaunchError(code: errno) }
    return fd
  }
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws {
    let get: Int32
    let set: Int32
    let bit: Int32
    switch flag {
    case .closeOnExec:
      get = F_GETFD
      set = F_SETFD
      bit = FD_CLOEXEC
    case .nonblocking:
      get = F_GETFL
      set = F_SETFL
      bit = O_NONBLOCK
    case .noSigPipe:
      get = F_GETNOSIGPIPE
      set = F_SETNOSIGPIPE
      bit = 1
    }
    let original = fcntl(fd, get)
    guard original >= 0 else { throw LaunchError(code: errno) }
    guard fcntl(fd, set, original | bit) == 0 else { throw LaunchError(code: errno) }
    let observed = fcntl(fd, get)
    guard observed >= 0 else { throw LaunchError(code: errno) }
    guard observed & bit == bit else { throw LaunchError(code: EIO) }
  }
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32 {
    let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 4)
    guard duplicate >= 0 else { throw LaunchError(code: errno) }
    return duplicate
  }
  func close(_ fd: Int32) -> Int32 { Darwin.close(fd) == 0 ? 0 : errno }
  func makeSpawn() -> any LaunchSpawnOperations { DarwinLaunchSpawn() }
  func signal(_ pid: Int32, _ signal: Int32) -> Int32 { Darwin.kill(pid, signal) == 0 ? 0 : errno }
  func wait(_ pid: Int32) -> LaunchWaitResult {
    var status: Int32 = 0
    let value = waitpid(pid, &status, WNOHANG)
    return .init(value: value, status: status, error: value == -1 ? errno : 0)
  }
}

private final class DarwinLaunchSpawn: LaunchSpawnOperations {
  private var actions: posix_spawn_file_actions_t?
  private var attributes: posix_spawnattr_t?
  private func checked(_ code: Int32) throws { if code != 0 { throw LaunchError(code: code) } }
  func initializeActions() throws { try checked(posix_spawn_file_actions_init(&actions)) }
  func initializeAttributes() throws { try checked(posix_spawnattr_init(&attributes)) }
  func duplicate(_ fd: Int32, to: Int32) throws {
    try checked(posix_spawn_file_actions_adddup2(&actions, fd, to))
  }
  func closeInChild(_ fd: Int32) throws {
    try checked(posix_spawn_file_actions_addclose(&actions, fd))
  }
  func configure(_ attribute: LaunchAttribute) throws {
    switch attribute {
    case .flags:
      try checked(
        posix_spawnattr_setflags(
          &attributes,
          Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
    case .emptyMask:
      var mask = sigset_t()
      guard sigemptyset(&mask) == 0 else { throw LaunchError(code: errno) }
      try checked(posix_spawnattr_setsigmask(&attributes, &mask))
    case .defaultSignals:
      var mask = sigset_t()
      guard sigfillset(&mask) == 0, sigdelset(&mask, SIGKILL) == 0, sigdelset(&mask, SIGSTOP) == 0
      else { throw LaunchError(code: errno) }
      try checked(posix_spawnattr_setsigdefault(&attributes, &mask))
    }
  }
  func spawn(path: String, arguments: [String], environment: [String]) -> LaunchSpawnResult {
    var allocated: [UnsafeMutablePointer<CChar>] = []
    defer { for pointer in allocated { free(pointer) } }
    func vector(_ values: [String]) -> [UnsafeMutablePointer<CChar>?]? {
      var result: [UnsafeMutablePointer<CChar>?] = []
      for value in values {
        guard let pointer = strdup(value) else { return nil }
        allocated.append(pointer)
        result.append(pointer)
      }
      result.append(nil)
      return result
    }
    guard var argv = vector(arguments), var env = vector(environment) else {
      return .init(code: ENOMEM, pid: 0)
    }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, path, &actions, &attributes, &argv, &env)
    return .init(code: code, pid: pid)
  }
  func destroyActions() { posix_spawn_file_actions_destroy(&actions) }
  func destroyAttributes() { posix_spawnattr_destroy(&attributes) }
}

protocol LaunchOperations: Sendable {
  func validateExecutable(_ path: String) throws
  func reaperPolicy() throws -> LaunchReaperPolicy
  func pipe() throws -> (Int32, Int32)
  /// Successful creation is atomically close-on-exec.
  func openNull() throws -> Int32
  func setAndVerify(_ flag: LaunchFlag, fd: Int32) throws
  /// Successful duplication is atomically close-on-exec.
  func duplicateAboveStdio(_ fd: Int32) throws -> Int32
  func close(_ fd: Int32) -> Int32
  func makeSpawn() -> any LaunchSpawnOperations
  func signal(_ pid: Int32, _ signal: Int32) -> Int32
  func wait(_ pid: Int32) -> LaunchWaitResult
}

final class SearchLaunchCoordinator: @unchecked Sendable {
  static let process = SearchLaunchCoordinator()
  let queue = DispatchQueue(label: "TheOnlyPad.search.spawn")
  let spawnGate: ProcessSpawnGate
  init(spawnGate: ProcessSpawnGate = .process) { self.spawnGate = spawnGate }
  // Queue confined, deliberately retained for the process lifetime after uncertainty.
  fileprivate var quarantine: LaunchQuarantine?
}

final class SearchChildLauncher: SearchChildSystem, @unchecked Sendable {
  let operations: any LaunchOperations
  let coordinator: SearchLaunchCoordinator
  let arguments: [String]
  let closeObservation: (@Sendable (LaunchCloseEvent) -> Void)?
  let adopt: @Sendable (Int32, Int32, Int32) -> any SearchChildConnection

  init(
    arguments: [String] = [], operations: any LaunchOperations,
    coordinator: SearchLaunchCoordinator,
    closeObservation: (@Sendable (LaunchCloseEvent) -> Void)? = nil,
    adopt: @escaping @Sendable (Int32, Int32, Int32) -> any SearchChildConnection
  ) {
    self.arguments = arguments
    self.operations = operations
    self.coordinator = coordinator
    self.closeObservation = closeObservation
    self.adopt = adopt
  }

  func launch(
    executable: URL, generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  ) {
    // The queued transaction retains completion even if the facade is abandoned.
    coordinator.queue.async { [self] in
      completion(perform(executable: executable, generation: generation))
    }
  }

  convenience init(arguments: [String] = []) {
    self.init(arguments: arguments, operations: DarwinLaunchOperations(), coordinator: .process) {
      SearchChildChannels(requestWriteFD: $0, responseReadFD: $1, lifetimeWriteFD: $2)
    }
  }

  /// Caller owns this exact unreaped child. No group signal and no implicit wait.
  func signal(pid: Int32, signal: Int32) -> Int32 {
    guard pid > 0 else { return EINVAL }
    return operations.signal(pid, signal)
  }

  /// Sole consuming observer; the lifecycle serializes calls and retires PID authority.
  func pollExit(pid: Int32) -> SearchChildPoll {
    guard pid > 0 else { return .failed(EINVAL) }
    let result = operations.wait(pid)
    if result.value == 0 { return .running }
    if result.value == -1 {
      return result.error == EINTR ? .interrupted : .failed(result.error)
    }
    guard result.value == pid else { return .failed(EPROTO) }
    let signal = result.status & 0x7f
    if signal == 0 { return .reaped(.exited((result.status >> 8) & 0xff)) }
    if signal != 0x7f, signal < NSIG { return .reaped(.signaled(signal)) }
    return .failed(EPROTO)
  }

  private func perform(executable: URL, generation: UUID) -> Result<
    SearchLaunchedChild, SearchChildFailure
  > {
    if let quarantine = coordinator.quarantine { return .failure(.launchFailed(quarantine.error)) }
    guard executable.isFileURL,
      let components = URLComponents(url: executable, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "file",
      components.host == nil || components.host == "" || components.host == "localhost",
      components.query == nil, components.fragment == nil,
      let path = components.percentEncodedPath.removingPercentEncoding,
      path.hasPrefix("/"), !path.utf8.contains(0)
    else { return .failure(.invalidExecutable) }
    guard generation.uuidString != "00000000-0000-0000-0000-000000000000",
      arguments.isEmpty
        || (arguments.count == 2 && arguments[0] == "--mode"
          && ["echo", "exit17", "parent-lifetime-busy-main"].contains(arguments[1]))
    else { return .failure(.launchFailed(EINVAL)) }

    var cells: [LaunchDescriptor] = []
    var spawn: (any LaunchSpawnOperations)?
    var actionsReady = false
    var attributesReady = false
    defer {
      if attributesReady { spawn?.destroyAttributes() }
      if actionsReady { spawn?.destroyActions() }
    }
    func own(_ fd: Int32, protected: Bool = false) -> LaunchDescriptor {
      let cell = LaunchDescriptor(fd, protected: protected)
      cells.append(cell)
      return cell
    }
    func normalize(_ cell: LaunchDescriptor, protected: Bool = false) throws -> LaunchDescriptor {
      if !protected {
        try operations.setAndVerify(.closeOnExec, fd: cell.fd)
        cell.confirmCloseOnExec()
      }
      guard cell.fd <= 3 else { return cell }
      let duplicate = own(try operations.duplicateAboveStdio(cell.fd), protected: true)
      let closeError = cell.close(using: operations)
      guard closeError == 0 else { throw LaunchError(code: closeError) }
      try operations.setAndVerify(.closeOnExec, fd: duplicate.fd)
      return duplicate
    }
    func pipe() throws -> (LaunchDescriptor, LaunchDescriptor) {
      let (read, write) = try coordinator.spawnGate.withCriticalRegion { permit in
        let pair = try operations.pipe()
        // Adopt BOTH results before any fallible flag or normalization operation.
        let read = own(pair.0)
        let write = own(pair.1)
        do {
          try operations.setAndVerify(.closeOnExec, fd: read.fd)
          read.confirmCloseOnExec()
          try operations.setAndVerify(.closeOnExec, fd: write.fd)
          write.confirmCloseOnExec()
          return (read, write)
        } catch {
          // Settle unprotected ownership BEFORE releasing shared admission.
          // Outer cleanup retains uncertainty but cannot retry these integers.
          for cell in [read, write] {
            let closeError = cell.close(using: operations)
            if closeError != 0 && !cell.closeOnExecConfirmed {
              permit.quarantine(closeError)
            }
          }
          throw error
        }
      }
      return (try normalize(read, protected: true), try normalize(write, protected: true))
    }
    func cleanup(primaryError: Int32? = nil) -> LaunchQuarantine? {
      for cell in cells { _ = cell.close(using: operations) }
      guard let error = cells.compactMap({ $0.uncertainError }).first else { return nil }
      let record = LaunchQuarantine(cells: cells, error: error, primaryError: primaryError)
      coordinator.quarantine = record
      return record
    }
    do {
      try operations.validateExecutable(path)
      // Maintain no-external-reaper policy throughout integration, not just this query.
      guard try operations.reaperPolicy() == .standard else { throw LaunchError(code: ECHILD) }
      let request = try pipe()
      let response = try pipe()
      let lifetime = try pipe()
      let null = try normalize(own(try operations.openNull(), protected: true))
      try operations.setAndVerify(.nonblocking, fd: request.1.fd)
      try operations.setAndVerify(.nonblocking, fd: response.0.fd)
      try operations.setAndVerify(.noSigPipe, fd: request.1.fd)
      let setup = operations.makeSpawn()
      spawn = setup
      try setup.initializeActions()
      actionsReady = true
      try setup.initializeAttributes()
      attributesReady = true
      for (source, target) in [(request.0, Int32(0)), (response.1, 1), (null, 2), (lifetime.0, 3)] {
        try setup.duplicate(source.fd, to: target)
      }
      for cell in cells where cell.isOwned { try setup.closeInChild(cell.fd) }
      for attribute in [LaunchAttribute.flags, .emptyMask, .defaultSignals] {
        try setup.configure(attribute)
      }
      let result = try coordinator.spawnGate.withCriticalRegion { _ in
        setup.spawn(
          path: path, arguments: [path, "--generation", generation.uuidString] + arguments,
          environment: ["LANG=C", "LC_ALL=C"])
      }
      guard result.code == 0 else { throw LaunchError(code: result.code) }
      // A zero spawn return is irrevocable child ownership, even for immediate exit.
      let connection = adopt(request.1.transfer(), response.0.transfer(), lifetime.1.transfer())
      if let quarantine = cleanup() {
        let failure = SearchChildFailure.launchFailed(quarantine.error)
        return .success(
          .init(
            pid: result.pid,
            connection: LaunchUnconfirmedConnection(
              connection, quarantine: quarantine, observe: closeObservation),
            startupFailure: failure))
      }
      return .success(.init(pid: result.pid, connection: connection))
    } catch {
      let code: Int32
      if case ProcessSpawnGateError.quarantined(let unsafeError) = error {
        code = unsafeError
      } else {
        code = (error as? LaunchError)?.code ?? EIO
      }
      _ = cleanup(primaryError: code)
      return .failure(.launchFailed(code))
    }
  }
}
