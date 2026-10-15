import Foundation
import PadCore

private final class DeliveryFence: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UUID
  init(_ generation: UUID) { self.generation = generation }
  var current: UUID {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }
  func set(_ value: UUID) {
    lock.lock()
    generation = value
    lock.unlock()
  }
}
struct FileStateBindingIdentity: Equatable {
  let documentID: UUID
  let bindingID: UUID
  let baselineRevision: UInt64
  let url: URL?
  let ownershipGeneration: UUID?
  init(_ value: FileStateLiveContext) {
    documentID = value.documentID
    bindingID = value.bindingID
    baselineRevision = value.baselineRevision
    url = value.url
    ownershipGeneration = value.ownershipGeneration
  }
}
struct FileStateEndpointDetachment {
  fileprivate let owner: UUID
  fileprivate let issuance: UUID
  let binding: FileStateBindingIdentity
}
struct FileStateOwnershipTransferReceipt {
  fileprivate let owner: UUID
  fileprivate let issuance: UUID
  let transactionID: UUID
  let binding: FileStateBindingIdentity
}
enum FileStateEndpointError: Error { case unavailable, stale }
@MainActor final class DocumentFileStateController {
  private enum OwnershipPhase { case reserved, suspended, attached }
  private final class OwnershipMove {
    let receipt: FileStateOwnershipTransferReceipt
    var ownership: UUID
    var used: Set<UUID>
    var phase = OwnershipPhase.reserved
    var invalidationRequest: UUID?
    init(_ receipt: FileStateOwnershipTransferReceipt, ownership: UUID) {
      self.receipt = receipt
      self.ownership = ownership
      used = [ownership]
    }
  }
  private var ownershipMove: OwnershipMove?
  private let endpointDelivery = DeliveryFence(UUID())
  var ownershipTransferInvalidationRequested: Bool { ownershipMove?.invalidationRequest != nil }
  private struct Binding {
    let id: UUID
    let url: URL
    let revision: UInt64
    let bytes: Data
    let identity: FileStateBindingIdentity
  }
  private struct ManualRequest {
    let id: UUID
    let token: FileObservationToken
    let bindingID: UUID
    let generation: UUID
  }
  private struct Envelope {
    let observation: DiskObservation
    let endpointGeneration: UUID
    let token: FileObservationToken
    let authority: UUID
    let bindingID: UUID
    let generation: UUID
  }
  private let documentID: UUID
  private let client: any MonitorClient
  private var liveContext: (() -> FileStateLiveContext?)?
  private var onChange: (() -> Void)?
  private let endpointOwner = UUID()
  private var detachment: FileStateEndpointDetachment?
  private var endpointTransition = false
  private var detachingEndpoint = false
  var isDetachingEndpoint: Bool { detachingEndpoint }
  private let fence: DeliveryFence
  private var binding: Binding?
  private var actionAuthorityID = UUID()
  private var authorityID = UUID() { didSet { actionAuthorityID = UUID() } }
  private var registration: (any MonitorHandle)?
  private var registrationBindingID: UUID?
  private var manualHandle: (any ManualHandle)?
  private var manualRequest: ManualRequest?
  private var manualMode = false
  private var manualSequence: UInt64 = 0
  private var requestFloor: FileObservationToken?
  private var pending: Envelope?
  private var boundIdentity: FileTargetIdentity?
  private var invalidated = false
  private(set) var state = ObservedFileState()
  private(set) var manualNotice: String?
  private(set) var lastFailure: MonitorFailure?

