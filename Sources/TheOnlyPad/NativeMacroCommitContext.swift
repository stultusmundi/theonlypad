// SPDX-License-Identifier: MIT
// Task1B finite value-only authority, lexical barriers and checked identities.
// Component scalar success does not prove native source origin or integration.
// No storage/controller/native-origin integration or runtime acceptance.
import Foundation

enum MacroContextOrigin: UInt8, Equatable {
  case explicitSource, nativeInsertion, markedText, nativeUndo, nativeRedo
}
enum MacroContextCommitKind: UInt8, Equatable { case changedCharacters, explicitAcceptedNoOp }
enum MacroContextPrimitiveKind: UInt8, Equatable { case characters, attributes }
enum MacroContextPhase: UInt8, Equatable {
  case entered, finallyAdmitted, permitIssued, consumed, invalidated
}
enum MacroContextFailure: UInt8, Equatable {
  case deniedDecision, wrongPhase, identityMismatch, recorderStateSerialExhausted
  case sequenceMismatch, sequenceExhausted
  case backingReentry, unsupportedCompletion, blockedByChildOrBarrier
  case capacity, identifierExhausted, cleanupOrder
}

enum MacroContextFinalDecision: Equatable {
  case pending, denied
  case admitted(UUID)
}

struct MacroContextIdentity: Equatable {
  let documentID: UUID
  let paneID: UUID
  let storageID: ObjectIdentifier
  let ownershipGeneration: UUID
  let recordingEpoch: UUID
  let recorderStateSerial: UInt64
  let recorderStateSerialExhausted: Bool
}

struct MacroContextPrimitiveState: Equatable {
  let sequence: UInt64
  let exhausted: Bool
  let backingReentry: Bool
}

struct MacroContextPrimitiveContract: Equatable {
  let kind: MacroContextCommitKind
  let range: NSRange
  let beforeUTF16Count: Int
  let replacementUTF16Count: Int
}

struct MacroContextPrimitiveCompletion: Equatable {
  let kind: MacroContextPrimitiveKind
  let range: NSRange
  let beforeUTF16Count: Int
  let afterUTF16Count: Int
  let replacementUTF16Count: Int?
  let changedCharacters: Bool
  let state: MacroContextPrimitiveState
}

struct MacroContextScope: Equatable {
  let contextID: UInt64
  let frameID: UInt64
  fileprivate init(contextID: UInt64, frameID: UInt64) {
    self.contextID = contextID
    self.frameID = frameID
  }
}

struct MacroContextPermit: Equatable {
  // The memberwise initializer inherits this field's fileprivate access.
  fileprivate let scope: MacroContextScope
}

struct MacroContextFrameStatus: Equatable {
  let phase: MacroContextPhase
  let firstFailure: MacroContextFailure?
  let finishRequested: Bool
}

@MainActor final class NativeMacroCommitContext {
  private struct Frame {
    let scope: MacroContextScope
    let origin: MacroContextOrigin
    let identity: MacroContextIdentity
    let primitive: MacroContextPrimitiveState
    let contract: MacroContextPrimitiveContract
    var phase: MacroContextPhase = .entered
    var firstFailure: MacroContextFailure?
    var finishRequested = false
    var decisionID: UUID?
  }
  private enum Entry {
    case frame(Frame)
    case barrier(id: UInt64, finishRequested: Bool)
  }
  private static var lastIssuedContextID: UInt64 = 0
  private let contextID: UInt64
  private var lastIssuedFrameID: UInt64 = 0
  private var frameIssuerExhausted = false
  private var entries: [Entry] = []
  private var overflowBarrierActive = false

  init?() {
    let (next, overflow) = Self.lastIssuedContextID.addingReportingOverflow(1)
    guard !overflow else { return nil }
    Self.lastIssuedContextID = next
    contextID = next
  }

  // Frames and barrier sentinels share one monotonic lexical entry issuer.
  // A failed authority operation never pops an entry or grants an ancestor.
  private func frameIndex(_ scope: MacroContextScope) -> Int? {
    guard scope.contextID == contextID else { return nil }
    for index in entries.indices {
      if case .frame(let frame) = entries[index], frame.scope == scope { return index }
    }
    return nil
  }

  private func refuse(_ index: Int, reason: MacroContextFailure) {
    guard case .frame(var frame) = entries[index] else { return }
    if frame.firstFailure == nil { frame.firstFailure = reason }
    if frame.phase != .consumed { frame.phase = .invalidated }
    entries[index] = .frame(frame)
  }

  private func poisonAll(_ reason: MacroContextFailure) {
    for index in entries.indices {
      if case .frame = entries[index] { refuse(index, reason: reason) }
    }
  }

  private func issueEntryID() -> UInt64? {
    guard !frameIssuerExhausted else {
      poisonAll(.identifierExhausted)
      return nil
    }
    let (next, overflow) = lastIssuedFrameID.addingReportingOverflow(1)
    guard !overflow else {
      frameIssuerExhausted = true
      poisonAll(.identifierExhausted)
      return nil
    }
    lastIssuedFrameID = next
    return next
  }

