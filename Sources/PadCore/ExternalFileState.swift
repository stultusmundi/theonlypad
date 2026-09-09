import Foundation

public struct FileObservationToken: Sendable, Equatable {
  public let documentID: UUID
  public let epoch: UInt64
  public let baselineRevision: UInt64
  public let sequence: UInt64
  public init(documentID: UUID, epoch: UInt64, baselineRevision: UInt64, sequence: UInt64) {
    self.documentID = documentID
    self.epoch = epoch
    self.baselineRevision = baselineRevision
    self.sequence = sequence
  }
}
public enum FileConflictAction: Sendable, CaseIterable, Equatable {
  case reload, openDiskCopy, keepBuffer, saveAs, locate, checkAgain
}
public enum FileActionAdmission: Equatable, Sendable {
  case allowed, requiresDiscardConfirmation, refused
}

/// Pure presentation/action state. Never owns document bytes or save/dirty authority.
/// The caller supplies the live owner token at acceptance, not the callback's captured token.
public struct ObservedFileState: Sendable {
  public private(set) var observation: DiskObservation?
  public private(set) var token: FileObservationToken?
  private var dismissed = false
  public var noticeIsProminent: Bool {
    guard let observation, !dismissed else { return false }
    return observation.content != .matchesBaseline || observation.locationProblem != nil
      || observation.readOnlyHint || observation.metadata == nil
      || observation.movedCandidate != nil
  }
  public init() {}

  @discardableResult public mutating func accept(
    _ incoming: DiskObservation,
    token incomingToken: FileObservationToken, currentToken: FileObservationToken
  ) -> Bool {
    guard incomingToken == currentToken else { return false }
    let sameContext = token.map { Self.sameContext($0, incomingToken) } ?? false
    if sameContext, let token, incomingToken.sequence <= token.sequence { return false }
    // Metadata/facet equality only deduplicates notice presentation, never proves byte equality.
    let unchangedNotice = sameContext && observation.map { Self.sameNotice($0, incoming) } == true
    if !unchangedNotice { dismissed = false }
    observation = incoming
    token = incomingToken
    return true
  }
  public mutating func dismiss(token requested: FileObservationToken) {
    guard token == requested else { return }
    dismissed = true
  }
  public func admission(
    for action: FileConflictAction, dirty: Bool, pendingPublication: Bool,
    busy: Bool = false, composing: Bool = false, recording: Bool = false,
    quitting: Bool = false, closed: Bool = false
  ) -> FileActionAdmission {
    guard !closed, !quitting else { return .refused }
    if busy || composing {
      switch action {
      case .reload, .openDiskCopy, .saveAs, .locate: return .refused
      case .keepBuffer, .checkAgain: break
      }
    }
    if recording && action == .reload { return .refused }
    if action == .checkAgain || action == .saveAs { return .allowed }
    guard let observation else { return .refused }
    let readable =
      observation.metadata != nil && observation.locationProblem == nil
      && observation.content != .unavailable
    switch action {
    case .reload:
      guard readable else { return .refused }
      return dirty || pendingPublication ? .requiresDiscardConfirmation : .allowed
    case .openDiskCopy:
      return readable ? .allowed : .refused
    case .keepBuffer:
      return .allowed
    case .locate:
      guard !pendingPublication else { return .refused }
      if readable { return .allowed }
      switch observation.locationProblem {
      case .missing?, .symbolicLink?, .nonregular?, .parentChanged?: return .allowed
      default: return .refused
      }
    case .saveAs, .checkAgain:
      return .allowed
    }
  }
  private static func sameContext(_ left: FileObservationToken, _ right: FileObservationToken)
    -> Bool
  {
    left.documentID == right.documentID && left.epoch == right.epoch
      && left.baselineRevision == right.baselineRevision
  }
  private static func sameNotice(_ left: DiskObservation, _ right: DiskObservation) -> Bool {
    left.metadata == right.metadata && left.content == right.content
      && left.locationProblem == right.locationProblem && left.readOnlyHint == right.readOnlyHint
      && left.movedCandidate == right.movedCandidate
  }
}
