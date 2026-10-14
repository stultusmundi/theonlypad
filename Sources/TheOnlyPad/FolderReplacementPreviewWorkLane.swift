// Read-only background preview work and primitive presentation projection.
// Cooperative cancellation retains admission until the submitted work actually finishes.
import Foundation
import PadCore

struct FolderReplacementPreviewInput: Sendable {
  let root: URL
  let files: [URL]
  let query: SearchQuery
  let replacement: String
}

struct FolderReplacementPreviewRow: Sendable, Equatable {
  let path: String
  let matches: Int
  let sourceBytes: Int
  let outputBytes: Int
  let hasBOM: Bool
  let wouldChange: Bool
  let originalExcerpt: String
  let proposedExcerpt: String
  let originalExcerptRange: NSRange
  let proposedExcerptRange: NSRange
  let originalMatchRange: NSRange?
  let proposedAnchorUTF16: Int?
  let excerptIsLimited: Bool
}

struct FolderReplacementPreviewDisplay: Sendable, Equatable {
  let operationID: UUID
  let rows: [FolderReplacementPreviewRow]
  let matchCount: Int
  let sourceBytes: Int
  let outputBytes: Int
}

enum FolderReplacementPreviewWorkFailure: Sendable, Equatable {
  case core(String)
  case io(domain: String, code: Int)
  case other(String)
}

enum FolderReplacementPreviewWorkOutcome: Sendable, Equatable {
  case ready(FolderReplacementPreviewDisplay)
  case failed(FolderReplacementPreviewWorkFailure)
  case cancelled
}

enum FolderReplacementPreviewNativeError: Error, Equatable {
  case unimplemented, activeRequest, closed
}

protocol FolderReplacementPreviewCancellation: Sendable {
  var isCancelled: Bool { get }
}

typealias FolderReplacementPreviewOperation =
  @Sendable (FolderReplacementPreviewInput, any FolderReplacementPreviewCancellation) throws
  -> FolderReplacementPreviewDisplay

protocol FolderReplacementPreviewWorkExecuting: Sendable {
  func submit(_ work: @escaping @Sendable () -> Void) throws
}

struct FolderReplacementPreviewDispatchExecutor: FolderReplacementPreviewWorkExecuting {
  private static let queue = DispatchQueue(label: "TheOnlyPad.folder-preview", qos: .userInitiated)

  func submit(_ work: @escaping @Sendable () -> Void) throws {
    Self.queue.async(execute: work)
  }
}

