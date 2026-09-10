import Darwin
import Foundation
import PadCore

struct NativeApplicationOpenDestination: Equatable {
  let endpointID: UUID
  let assignment: DocumentAssignment
}
@MainActor struct NativeApplicationOpenPorts {
  let chooseDestination: (LaunchRequest) throws -> NativeApplicationOpenDestination
  let requireDestination: (NativeApplicationOpenDestination) throws -> Void
  let existing: (LaunchRequest, NativeApplicationOpenDestination) throws -> UUID?
  let submit: (NativeDocumentSeed, NativeApplicationOpenDestination) throws -> DocumentIntakeID
  let wait: (DocumentIntakeID) async throws -> DocumentIntakeResult
  let retrySame:
    (DocumentIntakeID, NativeApplicationOpenDestination) async throws ->
      NativeApplicationOpenDestination
  let reconcileDestination:
    (UUID, NativeApplicationOpenDestination) throws -> NativeApplicationOpenDestination
  let navigate: (UUID, NativeApplicationOpenDestination, Int, Int) async throws -> Void
  let largeFile: (LaunchRequest, NativeApplicationOpenDestination) async throws -> Void
  let reportError: (OpenRequestFailure) -> Void
}
enum NativeApplicationOpenError: Error, LocalizedError {
  case tooLarge, unsafeFile, documentClosed, temporarilyUnavailable
  var errorDescription: String? {
    switch self {
    case .tooLarge:
      return "This file exceeds the 100 MB editable limit. Open it in the read-only byte viewer."
    case .unsafeFile: return "Open requires a regular local file."
    case .documentClosed:
      return "The opened document was closed before its requested position could be restored."
    case .temporarilyUnavailable:
      return "A window move is in progress. Retry opening the file after it finishes."
    }
  }
}
/// One process-owned queue and at most one preparation task. Retained intake never recreates its model.
@MainActor final class NativeApplicationOpenCoordinator {
  private final class Current {
    let requestID: UUID
    var destination: NativeApplicationOpenDestination
    var intakeID: DocumentIntakeID?
    var documentID: UUID?
    init(_ id: UUID, _ destination: NativeApplicationOpenDestination) {
      requestID = id
      self.destination = destination
    }
  }
  private let ports: NativeApplicationOpenPorts
  private var current: Current?
  private var pendingFailure: OpenRequestFailure?
  var onChange: (() -> Void)?
  private lazy var queue: ApplicationOpenRequests = {
    let value = ApplicationOpenRequests { [weak self] request in
      guard let self else { return .refused(DocumentIntakeError.expired) }
      return await self.process(request)
    }
    value.onChange = { [weak self] in
      guard let self else { return }
      // Consume before notifying: reporting may synchronously retry, quit, or enqueue.
      // Queue completion has already stored the failure and retired the failed task.
      if let failure = self.pendingFailure, self.queue.lastFailure?.id == failure.id {
        self.pendingFailure = nil
        self.ports.reportError(failure)
      }
      self.onChange?()
    }
    return value
  }()
  init(ports: NativeApplicationOpenPorts) { self.ports = ports }
  var pendingCount: Int { queue.pendingCount }
  var isProcessing: Bool { queue.isProcessing }
  var hasRetainedRequest: Bool { queue.currentID != nil && !queue.isProcessing }
  var lastFailure: OpenRequestFailure? { queue.lastFailure }
  var currentID: UUID? { queue.currentID }
  func enqueue(_ requests: [LaunchRequest]) -> OpenRequestAdmission { queue.enqueue(requests) }
  func startupFinished() { queue.startupFinished() }
  func beginQuit() { queue.beginQuit() }
  func drainCurrent() async { await queue.drainCurrent() }
  func resumeAfterVeto() { queue.resumeAfterVeto() }
  func retryCurrent() throws { try queue.retryCurrent() }

