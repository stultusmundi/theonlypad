import Foundation
import PadCore

@MainActor struct NativeIntakeDestinations {
  let requireAdmission: () throws -> Void
  let validate: (UUID, DocumentAssignment) throws -> Void
  let exists: (UUID) -> Bool
  let resolveSelection: (UUID, DocumentAssignment, EditorIntakeSelection) throws -> Bool
  let drainLegacyWrites: () async throws -> Void
  let project: (UUID, DocumentAssignment) throws -> Void
}

/// Concrete native factory/ownership adapter; the process intake remains the transaction owner.
@MainActor final class NativeDocumentIntakeController {
  private final class Slot {
    let submission: EditorPreparedSubmission
    var endpointID: UUID
    var reconciled = false
    var id: DocumentIntakeID?
    var model: EditorDocument?
    var task: Task<DocumentIntakeResult, Never>?
    init(_ submission: EditorPreparedSubmission) {
      self.submission = submission
      endpointID = submission.endpointID
    }
  }
  private let registry: ApplicationDocuments
  private let session: SessionCoordinator
  private let recovery: RecoveryCoordinator
  private let publication: DocumentIntakePublication
  private let destinations: NativeIntakeDestinations
  private var slot: Slot?
  private var terminal: (DocumentIntakeID, DocumentIntakeResult)?
  var status: DocumentIntakeStatus? { intake.status }
  private lazy var intake = ApplicationDocumentIntake(
    registry: registry, session: session, recovery: recovery, publication: publication,
    native: .init(
      requireApplicationAdmission: { try self.destinations.requireAdmission() },
      validateDestination: { request in try self.validate(self.matching(request)) },
      preflightResources: { request in try self.preflightResources(self.matching(request)) },
      drainLegacyWrites: { try await self.destinations.drainLegacyWrites() },
      readState: { try Self.state($0) },
      install: { handle, receipt, generation in
        guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
        try model.installRecoveryAdoption(receipt, expectedOwnershipGeneration: generation)
      },
      project: { assignment in
        guard let slot = self.slot, slot.submission.assignment == assignment else {
          throw DocumentIntakeError.staleDestination
        }
        try self.validate(slot)
        try self.destinations.project(slot.endpointID, assignment)
        try self.validate(slot)
      }))

