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
enum FileStateEndpointError: Error { case unavailable, stale }
@MainActor final class DocumentFileStateController {
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
  private let fence: DeliveryFence
  private var binding: Binding?
  private var authorityID = UUID()
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
  func retryRegistration() { _ = registerEndpoint() }
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
    fence.set(value.deliveryGeneration)
    do {
      registration = try client.register(
        id: documentID, url: binding.url,
        baseline: binding.bytes, revision: binding.revision, boundIdentity: boundIdentity
      ) { [weak self] token, observation in
        let generation = fence.current
        Task { @MainActor [weak self] in
          guard let self, let binding = self.binding else { return }
          self.accept(
            Envelope(
              observation: observation, token: token, authority: authority,
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
    guard boundLive() != nil else { return }
    enterManual(failure: nil)
  }
  func checkAgain() {
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
              observation: observation, token: request.token, authority: authority,
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
    guard let value = boundLive(), value.bindingID == envelope.bindingID,
      value.deliveryGeneration == envelope.generation,
      envelope.token.documentID == documentID,
      envelope.token.baselineRevision == value.baselineRevision,
      let token = currentToken(for: envelope), token == envelope.token
    else { return }
    // Continuity is binding authority, not deferred notice presentation.
    // Preserve it once this live envelope is validated, including while busy.
    if boundIdentity == nil { boundIdentity = envelope.observation.metadata?.identity }
    if value.operationID != nil || value.composing {
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
    guard !invalidated, detachment == nil, !endpointTransition, let binding else {
      throw FileStateEndpointError.unavailable
    }
    endpointTransition = true
    defer { endpointTransition = false }
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
    guard !invalidated, !endpointTransition, token.owner == endpointOwner,
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
  func invalidate() {
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
    guard let value = boundLive(), let token = state.token,
      state.admission(
        for: action, dirty: value.dirty, pendingPublication: value.pendingPublicationID != nil,
        busy: value.operationID != nil, composing: value.composing, recording: value.recording,
        quitting: value.quitting, closed: value.closed) != .refused,
      currentToken(
        for: Envelope(
          observation: state.observation!, token: token,
          authority: authorityID, bindingID: value.bindingID, generation: value.deliveryGeneration))
        == token
    else { return nil }
    return FileStateActionContext(
      live: value, authorityID: authorityID, token: token, action: action)
  }
  func isCurrent(_ context: FileStateActionContext) -> Bool {
    guard let current = captureAction(context.action) else { return false }
    return current.live == context.live && current.authorityID == context.authorityID
      && current.token == context.token
  }
  func isCurrent(_ context: FileStateActionContext, owningOperation: UUID) -> Bool {
    guard context.live.operationID == nil, let value = boundLive(),
      value.operationID == owningOperation, context.authorityID == authorityID,
      state.token == context.token, let observation = state.observation,
      currentToken(
        for: Envelope(
          observation: observation, token: context.token,
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
