import AppKit
import PadCore

/// Native adapters only; ApplicationDocumentClosing owns every close/repair transaction.
@MainActor final class NativeApplicationCloseCoordinator {
  typealias Endpoint = (endpointID: UUID, controller: EditorWindowController)
  private let registry: ApplicationDocuments
  private let recovery: RecoveryCoordinator
  private let publication: DocumentClosingPublication
  private let endpoint: (UUID) -> Endpoint?
  private let reportError: (Error) -> Void
  private let decide: ((NSAlert) async -> NSApplication.ModalResponse)?
  init(
    registry: ApplicationDocuments, recovery: RecoveryCoordinator,
    publication: DocumentClosingPublication, endpoint: @escaping (UUID) -> Endpoint?,
    reportError: @escaping (Error) -> Void,
    decide: ((NSAlert) async -> NSApplication.ModalResponse)? = nil
  ) {
    self.registry = registry
    self.recovery = recovery
    self.publication = publication
    self.endpoint = endpoint
    self.reportError = reportError
    self.decide = decide
  }
  private lazy var owner: ApplicationDocumentClosing = {
    let owner = ApplicationDocumentClosing(
      registry: registry, recovery: recovery, publication: publication,
      native: .init(
        confirm: { [weak self] request, windowID in
          guard let self, request.assignment.windowID == windowID else {
            throw DocumentClosingError.ownershipChanged
          }
          let endpoint = try self.requireEndpoint(request.assignment)
          let result = try await endpoint.controller.confirmManagedClose(
            request, endpointID: endpoint.endpointID, decide: self.decide)
          try self.requireSameEndpoint(endpoint, assignment: request.assignment)
          return result
        },
        applyAdmission: { [weak self] handle in
          guard let self else { throw DocumentClosingError.ownershipChanged }
          let (model, assignment) = try self.owned(handle)
          let endpoint = try self.requireEndpoint(assignment)
          try endpoint.controller.applyManagedAdmission(to: model, endpointID: endpoint.endpointID)
          try self.requireSameEndpoint(endpoint, assignment: assignment)
        },
        drainLegacyWrites: { [weak self] handle in
          guard let self else { throw DocumentClosingError.ownershipChanged }
          let (_, assignment) = try self.owned(handle)
          let endpoint = try self.requireEndpoint(assignment)
          try await endpoint.controller.drainLegacyRecoveryWrites(endpointID: endpoint.endpointID)
          try self.requireSameEndpoint(endpoint, assignment: assignment)
          _ = try self.owned(handle)
        },
        readState: { handle in
          guard let model = handle as? EditorDocument else {
            throw DocumentClosingError.unsupportedKind
          }
          return try model.captureCloseState()
        },
        capture: { [weak self] handle in
          guard let self else { throw DocumentClosingError.ownershipChanged }
          let (model, _) = try self.owned(handle)
          let value = try model.captureCloseRecovery()
          return .init(
            state: value.state, snapshot: value.snapshot, authority: value.authority,
            highestIssuedRevision: value.highestIssuedRevision)
        },
        installRepair: { [weak self] handle, attempt, receipt, context in
          guard let self else { throw DocumentClosingError.ownershipChanged }
          let (model, assignment) = try self.owned(handle)
          guard assignment == attempt.assignment, model.id == attempt.documentID,
            self.registry.closeStatus(documentID: model.id)
              == .repairing(repairID: attempt.repairID, attemptID: attempt.id),
            receipt.attemptID == attempt.id,
            receipt.mutationGeneration == attempt.state.mutationGeneration,
            context.state == attempt.state
          else { throw DocumentClosingError.staleState }
          try model.installCloseRepair(
            receipt,
            expected: .init(
              state: context.state,
              modelAuthority: context.modelAuthority,
              highestIssuedRevision: context.highestIssuedRevision))
        },
        projectRegistry: { [weak self] in
          guard let self else { throw DocumentClosingError.ownershipChanged }
          try self.projectRegistry()
        }))
    owner.onChange = { [weak self, weak owner] in
      guard let self, let status = owner?.status, status.stage == .failed, let error = status.error
      else { return }
      self.reportError(error)
    }
    return owner
  }()
  private func owned(_ handle: any WorkspaceDocumentHandle) throws -> (
    EditorDocument, DocumentAssignment
  ) {
    guard let model = handle as? EditorDocument, registry.handle(id: model.id) === model,
      let assignment = registry.assignment(of: model.id)
    else { throw DocumentClosingError.ownershipChanged }
    return (model, assignment)
  }
  private func requireEndpoint(_ assignment: DocumentAssignment) throws -> Endpoint {
    guard let value = endpoint(assignment.windowID) else {
      throw DocumentClosingError.ownershipChanged
    }
    try value.controller.requireEndpointIdentity(
      endpointID: value.endpointID, assignment: assignment)
    guard let current = endpoint(assignment.windowID), current.endpointID == value.endpointID,
      current.controller === value.controller
    else { throw DocumentClosingError.ownershipChanged }
    return value
  }
  private func requireSameEndpoint(_ value: Endpoint, assignment: DocumentAssignment) throws {
    let current = try requireEndpoint(assignment)
    guard current.endpointID == value.endpointID, current.controller === value.controller else {
      throw DocumentClosingError.ownershipChanged
    }
  }
  private func projectRegistry() throws {
    let revision = registry.workspaceRevision
    let windows = try registry.captureWindows()
    for window in windows {
      guard window.groups.count == 1, let group = window.groups.first else {
        throw DocumentClosingError.unsupportedKind
      }
      let assignment = DocumentAssignment(windowID: window.id, groupID: group.id)
      let current = try requireEndpoint(assignment)
      try current.controller.applyRegistryProjection(
        window, revision: revision, endpointID: current.endpointID)
      try requireSameEndpoint(current, assignment: assignment)
      guard registry.workspaceRevision == revision else { throw DocumentClosingError.staleState }
    }
    guard try registry.captureWindows() == windows else { throw DocumentClosingError.staleState }
  }
  var status: DocumentClosingStatus? { owner.status }
  var hasUnsettledTransactions: Bool { owner.hasUnsettledTransactions }
  func start(documentIDs: [UUID], sourceWindowID: UUID) throws -> DocumentClosingID {
    guard let window = registry.window(id: sourceWindowID),
      documentIDs.allSatisfy({ registry.assignment(of: $0)?.windowID == sourceWindowID }),
      window.groups.count == 1, let group = window.groups.first
    else { throw DocumentClosingError.invalidRequest }
    _ = try requireEndpoint(.init(windowID: sourceWindowID, groupID: group.id))
    return try owner.start(documentIDs: documentIDs, sourceWindowID: sourceWindowID)
  }
  func wait(for id: DocumentClosingID) async throws -> DocumentClosingResult {
    try await owner.wait(for: id)
  }
  func retry(_ id: DocumentClosingID) throws { try owner.retry(id) }
  func requireSettled() throws { try owner.requireSettledForFinalCheckpoint() }
  func endpointClosed(windowID: UUID) { owner.endpointDidClose(windowID: windowID) }
}
