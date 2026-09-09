import Foundation

public enum ShortcutTransferError: Error, Equatable, LocalizedError {
  case unavailable(DiskLocationProblem)
  case tooLarge
  public var errorDescription: String? {
    switch self {
    case .unavailable(.notDownloaded):
      return "Download the shortcut file explicitly in Finder, then retry importing it."
    case .unavailable(let problem):
      return
        "The shortcut file could not be read safely (\(problem)). Choose an available local regular file."
    case .tooLarge:
      return "The shortcut file exceeds the \(ShortcutProfile.maximumBytes)-byte import limit."
    }
  }
}
struct ShortcutTransferHooks: Sendable {
  var probe = ExternalFileProbe()
  var afterObservation: @Sendable () throws -> Void = {}
  var beforeRead: @Sendable () throws -> Void = {}
  var fault: SaveFault?
}

/// Synchronous explicit import/export. Call off the main thread.
/// Export requires a new filename and never authorizes replacing an existing file.
public struct ShortcutTransfer: Sendable {
  private let hooks: ShortcutTransferHooks
  public init() { hooks = ShortcutTransferHooks() }
  init(hooks: ShortcutTransferHooks) { self.hooks = hooks }
  public func importProfile(from url: URL, isCancelled: @Sendable () -> Bool = { false }) throws
    -> ShortcutProfile
  {
    if isCancelled() { throw CancellationError() }
    let observation = try hooks.probe.observe(
      url, expected: Data(), boundIdentity: nil, forceContents: true, previous: nil,
      isCancelled: isCancelled)
    if isCancelled() { throw CancellationError() }
    if let problem = observation.locationProblem {
      throw ShortcutTransferError.unavailable(problem)
    }
    guard let metadata = observation.metadata, observation.content != .unavailable else {
      throw ShortcutTransferError.unavailable(.changedDuringRead)
    }
    guard metadata.byteCount >= 0, metadata.byteCount <= ShortcutProfile.maximumBytes else {
      throw ShortcutTransferError.tooLarge
    }
    try hooks.afterObservation()
    if isCancelled() { throw CancellationError() }
    try hooks.beforeRead()
    let read = try hooks.probe.read(url, matching: observation, isCancelled: isCancelled)
    if isCancelled() { throw CancellationError() }
    let profile = try ShortcutProfile.decode(read.bytes)
    if isCancelled() { throw CancellationError() }
    return profile
  }
  public func export(_ profile: ShortcutProfile, to url: URL) throws {
    let bytes = try profile.encode()
    do {
      try AtomicFileStore().save(bytes, to: url, expected: nil, fault: hooks.fault)
    } catch FileStoreError.publicationUncertain(let evidence) {
      throw ShortcutPublicationUncertain(evidence: evidence, attemptedBytes: bytes)
    }
  }
}
