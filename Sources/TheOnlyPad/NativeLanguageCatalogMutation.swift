// SPDX-License-Identifier: MIT
// Immutable values and service closures; all Store authority stays in the owner.
import Foundation
import PadCore

struct NativeLanguageCatalogDraft: Sendable {
  let definitions: [LiteralLanguageDefinition]
  let overrides: [BuiltInLanguageOverride]
  init(definitions: [LiteralLanguageDefinition], overrides: [BuiltInLanguageOverride]) throws {
    _ = try LanguageCatalogSnapshot(definitions: definitions, overrides: overrides, generation: 0)
    self.definitions = definitions
    self.overrides = overrides
  }
}
struct NativeLanguageCatalogServices: Sendable {
  let read: @Sendable () throws -> LoadedLanguageCatalog
  let inspect: @Sendable () throws -> LanguageCatalogInspection
  let save:
    @Sendable (LanguageCatalogSnapshot, LoadedLanguageCatalog) throws -> LoadedLanguageCatalog
  let repair:
    @Sendable (
      [LiteralLanguageDefinition], [BuiltInLanguageOverride], CustomLanguageRepairInspection
    ) throws -> LoadedLanguageCatalog
  let validatePending: @Sendable (CustomLanguagePublicationUncertain) throws -> Void
  let retryPending: @Sendable (CustomLanguagePublicationUncertain) throws -> LoadedLanguageCatalog
  init(
    read: @escaping @Sendable () throws -> LoadedLanguageCatalog,
    inspect: @escaping @Sendable () throws -> LanguageCatalogInspection,
    save:
      @escaping @Sendable (LanguageCatalogSnapshot, LoadedLanguageCatalog) throws ->
      LoadedLanguageCatalog,
    repair:
      @escaping @Sendable (
        [LiteralLanguageDefinition], [BuiltInLanguageOverride], CustomLanguageRepairInspection
      ) throws -> LoadedLanguageCatalog,
    validatePending: @escaping @Sendable (CustomLanguagePublicationUncertain) throws -> Void,
    retryPending:
      @escaping @Sendable (CustomLanguagePublicationUncertain) throws -> LoadedLanguageCatalog
  ) {
    self.read = read
    self.inspect = inspect
    self.save = save
    self.repair = repair
    self.validatePending = validatePending
    self.retryPending = retryPending
  }
}
enum CatalogPublicationExpectation {
  case none
  case current(UUID)
}
enum CatalogUnresolvedID {
  case attempt(UUID)
  case pending(UUID)
}
enum CatalogRecoveryDecision { case discardAttemptAndReload }
enum CatalogAttemptKind { case apply, repair }
enum CatalogPendingKind { case publicationUncertain, readbackUnconfirmed }
enum CatalogOperationKind: Sendable {
  case load, apply, inspect, repair, verify, retry, retryFailedAttempt, discardAndReload
}
enum CatalogOperationPhase { case admitting, running, settling, settlingAfterInvalidation }
enum CatalogOperationOutcome {
  case succeeded(operationID: UUID, publicationID: UUID?)
  case failed(operationID: UUID, summary: CatalogFailureSummary)
}
enum CatalogLateOutcomeKind {
  case succeededReceiptRetainedWithoutPublication, failed, notLaunched, inspectionCompleted
  case publicationUncertain, readbackUnconfirmed
  case validationCompletedWithoutAcknowledgement, validationFailedWithoutAcknowledgement
  case discardReloadCompletedWithoutResolution
}
enum CatalogFailureSummary {
  case validation, storeRead, storeWrite, externalChange, publicationUncertain
  case readbackUnconfirmed, corruptCatalog, unsupportedCatalog
}
enum CatalogInspectionSnapshot {
  case notInspected
  case loaded(publicationID: UUID)
  case corrupt(inspectionID: UUID, summary: CatalogFailureSummary)
  case unsupported(summary: CatalogFailureSummary)
  case failed(summary: CatalogFailureSummary)
}
enum CatalogUnresolvedSnapshot {
  case failedAttempt(attemptID: UUID, kind: CatalogAttemptKind, summary: CatalogFailureSummary)
  case pending(
    attemptID: UUID, recoveryID: UUID, kind: CatalogPendingKind, summary: CatalogFailureSummary)
}
struct CatalogOperationSnapshot {
  let id: UUID
  let kind: CatalogOperationKind
  let phase: CatalogOperationPhase
}
struct CatalogDisplaySnapshot {
  let publicationID: UUID
  let catalog: LanguageCatalogSnapshot
}
struct CatalogInvalidationCustodySnapshot {
  let operationID: UUID
  let attemptID: UUID?
  let outcome: CatalogLateOutcomeKind
}
struct NativeLanguageCatalogMutationState {
  let activeOperation: CatalogOperationSnapshot?
  let lastOutcome: CatalogOperationOutcome?
  let lastGoodDisplay: CatalogDisplaySnapshot?
  let writeReceiptPublicationID: UUID?
  let inspection: CatalogInspectionSnapshot
  let unresolved: CatalogUnresolvedSnapshot?
  let preparedQuitID: UUID?
  let invalidationCustody: CatalogInvalidationCustodySnapshot?
  let canApply: Bool
  let canInspect: Bool
  let canRepair: Bool
  let canVerifyPending: Bool
  let canRetryPending: Bool
  let canRetryFailedAttempt: Bool
  let canDiscardAndReload: Bool
  let canPrepareQuit: Bool
}
enum NativeLanguageCatalogMutationRefusal {
  case busy(activeOperationID: UUID)
  case invalidated, invalidatedDuringAdmission
  case quitPrepared(quitID: UUID)
  case reservationWithdrawn, wrongPublication, noWriteReceipt, wrongInspection, unsupported
  case wrongAttempt, wrongRecovery
  case unresolvedAttempt(attemptID: UUID)
  case unresolvedPending(recoveryID: UUID)
  case notRetryable, notRetryableFailedAttempt, invalidDraft, confirmationRequired,
    noUnresolvedAttempt, servicesUnavailable
}
enum NativeLanguageCatalogMutationAdmission {
  case started(operationID: UUID)
  case refused(NativeLanguageCatalogMutationRefusal)
}
enum CatalogQuitAdmission {
  case prepared(UUID)
  case refused(NativeLanguageCatalogMutationRefusal)
}
