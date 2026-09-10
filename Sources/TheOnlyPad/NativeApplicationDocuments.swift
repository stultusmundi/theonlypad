import AppKit
import PadCore

enum NativeWorkspaceError: Error { case notReady, staleEndpoint, retainedImport, quitVetoed }

/// Process owner. The registry owns models; endpoint records own their current native presentation.
@MainActor final class NativeApplicationDocuments {
  private final class Endpoint {
    let id = UUID()
    let assignment: DocumentAssignment
    var controller: EditorWindowController?
    var announced = false
    init(_ assignment: DocumentAssignment) { self.assignment = assignment }
  }
  let registry: ApplicationDocuments
  private let session: SessionCoordinator
  private let recovery: RecoveryCoordinator
  private let monitoring: ApplicationFileMonitoring
  private let bindings: NativeDocumentEndpointBindings
  private let onWindowCreated: (EditorWindowController) -> Void
  private let configureWindow: (EditorWindowController) -> Void
  private let onError: (Error) -> Void
  private let openLargeFile: (LaunchRequest) async throws -> Void
  private var endpoints: [UUID: Endpoint] = [:]
  private var activation: ManagedPublisherActivation?
  private var startupTask: Task<Void, Error>?
  private var pending: [(UUID, NativeDocumentSeed)] = []
  private var retainedStartup: DocumentIntakeID?
  private var startupInFlight = false
  private var startupScratch: UUID?
  private var admissionRefreshPending = false
  private var ready = false
  private var quitting = false
  private var preparingHistory = false
  /// Internal preparation only. The existing transfer state machine owns the later handoff.
  private final class NewWindowPreparation {
    let id = NativeNewWindowMoveID()
    let choices: NativeDocumentMoveChoices
    let assignment: DocumentAssignment
    let capacity: SessionCapacitySnapshot
    let sourceRevision: UUID
    var registeredRevision: UUID?
    var endpoint: Endpoint?
    var unregistered = false
    var pause: CheckpointPauseToken?
    var pauseDrained = false
    var cancellationRequested = false
    var failure: Error?
    var task: Task<NativeNewWindowPreparationResult, Never>?
    var cleanupRunning = false
    var cleanupTask: Task<NativeNewWindowPreparationResult, Never>?
    init(_ choices: NativeDocumentMoveChoices, capacity: SessionCapacitySnapshot) {
      self.choices = choices
      self.capacity = capacity
      sourceRevision = choices.sourceWorkspaceRevision!
      var windowID = UUID()
      while capacity.windowIDs.contains(windowID) || capacity.documentIDs.contains(windowID) {
        windowID = UUID()
      }
      var groupID = UUID()
      while groupID == windowID || capacity.windowIDs.contains(groupID)
        || capacity.documentIDs.contains(groupID)
      { groupID = UUID() }
      assignment = .init(windowID: windowID, groupID: groupID)
    }
  }
  private var preparingNewWindow: NewWindowPreparation?
  private func requireNewWindowSettled() throws {
    guard preparingNewWindow == nil else { throw NativeNewWindowPreparationError.busy }
  }
  private func newWindowCapacity() throws -> SessionCapacitySnapshot {
    let windows = try registry.captureWindows()
    return try session.transferCapacity(
      liveWindows: Dictionary(
        uniqueKeysWithValues: windows.map {
          ($0.id, Set($0.groups.flatMap(\.documentIDs)))
        }))
  }
  /// A display hint only: start always repeats authoritative admission and captures fresh receipts.
  func newWindowMoveRefusalReason() -> String? {
    do {
      try requireUserAdmission()
      try transferring.requireSettled()
      try intake.requireSettled()
      try closing.requireSettled()
      guard !preparingHistory, externalOpens.pendingCount == 0 else {
        throw NativeWorkspaceError.notReady
      }
      guard try newWindowCapacity().windowIDs.count < 32 else { throw SessionStoreError.limit }
      return nil
    } catch { return error.localizedDescription }
  }
  private func validateNewWindowSource(_ value: NewWindowPreparation, revision: UUID) throws {
    guard preparingNewWindow === value, ready, !quitting, !preparingHistory,
      externalOpens.pendingCount == 0, registry.workspaceRevision == revision,
      let model = registry.handle(id: value.choices.documentID) as? EditorDocument,
      model.ownershipGeneration == value.choices.ownershipGeneration,
      registry.assignment(of: model.id)?.windowID == value.choices.sourceWindowID,
      registry.window(id: value.choices.sourceWindowID)?.groups.first?.selectedDocumentID
        == model.id,
      let source = endpoints[value.choices.sourceWindowID],
      source.id == value.choices.sourceEndpointID
    else { throw NativeNewWindowPreparationError.changed }
    try transferring.requireSettled()
    try intake.requireSettled()
    try closing.requireSettled()
    let controller = try validateTransferEndpoint(source)
    _ = try controller.captureTransferPreparation()
    guard registry.workspaceRevision == revision else {
      throw NativeNewWindowPreparationError.changed
    }
  }
  func startNewWindowPreparation(_ choices: NativeDocumentMoveChoices) throws
    -> NativeNewWindowMoveID
  {
    guard choices.sourceWorkspaceRevision != nil else {
      throw NativeNewWindowPreparationError.changed
    }
    try requireNewWindowSettled()
    // Scalar capacity capture invokes no collaborator. Install ownership before native admission.
    let capacity = try newWindowCapacity()
    let value = NewWindowPreparation(choices, capacity: capacity)
    preparingNewWindow = value
    do {
      try validateNewWindowSource(value, revision: value.sourceRevision)
      guard capacity.windowIDs.union([value.assignment.windowID]).count <= 32,
        !registry.containsReservedID(value.assignment.windowID),
        !registry.containsReservedID(value.assignment.groupID)
      else { throw SessionStoreError.limit }
      value.pause = try checkpoints.acquirePause()
      value.task = Task { await self.prepareNewWindow(value) }
      return value.id
    } catch {
      // Acquisition performs no callbacks after issuing its token. A issued token is always tracked.
      if value.pause == nil { preparingNewWindow = nil }
      throw error
    }
  }
  private func prepareNewWindow(_ value: NewWindowPreparation) async
    -> NativeNewWindowPreparationResult
  {
    do {
      guard let pause = value.pause else { throw NativeNewWindowPreparationError.expired }
      try await checkpoints.drainPause(pause)
      value.pauseDrained = true
      try validateNewWindowSource(value, revision: value.sourceRevision)
      guard try newWindowCapacity() == value.capacity, !value.cancellationRequested else {
        throw NativeNewWindowPreparationError.changed
      }
      try await drainLegacy()
      try validateNewWindowSource(value, revision: value.sourceRevision)
      guard try newWindowCapacity() == value.capacity, !value.cancellationRequested else {
        throw NativeNewWindowPreparationError.changed
      }
      try registry.registerWindow(
        id: value.assignment.windowID, initialGroupID: value.assignment.groupID,
        willNotify: { value.registeredRevision = $0 })
      let registered = value.registeredRevision!
      try validateNewWindowSource(value, revision: registered)
      try validateNewWindowCapacity(value)
      let endpoint = Endpoint(value.assignment)
      value.endpoint = endpoint
      _ = try constructEndpoint(endpoint, provisional: true)
      try validateNewWindowSource(value, revision: registered)
      try validateNewWindowCapacity(value)
      guard !value.cancellationRequested else { throw CancellationError() }
      return .prepared(
        .init(windowID: value.assignment.windowID, endpointID: endpoint.id, title: "New Window"))
    } catch {
      value.failure = error
      // Failed preparation remains explicitly owned until cancellation/recovery cleans its effects.
      return .retained(error)
    }
  }
  private func validateNewWindowCapacity(_ value: NewWindowPreparation) throws {
    let current = try newWindowCapacity()
    guard current.sessionRevision == value.capacity.sessionRevision,
      current.windowIDs == value.capacity.windowIDs.union([value.assignment.windowID]),
      current.documentIDs == value.capacity.documentIDs,
      registry.window(id: value.assignment.windowID)?.groups == [
        DocumentGroupSnapshot(
          id: value.assignment.groupID, documentIDs: [], selectedDocumentID: nil)
      ]
    else { throw NativeNewWindowPreparationError.changed }
  }
  func waitForNewWindowPreparation(_ id: NativeNewWindowMoveID) async throws
    -> NativeNewWindowPreparationResult
  {
    guard let value = preparingNewWindow, value.id == id, let task = value.task else {
      throw NativeNewWindowPreparationError.expired
    }
    // The owner's task deliberately outlives cancellation of any one waiter.
    let result = await task.value
    // Cancellation intent is not a receipt. A retained or unfinished cleanup still owns its pause.
    if let cleanup = value.cleanupTask { return await cleanup.value }
    guard preparingNewWindow === value else { throw NativeNewWindowPreparationError.expired }
    return result
  }
  func cancelNewWindowPreparation(_ id: NativeNewWindowMoveID) async throws {
    guard let value = preparingNewWindow, value.id == id, !value.cleanupRunning else {
      throw NativeNewWindowPreparationError.expired
    }
    value.cancellationRequested = true
    value.cleanupRunning = true
    let cleanup = Task { await self.cleanupNewWindowPreparation(value) }
    value.cleanupTask = cleanup
    switch await cleanup.value {
    case .cancelled: return
    case .retained(let error): throw error
    case .prepared: throw NativeNewWindowPreparationError.expired
    }
  }
  private func cleanupNewWindowPreparation(_ value: NewWindowPreparation) async
    -> NativeNewWindowPreparationResult
  {
    defer { value.cleanupRunning = false }
    // Await only raw preparation; public waiters may themselves be waiting for this cleanup.
    if let task = value.task { _ = await task.value }
    do {
      guard preparingNewWindow === value else { throw NativeNewWindowPreparationError.expired }
      if !value.pauseDrained, let pause = value.pause {
        try await checkpoints.drainPause(pause)
        value.pauseDrained = true
      }
      if let revision = value.registeredRevision, !value.unregistered {
        guard registry.workspaceRevision == revision,
          registry.closedHistoryCount(windowID: value.assignment.windowID) == 0,
          registry.window(id: value.assignment.windowID)?.groups == [
            DocumentGroupSnapshot(
              id: value.assignment.groupID, documentIDs: [], selectedDocumentID: nil)
          ],
          value.endpoint.map({ endpoints[value.assignment.windowID] === $0 && !$0.announced })
            ?? (endpoints[value.assignment.windowID] == nil)
        else { throw NativeNewWindowPreparationError.cleanupChanged }
        try registry.unregisterEmptyWindow(
          value.assignment.windowID, expectedRevision: revision,
          willNotify: { _ in
            value.unregistered = true
            if let endpoint = value.endpoint, self.endpoints[value.assignment.windowID] === endpoint
            {
              self.endpoints[value.assignment.windowID] = nil
            }
          })
        value.endpoint?.controller?.window?.close()
      }
      if let pause = value.pause {
        try checkpoints.releasePause(pause)
        value.pause = nil
      }
      preparingNewWindow = nil
      checkpoints.requestCheckpoint()
      return .cancelled
    } catch {
      value.failure = error
      return .retained(error)
    }
  }

