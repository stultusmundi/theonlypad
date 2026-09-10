import Foundation

@testable import PadCore

final class Handle: MonitorHandle, ManualHandle, @unchecked Sendable {
  private let lock = NSLock()
  private var token: FileObservationToken?
  private var cancelled = false
  var documentID = UUID()
  var epoch: UInt64 = 1
  var baselineRevision: UInt64 = 1
  var boundIdentity: FileTargetIdentity?
  var onCancel: (@Sendable () -> Void)?
  var snapshot: MonitorSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return MonitorSnapshot(
      currentToken: token, cancelled: cancelled, documentID: documentID, epoch: epoch,
      baselineRevision: baselineRevision, boundIdentity: boundIdentity)
  }
  func issue(_ value: FileObservationToken?) {
    lock.lock()
    token = value
    lock.unlock()
  }
  func cancel() { _ = cancelAndSnapshot() }
  func cancelAndSnapshot() -> MonitorSnapshot {
    lock.lock()
    cancelled = true
    let result = MonitorSnapshot(
      currentToken: token, cancelled: cancelled, documentID: documentID, epoch: epoch,
      baselineRevision: baselineRevision, boundIdentity: boundIdentity)
    lock.unlock()
    onCancel?()
    return result
  }
}
@MainActor final class Client: MonitorClient {
  var registrations = 0
  var requests = 0
  var failRegister = false
  var failRebind = false
  var inlineFailure = false
  var handle = Handle()
  var receive: (@Sendable (FileObservationToken, DiskObservation) -> Void)?
  var manuals: [UUID: @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void] = [:]
  var latestID: UUID?
  var passedIdentity: FileTargetIdentity?
  var registeredIdentity: FileTargetIdentity?
  func register(
    id: UUID, url: URL, baseline: Data, revision: UInt64, boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> any MonitorHandle {
    if failRegister { throw MonitorFailure.capacity }
    registrations += 1
    handle = Handle()
    handle.documentID = id
    handle.baselineRevision = revision
    handle.boundIdentity = boundIdentity
    registeredIdentity = boundIdentity
    self.receive = receive
    return handle
  }
  func rebind(id: UUID, url: URL, baseline: Data, revision: UInt64) throws {
    if failRebind { throw MonitorFailure.unavailable }
    handle.issue(nil)
    handle.baselineRevision = revision
    handle.epoch += 1
    handle.boundIdentity = nil
  }
  func requestCheck(id: UUID) { requests += 1 }
  func checkOnce(
    requestID: UUID, id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void
  ) -> any ManualHandle {
    latestID = requestID
    passedIdentity = boundIdentity
    manuals[requestID] = receive
    let handle = Handle()
    handle.onCancel = { receive(requestID, .failure(.cancelled)) }
    if inlineFailure { receive(requestID, .failure(.capacity)) }
    return handle
  }
}
@MainActor final class Fixture {
  let client = Client()
  var live = FileStateLiveContext(
    documentID: UUID(), bindingID: UUID(), baselineRevision: 1,
    url: URL(fileURLWithPath: "/synthetic/file"))
  var changes = 0
  lazy var bridge = DocumentFileStateController(
    documentID: live.documentID, client: client,
    liveContext: { [weak self] in self?.live }, onChange: { [weak self] in self?.changes += 1 })
  func token(_ sequence: UInt64, epoch: UInt64 = 1) -> FileObservationToken {
    FileObservationToken(
      documentID: live.documentID, epoch: epoch, baselineRevision: live.baselineRevision,
      sequence: sequence)
  }
  func send(_ sequence: UInt64, observation: DiskObservation = changed, epoch: UInt64 = 1) {
    let value = token(sequence, epoch: epoch)
    client.handle.issue(value)
    client.receive?(value, observation)
  }
}
let identity = FileTargetIdentity(parentDevice: 1, parentInode: 2, fileDevice: 1, fileInode: 3)
let metadata = FileMetadata(
  identity: identity, byteCount: 1, mode: 0, flags: 0, modificationSeconds: 0,
  modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0)
let changed = DiskObservation(
  metadata: metadata, content: .differsFromBaseline, locationProblem: nil, readOnlyHint: false,
  movedCandidate: nil)
let matching = DiskObservation(
  metadata: metadata, content: .matchesBaseline, locationProblem: nil, readOnlyHint: false,
  movedCandidate: nil)
@MainActor final class EndpointCallbackLifetime {}
@main struct Harness {
  @MainActor static func settle() async { for _ in 0..<12 { await Task.yield() } }
  @MainActor static func main() async {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      if !value {
        print("FAIL: \(message)")
        exit(1)
      }
      checks += 1
    }
    let refusedSuspend = Fixture()
    refusedSuspend.live.ownershipGeneration = UUID()
    refusedSuspend.bridge.adoptBaseline(bytes: Data([1]))
    do {
      let old = refusedSuspend.live.ownershipGeneration!
      let token = try refusedSuspend.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: old)
      do {
        try refusedSuspend.bridge.suspendOwnershipTransfer(
          token, validateLease: { throw FileStateEndpointError.stale })
        check(false, "lease refusal must throw")
      } catch {}
      try refusedSuspend.bridge.attachOwnershipTransfer(
        token, expectedPreviousOwnership: old, newOwnership: old,
        liveContext: { refusedSuspend.live }, onChange: {}, validateLease: {})
      try refusedSuspend.bridge.finishOwnershipTransfer(token, validateLease: {})
      check(
        true,
        "explicit prestage restoration recovers reservation whose suspend refused before effects")
    } catch { check(false, "prestage suspend refusal remains recoverable under exact valid lease") }
    refusedSuspend.bridge.invalidate()
    let cancelledMove = Fixture()
    cancelledMove.live.ownershipGeneration = UUID()
    cancelledMove.bridge.adoptBaseline(bytes: Data([1]))
    cancelledMove.send(1)
    await settle()
    let cancelledAction = cancelledMove.bridge.captureAction(.reload)!
    do {
      let original = cancelledMove.live.ownershipGeneration!
      let receipt = try cancelledMove.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: original)
      try cancelledMove.bridge.suspendOwnershipTransfer(receipt, validateLease: {})
      try cancelledMove.bridge.suspendOwnershipTransfer(receipt, validateLease: {})
      try cancelledMove.bridge.attachOwnershipTransfer(
        receipt, expectedPreviousOwnership: original, newOwnership: original,
        liveContext: { cancelledMove.live }, onChange: {}, validateLease: {})
      try cancelledMove.bridge.finishOwnershipTransfer(receipt, validateLease: {})
      check(
        !cancelledMove.bridge.isCurrent(cancelledAction),
        "cancelled prestage move cannot revive old action")
      check(
        cancelledMove.bridge.captureAction(.reload) != nil,
        "same ownership cancellation restores current endpoint admission")
    } catch {
      check(false, "prestage suspended transfer safely cancels without ownership rotation")
    }
    cancelledMove.bridge.invalidate()
    let moving = Fixture()
    moving.live.ownershipGeneration = UUID()
    moving.bridge.adoptBaseline(bytes: Data([1]))
    moving.send(1)
    await settle()
    let originalStateToken = moving.bridge.state.token
    let oldAction = moving.bridge.captureAction(.reload)!
    _ = moving.bridge.keepBuffer(moving.bridge.captureAction(.keepBuffer)!)
    do {
      let old = moving.live.ownershipGeneration!
      let token = try moving.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: old)
      // Queued before suspend; current registration token remains 2.
      moving.send(2, observation: matching)
      try moving.bridge.suspendOwnershipTransfer(token, validateLease: {})
      let target = UUID()
      moving.live.ownershipGeneration = target
      try moving.bridge.attachOwnershipTransfer(
        token, expectedPreviousOwnership: old, newOwnership: target, liveContext: { moving.live },
        onChange: { moving.changes += 1 }, validateLease: {})
      check(
        moving.bridge.captureAction(.reload) == nil,
        "active ownership transfer blocks action capture")
      check(!moving.bridge.isCurrent(oldAction), "old endpoint action cannot act during transfer")
      // A second rotation after target attachment exercises rollback without replaying an old receipt.
      try moving.bridge.suspendOwnershipTransfer(token, validateLease: {})
      let rollback = UUID()
      moving.live.ownershipGeneration = rollback
      // Delivered while suspended, before rollback attachment.
      moving.send(3, observation: matching)
      try moving.bridge.attachOwnershipTransfer(
        token, expectedPreviousOwnership: target, newOwnership: rollback,
        liveContext: { moving.live }, onChange: { moving.changes += 1 }, validateLease: {})
      try moving.bridge.finishOwnershipTransfer(token, validateLease: {})
      await settle()
      check(moving.client.registrations == 1, "ownership move preserves process registration")
      check(
        moving.bridge.state.token == originalStateToken,
        "old and suspended queued generations cannot replace observed state")
      check(!moving.bridge.state.noticeIsProminent, "ownership move preserves dismissed facet")
      check(
        !moving.bridge.isCurrent(oldAction), "old ownership action remains stale after rollback")
      moving.send(4)
      await settle()
      check(
        moving.bridge.state.token == moving.token(4),
        "fresh generation observation accepts after finish")
      check(
        !moving.bridge.state.noticeIsProminent,
        "same service epoch preserves dismissal on unchanged fresh observation")
      let invalidation = try moving.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: rollback)
      try moving.bridge.suspendOwnershipTransfer(invalidation, validateLease: {})
      moving.live.ownershipGeneration = UUID()
      try moving.bridge.attachOwnershipTransfer(
        invalidation, expectedPreviousOwnership: rollback,
        newOwnership: moving.live.ownershipGeneration!, liveContext: { moving.live }, onChange: {},
        validateLease: {})
      moving.bridge.invalidate()
      check(
        moving.bridge.ownershipTransferInvalidationRequested,
        "ordinary invalidation is explicit deferred state")
      do {
        try moving.bridge.finishOwnershipTransfer(invalidation, validateLease: {})
        check(false, "unresolved invalidation blocks finish")
      } catch { check(true, "unresolved invalidation blocks finish") }
      do {
        try moving.bridge.resolveOwnershipTransferInvalidation(
          invalidation, validateLease: { moving.bridge.invalidate() })
        check(false, "reentrant newer invalidation cannot be erased by resolving older request")
      } catch { check(true, "reentrant newer invalidation remains retained") }
      try moving.bridge.resolveOwnershipTransferInvalidation(invalidation, validateLease: {})
      try moving.bridge.finishOwnershipTransfer(invalidation, validateLease: {})
    } catch { check(false, "ownership transition must complete with exact lease: \(error)") }
    moving.bridge.invalidate()
    let manualMove = Fixture()
    manualMove.live.ownershipGeneration = UUID()
    manualMove.client.failRegister = true
    manualMove.bridge.adoptBaseline(bytes: Data([1]))
    manualMove.bridge.checkAgain()
    let manualRequest = manualMove.client.latestID!
    let notice = manualMove.bridge.manualNotice
    let failureBeforeMove = manualMove.bridge.lastFailure
    do {
      let old = manualMove.live.ownershipGeneration!
      let receipt = try manualMove.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: old)
      try manualMove.bridge.suspendOwnershipTransfer(receipt, validateLease: {})
      manualMove.live.ownershipGeneration = UUID()
      try manualMove.bridge.attachOwnershipTransfer(
        receipt, expectedPreviousOwnership: old, newOwnership: manualMove.live.ownershipGeneration!,
        liveContext: { manualMove.live }, onChange: {}, validateLease: {})
      try manualMove.bridge.finishOwnershipTransfer(receipt, validateLease: {})
      manualMove.client.manuals[manualRequest]?(manualRequest, .success(changed))
      await settle()
      check(
        manualMove.bridge.state.observation == nil,
        "cancelled manual request cannot deliver across ownership move")
      check(
        manualMove.bridge.manualNotice == notice
          && manualMove.bridge.lastFailure == failureBeforeMove,
        "manual mode and failure survive without automatic registration retry")
      let disposal = try manualMove.bridge.reserveOwnershipTransfer(
        transactionID: UUID(), expectedOwnership: manualMove.live.ownershipGeneration!)
      try manualMove.bridge.invalidateOwnershipTransfer(disposal, validateDisposal: {})
      check(
        manualMove.bridge.captureAction(.reload) == nil, "explicit transfer disposal retires bridge"
      )
    } catch { check(false, "manual ownership transition succeeds") }
    let detached = Fixture()
    detached.live.ownershipGeneration = UUID()
    detached.bridge.adoptBaseline(bytes: Data([1]))
    detached.send(1)
    await settle()
    let staleReceiver = detached.client.receive
    var cancellationSawNoAuthority = false
    detached.client.handle.onCancel = {
      MainActor.assumeIsolated {
        cancellationSawNoAuthority = detached.bridge.captureAction(.reload) == nil
        detached.bridge.checkAgain()
        detached.bridge.reconcileEligibility()
      }
    }
    do {
      let ticket = try detached.bridge.detachEndpoint()
      check(cancellationSawNoAuthority, "inline cancel sees endpoint authority already retired")
      check(detached.client.handle.snapshot.cancelled, "detach cancels actual registration")
      check(
        detached.bridge.captureAction(.reload) == nil, "detached endpoint has no action authority")
      try detached.bridge.reattachEndpoint(
        ticket, expectedBinding: FileStateBindingIdentity(detached.live),
        liveContext: { detached.live }, onChange: {})
      check(
        detached.client.registeredIdentity == identity,
        "reattachment retains accepted parent identity")
      let oldToken = detached.token(1)
      detached.client.handle.issue(oldToken)
      staleReceiver?(oldToken, changed)
      await settle()
      check(
        detached.bridge.state.token == nil,
        "old queued delivery cannot populate new endpoint authority")
    } catch { check(false, "valid endpoint detach and reattach succeeds") }
    do {
      let ticket = try detached.bridge.detachEndpoint()
      let registrations = detached.client.registrations
      var wrong = detached.live
      wrong.baselineRevision += 1
      do {
        try detached.bridge.reattachEndpoint(
          ticket, expectedBinding: FileStateBindingIdentity(wrong),
          liveContext: { wrong }, onChange: {})
        check(false, "wrong baseline must refuse reattachment")
      } catch {}
      check(
        detached.client.registrations == registrations, "failed preflight leaves detached state")
      var wrongOwner = detached.live
      wrongOwner.ownershipGeneration = UUID()
      do {
        try detached.bridge.reattachEndpoint(
          ticket, expectedBinding: ticket.binding,
          liveContext: { wrongOwner }, onChange: {})
        check(false, "different model ownership must refuse")
      } catch {}
      detached.client.failRegister = true
      var newRenders = 0
      let oldChanges = detached.changes
      try detached.bridge.reattachEndpoint(
        ticket, expectedBinding: ticket.binding,
        liveContext: { detached.live }, onChange: { newRenders += 1 })
      check(
        detached.bridge.manualNotice != nil && newRenders > 0,
        "reattachment registration failure exposes manual fallback on new endpoint")
      check(detached.changes == oldChanges, "reattachment never invokes old UI callback")
      detached.bridge.checkAgain()
      check(
        detached.client.passedIdentity == identity, "manual reattachment retains parent continuity")
      do {
        try detached.bridge.reattachEndpoint(
          ticket, expectedBinding: ticket.binding,
          liveContext: { detached.live }, onChange: {})
        check(false, "consumed detachment cannot attach twice")
      } catch {}
      let invalidatingTicket = try detached.bridge.detachEndpoint()
      do {
        try detached.bridge.reattachEndpoint(
          invalidatingTicket, expectedBinding: invalidatingTicket.binding,
          liveContext: {
            let lifetime = Fixture()
            lifetime.bridge.adoptBaseline(bytes: Data([1]))
            do {
              let token = try lifetime.bridge.detachEndpoint()
              var holder: EndpointCallbackLifetime? = EndpointCallbackLifetime()
              weak var retained = holder
              try lifetime.bridge.reattachEndpoint(
                token, expectedBinding: token.binding,
                liveContext: { [value = holder!] in
                  withExtendedLifetime(value) { lifetime.live }
                }, onChange: { [value = holder!] in withExtendedLifetime(value) {} })
              holder = nil
              check(retained != nil, "attached endpoint owns its callback context")
              _ = try lifetime.bridge.detachEndpoint()
              check(retained == nil, "detachment releases old endpoint callback context")
            } catch { check(false, "callback lifetime detach protocol succeeds") }
            lifetime.bridge.invalidate()
            detached.bridge.invalidate()
            return detached.live
          }, onChange: {})
        check(false, "reentrant invalidation must prevent reattachment")
      } catch {}
      check(
        detached.bridge.captureAction(.reload) == nil,
        "reentrant terminal invalidation preserves refusal")
    } catch { check(false, "detachment retry protocol succeeds") }
    detached.bridge.invalidate()
    let recursiveClient = Client()
    var recursiveLive = FileStateLiveContext(
      documentID: UUID(), bindingID: UUID(), baselineRevision: 1,
      url: URL(fileURLWithPath: "/synthetic/recursive"))
    var recurse = false
    var nestedRefused = false
    var recursiveBridge: DocumentFileStateController!
    recursiveBridge = DocumentFileStateController(
      documentID: recursiveLive.documentID, client: recursiveClient,
      liveContext: {
        if recurse {
          recurse = false
          do { _ = try recursiveBridge.detachEndpoint() } catch { nestedRefused = true }
        }
        return recursiveLive
      }, onChange: {})
    recursiveBridge.adoptBaseline(bytes: Data([1]))
    recurse = true
    do {
      let token = try recursiveBridge.detachEndpoint()
      check(nestedRefused, "detach context callback cannot recursively detach")
      var changedDuringRender = false
      do {
        try recursiveBridge.reattachEndpoint(
          token, expectedBinding: token.binding,
          liveContext: { recursiveLive },
          onChange: {
            guard !changedDuringRender else { return }
            changedDuringRender = true
            recursiveLive.bindingID = UUID()
            recursiveLive.baselineRevision += 1
            recursiveBridge.adoptBaseline(bytes: Data([2]))
          })
        check(false, "reattach cannot report success after callback replaces baseline")
      } catch {}
      check(changedDuringRender, "new endpoint render mutation regression exercised")
    } catch { check(false, "outer detach survives refused recursive detach") }
    recursiveBridge.invalidate()
    let f = Fixture()
    f.bridge.adoptBaseline(bytes: Data([1]))
    check(f.client.registrations == 1, "baseline must register once")
    f.send(1)
    f.client.handle.issue(f.token(2))
    await settle()
    check(f.bridge.state.token == nil, "second hop rejects token superseded before adoption")
    f.send(2)
    await settle()
    check(f.bridge.state.token == f.token(2), "current registered observation accepted")
    f.bridge.checkAgain()
    f.client.receive?(f.token(2), matching)
    await settle()
    check(
      f.bridge.state.observation?.content == .differsFromBaseline,
      "explicit request excludes old snapshot")
    f.send(3, observation: matching)
    await settle()
    check(f.bridge.state.observation?.content == .matchesBaseline, "later explicit check accepted")
    let oldToken = f.token(3)
    f.live.bindingID = UUID()
    f.live.baselineRevision = 2
    f.bridge.adoptBaseline(bytes: Data([2]))
    f.client.receive?(oldToken, changed)
    await settle()
    check(f.bridge.state.token == nil, "rebind rejects prior baseline")
    f.send(1, epoch: 2)
    await settle()
    check(f.bridge.state.token == f.token(1, epoch: 2), "same receiver accepts rebound epoch")
    let oldReceive = f.client.receive
    let oldHandle = f.client.handle
    f.bridge.useManualFallback()
    f.bridge.checkAgain()
    check(oldHandle.snapshot.cancelled, "fallback cancels registered authority")
    check(f.client.passedIdentity == identity, "manual fallback retains parent continuity")
    let firstManual = f.client.latestID!
    f.client.manuals[firstManual]?(firstManual, .success(changed))
    await settle()
    check(
      f.bridge.state.observation?.content == .differsFromBaseline && f.bridge.manualNotice != nil,
      "manual success retains explicit unavailable notice")
    oldReceive?(f.token(99, epoch: 2), matching)
    await settle()
    check(
      f.bridge.state.observation?.content == .differsFromBaseline,
      "registered callback cannot replace manual result")
    let action = f.bridge.captureAction(.openDiskCopy)!
    f.live.pendingPublicationID = UUID()
    check(!f.bridge.isCurrent(action), "pending identity invalidates action without text change")
    f.live.pendingPublicationID = nil
    f.bridge.checkAgain()
    let staleManual = f.client.latestID!
    f.bridge.checkAgain()
    let newManual = f.client.latestID!
    f.client.manuals[staleManual]?(staleManual, .success(matching))
    await settle()
    check(f.bridge.state.token == nil, "superseded manual callback cannot adopt")
    f.client.manuals[newManual]?(newManual, .success(changed))
    await settle()
    check(
      f.bridge.state.observation?.content == .differsFromBaseline,
      "new manual request survives previous cancellation")
    f.client.inlineFailure = true
    f.bridge.checkAgain()
    await settle()
    check(
      f.bridge.lastFailure != nil && f.bridge.state.token == nil,
      "inline capacity callback handled after preissuance")
    f.client.inlineFailure = false
    f.bridge.retryRegistration()
    f.send(1, epoch: 4)
    await settle()
    check(
      f.bridge.manualNotice == nil && f.bridge.state.token == f.token(1, epoch: 4),
      "retry switches authority to registration")
    f.live.operationID = UUID()
    f.send(2, epoch: 4)
    await settle()
    check(f.bridge.state.token == f.token(1, epoch: 4), "busy observation deferred")
    f.live.operationID = nil
    f.bridge.reconcileEligibility()
    check(
      f.bridge.state.token == f.token(2, epoch: 4),
      "current deferred observation accepted after busy")
    f.live.composing = true
    f.send(3, epoch: 4)
    await settle()
    f.live.bindingID = UUID()
    f.live.baselineRevision += 1
    f.bridge.adoptBaseline(bytes: Data([3]))
    f.live.composing = false
    f.bridge.reconcileEligibility()
    check(
      f.bridge.state.token == nil, "baseline adoption discards deferred composition observation")
    f.bridge.useManualFallback()
    f.bridge.checkAgain()
    let quitID = f.client.latestID!
    f.live.quitting = true
    f.live.deliveryGeneration = UUID()
    f.bridge.reconcileEligibility()
    f.live.quitting = false
    f.live.deliveryGeneration = UUID()
    f.bridge.reconcileEligibility()
    f.client.manuals[quitID]?(quitID, .success(changed))
    await settle()
    check(f.bridge.state.token == nil, "manual callback cannot cross quit veto generation")
    f.bridge.checkAgain()
    let closeID = f.client.latestID!
    let before = f.changes
    f.bridge.invalidate()
    f.client.manuals[closeID]?(closeID, .success(changed))
    await settle()
    check(
      f.bridge.state.token == nil && f.changes == before, "close rejects callback without late UI")
    let g = Fixture()
    g.client.failRegister = true
    g.bridge.adoptBaseline(bytes: Data([1]))
    check(g.bridge.manualNotice != nil, "capacity refusal exposes manual fallback")
    g.bridge.checkAgain()
    check(g.client.passedIdentity == nil, "never bound manual has no invented identity")
    let id = g.client.latestID!
    let originalLive = g.live
    g.client.manuals[id]?(id, .success(matching))
    await settle()
    check(g.live == originalLive, "observations never modify document authority")
    let a = Fixture()
    a.bridge.adoptBaseline(bytes: Data([1]))
    a.send(1)
    await settle()
    let captured = a.bridge.captureAction(.openDiskCopy)!
    let baselineLive = a.live
    a.live.editRevision += 1
    check(!a.bridge.isCurrent(captured), "edit revision invalidates action")
    a.live = baselineLive
    a.live.hasBOM.toggle()
    check(!a.bridge.isCurrent(captured), "BOM conversion invalidates action")
    a.live = baselineLive
    a.live.encoding = .utf16LE
    check(!a.bridge.isCurrent(captured), "encoding conversion invalidates action")
    a.live = baselineLive
    a.live.operationID = UUID()
    check(!a.bridge.isCurrent(captured), "busy operation blocks action")
    a.live = baselineLive
    a.live.composing = true
    check(!a.bridge.isCurrent(captured), "composition blocks direct action")
    a.live = baselineLive
    a.live.recording = true
    check(a.bridge.captureAction(.reload) == nil, "macro recording vetoes reload")
    a.live = baselineLive
    check(a.bridge.isCurrent(captured), "unchanged copied action context remains current")
    a.live.pendingPublicationID = UUID()
    let uncertain = a.bridge.captureAction(.openDiskCopy)!
    check(a.bridge.isCurrent(uncertain), "copied pending UUID keeps same attempt identity")
    a.live.pendingPublicationID = UUID()
    check(!a.bridge.isCurrent(uncertain), "equal-byte new pending instance invalidates action")
    a.live = baselineLive
    a.client.handle.issue(a.token(2))
    check(
      !a.bridge.isCurrent(captured), "new service issuance invalidates accepted action immediately")
    a.send(2)
    a.live.deliveryGeneration = UUID()
    await settle()
    check(
      a.bridge.state.token == a.token(1),
      "registered callback cannot cross application-generation hop")
    a.bridge.reconcileEligibility()
    a.send(3)
    await settle()
    check(a.bridge.state.token == a.token(3), "registered delivery resumes in new generation")
    a.live.operationID = UUID()
    a.send(4)
    await settle()
    a.client.handle.issue(a.token(5))
    a.live.operationID = nil
    let requests = a.client.requests
    a.bridge.reconcileEligibility()
    check(
      a.client.requests == requests + 1 && a.bridge.state.token == a.token(3),
      "stale deferred observation triggers one reconciliation")
    a.client.failRebind = true
    a.live.bindingID = UUID()
    a.live.baselineRevision += 1
    a.bridge.adoptBaseline(bytes: Data([7]))
    check(
      a.client.handle.snapshot.cancelled && a.bridge.manualNotice != nil,
      "rebind failure retires old registration and exposes fallback")
    a.bridge.checkAgain()
    let fallbackID = a.client.latestID!
    a.client.manuals[fallbackID]?(fallbackID, .success(changed))
    await settle()
    a.client.failRegister = true
    a.bridge.retryRegistration()
    a.bridge.checkAgain()
    check(
      a.client.passedIdentity == identity && a.bridge.manualNotice != nil,
      "failed retry preserves accepted parent continuity and manual notice")
    let continuityID = a.client.latestID!
    let refused = DiskObservation(
      metadata: nil, content: .unavailable, locationProblem: .parentChanged, readOnlyHint: false,
      movedCandidate: nil)
    a.client.manuals[continuityID]?(continuityID, .success(refused))
    await settle()
    a.bridge.checkAgain()
    check(
      a.client.passedIdentity == identity,
      "parent-retarget refusal cannot erase retained continuity")
    a.live.url = nil
    a.live.bindingID = UUID()
    a.live.baselineRevision += 1
    a.bridge.adoptBaseline(bytes: Data())
    check(
      a.bridge.manualNotice == nil && a.bridge.state.token == nil,
      "scratch adoption removes file authority")
    let priorManual = a.client.latestID
    a.bridge.checkAgain()
    check(a.client.latestID == priorManual, "scratch cannot issue a manual original-path check")
    let busyFirst = Fixture()
    busyFirst.bridge.adoptBaseline(bytes: Data([1]))
    busyFirst.live.operationID = UUID()
    busyFirst.send(1)
    await settle()
    busyFirst.bridge.useManualFallback()
    busyFirst.bridge.checkAgain()
    check(
      busyFirst.client.passedIdentity == identity,
      "deferred first observation retains parent continuity before manual fallback")
    let resumed = Fixture()
    resumed.bridge.adoptBaseline(bytes: Data([1]))
    resumed.send(1)
    await settle()
    let queuedReceiver = resumed.client.receive!
    let queuedToken = resumed.token(1)
    resumed.live.quitting = true
    resumed.live.deliveryGeneration = UUID()
    resumed.bridge.reconcileEligibility()
    resumed.live.quitting = false
    resumed.live.deliveryGeneration = UUID()
    resumed.bridge.reconcileEligibility()
    queuedReceiver(queuedToken, changed)
    await settle()
    check(
      resumed.bridge.state.token == nil,
      "callback invoked after resume cannot satisfy old issued-token request floor")
    resumed.live.bindingID = UUID()
    resumed.live.baselineRevision += 1
    resumed.bridge.adoptBaseline(bytes: Data([2]))
    check(
      resumed.client.handle.snapshot.currentToken == nil, "rebind test begins with nil live token")
    resumed.live.quitting = true
    resumed.live.deliveryGeneration = UUID()
    resumed.bridge.reconcileEligibility()
    resumed.live.quitting = false
    resumed.live.deliveryGeneration = UUID()
    resumed.bridge.reconcileEligibility()
    queuedReceiver(queuedToken, changed)
    await settle()
    check(resumed.bridge.state.token == nil, "nil-token resume cannot resurrect old callback")
    let undelivered = Fixture()
    undelivered.bridge.adoptBaseline(bytes: Data([1]))
    undelivered.client.handle.boundIdentity = identity  // Service bound before first callback.
    undelivered.bridge.useManualFallback()
    undelivered.bridge.checkAgain()
    check(
      undelivered.client.passedIdentity == identity,
      "atomic handoff retains undelivered first binding")
    undelivered.bridge.retryRegistration()
    check(
      undelivered.client.registeredIdentity == identity,
      "retry registration retains prior parent continuity")
    let failedRebind = Fixture()
    failedRebind.bridge.adoptBaseline(bytes: Data([1]))
    failedRebind.client.handle.boundIdentity = identity
    failedRebind.client.failRebind = true
    failedRebind.live.bindingID = UUID()
    failedRebind.live.baselineRevision += 1
    failedRebind.bridge.adoptBaseline(bytes: Data([2]))
    failedRebind.bridge.checkAgain()
    check(
      failedRebind.client.passedIdentity == nil,
      "failed rebind cannot inherit identity from old baseline receipt")
    for action in [FileConflictAction.reload, .openDiskCopy] {
      let owned = Fixture()
      owned.bridge.adoptBaseline(bytes: Data([1]))
      owned.send(1)
      await settle()
      let context = owned.bridge.captureAction(action)!
      let operation = UUID()
      check(
        !owned.bridge.isCurrent(context, owningOperation: operation),
        "operation must actually be live")
      owned.live.operationID = operation
      check(
        owned.bridge.isCurrent(context, owningOperation: operation),
        "admitted action remains current during its own operation")
      check(!owned.bridge.isCurrent(context), "original validator retains busy rejection")
      check(
        owned.bridge.captureAction(action) == nil, "new action admission remains blocked while busy"
      )
      let ownedLive = owned.live
      let mutations: [(String, (inout FileStateLiveContext) -> Void)] = [
        ("newer operation", { $0.operationID = UUID() }),
        ("finished operation", { $0.operationID = nil }),
        ("edit revision", { $0.editRevision += 1 }),
        ("encoding", { $0.encoding = .utf16LE }),
        ("BOM", { $0.hasBOM.toggle() }),
        ("dirty", { $0.dirty.toggle() }),
        ("pending publication identity", { $0.pendingPublicationID = UUID() }),
        ("baseline revision", { $0.baselineRevision += 1 }),
        ("binding identity", { $0.bindingID = UUID() }),
        ("source URL", { $0.url = URL(fileURLWithPath: "/synthetic/other") }),
        ("delivery generation", { $0.deliveryGeneration = UUID() }),
        ("closed", { $0.closed = true }),
        ("quitting", { $0.quitting = true }),
        ("recording", { $0.recording = true }),
        ("composition", { $0.composing = true }),
      ]
      for (name, mutate) in mutations {
        mutate(&owned.live)
        check(
          !owned.bridge.isCurrent(context, owningOperation: operation),
          "own-operation action rejects changed " + name)
        owned.live = ownedLive
      }
      check(
        !owned.bridge.isCurrent(context, owningOperation: UUID()),
        "caller cannot substitute another operation UUID")
      let fabricatedBusyContext = FileStateActionContext(
        live: owned.live, authorityID: context.authorityID,
        token: context.token, action: context.action)
      check(
        !owned.bridge.isCurrent(fabricatedBusyContext, owningOperation: operation),
        "validator requires pre-operation capture")
      owned.client.handle.issue(owned.token(2))
      check(
        !owned.bridge.isCurrent(context, owningOperation: operation),
        "new service issuance invalidates owned action")
      owned.client.handle.issue(context.token)
      owned.client.handle.cancel()
      check(
        !owned.bridge.isCurrent(context, owningOperation: operation),
        "cancelled registration invalidates owned action")
    }
    let manualOwned = Fixture()
    manualOwned.client.failRegister = true
    manualOwned.bridge.adoptBaseline(bytes: Data([1]))
    manualOwned.bridge.checkAgain()
    let manualID = manualOwned.client.latestID!
    manualOwned.client.manuals[manualID]?(manualID, .success(changed))
    await settle()
    let manualContext = manualOwned.bridge.captureAction(.openDiskCopy)!
    let manualOperation = UUID()
    manualOwned.live.operationID = manualOperation
    check(
      manualOwned.bridge.isCurrent(manualContext, owningOperation: manualOperation),
      "manual observation supports exact owning operation")
    manualOwned.bridge.checkAgain()
    check(
      !manualOwned.bridge.isCurrent(manualContext, owningOperation: manualOperation),
      "new manual request invalidates owned action")
    let kept = Fixture()
    kept.bridge.adoptBaseline(bytes: Data([1]))
    kept.send(1)
    await settle()
    let keepContext = kept.bridge.captureAction(.keepBuffer)!
    let keepLive = kept.live
    let noticeToken = kept.bridge.state.token
    let noticeObservation = kept.bridge.state.observation
    let wrongAction = kept.bridge.captureAction(.openDiskCopy)!
    let changesBeforeRefusal = kept.changes
    check(!kept.bridge.keepBuffer(wrongAction), "different action cannot dismiss notice")
    check(
      kept.bridge.state.noticeIsProminent && kept.changes == changesBeforeRefusal,
      "wrong dismissal does not render or suppress notice")
    check(kept.bridge.keepBuffer(keepContext), "current Keep Buffer dismisses notice")
    check(
      !kept.bridge.state.noticeIsProminent && kept.changes == changesBeforeRefusal + 1,
      "dismissal renders exactly once")
    check(
      kept.live == keepLive && kept.bridge.state.token == noticeToken
        && kept.bridge.state.observation?.content == noticeObservation?.content,
      "Keep Buffer preserves exact document authority and disk facts")
    kept.send(2, observation: matching)
    await settle()
    kept.send(3)
    await settle()
    let changesBeforeStale = kept.changes
    check(!kept.bridge.keepBuffer(keepContext), "old token cannot dismiss newer notice")
    check(
      kept.bridge.state.noticeIsProminent && kept.changes == changesBeforeStale,
      "stale dismissal preserves newer notice and does not render")
    let currentKeep = kept.bridge.captureAction(.keepBuffer)!
    kept.bridge.invalidate()
    check(!kept.bridge.keepBuffer(currentKeep), "closed bridge refuses notice dismissal")
    let located = Fixture()
    located.bridge.adoptBaseline(bytes: Data([1]))
    let locatedOldHandle = located.client.handle
    let candidate = FileTargetIdentity(
      parentDevice: 10, parentInode: 20, fileDevice: 10, fileInode: 30)
    located.bridge.adoptBaseline(bytes: Data([1]), validatedIdentity: candidate)
    check(
      located.client.registrations == 2,
      "validated identity forces fresh registration at same URL and revision")
    check(locatedOldHandle.snapshot.cancelled, "validated adoption cancels old registration")
    check(
      located.client.registeredIdentity == candidate, "fresh registration carries candidate parent")
    located.client.failRegister = true
    located.live.bindingID = UUID()
    located.live.baselineRevision += 1
    located.bridge.adoptBaseline(bytes: Data([1]), validatedIdentity: candidate)
    check(
      located.bridge.lastFailure == .capacity, "validated adoption exposes registration capacity")
    located.bridge.checkAgain()
    check(
      located.client.passedIdentity == candidate, "capacity manual check retains candidate identity"
    )
    located.client.failRegister = false
    located.bridge.retryRegistration()
    check(
      located.client.registeredIdentity == candidate,
      "retry registration retains candidate identity")
    located.bridge.invalidate()
    print("PASS \(checks) deterministic bridge assertions; no real monitor or GUI exercised")
  }
}
