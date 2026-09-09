import Foundation
import PadCore

@MainActor enum CheckpointTrace {
  struct Event: Codable {
    let kind: String
    let generation: UInt64
    let seconds: Double
    let recoveryUnits: Int?
  }
  static var events: [Event] = []
  static var writingGeneration: UInt64?
  static var writingUnits = 0
  static var acknowledged: UInt64 = 0
  static var lastError: [String: Any]?
  static func recordError(_ error: Error?) {
    guard let error else {
      lastError = nil
      return
    }
    let native = error as NSError
    let allowedDomains = [NSPOSIXErrorDomain, NSCocoaErrorDomain]
    var record: [String: Any] = [
      "type": String(reflecting: type(of: error)),
      "domain": allowedDomains.contains(native.domain) ? native.domain : "product-or-other",
      "code": native.code,
    ]
    if let value = error as? RecoveryError {
      record["knownProductError"] = String(describing: value)
    } else if let value = error as? CheckpointFailure {
      record["knownProductError"] = String(describing: value)
    } else if let value = error as? SessionStoreError {
      record["knownProductError"] = String(describing: value)
    } else if let value = error as? FileStoreError {
      switch value {
      case .externalChange: record["knownProductError"] = "externalChange"
      case .unsafeTarget: record["knownProductError"] = "unsafeTarget"
      case .readOnly: record["knownProductError"] = "readOnly"
      case .injectedFailure: record["knownProductError"] = "injectedFailure"
      case .publicationUncertain: record["knownProductError"] = "publicationUncertain"
      }
    }
    // Never serialize localizedDescription/userInfo or publication destination evidence.
    lastError = record
  }
  static func emit(_ kind: String, _ generation: UInt64, units: Int? = nil) {
    precondition(events.count < 1000, "Bounded experiment event budget")
    events.append(
      Event(
        kind: kind, generation: generation,
        seconds: ProcessInfo.processInfo.systemUptime, recoveryUnits: units))
  }
  static func captureStarted(_ generation: UInt64) { emit("captureStart", generation) }
  static func captureFinished(_ generation: UInt64) { emit("captureEnd", generation) }
  static func publicationStarted(_ capture: SessionCheckpointCapture) {
    writingGeneration = capture.generation
    // NSString length only on already-captured immutable text; no second snapshot.
    writingUnits = capture.recovery.reduce(0) {
      $0 + ($1.snapshot.map { ($0.text as NSString).length } ?? 0)
    }
    emit("commitAwaitStart", capture.generation, units: writingUnits)
  }
  static func publicationFinished(_ generation: UInt64) {
    emit("commitAwaitReturn", generation)
    writingGeneration = nil
    writingUnits = 0
  }
  static func acknowledgement(_ generation: UInt64) {
    if generation > acknowledged {
      acknowledged = generation
      emit("acknowledged", generation)
    }
  }
}

struct DiskEvent: Codable, Sendable {
  let kind: String
  let seconds: Double
}
/// Observation only: one short locked append, no gating or change to real storage operations.
final class DiskTrace: @unchecked Sendable {
  static let shared = DiskTrace()
  private let lock = NSLock()
  private var events: [DiskEvent] = []
  func emit(_ kind: String) {
    lock.lock()
    defer { lock.unlock() }
    precondition(events.count < 1000)
    events.append(DiskEvent(kind: kind, seconds: ProcessInfo.processInfo.systemUptime))
  }
  func snapshot() -> [DiskEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
  func recoveryWriteIsActive() -> Bool {
    let values = snapshot()
    return values.last(where: { $0.kind.hasPrefix("recoveryWrite") })?.kind == "recoveryWriteStart"
  }
}