  var windows: [EditorWindowController] {
    registry.windowIDs.compactMap { endpoints[$0]?.controller }
  }
  @MainActor private final class TransferOwnerReference {
    weak var owner: NativeApplicationDocuments?
  }
  private final class TransferPresentation: ApplicationDocumentTransferReceipt {
    let transactionID = UUID()
    let model: EditorDocument
    let bridge: DocumentFileStateController?
    let request: DocumentTransferRequest
    var source: Endpoint
    var target: Endpoint
    var sourceView: EditorTransferEndpointReceipt
    var targetView: EditorTransferEndpointReceipt
    var monitor: NativeEndpointOwnershipTransferReceipt?
    var ordinaryContext = false
    init(
      _ snapshot: DocumentTransferSnapshot, model: EditorDocument,
      source: Endpoint, target: Endpoint, sourceView: EditorTransferEndpointReceipt,
      targetView: EditorTransferEndpointReceipt
    ) {
      self.model = model
      bridge = model.fileState
      request = snapshot.request
      self.source = source
      self.target = target
      self.sourceView = sourceView
      self.targetView = targetView
    }
  }
  private var transferID: ApplicationDocumentTransferID?
  private var transferPresentation: TransferPresentation?
  private lazy var transferring = ApplicationDocumentTransfer(
    registry: registry,
    publication: .init(
      requireAdmission: {
        try self.requireNewWindowSettled()
        guard self.ready, !self.quitting, !self.preparingHistory,
          self.externalOpens.pendingCount == 0
        else { throw NativeWorkspaceError.notReady }
        try self.intake.requireSettled()
        try self.closing.requireSettled()
      }, acquirePause: { try self.checkpoints.acquirePause() },
      drainPause: {
        try await self.checkpoints.drainPause($0)
        try await self.drainLegacy()
      }, releasePause: { try self.checkpoints.releasePause($0) },
      requestCheckpoint: { self.checkpoints.requestCheckpoint() }),
    native: makeTransferNative())

