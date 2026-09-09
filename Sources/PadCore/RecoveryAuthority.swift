import Foundation

public struct RecoveryWriteAuthority: Equatable, Sendable {
  public let coordinatorID: UUID
  public let documentID: UUID
  public let epoch: UUID
  public init(coordinatorID: UUID, documentID: UUID, epoch: UUID) {
    self.coordinatorID = coordinatorID
    self.documentID = documentID
    self.epoch = epoch
  }
}
public struct RecoveryAdoptionReceipt: Sendable {
  public let authority: RecoveryWriteAuthority
  public let nextRevision: UInt64
  public init(authority: RecoveryWriteAuthority, nextRevision: UInt64) {
    self.authority = authority
    self.nextRevision = nextRevision
  }
}
public struct AuthorizedRecoveryItem: Sendable {
  public let authority: RecoveryWriteAuthority
  public let revision: UInt64
  public let snapshot: RecoverySnapshot?
  public init(authority: RecoveryWriteAuthority, revision: UInt64, snapshot: RecoverySnapshot?) {
    self.authority = authority
    self.revision = revision
    self.snapshot = snapshot
  }
}
public struct RecoveryCloseLease: Equatable, Sendable {
  public let authority: RecoveryWriteAuthority
  public let transactionID: UUID
  public let registryTicketID: UUID
  public init(authority: RecoveryWriteAuthority, transactionID: UUID, registryTicketID: UUID) {
    self.authority = authority
    self.transactionID = transactionID
    self.registryTicketID = registryTicketID
  }
}
public struct RecoveryCloseReceipt: Equatable, Sendable {
  public let lease: RecoveryCloseLease
  public let deletionID: UUID
  public init(lease: RecoveryCloseLease, deletionID: UUID) {
    self.lease = lease
    self.deletionID = deletionID
  }
}
public struct RecoveryRepairReceipt: Sendable {
  public let lease: RecoveryCloseLease
  public let attemptID: UUID
  public let mutationGeneration: UUID
  public let publicationID: UUID
  public let authority: RecoveryWriteAuthority
  public let nextRevision: UInt64
  public init(
    lease: RecoveryCloseLease, attemptID: UUID, mutationGeneration: UUID,
    publicationID: UUID, authority: RecoveryWriteAuthority, nextRevision: UInt64
  ) {
    self.lease = lease
    self.attemptID = attemptID
    self.mutationGeneration = mutationGeneration
    self.publicationID = publicationID
    self.authority = authority
    self.nextRevision = nextRevision
  }
}
public enum RecoveryAuthorityError: Error, Equatable {
  case authorityRequired, invalidAuthority, alreadyManaged, closed, staleRevision, invalidLease,
    uncertainty
}