private final class FolderReplacementPreviewCancellationToken:
  FolderReplacementPreviewCancellation, @unchecked Sendable
{
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

enum FolderReplacementPreviewWorkOperation {
  static let maximumExcerptUTF8Bytes = 16_384
  static let leftContextUTF8Bytes = 8_192

  static func run(
    _ input: FolderReplacementPreviewInput,
    cancellation: any FolderReplacementPreviewCancellation
  ) throws -> FolderReplacementPreviewDisplay {
    let preview = try FolderReplacementPreviewBuilder().preview(
      root: input.root, selectedURLs: input.files, query: input.query,
      replacement: input.replacement, isCancelled: { cancellation.isCancelled })
    // Core DTOs and complete bytes stay in this worker invocation. Only bounded primitives leave it.
    var rows: [FolderReplacementPreviewRow] = []
    for entry in preview.entries {
      try checkCancellation(cancellation)
      let original = try decode(entry.originalData, hasBOM: entry.hasBOM)
      let proposed = try decode(entry.proposedData, hasBOM: entry.hasBOM)
      let first = entry.ranges.first
      let anchor = first?.location ?? 0
      let before = try excerpt(original, anchor: anchor, cancellation: cancellation)
      let after = try excerpt(proposed, anchor: anchor, cancellation: cancellation)
      rows.append(
        FolderReplacementPreviewRow(
          path: entry.relativePath, matches: entry.ranges.count,
          sourceBytes: entry.originalData.count, outputBytes: entry.proposedData.count,
          hasBOM: entry.hasBOM, wouldChange: entry.wouldChange,
          originalExcerpt: before.text, proposedExcerpt: after.text,
          originalExcerptRange: before.range, proposedExcerptRange: after.range,
          originalMatchRange: first, proposedAnchorUTF16: first?.location,
          excerptIsLimited: before.limited || after.limited))
    }
    try checkCancellation(cancellation)
    return FolderReplacementPreviewDisplay(
      operationID: preview.id, rows: rows, matchCount: preview.matchCount,
      sourceBytes: preview.sourceBytes, outputBytes: preview.outputBytes)
  }

  private static func decode(_ data: Data, hasBOM: Bool) throws -> String {
    guard let text = String(data: Data(data.dropFirst(hasBOM ? 3 : 0)), encoding: .utf8) else {
      throw FolderReplacementPreviewError.unsupportedInput
    }
    return text
  }

  private static func checkCancellation(
    _ cancellation: any FolderReplacementPreviewCancellation
  ) throws {
    if cancellation.isCancelled { throw FolderReplacementPreviewError.cancelled }
  }

  private static func excerpt(
    _ text: String, anchor: Int, cancellation: any FolderReplacementPreviewCancellation
  ) throws -> (text: String, range: NSRange, limited: Bool) {
    let utf16 = text.utf16
    guard anchor >= 0,
      let offset = utf16.index(utf16.startIndex, offsetBy: anchor, limitedBy: utf16.endIndex),
      let center = offset.samePosition(in: text.unicodeScalars)
    else { throw FolderReplacementPreviewError.unsupportedInput }
    let scalars = text.unicodeScalars
    var start = center
    var end = center
    var bytes = 0
    while start > scalars.startIndex {
      try checkCancellation(cancellation)
      let previous = scalars.index(before: start)
      let count = String(scalars[previous]).utf8.count
      guard bytes + count <= leftContextUTF8Bytes else { break }
      bytes += count
      start = previous
    }
    while end < scalars.endIndex {
      try checkCancellation(cancellation)
      let count = String(scalars[end]).utf8.count
      guard bytes + count <= maximumExcerptUTF8Bytes else { break }
      bytes += count
      end = scalars.index(after: end)
    }
    guard let first = start.samePosition(in: utf16), let last = end.samePosition(in: utf16)
    else { throw FolderReplacementPreviewError.unsupportedInput }
    let range = NSRange(
      location: utf16.distance(from: utf16.startIndex, to: first),
      length: utf16.distance(from: first, to: last))
    return (
      String(scalars[start..<end]), range,
      start != scalars.startIndex || end != scalars.endIndex
    )
  }
}

@MainActor
final class FolderReplacementPreviewWorkLane {
  private let executor: any FolderReplacementPreviewWorkExecuting
  private let operation: FolderReplacementPreviewOperation?
  private var active: (id: UUID, token: FolderReplacementPreviewCancellationToken)?

  init(
    executor: any FolderReplacementPreviewWorkExecuting =
      FolderReplacementPreviewDispatchExecutor(),
    operation: FolderReplacementPreviewOperation? = nil
  ) {
    self.executor = executor
    self.operation = operation
  }

  func start(
    _ input: FolderReplacementPreviewInput,
    requestID: UUID,
    publish: @escaping @MainActor (UUID, FolderReplacementPreviewWorkOutcome) -> Void,
    settled: @escaping @MainActor (UUID) -> Void
  ) throws -> Bool {
    guard active == nil else { return false }
    let token = FolderReplacementPreviewCancellationToken()
    active = (requestID, token)
    let work: FolderReplacementPreviewOperation =
      operation ?? { input, cancellation in
        try FolderReplacementPreviewWorkOperation.run(input, cancellation: cancellation)
      }
    do {
      try executor.submit {
        let outcome: FolderReplacementPreviewWorkOutcome
        do {
          let display = try work(input, token)
          outcome = .ready(display)
        } catch let error as FolderReplacementPreviewError {
          outcome = error == .cancelled ? .cancelled : .failed(.core(String(describing: error)))
        } catch {
          // Reflect the native error's dynamic type before bridging: arbitrary Swift errors
          // must not acquire a fabricated NSError category merely through automatic bridging.
          if type(of: error) is NSError.Type {
            let native = error as NSError
            outcome = .failed(.io(domain: native.domain, code: native.code))
          } else {
            outcome = .failed(.other(String(describing: error)))
          }
        }
        Task { @MainActor in
          guard let owned = self.active, owned.id == requestID, owned.token === token else {
            return
          }
          let delivered: FolderReplacementPreviewWorkOutcome =
            token.isCancelled ? .cancelled : outcome
          self.active = nil
          publish(requestID, delivered)
          settled(requestID)
        }
      }
    } catch {
      if active?.token === token { active = nil }
      throw error
    }
    return true
  }

  func cancel(requestID: UUID) throws {
    guard let owned = active, owned.id == requestID else { return }
    owned.token.cancel()
  }
}

enum FolderReplacementPreviewWorkPhase: Equatable {
  case inputReady, running, cancelRequested, ready, failed, closed
}

@MainActor
final class FolderReplacementPreviewWorkState {
  private(set) var activeRequestID: UUID?
  private(set) var publicationGeneration = UUID()
  private(set) var phase: FolderReplacementPreviewWorkPhase = .inputReady
  private(set) var lastOutcome: FolderReplacementPreviewWorkOutcome?
  var canStart: Bool { activeRequestID == nil && phase != .closed }

  func begin(requestID: UUID) throws -> UUID {
    guard phase != .closed else { throw FolderReplacementPreviewNativeError.closed }
    guard activeRequestID == nil else { throw FolderReplacementPreviewNativeError.activeRequest }
    activeRequestID = requestID
    publicationGeneration = UUID()
    lastOutcome = nil
    phase = .running
    return publicationGeneration
  }

  func rejectAdmission(requestID: UUID) throws -> Bool {
    guard activeRequestID == requestID else { return false }
    activeRequestID = nil
    publicationGeneration = UUID()
    lastOutcome = nil
    if phase != .closed { phase = .inputReady }
    return true
  }

  func requestCancellation() throws -> UUID? {
    publicationGeneration = UUID()
    lastOutcome = nil
    if phase != .closed { phase = activeRequestID == nil ? .inputReady : .cancelRequested }
    return activeRequestID
  }

  func close() throws -> UUID? {
    publicationGeneration = UUID()
    lastOutcome = nil
    phase = .closed
    return activeRequestID
  }

  func publish(
    requestID: UUID, generation: UUID, outcome: FolderReplacementPreviewWorkOutcome
  ) throws -> Bool {
    guard phase != .closed, activeRequestID == requestID, publicationGeneration == generation else {
      return false
    }
    lastOutcome = outcome
    switch outcome {
    case .ready: phase = .ready
    case .failed: phase = .failed
    case .cancelled:
      lastOutcome = nil
      phase = .inputReady
    }
    return true
  }

  func acknowledgeSettlement(requestID: UUID) throws -> Bool {
    guard activeRequestID == requestID else { return false }
    activeRequestID = nil
    if phase == .running || phase == .cancelRequested { phase = .inputReady }
    return true
  }
}
