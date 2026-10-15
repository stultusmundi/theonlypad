// SPDX-License-Identifier: MIT
import AppKit

// Task2A real backing and explicit postcommit adapter; native-origin grants remain held.
// Editing remains confined by the existing native model/controller discipline.
enum PrimitiveCommitKind: UInt8 { case characters, attributes }

struct PrimitiveCommitObservation: Equatable {
  let sequence: UInt64
  let sequenceExhausted: Bool
  let kind: PrimitiveCommitKind
  let range: NSRange
  let replacementUTF16Count: Int?
  let beforeUTF16Count: Int
  let afterUTF16Count: Int
  let changedCharacters: Bool
  let backingReentry: Bool
}

final class DocumentCommitTextStorage: NSTextStorage {
  private let backing = NSMutableAttributedString(string: "")
  private var cachedString: String?
  private var primitiveSequence: UInt64 = 0
  private var primitiveSequenceExhausted = false
  private var lastPrimitiveCommit: PrimitiveCommitObservation?
  private var backingMutationDepth = 0

  // TASK2A-WEAK-OWNER-BEGIN
  private weak var macroOwner: EditorWindowController?
  private var macroLease: MacroBindingLease?

  // TASK2B-TRANSFER-SUSPENSION-BEGIN
  private var macroTransferSuspension: MacroTransferSuspension?

  @MainActor var nativeMacroBindingIsSuspended: Bool { macroTransferSuspension != nil }

  @MainActor func nativeMacroHasBinding(
    _ owner: EditorWindowController, lease: MacroBindingLease
  ) -> Bool {
    macroTransferSuspension == nil && macroOwner === owner && macroLease == lease
  }

  @MainActor func suspendMacroBinding(_ token: MacroTransferSuspension) -> Bool {
    guard token.storageID == ObjectIdentifier(self) else { return false }
    if let current = macroTransferSuspension { return current == token }
    macroTransferSuspension = token
    // Pure retirement burns only the captured owner's current matching lease.
    retireMacroBinding()
    return true
  }

  @MainActor func canFinishMacroBinding(_ token: MacroTransferSuspension) -> Bool {
    token.storageID == ObjectIdentifier(self) && macroTransferSuspension == token
      && macroOwner == nil && macroLease == nil
  }

  @MainActor func finishMacroBinding(
    _ token: MacroTransferSuspension, owner: EditorWindowController, lease: MacroBindingLease
  ) -> Bool {
    guard canFinishMacroBinding(token),
      lease.controllerID == ObjectIdentifier(owner),
      lease.storageID == token.storageID, lease.documentObjectID == token.documentObjectID,
      lease.documentID == token.documentID
    else { return false }
    // Every refusal precedes these nonthrowing scalar assignments.
    macroTransferSuspension = nil
    macroOwner = owner
    macroLease = lease
    return true
  }
  // TASK2B-TRANSFER-SUSPENSION-END

  @MainActor func bindMacroOwner(_ owner: EditorWindowController, lease: MacroBindingLease) -> Bool
  {
    guard macroTransferSuspension == nil, lease.controllerID == ObjectIdentifier(owner),
      lease.storageID == ObjectIdentifier(self)
    else { return false }
    if let current = macroOwner {
      guard current === owner, macroLease?.serial == lease.serial else { return false }
    }
    macroOwner = owner
    macroLease = lease
    return true
  }

  @MainActor func unbindMacroOwner(_ owner: EditorWindowController, lease: MacroBindingLease) {
    guard macroOwner === owner, macroLease == lease else { return }
    owner.nativeApprovedViewRetire(storageID: ObjectIdentifier(self))
    macroOwner = nil
    macroLease = nil
  }

  @MainActor func retireMacroBinding() {
    if let owner = macroOwner, let lease = macroLease { owner.nativeMacroRetireBinding(lease) }
    macroOwner = nil
    macroLease = nil
  }

  var nativeMacroPrimitiveState: MacroContextPrimitiveState {
    MacroContextPrimitiveState(
      sequence: primitiveSequence,
      exhausted: primitiveSequenceExhausted,
      backingReentry: backingMutationDepth > 0 || (lastPrimitiveCommit?.backingReentry ?? false))
  }

  @MainActor func prepareExplicitCharacters(in range: NSRange, with replacement: String)
    -> MacroPreparedReplacement
  {
    let beforeLength = backing.length
    let replacementString = replacement as NSString
    let changed = changesCharacters(
      in: range, replacement: replacementString,
      beforeLength: beforeLength)
    return MacroPreparedReplacement(
      replacement: replacement,
      replacementUTF16Count: replacementString.length, beforeUTF16Count: beforeLength,
      changedCharacters: changed, primitive: nativeMacroPrimitiveState)
  }