  init(
    registry: ApplicationDocuments, session: SessionCoordinator, recovery: RecoveryCoordinator,
    publication: DocumentIntakePublication, destinations: NativeIntakeDestinations
  ) {
    self.registry = registry
    self.session = session
    self.recovery = recovery
    self.publication = publication
    self.destinations = destinations
  }
  private static func state(_ handle: any WorkspaceDocumentHandle) throws -> DocumentAdoptionState {
    guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
    return .init(
      documentID: model.id, ownershipGeneration: model.ownershipGeneration,
      authority: model.recoveryAuthority, highestIssuedRevision: model.highestIssuedRecoveryRevision
    )
  }
  private func matching(_ request: DocumentIntakeRequest) throws -> Slot {
    guard let slot, slot.submission.seed.id == request.documentID,
      slot.submission.assignment == request.assignment
    else { throw DocumentIntakeError.staleDestination }
    return slot
  }
  private func validate(_ value: Slot) throws {
    guard slot === value else { throw DocumentIntakeError.staleDestination }
    let endpoint = value.endpointID
    if !value.reconciled { try value.submission.requireDestinationCurrent() }
    try destinations.validate(endpoint, value.submission.assignment)
    guard slot === value, value.endpointID == endpoint else {
      throw DocumentIntakeError.staleDestination
    }
  }
  private func preflightResources(_ value: Slot) throws {
    var budget = SessionStartupBudget()
    for window in try registry.captureWindows() {
      for id in window.groups.flatMap(\.documentIDs) {
        guard let model = registry.handle(id: id) as? EditorDocument else {
          throw DocumentIntakeError.staleModel
        }
        try budget.admit(
          utf16Count: model.storage.length, originalByteCount: model.originalBytes?.count ?? 0)
      }
    }
    try budget.admit(
      utf16Count: value.submission.seed.textUTF16Count,
      originalByteCount: value.submission.seed.originalByteCount)
  }
  func submit(_ submission: EditorPreparedSubmission) throws -> DocumentIntakeID {
    guard slot == nil else { throw DocumentIntakeError.busy }
    let value = Slot(submission)
    slot = value  // Reserve before every callback, including identity validation.
    do {
      try destinations.requireAdmission()
      try validate(value)
      try preflightResources(value)
      guard
        let group = registry.window(id: submission.assignment.windowID)?.groups.first(where: {
          $0.id == submission.assignment.groupID
        })
      else {
        throw DocumentIntakeError.staleDestination
      }
      var request = DocumentIntakeRequest(
        documentID: submission.seed.id, assignment: submission.assignment,
        metadata: .init(pinned: submission.seed.pinned),
        index: submission.insertionIndex ?? group.documentIDs.count,
        select: false, utf16Count: submission.seed.textUTF16Count,
        originalByteCount: submission.seed.originalByteCount, provenance: submission.provenance,
        makeHandle: {
          guard self.slot === value, value.model == nil else {
            throw DocumentIntakeError.staleModel
          }
          let model = try EditorDocumentFactory.make(submission.seed)
          model.onCharactersChanged = self.publication.requestCheckpoint
          value.model = model
          return model
        })
      request.resolveSelection = {
        try self.validate(value)
        return try self.destinations.resolveSelection(
          value.endpointID, submission.assignment, submission.selection)
      }
      let id = try intake.start(request)
      value.id = id
      launchWait(value, id: id)
      return id
    } catch {
      if slot === value { slot = nil }
      throw error
    }
  }
  private func launchWait(_ value: Slot, id: DocumentIntakeID) {
    value.task = Task {
      let outcome: DocumentIntakeResult
      do { outcome = try await self.intake.wait(for: id) } catch {
        outcome = .retained(value.submission.seed.id, error)
      }
      switch outcome {
      case .retained: break
      case .imported, .refused:
        if self.slot === value {
          self.terminal = (id, outcome)
          self.slot = nil
        }
      }
      return outcome
    }
  }
  func wait(for id: DocumentIntakeID) async throws -> DocumentIntakeResult {
    if let slot, slot.id == id, let task = slot.task { return await task.value }
    if let terminal, terminal.0 == id { return terminal.1 }
    throw DocumentIntakeError.expired
  }
  func retry(_ id: DocumentIntakeID) throws {
    guard let slot, slot.id == id else { throw DocumentIntakeError.expired }
    try intake.retry(id)
    launchWait(slot, id: id)
  }
  func reconcileDestination(_ id: DocumentIntakeID, endpointID: UUID) throws {
    guard let value = slot, value.id == id, intake.status?.id == id,
      intake.status?.stage == .failed, let model = value.model,
      registry.handle(id: model.id) === model,
      registry.assignment(of: model.id) == value.submission.assignment
    else { throw DocumentIntakeError.staleDestination }
    let previous = value.endpointID
    let state = try Self.state(model)
    let adoption = registry.adoptionStatus(documentID: model.id)
    let revision = registry.workspaceRevision
    guard !destinations.exists(previous) else { throw DocumentIntakeError.staleDestination }
    try destinations.validate(endpointID, value.submission.assignment)
    let oldEndpointAbsent = !destinations.exists(previous)
    let finalState = try Self.state(model)
    guard oldEndpointAbsent, finalState == state, registry.workspaceRevision == revision,
      registry.adoptionStatus(documentID: model.id) == adoption, slot === value,
      value.endpointID == previous, intake.status?.stage == .failed,
      registry.handle(id: model.id) === model,
      registry.assignment(of: model.id) == value.submission.assignment
    else { throw DocumentIntakeError.staleDestination }
    value.endpointID = endpointID
    value.reconciled = true
  }
  func requireSettled() throws {
    guard slot == nil else { throw DocumentIntakeError.unsettled }
    try intake.requireSettled()
  }
}
