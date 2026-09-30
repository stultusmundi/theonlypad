import Foundation

package enum ProcessSpawnGateError: Error, Equatable {
  case quarantined(Int32)
}

package struct ProcessSpawnPermit {
  fileprivate var unsafeError: Int32?
  fileprivate init() {}
  /// Monotonic refusal evidence; this permit never owns or retries descriptors.
  package mutating func quarantine(_ error: Int32) {
    if unsafeError == nil && error != 0 { unsafeError = error }
  }
}

/// Serializes transient descriptor protection with app-owned spawning. Lock order
/// is search spawn lane -> this gate; never hold it across adoption, I/O or waits.
package final class ProcessSpawnGate: @unchecked Sendable {
  package static let process = ProcessSpawnGate()
  private let lock = NSLock()
  private var unsafeError: Int32?
  private let onContention: (@Sendable () -> Void)?

  /// Optional observation is only for fresh injected test gates. It must only
  /// record/signal, never wait, reenter, or change ownership. Production uses nil.
  package init(onContention: (@Sendable () -> Void)? = nil) {
    self.onContention = onContention
  }

  package func withCriticalRegion<T>(
    _ body: (inout ProcessSpawnPermit) throws -> T
  ) throws -> T {
    if let onContention {
      if !lock.try() {
        onContention()
        lock.lock()
      }
    } else {
      lock.lock()
    }
    if let unsafeError {
      lock.unlock()
      throw ProcessSpawnGateError.quarantined(unsafeError)
    }
    var permit = ProcessSpawnPermit()
    defer {
      // Commit unsafe cleanup BEFORE any queued spawn can enter, even on throw.
      if let error = permit.unsafeError { unsafeError = error }
      lock.unlock()
    }
    return try body(&permit)
  }

  /// The optional query is a short internal owner-state read, never client work.
  /// Admission linearizes at this query; later cancellation may still launch and
  /// use the caller's existing stop path. Shared unsafe-state refusal wins first.
  @discardableResult
  package func run(_ process: Process, unlessCancelled: () -> Bool = { false }) throws -> Bool {
    try withCriticalRegion { _ in
      guard !unlessCancelled() else { return false }
      try process.run()
      return true
    }
  }
}