  @MainActor func prepareApprovedCharacters(in range: NSRange, with replacement: String)
    -> MacroPreparedReplacement?
  {
    let count = backing.length
    guard range.location >= 0, range.length >= 0, range.location <= count,
      range.length <= count - range.location, range.length <= 4096,
      replacement.utf16.count <= 4096
    else { return nil }
    let text = backing.mutableString
    func isScalarBoundary(_ offset: Int) -> Bool {
      guard offset > 0, offset < count else { return true }
      let previous = text.character(at: offset - 1)
      let next = text.character(at: offset)
      return !(previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF)
    }
    guard isScalarBoundary(range.location), isScalarBoundary(range.location + range.length)
    else { return nil }
    return prepareExplicitCharacters(in: range, with: replacement)
  }

  @MainActor func replaceExplicitCharacters(delivery: MacroExplicitDelivery) {
    replacePrimitive(
      in: delivery.seed.contract.range,
      with: delivery.seed.preparedReplacement.replacement, delivery: delivery)
  }

  @MainActor func prepareControlledCharacters(in range: NSRange, with replacement: String)
    -> MacroControlledCharacterWrite
  {
    let prepared = prepareExplicitCharacters(in: range, with: replacement)
    let owner = macroOwner
    let capture = owner.flatMap { owner in macroLease.flatMap { owner.nativeMacroCapture($0) } }
    return MacroControlledCharacterWrite(
      storageID: ObjectIdentifier(self), range: range,
      replacement: prepared, owner: owner, capture: capture)
  }

  @MainActor func replaceControlledCharacters(
    _ prepared: MacroControlledCharacterWrite, delivery: MacroExplicitDelivery?
  ) -> Bool {
    let facts = prepared.replacement
    guard prepared.storageID == ObjectIdentifier(self),
      facts.beforeUTF16Count == backing.length, facts.beforeUTF16Count <= 4096,
      facts.replacementUTF16Count >= 0, facts.replacementUTF16Count <= 4096,
      prepared.range.location >= 0, prepared.range.length == 0,
      prepared.range.location <= facts.beforeUTF16Count,
      facts.primitive == nativeMacroPrimitiveState
    else { return false }
    replacePrimitive(
      in: prepared.range, with: facts.replacement,
      delivery: delivery, prepared: prepared)
    return true
  }
  // TASK2A-WEAK-OWNER-END

  override init() {
    super.init()
  }

  // Application restoration populates decoded text explicitly; no storage archive
  // is supported by this prerequisite. Fail closed rather than silently decoding
  // an archive into an empty backing. Required initializer legality is a type gate.
  required init?(coder: NSCoder) {
    return nil
  }

