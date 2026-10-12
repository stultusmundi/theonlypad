// SPDX-License-Identifier: MIT
// Bounded standalone profile import and exclusive export through the actual file primitives.
import Foundation

public enum LanguageProfileTransferError: Error, Equatable {
  case unavailable(DiskLocationProblem)
  case tooLarge
}

public struct LanguageProfileExportUncertain: Error, LocalizedError, Sendable {
  public let evidence: FilePublicationEvidence
  public let attemptedBytes: Data

  fileprivate init(evidence: FilePublicationEvidence, attemptedBytes: Data) {
    self.evidence = evidence
    self.attemptedBytes = attemptedBytes
  }

  public var errorDescription: String? {
    "The profile may have been written, but publication could not be confirmed. Keep the attempted definition and verify the destination before deciding what to do next."
  }
}

struct LanguageProfileTransferHooks: Sendable {
  var probe = ExternalFileProbe()
  var afterObservation: @Sendable () throws -> Void = {}
  var beforeRead: @Sendable () throws -> Void = {}
  var saveNewFile: @Sendable (Data, URL) throws -> Void = { bytes, url in
    try AtomicFileStore().save(bytes, to: url, expected: nil)
  }
}

/// Synchronous real I/O. Call off the main/control queue.
public struct LanguageProfileTransfer: Sendable {
  private let hooks: LanguageProfileTransferHooks

  public init() { hooks = LanguageProfileTransferHooks() }
  init(hooks: LanguageProfileTransferHooks) { self.hooks = hooks }

  public func importDefinition(
    from url: URL, isCancelled: @Sendable () -> Bool = { false }
  ) throws -> LiteralLanguageDefinition {
    if isCancelled() { throw CancellationError() }
    let observation = try hooks.probe.observe(
      url, expected: Data(), boundIdentity: nil, forceContents: true, previous: nil,
      isCancelled: isCancelled)
    if isCancelled() { throw CancellationError() }
    if let problem = observation.locationProblem {
      throw LanguageProfileTransferError.unavailable(problem)
    }
    guard let metadata = observation.metadata, metadata.byteCount >= 0 else {
      throw LanguageProfileTransferError.unavailable(.changedDuringRead)
    }
    // Refuse oversized metadata before any matching payload read.
    if metadata.byteCount > 65_536 { throw LanguageProfileTransferError.tooLarge }
    try hooks.afterObservation()
    if isCancelled() { throw CancellationError() }
    try hooks.beforeRead()
    let read = try hooks.probe.read(url, matching: observation, isCancelled: isCancelled)
    if isCancelled() { throw CancellationError() }
    let definition = try LanguageProfileCodec.decodeDefinition(read.bytes)
    if isCancelled() { throw CancellationError() }
    return definition
  }

  public func exportDefinition(
    _ definition: LiteralLanguageDefinition, to url: URL,
    isCancelled: @Sendable () -> Bool = { false }
  ) throws {
    let bytes = try LanguageProfileCodec.encodeDefinition(definition)
    if isCancelled() { throw CancellationError() }
    var publicationError: Error?
    do {
      try hooks.saveNewFile(bytes, url)
    } catch let original {
      publicationError = original
    }
    // Preserve the joined actual publication outcome even if cancellation arrived during save.
    if let original = publicationError {
      if let fileError = original as? FileStoreError,
        case .publicationUncertain(let evidence) = fileError
      {
        throw LanguageProfileExportUncertain(evidence: evidence, attemptedBytes: bytes)
      }
      throw original
    }
  }
}
