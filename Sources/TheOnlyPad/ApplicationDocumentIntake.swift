import Foundation
import PadCore

/// Owns one decoded payload and its model through adoption, reconciliation and projection.
@MainActor final class ApplicationDocumentIntake {
  private final class Operation {
    let id = DocumentIntakeID(rawValue: UUID())
    let request: DocumentIntakeRequest
    var stage = DocumentIntakeStage.validating
    var error: Error?
    var task: Task<DocumentIntakeResult, Never>?
    var pause: CheckpointPauseToken?
    var drained = false
    var legacyAttempted = false
    var legacyDrained = false
    var cancelled = false
    var model: (any WorkspaceDocumentHandle)?
    var lease: DocumentAdoptionLease?
    var receipt: RecoveryAdoptionReceipt?
    var activated = false
    var resolved = false
    var projected = false
    var abortError: Error?
    init(_ request: DocumentIntakeRequest) { self.request = request }
  }
  private let registry: ApplicationDocuments
  private let session: SessionCoordinator
  private let recovery: RecoveryCoordinator
  private let publication: DocumentIntakePublication
  private let native: DocumentIntakeNative
  private var operation: Operation?
  private var terminal: (DocumentIntakeID, DocumentIntakeResult)?
  var onChange: (() -> Void)?
  var status: DocumentIntakeStatus? {
    operation.map {
      .init(id: $0.id, documentID: $0.request.documentID, stage: $0.stage, error: $0.error)
    }
  }
  var hasUnsettledTransactions: Bool { operation != nil }
  init(
    registry: ApplicationDocuments, session: SessionCoordinator, recovery: RecoveryCoordinator,
    publication: DocumentIntakePublication, native: DocumentIntakeNative
  ) {
    self.registry = registry
    self.session = session
    self.recovery = recovery
    self.publication = publication
    self.native = native
  }
  func start(_ request: DocumentIntakeRequest) throws -> DocumentIntakeID {
    guard operation == nil else { throw DocumentIntakeError.busy }
    guard (0...100_000_000).contains(request.utf16Count),
      (0...100_000_000).contains(request.originalByteCount), request.index >= 0
    else { throw DocumentIntakeError.invalidRequest }
    let value = Operation(request)
    operation = value  // Before every injected validation or notification callback.
    value.task = Task { await self.run(value) }
    onChange?()
    return value.id
  }
  func wait(for id: DocumentIntakeID) async throws -> DocumentIntakeResult {
    if let value = operation, value.id == id, let task = value.task { return await task.value }
    if let terminal, terminal.0 == id { return terminal.1 }
    throw DocumentIntakeError.expired
  }
  func retry(_ id: DocumentIntakeID) throws {
    guard let value = operation, value.id == id else { throw DocumentIntakeError.expired }
    guard value.stage == .failed else { throw DocumentIntakeError.busy }
    value.stage = .validating
    value.error = nil
    value.task = Task { await self.run(value) }
    onChange?()
  }
  func cancelBeforeRegistration(_ id: DocumentIntakeID) throws {
    guard let value = operation, value.id == id else { throw DocumentIntakeError.expired }
    guard value.stage == .draining, value.lease == nil else {
      throw DocumentIntakeError.cancellationUnavailable
    }
    value.cancelled = true
  }
  func requireSettled() throws {
    guard operation == nil else { throw DocumentIntakeError.unsettled }
  }
  private func preflight(_ value: Operation) throws -> UUID {
    let request = value.request
    let revision = registry.workspaceRevision
    let sessionRevision = session.capacityRevision
    try native.requireApplicationAdmission()
    try native.validateDestination(request)
    try native.preflightResources(request)
    guard registry.workspaceRevision == revision, session.capacityRevision == sessionRevision else {
      throw DocumentIntakeError.staleDestination
    }
    let windows = try registry.captureWindows()
    guard let window = windows.first(where: { $0.id == request.assignment.windowID }),
      let group = window.groups.first(where: { $0.id == request.assignment.groupID }),
      request.index <= group.documentIDs.count,
      !registry.containsReservedID(request.documentID)
    else { throw DocumentIntakeError.invalidRequest }
    let live = Dictionary(
      uniqueKeysWithValues: windows.map {
        ($0.id, Set($0.groups.flatMap(\.documentIDs)))
      })
    if case .history(let claim) = request.provenance {
      guard claim.replacementID == request.documentID,
        claim.windowID == request.assignment.windowID
      else { throw DocumentIntakeError.invalidRequest }
      try registry.validateHistory(claim)
    }
    switch request.provenance {
    case .fresh, .history:
      let capacity = try session.transferCapacity(liveWindows: live)
      guard !capacity.documentIDs.contains(request.documentID),
        !capacity.windowIDs.contains(request.documentID),
        capacity.windowIDs.count <= 32, capacity.documentIDs.count < 128
      else { throw SessionStoreError.limit }
    case .session(let claim):
      guard claim.documentID == request.documentID, claim.windowID == request.assignment.windowID
      else {
        throw DocumentIntakeError.invalidRequest
      }
      _ = try session.preflightImport(claim, liveWindows: live)
    case .recovery(let claim):
      guard claim.documentID == request.documentID, claim.windowID == request.assignment.windowID
      else {
        throw DocumentIntakeError.invalidRequest
      }
      _ = try session.preflightImport(claim, liveWindows: live)
    }
    return revision
  }
  private func requireOwned(_ value: Operation) throws -> any WorkspaceDocumentHandle {
    guard let model = value.model, let lease = value.lease,
      registry.handle(id: value.request.documentID) === model,
      registry.assignment(of: value.request.documentID) == value.request.assignment,
      model.id == value.request.documentID, model.workspaceKind == .editable,
      model.ownershipGeneration == lease.ownershipGeneration
    else { throw DocumentIntakeError.staleModel }
    return model
  }
  private func run(_ value: Operation) async -> DocumentIntakeResult {
    do {
      if let abort = value.abortError {
        if value.legacyAttempted && !value.legacyDrained {
          value.stage = .draining
          try await native.drainLegacyWrites()
          value.legacyDrained = true
        }
        return await finishUnregistered(value, error: abort)
      }
      if value.lease == nil {
        _ = try preflight(value)
        value.stage = .acquiring
        value.pause = try publication.acquirePause()
        value.stage = .draining
        try await publication.drainPause(value.pause!)
        value.drained = true
        if value.cancelled { throw CancellationError() }
        value.legacyAttempted = true
        try await native.drainLegacyWrites()
        value.legacyDrained = true
        if value.cancelled { throw CancellationError() }
        let revision = try preflight(value)
        let sessionRevision = session.capacityRevision
        value.stage = .creating
        let model = try value.request.makeHandle()
        value.model = model
        let state = try native.readState(model)
        guard model.id == value.request.documentID, model.workspaceKind == .editable,
          state.documentID == model.id, state.ownershipGeneration == model.ownershipGeneration,
          state.authority == nil, state.highestIssuedRevision == 0,
          registry.workspaceRevision == revision, session.capacityRevision == sessionRevision
        else { throw DocumentIntakeError.staleModel }
        let validatedRevision = try preflight(value)
        guard validatedRevision == revision else { throw DocumentIntakeError.staleDestination }
        value.stage = .registering  // Registry owns the handle during its onChange, before return.
        value.lease = try registry.registerPending(
          model, requestID: value.id.rawValue, expectedRevision: validatedRevision,
          metadata: value.request.metadata, in: value.request.assignment,
          at: value.request.index, select: value.request.select)
      }
      let model = try requireOwned(value)
      if !value.activated {
        value.stage = .adopting
        if case .failed(let failed) = registry.adoptionStatus(documentID: model.id) {
          guard value.lease == failed else { throw DocumentIntakeError.staleModel }
          value.lease = try registry.retryAdoption(failed)
        }
        if value.receipt == nil {
          value.receipt = try await recovery.adoptManagedDocument(id: model.id)
        }
        let receipt = value.receipt!
        _ = try requireOwned(value)
        value.stage = .installing
        try native.validateDestination(value.request)
        let state = try native.readState(model)
        if state.authority != receipt.authority
          || state.highestIssuedRevision != receipt.nextRevision - 1
        {
          try native.install(model, receipt, value.lease!.ownershipGeneration)
        }
        _ = try requireOwned(value)
        value.stage = .activating
        try registry.activateAdoption(value.lease!, receipt: receipt)
        value.activated = true
      }
      _ = try requireOwned(value)
      guard registry.adoptionStatus(documentID: model.id) == .active else {
        throw DocumentIntakeError.staleModel
      }
      if !value.resolved {
        value.stage = .resolving
        switch value.request.provenance {
        case .fresh: break
        case .history(let claim):
          try registry.consumeHistory(claim, replacementID: model.id)
        case .session(let original):
          try session.resolveImport(session.renewImportClaim(original))
        case .recovery(let original):
          try session.resolveRecoveryImport(session.renewImportClaim(original))
        }
        value.resolved = true
      }
      _ = try requireOwned(value)
      guard registry.adoptionStatus(documentID: model.id) == .active else {
        throw DocumentIntakeError.staleModel
      }
      if !value.projected {
        value.stage = .projecting
        try native.project(value.request.assignment)
        _ = try requireOwned(value)
        value.projected = true
      }
      value.stage = .releasing
      if let pause = value.pause {
        try publication.releasePause(pause)
        value.pause = nil
      }
      let result = DocumentIntakeResult.imported(model.id)
      finish(value, result: result)
      publication.requestCheckpoint()
      return result
    } catch {
      if value.lease == nil {
        value.abortError = error
        return await finishUnregistered(value, error: error)
      }
      // No rollback of registered ownership or actor authority. Retain exact progress for Retry.
      if !value.activated, let lease = value.lease,
        registry.adoptionStatus(documentID: lease.documentID) == .pending(lease)
      {
        do { try registry.failAdoption(lease) } catch {
          return retain(value, error: error)
        }
      }
      return retain(value, error: error)
    }
  }
  private func finishUnregistered(_ value: Operation, error: Error) async -> DocumentIntakeResult {
    guard value.lease == nil else { return retain(value, error: error) }
    if value.legacyAttempted && !value.legacyDrained { return retain(value, error: error) }
    do {
      if let pause = value.pause {
        value.stage = .draining
        if !value.drained {
          try await publication.drainPause(pause)
          value.drained = true
        }
        value.stage = .releasing
        try publication.releasePause(pause)
        value.pause = nil
      }
      let result = DocumentIntakeResult.refused(error)
      finish(value, result: result)
      return result
    } catch { return retain(value, error: error) }
  }
  private func retain(_ value: Operation, error: Error) -> DocumentIntakeResult {
    value.error = error
    value.stage = .failed
    onChange?()
    return .retained(value.request.documentID, error)
  }
  private func finish(_ value: Operation, result: DocumentIntakeResult) {
    value.stage = .settled
    terminal = (value.id, result)
    operation = nil
    onChange?()
  }
}