  private func authorityFrame(_ scope: MacroContextScope, phase: MacroContextPhase)
    -> (index: Int, frame: Frame)?
  {
    guard let index = frameIndex(scope), case .frame(let frame) = entries[index] else { return nil }
    guard !overflowBarrierActive, index == entries.count - 1 else {
      refuse(index, reason: .blockedByChildOrBarrier)
      return nil
    }
    guard frame.phase == phase else {
      refuse(index, reason: .wrongPhase)
      return nil
    }
    return (index, frame)
  }

  private func identityFailure(_ frame: Frame, current: MacroContextIdentity)
    -> MacroContextFailure?
  {
    if frame.identity.recorderStateSerialExhausted || current.recorderStateSerialExhausted {
      return .recorderStateSerialExhausted
    }
    return frame.identity == current ? nil : .identityMismatch
  }

  // Validate entered geometry before any authority grant. Every subtraction/addition
  // is checked; an explicit no-op must also preserve the actual UTF16 count.
  private func expectedAfterCount(_ contract: MacroContextPrimitiveContract) -> Int? {
    guard contract.beforeUTF16Count >= 0, contract.replacementUTF16Count >= 0,
      contract.range.location >= 0, contract.range.length >= 0,
      contract.range.location <= contract.beforeUTF16Count
    else { return nil }
    let (available, locationOverflow) =
      contract.beforeUTF16Count.subtractingReportingOverflow(contract.range.location)
    guard !locationOverflow, contract.range.length <= available else { return nil }
    let (remaining, removalOverflow) =
      contract.beforeUTF16Count.subtractingReportingOverflow(contract.range.length)
    guard !removalOverflow else { return nil }
    let (after, additionOverflow) = remaining.addingReportingOverflow(
      contract.replacementUTF16Count)
    guard !additionOverflow, after >= 0 else { return nil }
    if contract.kind == .explicitAcceptedNoOp {
      guard contract.replacementUTF16Count == contract.range.length,
        after == contract.beforeUTF16Count
      else { return nil }
    }
    return after
  }

  private func preAuthorityFailure(
    _ frame: Frame, identity: MacroContextIdentity,
    primitive: MacroContextPrimitiveState
  ) -> MacroContextFailure? {
    if let failure = identityFailure(frame, current: identity) { return failure }
    // Exhaustion is unusable irrespective of the supplied reentry bit.
    if frame.primitive.exhausted || primitive.exhausted || frame.primitive.sequence == UInt64.max {
      return .sequenceExhausted
    }
    if frame.primitive.backingReentry || primitive.backingReentry { return .backingReentry }
    if frame.primitive.sequence != primitive.sequence { return .sequenceMismatch }
    guard frame.origin == .explicitSource, expectedAfterCount(frame.contract) != nil else {
      return .unsupportedCompletion
    }
    return nil
  }

  func begin(
    origin: MacroContextOrigin, identity: MacroContextIdentity,
    primitive: MacroContextPrimitiveState, contract: MacroContextPrimitiveContract
  )
    -> MacroContextScope?
  {
    guard !overflowBarrierActive, entries.count < 64 else {
      poisonAll(.capacity)
      return nil
    }
    guard let next = issueEntryID() else { return nil }
    let scope = MacroContextScope(contextID: contextID, frameID: next)
    entries.append(
      .frame(
        Frame(
          scope: scope, origin: origin, identity: identity,
          primitive: primitive, contract: contract)))
    return scope
  }

  func admitFinalDecision(
    _ scope: MacroContextScope, decision: MacroContextFinalDecision,
    identity: MacroContextIdentity, primitive: MacroContextPrimitiveState
  ) -> Bool {
    guard let target = authorityFrame(scope, phase: .entered) else { return false }
    switch decision {
    case .pending:
      refuse(target.index, reason: .wrongPhase)
      return false
    case .denied:
      refuse(target.index, reason: .deniedDecision)
      return false
    case .admitted(let marker):
      if let failure = preAuthorityFailure(target.frame, identity: identity, primitive: primitive) {
        refuse(target.index, reason: failure)
        return false
      }
      var frame = target.frame
      frame.decisionID = marker
      frame.phase = .finallyAdmitted
      entries[target.index] = .frame(frame)
      return true
    }
  }

  func issueExplicitPermit(
    _ scope: MacroContextScope, identity: MacroContextIdentity,
    primitive: MacroContextPrimitiveState
  ) -> MacroContextPermit? {
    guard let target = authorityFrame(scope, phase: .finallyAdmitted) else { return nil }
    if let failure = preAuthorityFailure(target.frame, identity: identity, primitive: primitive) {
      refuse(target.index, reason: failure)
      return nil
    }
    var frame = target.frame
    frame.phase = .permitIssued
    entries[target.index] = .frame(frame)
    return MacroContextPermit(scope: scope)
  }

