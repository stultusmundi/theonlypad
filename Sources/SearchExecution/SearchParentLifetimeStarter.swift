import Darwin

package struct SearchParentLifetimeStartError: Error, Equatable {
  package enum Stage: Equatable {
    case invalidDescriptor, attributeInitialization, detachedState, creation, attributeDestruction
  }
  package let stage: Stage
  package let code: Int32
  package let attributeCleanupCode: Int32?
  package let threadCreated: Bool
}

typealias SearchParentLifetimeThreadEntry =
  @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

final class SearchParentLifetimeThreadContext {
  let controlFD: Int32
  let run: (Int32) -> Void
  init(controlFD: Int32, run: @escaping (Int32) -> Void) {
    self.controlFD = controlFD
    self.run = run
  }
}

struct SearchParentLifetimeThreadOperations {
  let initializeAttributes: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  let setDetached: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  let create:
    (
      UnsafeMutablePointer<pthread_t?>, UnsafePointer<pthread_attr_t>,
      SearchParentLifetimeThreadEntry, UnsafeMutableRawPointer
    ) -> Int32
  let destroyAttributes: (UnsafeMutablePointer<pthread_attr_t>) -> Int32
  static let darwin = SearchParentLifetimeThreadOperations(
    initializeAttributes: { pthread_attr_init($0) },
    setDetached: { pthread_attr_setdetachstate($0, PTHREAD_CREATE_DETACHED) },
    create: { pthread_create($0, $1, $2, $3) },
    destroyAttributes: { pthread_attr_destroy($0) })
}

extension SearchParentLifetime {
  package static func start(controlFD: Int32) throws {
    try start(controlFD: controlFD, operations: .darwin) {
      SearchParentLifetime.run(controlFD: $0)
    }
  }

  static func start(
    controlFD: Int32, operations: SearchParentLifetimeThreadOperations,
    run: @escaping (Int32) -> Void
  ) throws {
    guard controlFD >= 0 else {
      throw SearchParentLifetimeStartError(
        stage: .invalidDescriptor, code: EINVAL, attributeCleanupCode: nil, threadCreated: false)
    }
    var attributes = pthread_attr_t()
    let initializationCode = operations.initializeAttributes(&attributes)
    guard initializationCode == 0 else {
      throw SearchParentLifetimeStartError(
        stage: .attributeInitialization, code: initializationCode,
        attributeCleanupCode: nil, threadCreated: false)
    }
    let detachedCode = operations.setDetached(&attributes)
    guard detachedCode == 0 else {
      let cleanupCode = operations.destroyAttributes(&attributes)
      throw SearchParentLifetimeStartError(
        stage: .detachedState, code: detachedCode,
        attributeCleanupCode: cleanupCode == 0 ? nil : cleanupCode, threadCreated: false)
    }
    let argument = retainSearchParentLifetimeContext(controlFD: controlFD, run: run)
    var thread: pthread_t? = nil
    let creationCode = operations.create(
      &thread, &attributes, searchParentLifetimeThreadEntry, argument)
    guard creationCode == 0 else {
      // A failed pthread_create cannot have invoked the callback.
      Unmanaged<SearchParentLifetimeThreadContext>.fromOpaque(argument).release()
      let cleanupCode = operations.destroyAttributes(&attributes)
      throw SearchParentLifetimeStartError(
        stage: .creation, code: creationCode,
        attributeCleanupCode: cleanupCode == 0 ? nil : cleanupCode, threadCreated: false)
    }
    // Success transferred ownership even if the callback has already finished.
    let cleanupCode = operations.destroyAttributes(&attributes)
    guard cleanupCode == 0 else {
      throw SearchParentLifetimeStartError(
        stage: .attributeDestruction, code: cleanupCode,
        attributeCleanupCode: nil, threadCreated: true)
    }
  }
}

private func retainSearchParentLifetimeContext(
  controlFD: Int32, run: @escaping (Int32) -> Void
) -> UnsafeMutableRawPointer {
  var context: SearchParentLifetimeThreadContext? = .init(controlFD: controlFD, run: run)
  let argument = Unmanaged.passRetained(context!).toOpaque()
  context = nil
  return argument
}

private func takeSearchParentLifetimeWork(
  _ argument: UnsafeMutableRawPointer
) -> (Int32, (Int32) -> Void) {
  var context: SearchParentLifetimeThreadContext? =
    Unmanaged<SearchParentLifetimeThreadContext>.fromOpaque(argument).takeRetainedValue()
  let work = (context!.controlFD, context!.run)
  // The production body exits without running defers: release the box in this scope.
  context = nil
  return work
}

private let searchParentLifetimeThreadEntry: SearchParentLifetimeThreadEntry = { argument in
  let (controlFD, run) = takeSearchParentLifetimeWork(argument)
  run(controlFD)
  return nil
}