  // Pasteboard construction is unsupported by this prerequisite scaffold.
  // Inherited native paste routes and imported signature legality remain held.
  required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType)
  {
    return nil
  }

  // Actual inherited processing, including attribute fixing and delegate callbacks.
  // Selected owned MainActor caller discipline is a separate native prerequisite.
  override func processEditing() {
    MainActor.assumeIsolated {
      EditorWindowController.withNativeMacroProcessingBarrier {
        super.processEditing()
      }
    }
  }

  override var string: String {
    // A backing mutation may reenter; never publish an intermediate cached value.
    guard backingMutationDepth == 0 else { return backing.string }
    if let cachedString { return cachedString }
    let snapshot = backing.string
    cachedString = snapshot
    return snapshot
  }

  override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
    -> [NSAttributedString.Key: Any]
  {
    backing.attributes(at: location, effectiveRange: range)
  }

  // Compare UTF16 units without cloning the removed or full document text.
  // Invalid arguments still reach the actual backing call unchanged.
  private func changesCharacters(
    in range: NSRange, replacement: NSString,
    beforeLength: Int
  ) -> Bool {
    guard range.location >= 0, range.length >= 0, range.location <= beforeLength,
      range.length <= beforeLength - range.location
    else { return true }
    guard range.length == replacement.length else { return true }
    guard range.length > 0 else { return false }
    let original = backing.mutableString
    var units = [unichar](repeating: 0, count: min(4096, range.length))
    var offset = 0
    while offset < range.length {
      let count = min(units.count, range.length - offset)
      units.withUnsafeMutableBufferPointer { buffer in
        original.getCharacters(
          buffer.baseAddress!,
          range: NSRange(location: range.location + offset, length: count))
      }
      for index in 0..<count {
        if units[index] != replacement.character(at: offset + index) { return true }
      }
      offset += count
    }
    return false
  }

  private func advancePrimitiveSequence() {
    let (next, overflow) = primitiveSequence.addingReportingOverflow(1)
    if overflow {
      primitiveSequenceExhausted = true
    } else {
      primitiveSequence = next
    }
  }

  override func replaceCharacters(in range: NSRange, with replacement: String) {
    replacePrimitive(in: range, with: replacement, delivery: nil)
  }

  private func replacePrimitive(
    in range: NSRange, with replacement: String,
    delivery: MacroExplicitDelivery?, prepared: MacroControlledCharacterWrite? = nil
  ) {
    let owner: EditorWindowController?
    let beforeLength = backing.length
    let capture: MacroPrimitiveCapture?
    var approved: ApprovedViewReservation? = nil
    let replacementLength: Int
    let changed: Bool
    if let prepared {
      // Prepared but unauthorized is structurally separate from ordinary raw nil.
      owner = prepared.owner
      capture = delivery?.capture ?? prepared.capture
      replacementLength = prepared.replacement.replacementUTF16Count
      changed = prepared.replacement.changedCharacters
    } else if let delivery {
      owner = nil
      // Explicit derivation and lease/epoch capture were completed before issuance.
      capture = delivery.capture
      replacementLength = delivery.seed.preparedReplacement.replacementUTF16Count
      changed = delivery.seed.preparedReplacement.changedCharacters
    } else {
      owner = macroOwner
      var rawCapture: MacroPrimitiveCapture? = nil
      if let owner, let lease = macroLease {
        MainActor.assumeIsolated { rawCapture = owner.nativeMacroCapture(lease) }
      }
      capture = rawCapture
      let replacementString = replacement as NSString
      replacementLength = replacementString.length
      changed = changesCharacters(
        in: range, replacement: replacementString,
        beforeLength: beforeLength)
      if let owner {
        MainActor.assumeIsolated {
          approved = owner.nativeApprovedReserve(
            storageID: ObjectIdentifier(self),
            range: range, replacement: replacement, before: beforeLength, changed: changed)
        }
      }
    }
    let incomingDepth = backingMutationDepth
    let beforeSequence = primitiveSequence
    let beforeExhaustion = primitiveSequenceExhausted
    backingMutationDepth = incomingDepth < 64 ? incomingDepth + 1 : 64
    cachedString = nil
    backing.replaceCharacters(in: range, with: replacement)
    cachedString = nil
    backingMutationDepth = incomingDepth
    let afterLength = backing.length
    let reentry =
      incomingDepth > 0 || primitiveSequence != beforeSequence
      || primitiveSequenceExhausted != beforeExhaustion
    advancePrimitiveSequence()
    // Exhaustion dominates this reentry bit: false then gives no negative guarantee.
    lastPrimitiveCommit = PrimitiveCommitObservation(
      sequence: primitiveSequence,
      sequenceExhausted: primitiveSequenceExhausted, kind: .characters, range: range,
      replacementUTF16Count: replacementLength, beforeUTF16Count: beforeLength,
      afterUTF16Count: afterLength, changedCharacters: changed, backingReentry: reentry)
    if let owner = owner ?? macroOwner, let observation = lastPrimitiveCommit {
      MainActor.assumeIsolated {
        owner.nativeMacroPublish(
          capture, delivery: delivery, observation: observation, approved: approved)
      }
    }
    edited(.editedCharacters, range: range, changeInLength: afterLength - beforeLength)
  }

  override func setAttributes(_ attributes: [NSAttributedString.Key: Any]?, range: NSRange) {
    let owner = macroOwner
    if let owner {
      MainActor.assumeIsolated {
        owner.nativeApprovedAttributes(storageID: ObjectIdentifier(self))
      }
    }
    var capture: MacroPrimitiveCapture? = nil
    if let owner, let lease = macroLease {
      MainActor.assumeIsolated { capture = owner.nativeMacroCapture(lease) }
    } else {
      capture = nil
    }
    let beforeLength = backing.length
    let incomingDepth = backingMutationDepth
    let beforeSequence = primitiveSequence
    let beforeExhaustion = primitiveSequenceExhausted
    backingMutationDepth = incomingDepth < 64 ? incomingDepth + 1 : 64
    backing.setAttributes(attributes, range: range)
    backingMutationDepth = incomingDepth
    let afterLength = backing.length
    let reentry =
      incomingDepth > 0 || primitiveSequence != beforeSequence
      || primitiveSequenceExhausted != beforeExhaustion
    advancePrimitiveSequence()
    lastPrimitiveCommit = PrimitiveCommitObservation(
      sequence: primitiveSequence,
      sequenceExhausted: primitiveSequenceExhausted, kind: .attributes, range: range,
      replacementUTF16Count: nil, beforeUTF16Count: beforeLength,
      afterUTF16Count: afterLength, changedCharacters: false, backingReentry: reentry)
    if let owner, let observation = lastPrimitiveCommit {
      MainActor.assumeIsolated {
        owner.nativeMacroPublish(capture, delivery: nil, observation: observation)
      }
    }
    edited(.editedAttributes, range: range, changeInLength: 0)
  }
}