  private func process(_ envelope: ApplicationOpenRequest) async -> ApplicationOpenRequestOutcome {
    do {
      let value: Current
      if let retained = current {
        guard retained.requestID == envelope.id else { throw DocumentIntakeError.staleModel }
        value = retained
        if let document = value.documentID {
          value.destination = try ports.reconcileDestination(document, value.destination)
        } else if let intake = value.intakeID {
          value.destination = try await ports.retrySame(intake, value.destination)
        }
      } else {
        _ = try envelope.request.protocolURL()
        value = Current(envelope.id, try ports.chooseDestination(envelope.request))
        current = value
        try ports.requireDestination(value.destination)
        value.documentID = try ports.existing(envelope.request, value.destination)
        try ports.requireDestination(value.destination)
        if value.documentID == nil {
          let seed: NativeDocumentSeed
          do {
            seed = try await Task.detached(priority: .userInitiated) {
              try Self.read(envelope.request.url)
            }.value
          } catch NativeApplicationOpenError.tooLarge {
            try ports.requireDestination(value.destination)
            try await ports.largeFile(envelope.request, value.destination)
            current = nil
            return .completed
          }
          try ports.requireDestination(value.destination)
          value.intakeID = try ports.submit(seed, value.destination)
        }
      }
      if value.documentID == nil, let intake = value.intakeID {
        switch try await ports.wait(intake) {
        case .imported(let document): value.documentID = document
        case .refused(let error):
          current = nil
          pendingFailure = .init(id: envelope.id, error: error)
          return .refused(error)
        case .retained(_, let error):
          pendingFailure = .init(id: envelope.id, error: error)
          return .retained(error)
        }
      }
      guard let document = value.documentID else { throw DocumentIntakeError.staleModel }
      try ports.requireDestination(value.destination)
      try await ports.navigate(
        document, value.destination, envelope.request.line, envelope.request.column)
      try ports.requireDestination(value.destination)
      current = nil
      return .completed
    } catch {
      // Destination admission can defer an accepted envelope before any native/import effects.
      // Preserve only this typed transient refusal; malformed and permanent requests still advance.
      if current == nil, case NativeApplicationOpenError.temporarilyUnavailable = error {
        pendingFailure = .init(id: envelope.id, error: error)
        return .retained(error)
      }
      let positioningIsTerminal = current?.documentID != nil && Self.isTerminalPositionError(error)
      let retained =
        !positioningIsTerminal && (current?.intakeID != nil || current?.documentID != nil)
      if !retained { current = nil }
      pendingFailure = .init(id: envelope.id, error: error)
      return retained ? .retained(error) : .refused(error)
    }
  }

  /// These failures concern positioning only; an already imported model remains registry-owned.
  /// A retained intake without an imported document ID must never be abandoned by error classification.
  private static func isTerminalPositionError(_ error: Error) -> Bool {
    if let error = error as? LaunchRequestError {
      switch error {
      case .lineOutOfRange, .invalidPosition: return true
      default: return false
      }
    }
    if case NativeApplicationOpenError.documentClosed = error { return true }
    return false
  }

  nonisolated private static func read(_ url: URL) throws -> NativeDocumentSeed {
    // Validate local URL before POSIX use; O_NONBLOCK avoids waiting on a substituted FIFO.
    _ = try LaunchRequest(url: url).protocolURL()
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw NativeApplicationOpenError.unsafeFile
    }
    let maximum = 100_000_000
    guard info.st_size <= maximum else { throw NativeApplicationOpenError.tooLarge }
    var bytes = Data()
    while bytes.count <= maximum {
      let chunk = try handle.read(upToCount: min(1_048_576, maximum + 1 - bytes.count)) ?? Data()
      if chunk.isEmpty { break }
      bytes.append(chunk)
    }
    guard bytes.count <= maximum else { throw NativeApplicationOpenError.tooLarge }
    return try NativeDocumentSeed.opened(url: url, bytes: bytes)
  }
}
