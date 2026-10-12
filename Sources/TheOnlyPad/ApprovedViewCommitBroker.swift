// SPDX-License-Identifier: MIT
// Private approved-view transcript broker: exact approved actual writes, no writer attribution.
import Foundation
import PadCore

enum ApprovedHistoryAction: Equatable { case undo, redo, nestedUndo }
struct ApprovedViewRoute: Equatable {
  let lease: MacroBindingLease
  let viewID: ObjectIdentifier
  let paneID: UUID
  let windowID: ObjectIdentifier
  let managerID: ObjectIdentifier
  let generation: UInt64
}
struct ApprovedRecorderState: Equatable {
  let identity: MacroContextIdentity
  let active: Bool
  let firstReason: MacroRecordingGap?
  let compatibilityPhase: UInt8
  let saving: Bool
  let saveAttempt: UUID?
  let commands: [MacroCommand]
  let units: Int
}
struct ApprovedViewSnapshot: Equatable {
  let route: ApprovedViewRoute
  let recorder: ApprovedRecorderState
  let primitive: MacroContextPrimitiveState
  let revision: UInt64
  let closeMutation: UUID
  let bookmarks: DocumentBookmarks
  let pending: DocumentBookmarks?
  let pendingUndo: Bool
}
struct ApprovedHistoryInvocation: Equatable {
  fileprivate let id: UInt64
  fileprivate let brokerID: UUID
  fileprivate let root: UInt64
  let action: ApprovedHistoryAction
}
struct ApprovedDecisionCapture: Equatable {
  fileprivate let id: UInt64
  fileprivate let brokerID: UUID
}
struct ApprovedViewReservation {
  fileprivate let id: UInt64
  fileprivate let brokerID: UUID
  fileprivate let decision: UInt64
  fileprivate let invocation: UInt64
  fileprivate let barrier: UInt64?
  fileprivate let snapshot: ApprovedViewSnapshot
  fileprivate let range: NSRange
  fileprivate let replacement: String
  fileprivate let replacementCount: Int
  fileprivate let before: Int
  fileprivate let after: Int
}
extension ApprovedViewReservation {
  var lease: MacroBindingLease { snapshot.route.lease }
  var paneID: UUID { snapshot.route.paneID }
  var epoch: UUID { snapshot.recorder.identity.recordingEpoch }
  var unitCost: Int { replacementCount }
}
enum ApprovedBookkeepingEdge: Equatable { case clearPending, clearUndoFlag }

@MainActor final class ApprovedViewCommitBroker {
  private struct Invocation {
    let token: ApprovedHistoryInvocation
    let owner: ObjectIdentifier
    let manager: ObjectIdentifier
    let association: ApprovedViewRoute
    var finishRequested = false
  }
  private struct Decision {
    let token: ApprovedDecisionCapture
    let invocation: UInt64
    let family: UInt64
    let view: ObjectIdentifier
    let parentBarrier: UInt64?
    let snapshot: ApprovedViewSnapshot?
    let range: NSRange?
    let replacement: String?
    let before: Int?
    let replacementCount: Int?
    let singular: Bool
    var expectedClose: UUID?
    var expectedPending: DocumentBookmarks?
    var expectedUndo = false
    var edgeCount = 0
    var burned = false
    var finishRequested = false
  }
  private struct Pending {
    let decision: Decision
    let reservation: ApprovedViewReservation
  }
  private struct Barrier {
    let id: UInt64
    let decision: UInt64?
    var finishRequested = false
  }
  private let brokerID = UUID()
  private var serial: UInt64 = 0
  private var exhausted = false
  private var invocations: [Invocation] = []
  private var decisions: [Decision] = []
  private var barriers: [Barrier] = []
  private var pending: Pending?
  private var reserved: ApprovedViewReservation?
  private var capacityPoisoned = false