  init(
    documentID: UUID, client: any MonitorClient,
    liveContext: @escaping () -> FileStateLiveContext?, onChange: @escaping () -> Void
  ) {
    self.documentID = documentID
    self.client = client
    self.liveContext = liveContext
    self.onChange = onChange
    fence = DeliveryFence(liveContext()?.deliveryGeneration ?? UUID())
  }
  private func live() -> FileStateLiveContext? {
    let expectedAuthority = authorityID
    guard !invalidated, detachment == nil, !endpointTransition, let value = liveContext?(),
      !invalidated, detachment == nil, !endpointTransition, authorityID == expectedAuthority,
      value.documentID == documentID, !value.closed, !value.quitting
    else { return nil }
    return value
  }
  private func boundLive() -> FileStateLiveContext? {
    guard let value = live(), let binding, value.bindingID == binding.id,
      value.url == binding.url, value.baselineRevision == binding.revision,
      value.ownershipGeneration == binding.identity.ownershipGeneration
    else { return nil }
    return value
  }
  private func clearAdmission() {
    state = ObservedFileState()
    pending = nil
    requestFloor = nil
    let previous = manualHandle
    manualHandle = nil
    manualRequest = nil
    previous?.cancel()
  }
  private func retireRegistration(retainingContinuity: Bool) {
    guard let handle = registration else { return }
    registration = nil
    let installedBindingID = registrationBindingID
    registrationBindingID = nil
    let receipt = handle.cancelAndSnapshot()
    guard retainingContinuity, let binding,
      installedBindingID == binding.id, receipt.documentID == documentID,
      receipt.baselineRevision == binding.revision
    else { return }
    if boundIdentity == nil { boundIdentity = receipt.boundIdentity }
  }
  func adoptBaseline(bytes: Data, validatedIdentity: FileTargetIdentity? = nil) {
    guard ownershipMove == nil else { return }
    guard let value = live() else { return }
    clearAdmission()
    if validatedIdentity != nil { retireRegistration(retainingContinuity: false) }
    boundIdentity = validatedIdentity
    fence.set(value.deliveryGeneration)
    guard let url = value.url else {
      binding = nil
      authorityID = UUID()
      retireRegistration(retainingContinuity: false)
      manualMode = false
      manualNotice = nil
      lastFailure = nil
      onChange?()
      return
    }
    binding = Binding(
      id: value.bindingID, url: url, revision: value.baselineRevision, bytes: bytes,
      identity: FileStateBindingIdentity(value))
    if registration != nil && !manualMode {
      do {
        try client.rebind(
          id: documentID, url: url, baseline: bytes, revision: value.baselineRevision)
        registrationBindingID = binding?.id
        lastFailure = nil
        onChange?()
        return
      } catch {
        enterManual(failure: .unavailable)
        return
      }
    }
    retryRegistration()
  }
  func retryRegistration() {
    guard ownershipMove == nil else { return }
    _ = registerEndpoint()
  }
  private func registerEndpoint() -> UUID? {
    guard let value = boundLive(), let binding else { return nil }
    authorityID = UUID()
    clearAdmission()
    retireRegistration(retainingContinuity: true)
    manualMode = false
    manualNotice = nil
    lastFailure = nil
    let authority = authorityID
    let fence = fence
    let endpointDelivery = endpointDelivery
    fence.set(value.deliveryGeneration)
    do {
      registration = try client.register(
        id: documentID, url: binding.url,
        baseline: binding.bytes, revision: binding.revision, boundIdentity: boundIdentity
      ) { [weak self] token, observation in
        let generation = fence.current
        let endpointGeneration = endpointDelivery.current
        Task { @MainActor [weak self] in
          guard let self, let binding = self.binding else { return }
          self.accept(
            Envelope(
              observation: observation, endpointGeneration: endpointGeneration, token: token,
              authority: authority,
              bindingID: binding.id, generation: generation))
        }
      }
      registrationBindingID = binding.id
    } catch {
      return enterManual(failure: (error as? MonitorFailure) ?? .unavailable)
    }
    onChange?()
    return authority
  }
  @discardableResult private func enterManual(failure: MonitorFailure?) -> UUID {
    authorityID = UUID()
    let authority = authorityID
    clearAdmission()
    retireRegistration(retainingContinuity: true)
    manualMode = true
    manualSequence = 0
    lastFailure = failure
    manualNotice =
      "Automatic monitoring unavailable; Check Again performs one check. Retry Monitoring is available."
    onChange?()
    return authority
  }
  func useManualFallback() {
    guard ownershipMove == nil else { return }
    guard boundLive() != nil else { return }
    enterManual(failure: nil)
  }
  func checkAgain() {
    guard ownershipMove == nil else { return }
    guard let value = boundLive(), let binding else { return }
    if !manualMode, let registration {
      requestFloor = registration.snapshot.currentToken
      client.requestCheck(id: documentID)
      return
    }
    if !manualMode { enterManual(failure: .unavailable) }
    if manualSequence == .max {
      authorityID = UUID()
      manualSequence = 0
    }
    manualSequence += 1
    let request = ManualRequest(
      id: UUID(),
      token: FileObservationToken(
        documentID: documentID,
        epoch: 1, baselineRevision: binding.revision, sequence: manualSequence),
      bindingID: binding.id, generation: value.deliveryGeneration)
    let previous = manualHandle
    manualHandle = nil
    manualRequest = request
    pending = nil
    state = ObservedFileState()
    lastFailure = nil
    previous?.cancel()  // The new issuance already fences inline cancellation of the old request.
    let authority = authorityID
    manualHandle = client.checkOnce(
      requestID: request.id, id: documentID, url: binding.url,
      baseline: binding.bytes, revision: binding.revision, boundIdentity: boundIdentity
    ) { [weak self] id, result in
      Task { @MainActor [weak self] in
        guard let self, let live = self.boundLive(), self.manualMode,
          self.authorityID == authority, self.manualRequest?.id == id,
          id == request.id, live.bindingID == request.bindingID,
          live.deliveryGeneration == request.generation
        else { return }
        self.manualHandle = nil
        switch result {
        case .success(let observation):
          self.accept(
            Envelope(
              observation: observation, endpointGeneration: self.endpointDelivery.current,
              token: request.token, authority: authority,
              bindingID: request.bindingID, generation: request.generation))
        case .failure(let error):
          self.lastFailure = error
          self.manualRequest = nil
          self.pending = nil
          self.onChange?()
        }
      }
    }
    onChange?()
  }
  private func currentToken(for envelope: Envelope) -> FileObservationToken? {
    guard envelope.authority == authorityID else { return nil }
    if manualMode { return manualRequest?.token }
    guard let snapshot = registration?.snapshot, !snapshot.cancelled,
      let token = snapshot.currentToken
    else { return nil }
    if let floor = requestFloor, token.epoch == floor.epoch, token.sequence <= floor.sequence {
      return nil
    }
    return token
  }
  private func accept(_ envelope: Envelope) {
    guard envelope.endpointGeneration == endpointDelivery.current, let value = boundLive(),
      value.bindingID == envelope.bindingID,
      value.deliveryGeneration == envelope.generation,
      envelope.token.documentID == documentID,
      envelope.token.baselineRevision == value.baselineRevision,
      let token = currentToken(for: envelope), token == envelope.token
    else { return }
    // Continuity is binding authority, not deferred notice presentation.
    // Preserve it once this live envelope is validated, including while busy.
    if boundIdentity == nil { boundIdentity = envelope.observation.metadata?.identity }
    if ownershipMove != nil || value.operationID != nil || value.composing {
      pending = envelope
      return
    }
    pending = nil
    if state.accept(envelope.observation, token: envelope.token, currentToken: token) {
      requestFloor = nil
      lastFailure = nil
      onChange?()
    }
  }
  func reconcileEligibility() {
    guard ownershipMove == nil else { return }
    let expectedAuthority = authorityID
    guard !invalidated, detachment == nil, !endpointTransition, let value = liveContext?(),
      !invalidated, detachment == nil, !endpointTransition, authorityID == expectedAuthority
    else { return }
    let generationChanged = fence.current != value.deliveryGeneration
    fence.set(value.deliveryGeneration)
    if value.closed {
      invalidate()
      return
    }
    if value.quitting || generationChanged {
      clearAdmission()
      if !value.quitting { checkAgain() }
      return
    }
    guard value.operationID == nil, !value.composing, let envelope = pending else { return }
    pending = nil
    if currentToken(for: envelope) == envelope.token { accept(envelope) } else { checkAgain() }
  }
  /// Must precede terminal invalidation. Retains binding safety while retiring endpoint callbacks.
  func detachEndpoint() throws -> FileStateEndpointDetachment {
    guard ownershipMove == nil, !invalidated, detachment == nil, !endpointTransition, let binding
    else {
      throw FileStateEndpointError.unavailable
    }
    endpointTransition = true
    detachingEndpoint = true
    defer {
      detachingEndpoint = false
      endpointTransition = false
    }
    guard let value = liveContext?(), FileStateBindingIdentity(value) == binding.identity,
      !invalidated, detachment == nil,
      self.binding?.identity == binding.identity
    else { throw FileStateEndpointError.stale }
    let token = FileStateEndpointDetachment(
      owner: endpointOwner, issuance: UUID(), binding: binding.identity)
    detachment = token
    authorityID = UUID()
    fence.set(UUID())
    liveContext = nil
    onChange = nil
    pending = nil
    requestFloor = nil
    let previous = manualHandle
    manualHandle = nil
    manualRequest = nil
    // Authority and callbacks are retired before callback-capable cancellation.
    previous?.cancel()
    retireRegistration(retainingContinuity: true)
    guard !invalidated, detachment?.issuance == token.issuance else {
      throw FileStateEndpointError.stale
    }
    return token
  }
  func reattachEndpoint(
    _ token: FileStateEndpointDetachment, expectedBinding: FileStateBindingIdentity,
    liveContext: @escaping () -> FileStateLiveContext?, onChange: @escaping () -> Void
  ) throws {
    guard ownershipMove == nil, !invalidated, !endpointTransition, token.owner == endpointOwner,
      detachment?.issuance == token.issuance, token.binding == expectedBinding,
      binding?.identity == expectedBinding
    else { throw FileStateEndpointError.stale }
    endpointTransition = true
    defer { endpointTransition = false }
    let value = liveContext()
    guard !invalidated, detachment?.issuance == token.issuance,
      binding?.identity == expectedBinding, let value,
      FileStateBindingIdentity(value) == expectedBinding, !value.closed, !value.quitting
    else { throw FileStateEndpointError.stale }
    self.liveContext = liveContext
    self.onChange = onChange
    detachment = nil
    fence.set(value.deliveryGeneration)
    endpointTransition = false
    let installedAuthority = registerEndpoint()
    guard !invalidated, detachment == nil, !endpointTransition,
      binding?.identity == expectedBinding, installedAuthority == authorityID
    else { throw FileStateEndpointError.stale }
  }
  func reserveOwnershipTransfer(transactionID: UUID, expectedOwnership: UUID) throws
    -> FileStateOwnershipTransferReceipt
  {
    guard !invalidated, !endpointTransition, detachment == nil, ownershipMove == nil,
      let binding, binding.identity.ownershipGeneration == expectedOwnership
    else { throw FileStateEndpointError.stale }
    let receipt = FileStateOwnershipTransferReceipt(
      owner: endpointOwner, issuance: UUID(), transactionID: transactionID,
      binding: binding.identity)
    ownershipMove = OwnershipMove(receipt, ownership: expectedOwnership)
    return receipt
  }
  private func ownership(_ receipt: FileStateOwnershipTransferReceipt) throws -> OwnershipMove {
    guard !invalidated, !endpointTransition, receipt.owner == endpointOwner,
      let move = ownershipMove, move.receipt.issuance == receipt.issuance,
      move.receipt.transactionID == receipt.transactionID
    else { throw FileStateEndpointError.stale }
    return move
  }
  func currentTransferOwnership(_ receipt: FileStateOwnershipTransferReceipt) throws -> UUID {
    try ownership(receipt).ownership
  }
  func suspendOwnershipTransfer(
    _ receipt: FileStateOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let move = try ownership(receipt)
    endpointTransition = true
    defer { endpointTransition = false }
    try validateLease()
    guard ownershipMove === move else { throw FileStateEndpointError.stale }
    move.phase = .suspended
    actionAuthorityID = UUID()
    endpointDelivery.set(UUID())
    liveContext = nil
    onChange = nil
    pending = nil
    if let handle = manualHandle {
      manualHandle = nil
      manualRequest = nil
      handle.cancel()
    }
    try validateLease()
    guard ownershipMove === move else { throw FileStateEndpointError.stale }
  }
  private func sameBaseline(_ first: FileStateBindingIdentity, _ second: FileStateBindingIdentity)
    -> Bool
  {
    let sameURL: Bool
    switch (first.url?.absoluteString, second.url?.absoluteString) {
    case (nil, nil): sameURL = true
    case (let a?, let b?): sameURL = a.utf8.elementsEqual(b.utf8)
    default: sameURL = false
    }
    return first.documentID == second.documentID && first.bindingID == second.bindingID
      && first.baselineRevision == second.baselineRevision && sameURL
  }
  func attachOwnershipTransfer(
    _ receipt: FileStateOwnershipTransferReceipt, expectedPreviousOwnership: UUID,
    newOwnership: UUID, liveContext: @escaping () -> FileStateLiveContext?,
    onChange: @escaping () -> Void, validateLease: () throws -> Void
  ) throws {
    let move = try ownership(receipt)
    // A pre-stage validation failure may leave only the pure reservation. Explicit restoration
    // first retires its source callbacks under the now-valid lease, without rotating ownership.
    if move.phase == .reserved, expectedPreviousOwnership == move.ownership,
      newOwnership == expectedPreviousOwnership
    {
      try suspendOwnershipTransfer(receipt, validateLease: validateLease)
    }

    guard move.phase == .suspended, move.ownership == expectedPreviousOwnership,
      newOwnership == expectedPreviousOwnership || !move.used.contains(newOwnership),
      let old = binding
    else { throw FileStateEndpointError.stale }
    endpointTransition = true
    defer { endpointTransition = false }
    try validateLease()
    guard let value = liveContext(), !value.closed, !value.quitting, value.operationID == nil,
      !value.composing,
      value.ownershipGeneration == newOwnership,
      sameBaseline(old.identity, FileStateBindingIdentity(value))
    else { throw FileStateEndpointError.stale }
    try validateLease()
    guard ownershipMove === move, move.phase == .suspended, binding?.identity == old.identity else {
      throw FileStateEndpointError.stale
    }
    binding = Binding(
      id: old.id, url: old.url, revision: old.revision, bytes: old.bytes,
      identity: FileStateBindingIdentity(value))
    move.ownership = newOwnership
    move.used.insert(newOwnership)
    move.phase = .attached
    self.liveContext = liveContext
    self.onChange = onChange
    fence.set(value.deliveryGeneration)
    endpointDelivery.set(UUID())
    onChange()
    try validateLease()
    guard ownershipMove === move, move.phase == .attached, let final = liveContext(),
      FileStateBindingIdentity(final) == binding?.identity, !final.closed, !final.quitting
    else { throw FileStateEndpointError.stale }
    try validateLease()
  }
  func finishOwnershipTransfer(
    _ receipt: FileStateOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let move = try ownership(receipt)
    guard move.phase == .attached, move.invalidationRequest == nil else {
      throw FileStateEndpointError.stale
    }
    endpointTransition = true
    do {
      try validateLease()
      guard let value = liveContext?(), FileStateBindingIdentity(value) == binding?.identity,
        !value.closed, !value.quitting
      else { throw FileStateEndpointError.stale }
      try validateLease()
      guard ownershipMove === move, move.invalidationRequest == nil else {
        throw FileStateEndpointError.stale
      }
      ownershipMove = nil
      endpointTransition = false
    } catch {
      endpointTransition = false
      throw error
    }
    onChange?()
  }
  /// Explicit owner decision after validating the attached destination; never silently discard a close request.
  func resolveOwnershipTransferInvalidation(
    _ receipt: FileStateOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let move = try ownership(receipt)
    guard move.phase == .attached, let invalidationRequest = move.invalidationRequest else {
      throw FileStateEndpointError.stale
    }
    endpointTransition = true
    defer { endpointTransition = false }
    try validateLease()
    guard let value = liveContext?(), !value.closed, !value.quitting,
      FileStateBindingIdentity(value) == binding?.identity
    else { throw FileStateEndpointError.stale }
    try validateLease()
    guard ownershipMove === move, move.invalidationRequest == invalidationRequest else {
      throw FileStateEndpointError.stale
    }
    move.invalidationRequest = nil
  }
  /// Terminal cleanup only when the process has separately authorized bridge disposal.
  func invalidateOwnershipTransfer(
    _ receipt: FileStateOwnershipTransferReceipt, validateDisposal: () throws -> Void
  ) throws {
    let move = try ownership(receipt)
    endpointTransition = true
    do {
      try validateDisposal()
      guard ownershipMove === move else { throw FileStateEndpointError.stale }
      ownershipMove = nil
      endpointTransition = false
    } catch {
      endpointTransition = false
      throw error
    }
    invalidate()
  }
  func invalidate() {
    if let move = ownershipMove {
      move.invalidationRequest = UUID()
      return
    }
    guard !invalidated else { return }
    invalidated = true
    detachment = nil
    liveContext = nil
    onChange = nil
    authorityID = UUID()
    clearAdmission()
    retireRegistration(retainingContinuity: false)
    binding = nil
  }
  func captureAction(_ action: FileConflictAction) -> FileStateActionContext? {
    guard ownershipMove == nil else { return nil }
    guard let value = boundLive(), let token = state.token,
      state.admission(
        for: action, dirty: value.dirty, pendingPublication: value.pendingPublicationID != nil,
        busy: value.operationID != nil, composing: value.composing, recording: value.recording,
        quitting: value.quitting, closed: value.closed) != .refused,
      currentToken(
        for: Envelope(
          observation: state.observation!, endpointGeneration: endpointDelivery.current,
          token: token,
          authority: authorityID, bindingID: value.bindingID, generation: value.deliveryGeneration))
        == token
    else { return nil }
    return FileStateActionContext(
      live: value, authorityID: actionAuthorityID, token: token, action: action)
  }
  func isCurrent(_ context: FileStateActionContext) -> Bool {
    guard let current = captureAction(context.action) else { return false }
    return current.live == context.live && current.authorityID == context.authorityID
      && current.token == context.token
  }
  func isCurrent(_ context: FileStateActionContext, owningOperation: UUID) -> Bool {
    guard ownershipMove == nil else { return false }
    guard context.live.operationID == nil, let value = boundLive(),
      value.operationID == owningOperation, context.authorityID == actionAuthorityID,
      state.token == context.token, let observation = state.observation,
      currentToken(
        for: Envelope(
          observation: observation, endpointGeneration: endpointDelivery.current,
          token: context.token,
          authority: authorityID, bindingID: value.bindingID, generation: value.deliveryGeneration))
        == context.token
    else { return false }
    // Only the caller's proven operation may differ from the pre-operation capture.
    var comparable = value
    comparable.operationID = nil
    guard comparable == context.live else { return false }
    return state.admission(
      for: context.action, dirty: value.dirty,
      pendingPublication: value.pendingPublicationID != nil, busy: false,
      composing: value.composing, recording: value.recording,
      quitting: value.quitting, closed: value.closed) != .refused
  }

  @discardableResult func keepBuffer(_ context: FileStateActionContext) -> Bool {
    guard context.action == .keepBuffer, isCurrent(context) else { return false }
    state.dismiss(token: context.token)
    onChange?()
    return true
  }

}
