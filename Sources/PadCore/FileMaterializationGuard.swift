import Darwin
import Foundation

public enum FileMaterializationError: Error, Sendable {
  case query(Int32)
  case disable(Int32)
  case restore(Int32)
}
struct MaterializationPolicyHooks {
  var get: () -> Int32 = {
    getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
  }
  var set: (Int32) -> Int32 = {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, $0)
  }
}
/// Runs synchronous work with dataless-file materialization disabled on the calling thread only.
/// All path lookup/content access must stay on this thread; do not dispatch it to another thread.
/// Returned owned resources require disposal if restoring the prior policy fails.
public enum FileMaterializationGuard {
  public static func perform<T>(
    discardOnRestoreFailure: (T) -> Void = { _ in },
    _ operation: () throws -> T
  ) throws -> T {
    try perform(
      hooks: MaterializationPolicyHooks(), discardOnRestoreFailure: discardOnRestoreFailure,
      operation)
  }
  // The operation must stay synchronous on this thread. Perform no path lookup or content access before entry.
  // Callers returning owned resources must provide disposal if restoring the prior policy fails.
  static func perform<T>(
    hooks: MaterializationPolicyHooks,
    discardOnRestoreFailure: (T) -> Void = { _ in }, _ operation: () throws -> T
  ) throws -> T {
    let previous = hooks.get()
    guard previous >= 0 else { throw FileMaterializationError.query(errno) }
    guard hooks.set(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
      throw FileMaterializationError.disable(errno)
    }
    let outcome = Result<T, Error>(catching: operation)
    guard hooks.set(previous) == 0 else {
      let restorationError = errno
      if case .success(let value) = outcome { discardOnRestoreFailure(value) }
      throw FileMaterializationError.restore(restorationError)
    }
    return try outcome.get()
  }
}