  private func available(_ contextCount: Int, _ contextAvailable: Bool) -> Bool {
    let used =
      invocations.count + decisions.count + barriers.count
      + (pending == nil ? 0 : 1) + (reserved == nil ? 0 : 1)
    guard contextAvailable, contextCount >= 0, contextCount < 64,
      used < 64 - contextCount, !exhausted, !capacityPoisoned
    else {
      burnAll()
      return false
    }
    return true
  }
  private func issue(_ contextCount: Int, _ contextAvailable: Bool) -> UInt64? {
    guard available(contextCount, contextAvailable) else { return nil }
    let (next, overflow) = serial.addingReportingOverflow(1)
    guard !overflow else {
      exhausted = true
      burnAll()
      return nil
    }
    serial = next
    return next
  }
  private func burnAll() {
    pending = nil
    reserved = nil
    for index in decisions.indices { decisions[index].burned = true }
  }
  func retire(owner: ObjectIdentifier, storage: ObjectIdentifier? = nil) {
    if let value = pending, value.reservation.snapshot.route.lease.controllerID == owner,
      storage == nil || value.reservation.snapshot.route.lease.storageID == storage
    {
      pending = nil
    }
    if let value = reserved, value.snapshot.route.lease.controllerID == owner,
      storage == nil || value.snapshot.route.lease.storageID == storage
    {
      reserved = nil
    }
    for index in decisions.indices {
      if let value = decisions[index].snapshot, value.route.lease.controllerID == owner,
        storage == nil || value.route.lease.storageID == storage
      {
        decisions[index].burned = true
      }
    }
  }
  func beginHistory(
    owner: ObjectIdentifier, manager: ObjectIdentifier, association: ApprovedViewRoute,
    action: ApprovedHistoryAction,
    contextCount: Int, contextAvailable: Bool
  ) -> ApprovedHistoryInvocation? {
    burnAll()  // A child can never revive an ancestor approval.
    guard let id = issue(contextCount, contextAvailable) else { return nil }
    let token = ApprovedHistoryInvocation(
      id: id, brokerID: brokerID, root: invocations.first?.token.root ?? id, action: action)
    invocations.append(
      Invocation(token: token, owner: owner, manager: manager, association: association))
    return token
  }
  func finishHistory(_ token: ApprovedHistoryInvocation) {
    guard let index = invocations.firstIndex(where: { $0.token == token }) else { return }
    for d in decisions.indices where decisions[d].invocation == token.id {
      decisions[d].burned = true
    }
    if pending?.reservation.invocation == token.id { pending = nil }
    if reserved?.invocation == token.id { reserved = nil }
    invocations[index].finishRequested = true
    if index != invocations.count - 1 { burnAll() }
    while invocations.last?.finishRequested == true { invocations.removeLast() }
  }
  func historyMatches(_ route: ApprovedViewRoute) -> Bool {
    guard let leaf = invocations.last, !leaf.finishRequested else { return false }
    return leaf.owner == route.lease.controllerID && leaf.manager == route.managerID
      && leaf.association.lease == route.lease && leaf.association.windowID == route.windowID
  }
  // Admission uses the actual lexical context and this broker's retained state.
  // One additional explicit frame must fit without borrowing a cleanup slot.
  func beginExplicitScope(
    in context: NativeMacroCommitContext,
    identity: MacroContextIdentity, primitive: MacroContextPrimitiveState,
    contract: MacroContextPrimitiveContract
  ) -> MacroContextScope? {
    let used =
      invocations.count + decisions.count + barriers.count
      + (pending == nil ? 0 : 1) + (reserved == nil ? 0 : 1)
    let contextCount = context.entryCount
    guard !context.overflowBarrierIsActive, contextCount >= 0, contextCount < 64,
      used <= 63 - contextCount
    else {
      burnAll()
      // Existing rejection invalidates frames without appending or popping entries.
      context.withRejectedCallbackBarrier {}
      return nil
    }
    // Preserve the context's own identifier-exhaustion and frame validation policy.
    return context.begin(
      origin: .explicitSource, identity: identity,
      primitive: primitive, contract: contract)
  }
  func beginBarrier(
    decision: ApprovedDecisionCapture? = nil,
    contextCount: Int, contextAvailable: Bool
  ) -> UInt64? {
    pending = nil
    reserved = nil
    // Reserve the broker and the existing context callback entry as one pair.
    // Count retained entries, including entries still awaiting lexical cleanup.
    guard contextCount >= 0, contextCount < 63,
      let id = issue(contextCount + 1, contextAvailable)
    else {
      burnAll()
      capacityPoisoned = true
      return nil
    }
    barriers.append(Barrier(id: id, decision: decision?.id))
    return id
  }
  func finishBarrier(_ id: UInt64?) {
    guard let id, let index = barriers.firstIndex(where: { $0.id == id }) else { return }
    barriers[index].finishRequested = true
    if index != barriers.count - 1 { burnAll() }
    while barriers.last?.finishRequested == true { barriers.removeLast() }
    if barriers.isEmpty, invocations.isEmpty, decisions.isEmpty { capacityPoisoned = false }
  }
  func beginDecision(
    view: ObjectIdentifier, snapshot: ApprovedViewSnapshot?,
    range: NSRange?, replacement: String?, before: Int?, replacementCount: Int?, singular: Bool,
    contextCount: Int, contextAvailable: Bool
  ) -> ApprovedDecisionCapture? {
    pending = nil
    reserved = nil
    guard let leaf = invocations.last, !leaf.finishRequested,
      let id = issue(contextCount, contextAvailable)
    else { return nil }
    let parent = decisions.last
    let sameFamily = parent?.view == view && parent?.invocation == leaf.token.id
    let family = sameFamily ? parent!.family : id
    if !sameFamily, parent != nil {
      for index in decisions.indices { decisions[index].burned = true }
    }
    let token = ApprovedDecisionCapture(id: id, brokerID: brokerID)
    decisions.append(
      Decision(
        token: token, invocation: leaf.token.id,
        family: family, view: view, parentBarrier: barriers.last?.id,
        snapshot: snapshot, range: range, replacement: replacement, before: before,
        replacementCount: replacementCount, singular: singular,
        expectedClose: snapshot?.closeMutation,
        expectedPending: snapshot?.pending, expectedUndo: snapshot?.pendingUndo ?? false))
    return token
  }
  private func familyIndex(view: ObjectIdentifier, range: NSRange, replacement: String)
    -> Int?
  {
    guard let current = decisions.last, barriers.last?.decision == current.token.id,
      let index = decisions.firstIndex(where: { $0.token.id == current.family }),
      decisions[index].view == view, decisions[index].range == range,
      let familyReplacement = decisions[index].replacement,
      familyReplacement.utf16.elementsEqual(replacement.utf16),
      invocations.last?.token.id == current.invocation
    else { return nil }
    return index
  }
  private func matches(_ decision: Decision, _ actual: ApprovedViewSnapshot) -> Bool {
    guard let initial = decision.snapshot else { return false }
    return !decision.burned && initial.route == actual.route
      && initial.recorder == actual.recorder && initial.primitive == actual.primitive
      && initial.revision == actual.revision && initial.bookmarks == actual.bookmarks
      && decision.expectedClose == actual.closeMutation
      && decision.expectedPending == actual.pending && decision.expectedUndo == actual.pendingUndo
      && historyMatches(actual.route)
  }
  func beginBookkeeping(
    view: ObjectIdentifier, range: NSRange, replacement: String,
    edge: ApprovedBookkeepingEdge, actual: ApprovedViewSnapshot
  ) -> ApprovedDecisionCapture? {
    guard let index = familyIndex(view: view, range: range, replacement: replacement) else {
      return nil
    }
    let expectedCount = edge == .clearPending ? 0 : 1
    guard decisions[index].edgeCount == expectedCount, matches(decisions[index], actual) else {
      decisions[index].burned = true
      return nil
    }
    return decisions[index].token
  }
  func finishBookkeeping(
    _ token: ApprovedDecisionCapture?, edge: ApprovedBookkeepingEdge,
    before: ApprovedViewSnapshot?, after: ApprovedViewSnapshot?
  ) {
    guard let token, let index = decisions.firstIndex(where: { $0.token == token }),
      let before, let after
    else { return }
    let old = decisions[index]
    guard old.snapshot != nil, !old.burned, let range = old.range,
      let replacement = old.replacement,
      before.route == after.route, before.recorder == after.recorder,
      before.primitive == after.primitive, before.revision == after.revision,
      before.bookmarks == after.bookmarks,
      familyIndex(view: old.view, range: range, replacement: replacement) == index
    else {
      decisions[index].burned = true
      return
    }
    let valid: Bool
    switch edge {
    case .clearPending:
      valid =
        old.edgeCount == 0 && after.pending == nil && before.pendingUndo == after.pendingUndo
        && before.closeMutation != after.closeMutation
    case .clearUndoFlag:
      valid =
        old.edgeCount == 1 && !after.pendingUndo && before.pending == after.pending
        && (before.pendingUndo
          ? before.closeMutation != after.closeMutation
          : before.closeMutation == after.closeMutation)
    }
    guard valid else {
      decisions[index].burned = true
      return
    }
    decisions[index].expectedClose = after.closeMutation
    decisions[index].expectedPending = after.pending
    decisions[index].expectedUndo = after.pendingUndo
    decisions[index].edgeCount += 1
  }
  func finishDecision(
    _ token: ApprovedDecisionCapture, result: Bool,
    actual: ApprovedViewSnapshot?, contextCount: Int, contextAvailable: Bool
  ) {
    guard let index = decisions.firstIndex(where: { $0.token == token }) else { return }
    let value = decisions[index]
    decisions[index].finishRequested = true
    guard index == decisions.count - 1 else {
      burnAll()
      return
    }
    decisions.removeLast()
    if value.family != value.token.id { return }  // Inner plural/singular never issues.
    guard result, value.singular, value.edgeCount == 2,
      value.parentBarrier == barriers.last?.id, let actual,
      matches(value, actual), let range = value.range, let replacement = value.replacement,
      let before = value.before, let units = value.replacementCount,
      range.location >= 0, range.length >= 0,
      range.location <= before, range.length <= before - range.location,
      range.length <= 4096, units >= 0, units <= 4096,
      !actual.primitive.exhausted, !actual.primitive.backingReentry,
      actual.primitive.sequence < UInt64.max,
      let id = issue(contextCount, contextAvailable)
    else {
      pending = nil
      return
    }
    let (after, overflow) = (before - range.length).addingReportingOverflow(units)
    guard !overflow else { return }
    let receipt = ApprovedViewReservation(
      id: id, brokerID: brokerID, decision: value.token.id,
      invocation: value.invocation, barrier: barriers.last?.id, snapshot: actual,
      range: range, replacement: replacement, replacementCount: units, before: before, after: after)
    pending = Pending(decision: value, reservation: receipt)
  }
  func cancelDecision(_ token: ApprovedDecisionCapture) {
    guard let index = decisions.firstIndex(where: { $0.token == token }) else { return }
    decisions[index].burned = true
    decisions[index].finishRequested = true
    while decisions.last?.finishRequested == true { decisions.removeLast() }
  }
  func discardReservation(_ receipt: ApprovedViewReservation) {
    if receipt.brokerID == brokerID, reserved?.id == receipt.id { reserved = nil }
  }
  func reservationRoute(_ receipt: ApprovedViewReservation) -> ApprovedViewRoute {
    receipt.snapshot.route
  }
  func pendingRoute(storage: ObjectIdentifier) -> ApprovedViewRoute? {
    guard let value = pending, value.reservation.snapshot.route.lease.storageID == storage
    else { return nil }
    return value.reservation.snapshot.route
  }
  func burnPending(owner: ObjectIdentifier, storage: ObjectIdentifier) {
    if pending?.reservation.snapshot.route.lease.controllerID == owner,
      pending?.reservation.snapshot.route.lease.storageID == storage
    {
      pending = nil
    }
    if reserved?.snapshot.route.lease.controllerID == owner,
      reserved?.snapshot.route.lease.storageID == storage
    {
      reserved = nil
    }
  }
  func reserve(
    range: NSRange, replacement: String, before: Int, changed: Bool,
    actual: ApprovedViewSnapshot?, contextCount: Int, contextAvailable: Bool
  )
    -> ApprovedViewReservation?
  {
    guard let value = pending else { return nil }
    pending = nil  // Exact attempt spends on match, mismatch and equal no-op alike.
    guard available(contextCount, contextAvailable), changed,
      let actual, value.reservation.barrier == barriers.last?.id,
      value.reservation.invocation == invocations.last?.token.id,
      matches(value.decision, actual), actual == value.reservation.snapshot,
      range == value.reservation.range,
      replacement.utf16.elementsEqual(value.reservation.replacement.utf16),
      before == value.reservation.before
    else { return nil }
    reserved = value.reservation
    return value.reservation
  }
  func consume(
    _ receipt: ApprovedViewReservation, recorder: ApprovedRecorderState?,
    currentLease: MacroBindingLease?, observation: PrimitiveCommitObservation,
    contextCount: Int, contextAvailable: Bool
  ) -> MacroCommand? {
    guard receipt.brokerID == brokerID, reserved?.id == receipt.id else { return nil }
    reserved = nil
    guard available(contextCount, contextAvailable),
      receipt.invocation == invocations.last?.token.id, receipt.barrier == barriers.last?.id,
      currentLease == receipt.snapshot.route.lease, recorder == receipt.snapshot.recorder,
      observation.kind == .characters, observation.changedCharacters,
      !observation.sequenceExhausted, !observation.backingReentry,
      observation.sequence == receipt.snapshot.primitive.sequence + 1,
      observation.range == receipt.range, observation.beforeUTF16Count == receipt.before,
      observation.afterUTF16Count == receipt.after,
      observation.replacementUTF16Count == receipt.replacementCount
    else { return nil }
    return .replace(
      location: receipt.range.location, length: receipt.range.length, text: receipt.replacement)
  }
}