  func prepareMove(documentID: UUID) throws -> NativeDocumentMoveChoices {
    try requireUserAdmission()
    try transferring.requireSettled()
    try intake.requireSettled()
    try closing.requireSettled()
    guard let model = registry.handle(id: documentID) as? EditorDocument,
      let assignment = registry.assignment(of: documentID),
      registry.window(id: assignment.windowID)?.groups.first?.selectedDocumentID == documentID
    else { throw DocumentTransferError.invalidRequest }
    let source = try endpoint(windowID: assignment.windowID)
    _ = try validateTransferEndpoint(source)
    let destinations = try registry.windowIDs.enumerated().compactMap {
      index, id -> NativeDocumentMoveDestination? in
      guard id != assignment.windowID, let value = endpoints[id] else { return nil }
      let controller = try validateTransferEndpoint(value)
      let title = controller.window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return .init(
        windowID: id, endpointID: value.id,
        title: title.isEmpty ? "Window \(index + 1)" : "\(title) (\(index + 1))")
    }
    return .init(
      documentID: documentID, ownershipGeneration: model.ownershipGeneration,
      sourceWindowID: assignment.windowID, sourceEndpointID: source.id, destinations: destinations,
      sourceWorkspaceRevision: registry.workspaceRevision)
  }
  func moveDocument(
    _ choices: NativeDocumentMoveChoices, to destination: NativeDocumentMoveDestination
  ) throws -> ApplicationDocumentTransferID {
    guard choices.destinations.contains(destination),
      let model = registry.handle(id: choices.documentID) as? EditorDocument,
      model.ownershipGeneration == choices.ownershipGeneration,
      registry.assignment(of: model.id)?.windowID == choices.sourceWindowID,
      endpoints[choices.sourceWindowID]?.id == choices.sourceEndpointID,
      endpoints[destination.windowID]?.id == destination.endpointID
    else { throw NativeDocumentTransferError.changed }
    return try moveDocument(choices.documentID, toWindowID: destination.windowID)
  }
  func movePresentation(documentID: UUID, destination: NativeDocumentMoveDestination) throws
    -> EditorWindowController
  {
    try requireUserAdmission()
    try transferring.requireSettled()
    try intake.requireSettled()
    try closing.requireSettled()
    let value = try endpoint(windowID: destination.windowID)
    guard value.id == destination.endpointID,
      registry.assignment(of: documentID) == value.assignment,
      registry.window(id: destination.windowID)?.groups.first?.selectedDocumentID == documentID,
      registry.handle(id: documentID) is EditorDocument
    else { throw NativeWorkspaceError.staleEndpoint }
    return try validateTransferEndpoint(value)
  }
  func moveDocument(_ documentID: UUID, toWindowID: UUID) throws -> ApplicationDocumentTransferID {
    try requireUserAdmission()
    try transferring.requireSettled()
    try intake.requireSettled()
    try closing.requireSettled()
    guard !preparingHistory, externalOpens.pendingCount == 0,
      let model = registry.handle(id: documentID) as? EditorDocument,
      let source = registry.assignment(of: documentID),
      source.windowID != toWindowID,
      let targetWindow = registry.window(id: toWindowID), targetWindow.groups.count == 1
    else { throw DocumentTransferError.invalidRequest }
    _ = try endpoint(windowID: source.windowID)
    _ = try endpoint(windowID: toWindowID)
    let group = targetWindow.groups[0]
    if let url = model.url?.standardizedFileURL.absoluteString {
      for id in group.documentIDs {
        if let other = registry.handle(id: id) as? EditorDocument,
          let otherURL = other.url?.standardizedFileURL.absoluteString,
          url.utf8.elementsEqual(otherURL.utf8)
        {
          throw DocumentTransferError.invalidRequest
        }
      }
    }
    let pinned = registry.metadata(id: documentID)?.pinned == true
    let index =
      pinned
      ? group.documentIDs.filter { registry.metadata(id: $0)?.pinned == true }.count
      : group.documentIDs.count
    let request = DocumentTransferRequest(
      documentID: documentID, source: source,
      target: .init(windowID: toWindowID, groupID: group.id), targetIndex: index,
      workspaceRevision: registry.workspaceRevision, ownershipGeneration: model.ownershipGeneration)
    let id = try transferring.start(request)
    transferID = id
    return id
  }
  func waitForTransfer(_ id: ApplicationDocumentTransferID) async throws
    -> ApplicationDocumentTransferResult
  {
    let result = try await transferring.wait(for: id)
    switch result {
    case .moved, .restored:
      if transferID == id {
        transferID = nil
        transferPresentation = nil
      }
    case .retained: break
    }
    return result
  }
  private func transferValue(_ value: any ApplicationDocumentTransferReceipt) throws
    -> TransferPresentation
  {
    guard let value = value as? TransferPresentation,
      transferPresentation === value,
      registry.handle(id: value.model.id) === value.model,
      value.model.fileState === value.bridge
    else { throw NativeDocumentTransferError.changed }
    return value
  }
  private func validateTransferEndpoint(_ value: Endpoint) throws -> EditorWindowController {
    guard endpoints[value.assignment.windowID] === value, let controller = value.controller else {
      throw NativeWorkspaceError.staleEndpoint
    }
    try validate(endpointID: value.id, assignment: value.assignment)
    return controller
  }
  /// Rebind only explicit endpoint incarnations. Original transfer views remain in the receipt.
  private func reconcileTransferEndpoints(
    _ value: TransferPresentation, lease: DocumentTransferLease?
  ) throws {
    _ = try transferValue(value)
    var failure: Error?
    let windowIDs = [value.request.source.windowID, value.request.target.windowID]
    // Both records must exist before strict model-state capture can consult the current owner.
    for windowID in windowIDs where endpoints[windowID] == nil {
      do { _ = try createEndpoint(windowID: windowID, forTransfer: true) } catch {
        if failure == nil { failure = error }
      }
    }
    for (index, windowID) in windowIDs.enumerated() {
      do {
        let current = try endpoint(windowID: windowID)
        let original = index == 0 ? value.source : value.target
        guard current !== original else { continue }
        let controller = try validateTransferEndpoint(current)
        let previous = index == 0 ? value.sourceView : value.targetView
        let replacement: EditorTransferEndpointReceipt
        if let lease {
          let snapshot = try registry.transferSnapshot(lease)
          replacement = try controller.reconcileTransferEndpoint(
            snapshot, receipt: previous, endpointID: current.id)
        } else {
          guard transferring.allowsNativeAdmission, let expected = registry.window(id: windowID)
          else { throw ApplicationDocumentTransferError.pendingLayout }
          replacement = try controller.reconcileSettledTransferEndpoint(
            receipt: previous, expected: expected, endpointID: current.id)
        }
        if index == 0 {
          value.source = current
          value.sourceView = replacement
        } else {
          value.target = current
          value.targetView = replacement
        }
      } catch { if failure == nil { failure = error } }
    }
    if let failure { throw failure }
  }
  private func makeTransferNative() -> ApplicationDocumentTransferNative {
    .init(
      capture: { snapshot in
        guard let model = snapshot.handle as? EditorDocument else {
          throw DocumentTransferError.invalidRequest
        }
        let source = try self.endpoint(windowID: snapshot.request.source.windowID)
        let target = try self.endpoint(windowID: snapshot.request.target.windowID)
        let sourceView = try self.validateTransferEndpoint(source).captureTransferEndpoint(
          snapshot, endpointID: source.id)
        let targetView = try self.validateTransferEndpoint(target).captureTransferEndpoint(
          snapshot, endpointID: target.id)
        let value = TransferPresentation(
          snapshot, model: model, source: source, target: target,
          sourceView: sourceView, targetView: targetView)
        self.transferPresentation = value
        return value
      },
      validate: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        try self.validateTransferEndpoint(value.source).validateTransferEndpoint(
          snapshot, receipt: value.sourceView)
        try self.validateTransferEndpoint(value.target).validateTransferEndpoint(
          snapshot, receipt: value.targetView)
      },
      suspendMonitor: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        if value.monitor == nil {
          do {
            value.monitor = try self.bindings.reserveTransfer(
              value.model, transactionID: value.transactionID)
          } catch {
            if let retained = self.bindings.retainedTransfer(documentID: value.model.id),
              retained.transactionID == value.transactionID
            {
              value.monitor = retained
            }
            throw error
          }
        }
        if let monitor = value.monitor {
          try self.bindings.suspendTransfer(monitor) {
            _ = try self.registry.validateTransferSnapshot(snapshot.lease)
          }
        }
      },
      projectSource: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        try self.validateTransferEndpoint(value.source).applyTransferProjection(
          snapshot, receipt: value.sourceView)
      },
      projectTarget: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        try self.validateTransferEndpoint(value.target).applyTransferProjection(
          snapshot, receipt: value.targetView)
      },
      attachMonitor: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        guard let monitor = value.monitor else { return }
        let destination = snapshot.phase == .staged ? value.target : value.source
        let useTarget = snapshot.phase == .staged
        let controller = try self.validateTransferEndpoint(destination)
        let previous = try self.bindings.transferOwnership(monitor)
        try self.bindings.attachTransfer(
          monitor, expectedPreviousOwnership: previous,
          newOwnership: snapshot.expectedState.ownershipGeneration,
          liveContext: { [weak value, weak controller, weak model = value.model] in
            guard let controller, let model else { return nil }
            if let value, !value.ordinaryContext {
              return controller.transferFileStateContext(
                model, receipt: useTarget ? value.targetView : value.sourceView)
            }
            return controller.ordinaryFileStateContext(model)
          },
          onChange: { [weak value, weak controller] in
            if let value, !value.ordinaryContext { return }
            controller?.notifyTransferDiskStateChange()
          }, validateLease: { _ = try self.registry.validateTransferSnapshot(snapshot.lease) })
      },
      refreshAdmission: { receipt in
        let value = try self.transferValue(receipt)
        value.ordinaryContext = true
        var failure: Error?
        // A missing peer must not leave an already committed live editor read-only.
        for endpoint in [value.source, value.target] {
          do {
            _ = try self.validateTransferEndpoint(endpoint)
            try self.project(windowID: endpoint.assignment.windowID)
          } catch { if failure == nil { failure = error } }
        }
        do { try self.refreshAdmission() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
        for endpoint in [value.source, value.target] where !endpoint.announced {
          let controller = try self.validateTransferEndpoint(endpoint)
          endpoint.announced = true
          self.onWindowCreated(controller)
          _ = try self.validateTransferEndpoint(endpoint)
        }
      },
      finishMonitor: { snapshot, receipt in
        let value = try self.transferValue(receipt)
        if let monitor = value.monitor {
          try self.bindings.finishTransfer(monitor) {
            _ = try self.registry.validateTransferSnapshot(snapshot.lease)
          }
        }
      })
  }

  private lazy var checkpoints: ApplicationSessionCheckpoints = ApplicationSessionCheckpoints(
    session: session, recovery: recovery,
    managed: .init(
      registry: registry,
      requireIntakeSettled: {
        try self.requireNewWindowSettled()
        try self.intake.requireSettled()
        try self.transferring.requireSettled()
      },
      requireCloseSettled: { try self.closing.requireSettled() },
      validateProjection: { values in
        for value in values {
          let endpoint = try self.endpoint(windowID: value.id)
          try endpoint.controller!.validateRegistryProjection(
            value,
            revision: self.registry.workspaceRevision, endpointID: endpoint.id)
        }
      },
      captureWindow: { value in
        try self.endpoint(windowID: value.id).controller!.captureManagedSessionCheckpoint(
          expected: value)
      },
      preflightResources: { values in
        var budget = SessionStartupBudget()
        for value in values {
          for id in value.groups.flatMap(\.documentIDs) {
            guard let model = self.registry.handle(id: id) as? EditorDocument else {
              throw DocumentIntakeError.staleModel
            }
            try budget.admit(
              utf16Count: model.storage.length, originalByteCount: model.originalBytes?.count ?? 0)
          }
          try self.endpoint(windowID: value.id).controller!.validateManagedResources(
            expected: value)
        }
      },
      renderStatus: { message, retry in
        for window in self.windows {
          window.updateSessionCheckpointStatus(message: message, retry: retry)
        }
      }))
  private lazy var intake: NativeDocumentIntakeController = NativeDocumentIntakeController(
    registry: registry, session: session, recovery: recovery,
    publication: .init(
      acquirePause: {
        if let activation = self.activation {
          return try self.checkpoints.acquireActivationPause(activation)
        }
        return try self.checkpoints.acquirePause()
      }, drainPause: { try await self.checkpoints.drainPause($0) },
      releasePause: { try self.checkpoints.releasePause($0) },
      requestCheckpoint: { self.checkpoints.requestCheckpoint() }),
    destinations: .init(
      requireAdmission: {
        try self.requireNewWindowSettled()
        guard self.activation != nil || self.ready else { throw NativeWorkspaceError.notReady }
        try self.closing.requireSettled()
        try self.transferring.requireSettled()
      }, validate: { try self.validate(endpointID: $0, assignment: $1) },
      exists: { id in self.endpoints.values.contains { $0.id == id && $0.controller != nil } },
      resolveSelection: { id, assignment, selection in
        try self.validate(endpointID: id, assignment: assignment)
        switch selection {
        case .select: return true
        case .preserve: return false
        case .selectIfStillSelected(let documentID, let generation):
          return self.registry.window(id: assignment.windowID)?.groups.first?.selectedDocumentID
            == documentID
            && self.registry.handle(id: documentID)?.ownershipGeneration == generation
        }
      }, drainLegacyWrites: { try await self.drainLegacy() },
      project: { id, assignment in
        try self.validate(endpointID: id, assignment: assignment)
        try self.project(windowID: assignment.windowID)
      }))
  private lazy var closing: NativeApplicationCloseCoordinator = NativeApplicationCloseCoordinator(
    registry: registry, recovery: recovery,
    publication: .init(
      requireApplicationAdmission: {
        try self.requireUserAdmission()
        try self.intake.requireSettled()
        try self.transferring.requireSettled()
      },
      acquirePause: { try self.checkpoints.acquirePause() },
      drainPause: { try await self.checkpoints.drainPause($0) },
      releasePause: { try self.checkpoints.releasePause($0) },
      requestCheckpoint: { self.checkpoints.requestCheckpoint() }),
    endpoint: { windowID in
      guard let value = self.endpoints[windowID], let controller = value.controller else {
        return nil
      }
      return (value.id, controller)
    }, reportError: { self.onError($0) })

  private lazy var externalOpens: NativeApplicationOpenCoordinator = .init(
    ports: .init(
      chooseDestination: { _ in
        guard self.preparingNewWindow == nil else {
          throw NativeApplicationOpenError.temporarilyUnavailable
        }
        guard self.ready else { throw NativeWorkspaceError.notReady }
        try self.intake.requireSettled()
        try self.closing.requireSettled()
        try self.transferring.requireSettled()
        let chosen = self.windows.first { $0.window === NSApp.keyWindow } ?? self.windows.first
        let value =
          try chosen.map { try self.endpoint(windowID: $0.sessionMetadata.id) }
          ?? self.createEndpoint()
        return .init(endpointID: value.id, assignment: value.assignment)
      },
      requireDestination: { destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
      },
      existing: { request, destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        guard let window = self.registry.window(id: destination.assignment.windowID) else {
          throw NativeWorkspaceError.staleEndpoint
        }
        guard
          let id = window.groups.flatMap(\.documentIDs).first(where: {
            (self.registry.handle(id: $0) as? EditorDocument)?.url?.standardizedFileURL
              == request.url.standardizedFileURL
          })
        else { return nil }
        try self.selectOwnedDocument(id, destination: destination)
        return id
      },
      submit: { seed, destination in
        try self.intake.submit(
          .init(
            endpointID: destination.endpointID, assignment: destination.assignment,
            seed: seed, provenance: .fresh, selection: .select,
            requireDestinationCurrent: {
              try self.validate(
                endpointID: destination.endpointID, assignment: destination.assignment)
            }))
      }, wait: { try await self.intake.wait(for: $0) },
      retrySame: { id, destination in
        guard self.intake.status?.id == id, self.intake.status?.stage == .failed else {
          throw DocumentIntakeError.expired
        }
        if self.endpoints[destination.assignment.windowID] == nil {
          try self.recreateEndpoint(windowID: destination.assignment.windowID)
        }
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        try self.intake.retry(id)
        return .init(endpointID: value.id, assignment: value.assignment)
      },
      reconcileDestination: { documentID, destination in
        guard self.registry.handle(id: documentID) != nil else {
          throw NativeApplicationOpenError.documentClosed
        }
        guard self.registry.assignment(of: documentID) == destination.assignment else {
          throw DocumentIntakeError.staleDestination
        }
        if self.endpoints[destination.assignment.windowID] == nil {
          try self.recreateEndpoint(windowID: destination.assignment.windowID)
        }
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        let reconciled = NativeApplicationOpenDestination(
          endpointID: value.id, assignment: value.assignment)
        try self.selectOwnedDocument(documentID, destination: reconciled)
        return reconciled
      },
      navigate: { documentID, destination, line, column in
        guard self.registry.handle(id: documentID) != nil else {
          throw NativeApplicationOpenError.documentClosed
        }
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        let value = try self.endpoint(windowID: destination.assignment.windowID)
        try await value.controller!.navigateManaged(
          documentID: documentID, endpointID: value.id, line: line, column: column)
        guard let model = self.registry.handle(id: documentID) as? EditorDocument else {
          throw DocumentIntakeError.staleModel
        }
        if let url = model.url { value.controller!.onOpenedURL?(url) }
      },
      largeFile: { request, destination in
        try self.validate(endpointID: destination.endpointID, assignment: destination.assignment)
        try await self.openLargeFile(request)
      }, reportError: { self.onError($0.error) }))

  init(
    session: SessionCoordinator, recovery: RecoveryCoordinator,
    monitoring: ApplicationFileMonitoring,
    onWindowCreated: @escaping (EditorWindowController) -> Void,
    configureWindow: @escaping (EditorWindowController) -> Void = { _ in },
    onError: @escaping (Error) -> Void,
    openLargeFile: @escaping (LaunchRequest) async throws -> Void = { _ in
      throw NativeApplicationOpenError.tooLarge
    }
  ) throws {
    self.session = session
    self.recovery = recovery
    self.monitoring = monitoring
    self.onWindowCreated = onWindowCreated
    self.configureWindow = configureWindow
    self.onError = onError
    self.openLargeFile = openLargeFile
    bindings = try NativeDocumentEndpointBindings()
    let transferOwner = TransferOwnerReference()
    registry = ApplicationDocuments(
      closeServices: .init(readState: { handle in
        guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
        return try model.captureCloseState()
      }),
      adoptionServices: .init(
        coordinatorID: recovery.coordinatorID,
        readState: { handle in
          guard let model = handle as? EditorDocument else { throw DocumentIntakeError.staleModel }
          return .init(
            documentID: model.id, ownershipGeneration: model.ownershipGeneration,
            authority: model.recoveryAuthority,
            highestIssuedRevision: model.highestIssuedRecoveryRevision)
        }),
      transferServices: .init(
        rotateOwnership: { handle in
          guard let model = handle as? EditorDocument else {
            return .init(
              ownershipGeneration: handle.ownershipGeneration,
              mutationGeneration: handle.ownershipGeneration)
          }
          let pair = model.rotateTransferOwnership()
          return .init(
            ownershipGeneration: pair.ownershipGeneration,
            mutationGeneration: pair.mutationGeneration)
        },
        readState: { [transferOwner] handle in
          guard let owner = transferOwner.owner, let model = handle as? EditorDocument,
            let assignment = owner.registry.assignment(of: model.id)
          else { throw DocumentTransferError.stale }
          let endpoint = try owner.endpoint(windowID: assignment.windowID)
          let preparation = try owner.validateTransferEndpoint(endpoint)
            .captureTransferPreparation()
          return try model.captureTransferState(preparation: preparation)
        }))
    transferOwner.owner = self
  }
  private func requireUserAdmission() throws {
    try requireNewWindowSettled()
    guard ready, !quitting, transferring.allowsNativeAdmission else {
      throw NativeWorkspaceError.notReady
    }
  }
  private func endpoint(windowID: UUID) throws -> Endpoint {
    guard let value = endpoints[windowID], value.controller != nil else {
      throw NativeWorkspaceError.staleEndpoint
    }
    return value
  }
  private func validate(endpointID: UUID, assignment: DocumentAssignment) throws {
    let value = try endpoint(windowID: assignment.windowID)
    guard value.id == endpointID, value.assignment == assignment else {
      throw NativeWorkspaceError.staleEndpoint
    }
    try value.controller!.requireEndpointIdentity(endpointID: endpointID, assignment: assignment)
  }
  private func createEndpoint(windowID: UUID = UUID(), forTransfer: Bool = false) throws -> Endpoint
  {
    guard endpoints[windowID] == nil else { throw NativeWorkspaceError.staleEndpoint }
    let assignment: DocumentAssignment
    if let window = registry.window(id: windowID) {
      guard window.groups.count == 1 else { throw ApplicationCheckpointError.invalidProjection }
      assignment = .init(windowID: windowID, groupID: window.groups[0].id)
    } else {
      guard !forTransfer else { throw NativeWorkspaceError.staleEndpoint }
      let live = Set(try registry.captureWindows().map(\.id))
      let reserved = Set(session.unresolved.map(\.windowID))
      guard live.union(reserved).union([windowID]).count <= 32 else {
        throw SessionStoreError.limit
      }
      assignment = .init(windowID: windowID, groupID: UUID())
      try registry.registerWindow(id: windowID, initialGroupID: assignment.groupID)
    }
    let value = Endpoint(assignment)
    return try constructEndpoint(value, forTransfer: forTransfer)
  }
  /// Registration, endpoint installation/configuration, and visible announcement are distinct effects.
  private func constructEndpoint(
    _ value: Endpoint, forTransfer: Bool = false, provisional: Bool = false
  ) throws -> Endpoint {
    let assignment = value.assignment
    let windowID = assignment.windowID
    guard endpoints[windowID] == nil else { throw NativeWorkspaceError.staleEndpoint }
    endpoints[windowID] = value
    let current: () throws -> Void = { [weak self, weak value] in
      guard let self, let value, self.endpoints[windowID] === value else {
        throw NativeWorkspaceError.staleEndpoint
      }
    }
    let routing = EditorApplicationRouting(
      endpointID: value.id, assignment: assignment, registry: registry,
      requireEndpointCurrent: current,
      requireUserAdmission: { [weak self] in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.requireUserAdmission()
      },
      submit: { [weak self] submission in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.requireUserAdmission()
        return try self.intake.submit(submission)
      },
      wait: { [weak self] id in
        guard let self else { throw NativeWorkspaceError.notReady }
        return try await self.intake.wait(for: id)
      },
      requestClose: { [weak self] ids in
        guard let self else { throw NativeWorkspaceError.notReady }
        try current()
        guard let window = self.registry.window(id: windowID) else {
          throw NativeWorkspaceError.staleEndpoint
        }
        let ordered = window.groups.flatMap(\.documentIDs).filter { ids.contains($0) }
        guard Set(ordered) == ids else { throw DocumentClosingError.invalidRequest }
        return try self.closing.start(documentIDs: ordered, sourceWindowID: windowID)
      },
      requestReopen: { [weak self] in
        guard let self else { throw NativeWorkspaceError.notReady }
        try current()
        return try await self.reopen(windowID: windowID)
      },
      detachDocumentEndpoint: { [weak self, weak value] model in
        guard let self, let value else { throw NativeWorkspaceError.notReady }
        try current()
        if let presentation = self.transferPresentation, presentation.model === model,
          presentation.source === value || presentation.target === value,
          self.registry.hasActiveTransferLease(presentation.sourceView.lease)
        {
          // The live transaction owns monitor suspension, including before its first reservation.
          // Ordinary detachment here would create a competing receipt that transfer cannot consume.
          return
        }
        try self.bindings.detach(model)
      },
      reattachDocumentEndpoint: { [weak self] model, context, change in
        guard let self else { throw NativeWorkspaceError.notReady }
        try self.bindings.reattach(model, liveContext: context, onChange: change)
      },
      endpointClosed: { [weak self, weak value] id in
        guard let self, let value, value.id == id, self.endpoints[windowID] === value else {
          return
        }
        if self.preparingNewWindow?.endpoint === value {
          // The preparation record alone owns unused provisional removal.
          return
        }
        self.endpoints[windowID] = nil
        self.closing.endpointClosed(windowID: windowID)
        if !self.transferring.hasUnsettledTransactions,
          self.registry.window(id: windowID)?.groups.allSatisfy({ $0.documentIDs.isEmpty }) == true
        {
          do {
            try self.registry.unregisterEmptyWindow(
              windowID, expectedRevision: self.registry.workspaceRevision)
            self.checkpoints.requestCheckpoint()
          } catch { self.onError(error) }
        }
      }, requestCheckpoint: { [weak self] in self?.checkpoints.requestCheckpoint() })
    do {
      let controller = try EditorWindowController(
        id: windowID, application: routing, onError: onError)
      value.controller = controller
      controller.configureFileMonitoring(monitoring)
      configureWindow(controller)
      try current()
      if !forTransfer,
        registry.window(id: windowID)?.groups.allSatisfy({ $0.documentIDs.isEmpty }) == true
      {
        try project(windowID: windowID)
      }
      if !forTransfer, !provisional {
        value.announced = true
        onWindowCreated(controller)
      }
      try current()
      return value
    } catch {
      if !provisional, endpoints[windowID] === value { endpoints[windowID] = nil }
      throw error
    }
  }
  private func selectOwnedDocument(_ id: UUID, destination: NativeApplicationOpenDestination) throws
  {
    try validate(endpointID: destination.endpointID, assignment: destination.assignment)
    let value = try endpoint(windowID: destination.assignment.windowID)
    guard let model = registry.handle(id: id) as? EditorDocument,
      registry.assignment(of: id) == destination.assignment,
      registry.allows(.select, documentID: id), model.composingPaneID == nil,
      !model.storage.editedMask.contains(.editedCharacters),
      value.controller?.focusedPane?.document.composingPaneID == nil
    else { throw PaneRoutingError.stale }
    try registry.selectDocument(
      id, in: destination.assignment, expectedRevision: registry.workspaceRevision)
    try project(windowID: destination.assignment.windowID)
  }
  private func project(windowID: UUID) throws {
    let value = try endpoint(windowID: windowID)
    guard let expected = registry.window(id: windowID) else {
      throw NativeWorkspaceError.staleEndpoint
    }
    try value.controller!.applyRegistryProjection(
      expected, revision: registry.workspaceRevision, endpointID: value.id)
  }
  private func drainLegacy() async throws {
    try EditorWindowController.assertNoPendingCloses()
    for value in Array(endpoints.values) {
      guard let controller = value.controller else { throw NativeWorkspaceError.staleEndpoint }
      try await controller.drainLegacyRecoveryWrites(endpointID: value.id)
      try validate(endpointID: value.id, assignment: value.assignment)
    }
    try EditorWindowController.assertNoPendingCloses()
  }
  private func refreshAdmission() throws {
    for value in endpoints.values {
      guard let window = registry.window(id: value.assignment.windowID),
        let controller = value.controller
      else {
        throw NativeWorkspaceError.staleEndpoint
      }
      for id in window.groups.flatMap(\.documentIDs) {
        guard let model = registry.handle(id: id) as? EditorDocument else {
          throw DocumentIntakeError.staleModel
        }
        try controller.applyManagedAdmission(to: model, endpointID: value.id)
      }
    }
  }
  func start() async throws {
    try requireNewWindowSettled()
    if let startupTask { return try await startupTask.value }
    startupInFlight = true
    let task = Task {
      defer { self.startupInFlight = false }
      try await self.restore()
    }
    startupTask = task
    try await task.value
  }
  private func restore() async throws {
    let token = try checkpoints.beginManagedActivation()
    activation = token
    do {
      try await checkpoints.drainManagedActivation(token)
      await session.restore { window in
        var failures: [UUID: String] = [:]
        for tab in window.tabs {
          failures[tab.metadata.id] = "Awaiting managed document import."
          if self.pending.count < 128,
            Set(self.pending.map { $0.0 }).union([window.id]).count <= 32,
            let seed = tab.seed
          {
            self.pending.append((window.id, seed))
          }
        }
        return failures
      }
      try await continueStartup()
    } catch {
      if activation != nil { try checkpoints.failManagedActivation(token, error: error) }
      throw error
    }
  }
  private func continueStartup() async throws {
    guard let token = activation else { throw NativeWorkspaceError.notReady }
    if let id = retainedStartup {
      if let windowID = pending.first?.0, endpoints[windowID] == nil {
        try recreateEndpoint(windowID: windowID)
      }
      try intake.retry(id)
      switch try await intake.wait(for: id) {
      case .imported:
        retainedStartup = nil
        pending.removeFirst()
      case .refused(let error):
        retainedStartup = nil
        throw error
      case .retained(_, let error): throw error
      }
    }
    if pending.isEmpty, try registry.captureWindows().isEmpty {
      let reservedWindows = Set(session.unresolved.map(\.windowID))
      let reservedDocuments = Set(session.unresolved.map { $0.metadata.id })
      if reservedDocuments.count < 128, reservedWindows.count <= 32 {
        let seed = try NativeDocumentSeed.scratch()
        startupScratch = seed.id
        let destination = reservedWindows.count == 32 ? session.unresolved[0].windowID : UUID()
        pending.append((destination, seed))
      } else {
        // Existing unresolved ownership fills the budget; expose its repair UI without adding a record.
        onError(SessionStoreError.limit)
      }
    }
    while let (windowID, seed) = pending.first {
      let value = try endpoints[windowID] ?? createEndpoint(windowID: windowID)
      let provenance: DocumentIntakeProvenance
      var selection = EditorIntakeSelection.select
      var insertionIndex: Int?
      if seed.id == startupScratch {
        provenance = .fresh
      } else {
        guard
          let entry = session.unresolved.first(where: {
            $0.metadata.id == seed.id && $0.windowID == windowID
          })
        else { throw SessionImportError.invalidClaim }
        do { provenance = .session(try session.claimImport(entry)) } catch {
          guard seed.url == nil, seed.originalBytes == nil else { throw error }
          provenance = .recovery(try session.claimRecoveryImport(entry))
        }
        selection = session.shouldSelect(entry) ? .select : .preserve
        insertionIndex = session.insertionIndex(for: entry, in: value.controller!.sessionMetadata)
      }
      let submission = EditorPreparedSubmission(
        endpointID: value.id, assignment: value.assignment,
        seed: seed, provenance: provenance, selection: selection,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        },
        insertionIndex: insertionIndex)
      let id = try intake.submit(submission)
      switch try await intake.wait(for: id) {
      case .imported: pending.removeFirst()
      case .refused(let error):
        onError(error)
        pending.removeFirst()
      case .retained(_, let error):
        retainedStartup = id
        throw error
      }
    }
    try checkpoints.finishManagedActivation(token)
    activation = nil
    ready = true
    session.onSessionChange = { [weak self] in self?.checkpoints.requestCheckpoint() }
    admissionRefreshPending = true
    try refreshAdmission()
    admissionRefreshPending = false
    externalOpens.startupFinished()
  }
  func retryStartup() async throws {
    guard !quitting else { throw NativeWorkspaceError.notReady }
    guard !startupInFlight else { throw DocumentIntakeError.busy }
    if admissionRefreshPending {
      try refreshAdmission()
      admissionRefreshPending = false
      startupTask = Task {}
      externalOpens.startupFinished()
      return
    }
    guard activation != nil else { throw NativeWorkspaceError.notReady }
    startupInFlight = true
    let task = Task {
      defer { self.startupInFlight = false }
      try await self.continueStartup()
    }
    startupTask = task
    try await task.value
  }
  /// Explicitly reconstruct a lost endpoint without replacing its registry-owned models.
  func recreateEndpoint(windowID: UUID) throws {
    try requireNewWindowSettled()
    guard !quitting, endpoints[windowID] == nil, registry.window(id: windowID) != nil else {
      throw NativeWorkspaceError.staleEndpoint
    }
    let value = try createEndpoint(windowID: windowID)
    if let status = intake.status, status.stage == .failed,
      registry.assignment(of: status.documentID)?.windowID == windowID
    {
      try intake.reconcileDestination(status.id, endpointID: value.id)
    } else {
      try project(windowID: windowID)
    }
  }
  private func reopen(windowID: UUID) async throws -> DocumentIntakeID {
    try transferring.requireSettled()
    try requireUserAdmission()
    try intake.requireSettled()
    try closing.requireSettled()
    guard !preparingHistory else { throw DocumentIntakeError.busy }
    let value = try endpoint(windowID: windowID)
    preparingHistory = true
    defer { preparingHistory = false }
    let prepared = try await NativeHistoryPreparation.prepare(
      registry: registry, windowID: windowID)
    try requireUserAdmission()
    try validate(endpointID: value.id, assignment: value.assignment)
    return try intake.submit(
      .init(
        endpointID: value.id, assignment: value.assignment,
        seed: prepared.seed, provenance: .history(prepared.claim), selection: .select,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        }))
  }
  @discardableResult func enqueueExternal(_ requests: [LaunchRequest]) -> OpenRequestAdmission {
    externalOpens.enqueue(requests)
  }
  var pendingExternalOpenCount: Int { externalOpens.pendingCount }
  var externalOpenFailure: OpenRequestFailure? { externalOpens.lastFailure }
  func retryExternalOpen() throws {
    try requireUserAdmission()
    try externalOpens.retryCurrent()
  }

  func retryDocumentIntake() async throws {
    try requireUserAdmission()
    guard let status = intake.status, status.stage == .failed else {
      throw DocumentIntakeError.expired
    }
    guard let assignment = registry.assignment(of: status.documentID) else {
      throw DocumentIntakeError.staleDestination
    }
    if endpoints[assignment.windowID] == nil { try recreateEndpoint(windowID: assignment.windowID) }
    try intake.retry(status.id)
    switch try await intake.wait(for: status.id) {
    case .imported: return
    case .refused(let error), .retained(_, let error): throw error
    }
  }

  var canRetryRecovery: Bool {
    preparingNewWindow?.failure != nil
      || (transferID != nil && transferring.hasUnsettledTransactions) || activation != nil
      || admissionRefreshPending || externalOpens.hasRetainedRequest
      || intake.status?.stage == .failed || closing.status?.stage == .failed
      || checkpoints.lastError != nil
  }
  func retryRecovery() async throws {
    guard !quitting else { throw NativeWorkspaceError.notReady }
    if let value = preparingNewWindow {
      guard value.failure != nil else { throw NativeNewWindowPreparationError.busy }
      try await cancelNewWindowPreparation(value.id)
      return
    }
    if let id = transferID, transferring.hasUnsettledTransactions {
      let lease = try transferring.retryLease(for: id)
      if let value = transferPresentation, lease != nil || transferring.allowsNativeAdmission {
        try reconcileTransferEndpoints(value, lease: lease)
      }
      try transferring.retryLayout(id)
      switch try await waitForTransfer(id) {
      case .moved, .restored: return
      case .retained(let error): throw error
      }
    }
    if activation != nil || admissionRefreshPending {
      try await retryStartup()
      return
    }
    if externalOpens.hasRetainedRequest {
      try retryExternalOpen()
      return
    }
    if intake.status?.stage == .failed {
      try await retryDocumentIntake()
      return
    }
    if let status = closing.status, status.stage == .failed {
      for window in try registry.captureWindows() where endpoints[window.id] == nil {
        try recreateEndpoint(windowID: window.id)
      }
      try closing.retry(status.id)
      if case .retained(_, _, let error) = try await closing.wait(for: status.id) { throw error }
      return
    }
    try requireUserAdmission()
    try intake.requireSettled()
    try closing.requireSettled()
    for window in try registry.captureReadyWindows() {
      if endpoints[window.id] == nil {
        try recreateEndpoint(windowID: window.id)
      } else {
        try project(windowID: window.id)
      }
    }
    checkpoints.requestCheckpoint()
  }

  var lastCheckpointError: Error? { checkpoints.lastError }
  func requestCheckpoint() { checkpoints.requestCheckpoint() }

  func createWindow(createDocument: Bool = true) throws -> EditorWindowController {
    try requireUserAdmission()
    try transferring.requireSettled()
    try intake.requireSettled()
    try closing.requireSettled()
    if createDocument {
      let live = Set(try registry.captureWindows().flatMap { $0.groups.flatMap(\.documentIDs) })
      guard live.union(session.unresolved.map { $0.metadata.id }).count < 128 else {
        throw SessionStoreError.limit
      }
    }
    let value = try createEndpoint()
    let controller = value.controller!
    if createDocument { controller.newDocument() }
    return controller
  }

  /// The panel supplies a worker-prepared seed; only managed intake resolves its exact claim.
  func acceptSession(_ entry: UnresolvedSessionEntry, file: SessionResolvedFile) async throws {
    try requireUserAdmission()
    try transferring.requireSettled()
    try intake.requireSettled()
    guard let seed = file.seed, seed.id == entry.metadata.id else {
      throw DocumentIntakeError.invalidRequest
    }
    let provenance: DocumentIntakeProvenance
    do { provenance = .session(try session.claimImport(entry)) } catch {
      guard seed.url == nil, seed.originalBytes == nil else { throw error }
      provenance = .recovery(try session.claimRecoveryImport(entry))
    }
    let value = try endpoints[entry.windowID] ?? createEndpoint(windowID: entry.windowID)
    let id = try intake.submit(
      .init(
        endpointID: value.id, assignment: value.assignment,
        seed: seed, provenance: provenance,
        selection: session.shouldSelect(entry) ? .select : .preserve,
        requireDestinationCurrent: {
          try self.validate(endpointID: value.id, assignment: value.assignment)
        },
        insertionIndex: session.insertionIndex(for: entry, in: value.controller!.sessionMetadata)))
    switch try await intake.wait(for: id) {
    case .imported: return
    case .refused(let error), .retained(_, let error): throw error
    }
  }

  func prepareQuit() async throws -> SessionCheckpointReceipt {
    try requireNewWindowSettled()
    try transferring.requireSettled()
    guard !quitting else { throw NativeWorkspaceError.notReady }
    quitting = true
    externalOpens.beginQuit()
    do {
      if let startupTask { try await startupTask.value }
      await externalOpens.drainCurrent()
      guard externalOpens.pendingCount == 0 else { throw OpenRequestQueueError.busy }
      guard !preparingHistory else { throw DocumentIntakeError.busy }
      if let status = intake.status {
        _ = try await intake.wait(for: status.id)
      }
      try intake.requireSettled()
      try closing.requireSettled()
      try await checkpoints.prepareQuit()
      for window in windows {
        guard await window.prepareToQuit(persistRecovery: false) else {
          throw NativeWorkspaceError.quitVetoed
        }
      }
      try await drainLegacy()
      try checkpoints.markNativeQuitPrepared()
      return try await checkpoints.commitFinal()
    } catch {
      cancelPreparedQuit()
      throw error
    }
  }
  func cancelPreparedQuit() {
    quitting = false
    for window in windows { window.cancelPreparedQuit() }
    checkpoints.cancelPreparedQuit()
    externalOpens.resumeAfterVeto()
  }
}