  func consumeExplicitPermit(
    _ permit: MacroContextPermit, identity: MacroContextIdentity,
    completion: MacroContextPrimitiveCompletion
  ) -> Bool {
    guard let target = authorityFrame(permit.scope, phase: .permitIssued) else { return false }
    let frame = target.frame
    if let failure = identityFailure(frame, current: identity) {
      refuse(target.index, reason: failure)
      return false
    }
    guard !frame.primitive.exhausted, !completion.state.exhausted,
      frame.primitive.sequence < UInt64.max
    else {
      refuse(target.index, reason: .sequenceExhausted)
      return false
    }
    guard !frame.primitive.backingReentry, !completion.state.backingReentry else {
      refuse(target.index, reason: .backingReentry)
      return false
    }
    let (next, overflow) = frame.primitive.sequence.addingReportingOverflow(1)
    guard !overflow else {
      refuse(target.index, reason: .sequenceExhausted)
      return false
    }
    guard completion.state.sequence == next else {
      refuse(target.index, reason: .sequenceMismatch)
      return false
    }
    guard frame.origin == .explicitSource, let after = expectedAfterCount(frame.contract),
      completion.kind == .characters, completion.range == frame.contract.range,
      completion.beforeUTF16Count == frame.contract.beforeUTF16Count,
      completion.afterUTF16Count == after,
      completion.replacementUTF16Count == frame.contract.replacementUTF16Count,
      completion.changedCharacters == (frame.contract.kind == .changedCharacters)
    else {
      refuse(target.index, reason: .unsupportedCompletion)
      return false
    }
    var consumed = frame
    consumed.phase = .consumed  // One-use, including an explicitly admitted accepted no-op.
    entries[target.index] = .frame(consumed)
    return true
  }

  private func drainPending() {
    while let last = entries.last {
      switch last {
      case .frame(let frame):
        guard frame.finishRequested else { return }
      case .barrier(_, let finishRequested):
        guard finishRequested else { return }
      }
      entries.removeLast()
    }
  }

  func finish(_ scope: MacroContextScope) -> Bool {
    guard let index = frameIndex(scope), case .frame(var frame) = entries[index] else {
      return false
    }
    guard index == entries.count - 1 else {
      poisonAll(.cleanupOrder)
      // Refresh after poison so a stale local copy cannot restore authority/reason.
      guard case .frame(let poisoned) = entries[index] else { return false }
      frame = poisoned
      frame.finishRequested = true
      entries[index] = .frame(frame)
      return false
    }
    entries.removeLast()
    drainPending()
    return true
  }

  private func finishBarrier(_ id: UInt64) {
    guard
      let index = entries.firstIndex(where: {
        if case .barrier(let candidate, _) = $0 { return candidate == id }
        return false
      })
    else { return }
    if index == entries.count - 1 {
      entries.removeLast()
      drainPending()
    } else {
      poisonAll(.cleanupOrder)
      entries[index] = .barrier(id: id, finishRequested: true)
    }
  }

  private func withOverflowBarrier<Value>(
    reason: MacroContextFailure,
    _ body: () throws -> Value
  ) rethrows -> Value {
    let incoming = overflowBarrierActive
    poisonAll(reason)
    overflowBarrierActive = true
    defer { overflowBarrierActive = incoming }
    return try body()
  }

  // A caller that rejected combined retained-entry admission must still suspend
  // frames and run its native body once, without adding a context entry.
  func withRejectedCallbackBarrier<Value>(_ body: () throws -> Value) rethrows -> Value {
    return try withOverflowBarrier(reason: .capacity, body)
  }

  func withCallbackBarrier<Value>(_ body: () throws -> Value) rethrows -> Value {
    guard !overflowBarrierActive, entries.count < 64 else {
      return try withOverflowBarrier(reason: .capacity, body)
    }
    guard let id = issueEntryID() else {
      return try withOverflowBarrier(reason: .identifierExhausted, body)
    }
    entries.append(.barrier(id: id, finishRequested: false))
    defer { finishBarrier(id) }
    return try body()
  }

  // Pure eligibility excludes existing explicit parent frames, not callback barriers.
  var hasActiveExplicitFrame: Bool {
    entries.contains {
      if case .frame = $0 { return true }
      return false
    }
  }
  var entryCount: Int { entries.count }
  var overflowBarrierIsActive: Bool { overflowBarrierActive }
  var frameIssuerIsExhausted: Bool { frameIssuerExhausted }

  func status(of scope: MacroContextScope) -> MacroContextFrameStatus? {
    guard scope.contextID == contextID else { return nil }
    for entry in entries {
      if case .frame(let frame) = entry, frame.scope == scope {
        return MacroContextFrameStatus(
          phase: frame.phase, firstFailure: frame.firstFailure,
          finishRequested: frame.finishRequested)
      }
    }
    return nil
  }
}
