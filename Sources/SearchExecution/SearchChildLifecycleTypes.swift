import Foundation

final class SearchChildObserverRegistration: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

public struct SearchChildPolicy: Sendable, Equatable {
  public let operationNanoseconds: UInt64
  public let reapGraceNanoseconds: UInt64
  public let idleNanoseconds: UInt64
  public let maximumRequestsPerChild: UInt32

  public init(
    operationNanoseconds: UInt64,
    reapGraceNanoseconds: UInt64,
    idleNanoseconds: UInt64,
    maximumRequestsPerChild: UInt32
  ) throws {
    guard
      operationNanoseconds > 0,
      operationNanoseconds <= 60_000_000_000,
      reapGraceNanoseconds > 0,
      reapGraceNanoseconds <= 5_000_000_000,
      idleNanoseconds > 0,
      idleNanoseconds <= 60_000_000_000,
      maximumRequestsPerChild > 0
    else {
      throw SearchChildFailure.invalidPolicy
    }
    self.operationNanoseconds = operationNanoseconds
    self.reapGraceNanoseconds = reapGraceNanoseconds
    self.idleNanoseconds = idleNanoseconds
    self.maximumRequestsPerChild = maximumRequestsPerChild
  }
}

public struct SearchChildTicket: Sendable, Equatable {
  public let identity: SearchWireIdentity
}

public enum SearchChildFailure: Error, Sendable, Equatable {
  case busy
  case invalidPolicy
  case invalidExecutable
  case invalidRequestID
  case observerBusy
  case staleTicket
  case launchFailed(Int32)
  case channelFailure(Int32)
  case handshakeFailure
  case protocolFailure
  case cancelled
  case deadline
  case unexpectedExit
  case shutDown
}

public enum SearchChildExit: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}

public enum SearchChildOutcome: Sendable, Equatable {
  case completed(SearchWireTerminal)
  case failed(SearchChildFailure)
}

public enum SearchChildCleanup: Sendable, Equatable {
  /// No spawned child is retained. This does not certify closure of descriptors
  /// quarantined by a failed launcher setup before child/connection adoption.
  case noChild
  case pendingLaunch(generation: UUID)
  case stopping(generation: UUID)
  case reaped(generation: UUID, exit: SearchChildExit)
  case stopUnconfirmed(generation: UUID)
}

public struct SearchChildShutdown: Sendable, Equatable {
  public let cleanup: SearchChildCleanup
  /// Confirms adopted connection cleanup, including its retained ancillary resources.
  /// Pre-adoption launcher quarantine is outside this connection receipt.
  public let channelsClosed: Bool

  /// Child/adopted-connection settlement, not complete process resource cleanup.
  /// A launcher may retain pre-adoption quarantine and permanently refuse new launches.
  public var stopped: Bool {
    switch cleanup {
    case .noChild, .reaped:
      return channelsClosed
    case .pendingLaunch, .stopping, .stopUnconfirmed:
      return false
    }
  }
}

protocol SearchChildConnection: AnyObject, Sendable {
  func write(_ bytes: Data) async throws
  func read(maxBytes: Int) async throws -> Data
  func close() async
}

/// Cancellation is idempotent and nonblocking. A callback already enqueued may still run;
/// lifecycle identity/token checks fence it. The scheduler uses absolute monotonic time.
protocol SearchChildTimer: AnyObject, Sendable {
  func cancel()
}

struct SearchLaunchedChild: Sendable {
  let pid: Int32
  let connection: any SearchChildConnection
  /// A real child exists even when startup fails. Its connection retains every
  /// adopted cleanup obligation; failure must not bypass PID adoption and reap.
  let startupFailure: SearchChildFailure?

  init(
    pid: Int32, connection: any SearchChildConnection,
    startupFailure: SearchChildFailure? = nil
  ) {
    self.pid = pid
    self.connection = connection
    self.startupFailure = startupFailure
  }
}

enum SearchChildPoll: Sendable {
  case running
  case reaped(SearchChildExit)
  case interrupted
  case failed(Int32)
}

/// Control-lane methods must return promptly. Launch submits to one retained spawn lane
/// and invokes completion exactly once; filesystem work must happen on that spawn lane.
/// pollExit is the sole serialized, nonblocking wait authority for the exact owned PID.
protocol SearchChildSystem: AnyObject, Sendable {
  func launch(
    executable: URL,
    generation: UUID,
    completion: @escaping @Sendable (Result<SearchLaunchedChild, SearchChildFailure>) -> Void
  )
  func signal(pid: Int32, signal: Int32) -> Int32
  func pollExit(pid: Int32) -> SearchChildPoll
}

/// Generation-tagged observation from the sole channel consumer.
enum SearchChildChannelObservation: Sendable, Equatable {
  case endOfFile
  case failure(Int32)
}

/// Read-only control-lane observation, not a launcher quarantine certificate.
enum SearchChildAdmissionInspection: Sendable, Equatable {
  case unsettled
  case absent(admissionClosed: Bool)
  case healthy(generation: UUID)
}
