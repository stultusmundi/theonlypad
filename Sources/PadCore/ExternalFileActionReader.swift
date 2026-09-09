import Foundation

public struct ExternalFileActionSnapshot: Sendable {
  public let bytes: Data
  public let document: DecodedDocument
  fileprivate let observation: DiskObservation
  fileprivate let url: URL
}

/// Synchronous work for a bounded background worker; never call from the UI thread.
public struct ExternalFileActionReader: Sendable {
  public init() {}
  public func read(
    _ url: URL, matching observation: DiskObservation, fallbackEncoding: DocumentEncoding,
    isCancelled: @Sendable () -> Bool
  ) throws -> ExternalFileActionSnapshot {
    if isCancelled() { throw CancellationError() }
    let read = try FileMaterializationGuard.perform {
      try ExternalFileProbe().read(url, matching: observation, isCancelled: isCancelled)
    }
    if isCancelled() { throw CancellationError() }
    let document = try ExternalDocumentDecoder.decode(
      read.bytes, fallbackEncoding: fallbackEncoding)
    if isCancelled() { throw CancellationError() }
    return ExternalFileActionSnapshot(
      bytes: read.bytes, document: document, observation: read.observation, url: url)
  }
  public func revalidate(
    _ snapshot: ExternalFileActionSnapshot, isCancelled: @Sendable () -> Bool
  ) throws {
    if isCancelled() { throw CancellationError() }
    let current = try FileMaterializationGuard.perform {
      try ExternalFileProbe().read(
        snapshot.url, matching: snapshot.observation, isCancelled: isCancelled)
    }
    guard current.bytes == snapshot.bytes else { throw ExternalFileProbeError.observationChanged }
    if isCancelled() { throw CancellationError() }
  }
}
