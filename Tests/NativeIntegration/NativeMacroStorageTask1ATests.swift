// SPDX-License-Identifier: MIT
// SOURCE ONLY: Task1A real-storage tests; no storage/controller/context implementation.
// Default: three baseline parity/dispatch tests against accepted unmodified private D.
// Define exactly NATIVE_MACRO_TASK1A_STORAGE only after the separate actual-storage
// Swift5 initializer/override/isolation prerequisite. Then the twelve custom tests
// and the same three parity tests are eligible; no default result credits them.
import AppKit
import Foundation
import XCTest

@testable import NativeRouting

// Real delegate characterization, not a replacement storage or observation journal.
private final class Task1ABaselineChildDelegate: NSObject, NSTextStorageDelegate {
  private(set) var willCalls = 0
  private(set) var didCalls = 0
  private(set) var phase: UInt8 = 0
  private(set) var overflow = false

  func textStorage(
    _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard willCalls < 1 else {
      overflow = true
      XCTFail("Unexpected baseline will recursion")
      return
    }
    willCalls += 1
    XCTAssertEqual(willCalls, 1)
    XCTAssertEqual(phase, 0)
    XCTAssertEqual(textStorage.string, "Xb")
    XCTAssertEqual(textStorage.length, 2)
    XCTAssertTrue(editedMask.contains(.editedCharacters))
    XCTAssertEqual(delta, 0)
    phase = 1
    // Actual supported will-process child; bracket only its pending edited dispatch.
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "Y")
    XCTAssertEqual(textStorage.string, "XY")
    XCTAssertEqual(textStorage.length, 2)
    phase = 2
    textStorage.endEditing()
  }

  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard didCalls < 1 else {
      overflow = true
      XCTFail("Unexpected baseline did recursion")
      return
    }
    didCalls += 1
    XCTAssertEqual(didCalls, 1)
    XCTAssertEqual(phase, 2)
    XCTAssertEqual(textStorage.string, "XY")
    XCTAssertEqual(textStorage.length, 2)
    XCTAssertTrue(editedMask.contains(.editedCharacters))
    XCTAssertEqual(delta, 0)
    phase = 3
  }
}

@MainActor final class NativeMacroStorageTask1ABaselineParityTests: XCTestCase {
  // Break caught: D construction/second pane no longer shares the actual storage,
  // or a real supplementary replacement loses observer/revision/dirty semantics.
  func testCharacterReplacementPreservesSharedPaneRevisionAndDirtyBehavior() throws {
    let document = EditorDocument()
    document.storage.mutableString.setString("ab")
    document.savedText = "ab"
    let first = try XCTUnwrap(document.panePool.first)
    let second = try document.makePane()
    XCTAssertTrue(first.document === document)
    XCTAssertTrue(second.document === document)
    XCTAssertTrue(first.layoutManager.textStorage === document.storage)
    XCTAssertTrue(second.layoutManager.textStorage === document.storage)
    XCTAssertTrue(first.editor.textStorage === document.storage)
    XCTAssertTrue(second.editor.textStorage === document.storage)
    XCTAssertEqual(document.storage.layoutManagers.count, 2)
    let revision = document.editRevision
    let ownership = document.ownershipGeneration
    let closeMutation = document.closeMutationGeneration
    var notifications = 0
    let previous = document.onCharactersChanged
    document.onCharactersChanged = { notifications += 1 }
    defer { document.onCharactersChanged = previous }
    document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "😀")
    XCTAssertEqual(document.storage.string, "😀b")
    XCTAssertEqual(document.storage.length, 3)
    XCTAssertEqual((document.storage.string as NSString).character(at: 0), 0xD83D)
    XCTAssertEqual((document.storage.string as NSString).character(at: 1), 0xDE00)
    XCTAssertEqual((document.storage.string as NSString).character(at: 2), 0x0062)
    XCTAssertEqual(document.editRevision, revision + 1)
    XCTAssertEqual(notifications, 1)
    XCTAssertFalse(document.searchRevisionExhausted)
    XCTAssertTrue(document.dirty)
    XCTAssertEqual(document.ownershipGeneration, ownership)
    XCTAssertNotEqual(document.closeMutationGeneration, closeMutation)
    XCTAssertTrue(first.layoutManager.textStorage === second.layoutManager.textStorage)
    XCTAssertTrue(first.editor.textStorage === second.editor.textStorage)
    second.detach()
    XCTAssertNil(second.layoutManager.textStorage)
    XCTAssertEqual(document.storage.layoutManagers.count, 1)
    XCTAssertTrue(first.layoutManager.textStorage === document.storage)
    second.attach()
    XCTAssertTrue(second.layoutManager.textStorage === document.storage)
    XCTAssertTrue(second.editor.textStorage === document.storage)
    XCTAssertEqual(document.storage.layoutManagers.count, 2)
  }

  // Break caught: equal character calls disappear from D's existing observer,
  // or attribute-only calls incorrectly advance character revision/change callbacks.
  func testEqualCharacterAndAttributeWritesPreserveExistingRevisionSemantics() {
    let document = EditorDocument()
    document.storage.mutableString.setString("ab")
    document.savedText = "ab"
    let revision = document.editRevision
    var notifications = 0
    let previous = document.onCharactersChanged
    document.onCharactersChanged = { notifications += 1 }
    defer { document.onCharactersChanged = previous }
    document.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "a")
    XCTAssertEqual(document.storage.string, "ab")
    XCTAssertEqual(document.editRevision, revision + 1)
    XCTAssertEqual(notifications, 1)
    XCTAssertFalse(document.dirty)
    let afterEqualRevision = document.editRevision
    let afterEqualMutation = document.closeMutationGeneration
    document.storage.setAttributes(
      [.kern: NSNumber(value: 2)], range: NSRange(location: 0, length: 2))
    XCTAssertEqual(document.storage.string, "ab")
    XCTAssertEqual(document.storage.length, 2)
    XCTAssertEqual(document.editRevision, afterEqualRevision)
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(document.closeMutationGeneration, afterEqualMutation)
    XCTAssertFalse(document.dirty)
    XCTAssertEqual(
      (document.storage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 2)
  }

  // Characterization prerequisite: literal will -> child return -> did order.
  // A difference is retained as an AppKit reachability/order failure, not scalar RED.
  func testActualWillProcessChildCompletesBeforeDidProcess() {
    let storage = NSTextStorage(string: "ab")
    let delegate = Task1ABaselineChildDelegate()
    let original = storage.delegate
    storage.delegate = delegate
    defer {
      storage.delegate = original
      withExtendedLifetime(delegate) {}
    }
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
    XCTAssertEqual(delegate.willCalls, 0)
    XCTAssertEqual(delegate.didCalls, 0)
    storage.endEditing()
    XCTAssertEqual(storage.string, "XY")
    XCTAssertEqual(delegate.willCalls, 1)
    XCTAssertEqual(delegate.didCalls, 1)
    XCTAssertEqual(delegate.phase, 3)
    XCTAssertFalse(delegate.overflow)
  }
}

#if NATIVE_MACRO_TASK1A_STORAGE
  // This observer reads real getter values in actual AppKit delegate calls.
  // No stamp is constructed, no text is reconstructed, and no macro/origin is inferred.
  private final class Task1APrimitiveDelegate: NSObject, NSTextStorageDelegate {
    enum Route: Equatable { case supplementary, equal, attributes, child }
    let route: Route
    let startingSequence: UInt64
    private(set) var willCalls = 0
    private(set) var didCalls = 0
    private(set) var phase: UInt8 = 0
    private(set) var overflow = false
    private(set) var firstWillSequence: UInt64?
    private(set) var didSequence: UInt64?

    init(route: Route, startingSequence: UInt64) {
      self.route = route
      self.startingSequence = startingSequence
      super.init()
    }

    func textStorage(
      _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard willCalls < 1 else {
        overflow = true
        XCTFail("Unexpected primitive will recursion")
        return
      }
      willCalls += 1
      XCTAssertEqual(willCalls, 1)
      XCTAssertEqual(phase, 0)
      guard let storage = textStorage as? DocumentCommitTextStorage,
        let stamp = storage.nativeMacroTestLastPrimitiveCommit
      else {
        XCTFail("Actual primitive observation absent at will-process")
        return
      }
      firstWillSequence = stamp.sequence
      XCTAssertEqual(stamp.sequence, startingSequence + 1)
      XCTAssertEqual(storage.nativeMacroTestPrimitiveSequence, startingSequence + 1)
      XCTAssertFalse(stamp.sequenceExhausted)
      XCTAssertFalse(storage.nativeMacroTestSequenceExhausted)
      XCTAssertFalse(stamp.backingReentry)
      XCTAssertEqual(stamp.beforeUTF16Count, 2)
      phase = 1
      switch route {
      case .supplementary:
        XCTAssertEqual(storage.string, "😀b")
        XCTAssertEqual(storage.length, 3)
        XCTAssertEqual(stamp.kind, .characters)
        XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(stamp.replacementUTF16Count, 2)
        XCTAssertEqual(stamp.afterUTF16Count, 3)
        XCTAssertTrue(stamp.changedCharacters)
        XCTAssertTrue(editedMask.contains(.editedCharacters))
        XCTAssertEqual(delta, 1)
      case .equal:
        XCTAssertEqual(storage.string, "ab")
        XCTAssertEqual(stamp.kind, .characters)
        XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(stamp.replacementUTF16Count, 1)
        XCTAssertEqual(stamp.afterUTF16Count, 2)
        XCTAssertFalse(stamp.changedCharacters)
        XCTAssertTrue(editedMask.contains(.editedCharacters))
        XCTAssertEqual(delta, 0)
      case .attributes:
        XCTAssertEqual(storage.string, "ab")
        XCTAssertEqual(stamp.kind, .attributes)
        XCTAssertEqual(stamp.range, NSRange(location: 0, length: 2))
        XCTAssertNil(stamp.replacementUTF16Count)
        XCTAssertEqual(stamp.afterUTF16Count, 2)
        XCTAssertFalse(stamp.changedCharacters)
        XCTAssertTrue(editedMask.contains(.editedAttributes))
        XCTAssertFalse(editedMask.contains(.editedCharacters))
        XCTAssertEqual(delta, 0)
      case .child:
        XCTAssertEqual(storage.string, "Xb")
        XCTAssertEqual(stamp.kind, .characters)
        XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(stamp.replacementUTF16Count, 1)
        XCTAssertEqual(stamp.afterUTF16Count, 2)
        XCTAssertTrue(stamp.changedCharacters)
        XCTAssertEqual(delta, 0)
        // Metadata is sampled before this real child's endEditing may process/fix attributes.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "Y")
        guard let child = storage.nativeMacroTestLastPrimitiveCommit else {
          storage.endEditing()
          XCTFail("Actual child observation absent")
          return
        }
        XCTAssertEqual(storage.string, "XY")
        XCTAssertEqual(child.sequence, startingSequence + 2)
        XCTAssertEqual(storage.nativeMacroTestPrimitiveSequence, startingSequence + 2)
        XCTAssertEqual(child.kind, .characters)
        XCTAssertEqual(child.range, NSRange(location: 1, length: 1))
        XCTAssertEqual(child.beforeUTF16Count, 2)
        XCTAssertEqual(child.afterUTF16Count, 2)
        XCTAssertEqual(child.replacementUTF16Count, 1)
        XCTAssertTrue(child.changedCharacters)
        XCTAssertFalse(child.sequenceExhausted)
        // Catches a backing-depth bracket incorrectly extended across outer edited/processing.
        XCTAssertFalse(child.backingReentry)
        phase = 2
        storage.endEditing()
      }
      if route != .child { phase = 2 }
    }

    func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard didCalls < 1 else {
        overflow = true
        XCTFail("Unexpected primitive did recursion")
        return
      }
      didCalls += 1
      XCTAssertEqual(didCalls, 1)
      XCTAssertEqual(phase, 2)
      guard let storage = textStorage as? DocumentCommitTextStorage,
        let stamp = storage.nativeMacroTestLastPrimitiveCommit
      else {
        XCTFail("Actual latest primitive observation absent at did-process")
        return
      }
      didSequence = stamp.sequence
      XCTAssertEqual(stamp.sequence, storage.nativeMacroTestPrimitiveSequence)
      XCTAssertFalse(stamp.sequenceExhausted)
      XCTAssertFalse(storage.nativeMacroTestSequenceExhausted)
      XCTAssertFalse(stamp.backingReentry)
      switch route {
      case .supplementary:
        XCTAssertEqual(storage.string, "😀b")
        XCTAssertEqual(storage.length, 3)
        XCTAssertEqual(delta, 1)
      case .equal, .attributes:
        XCTAssertEqual(storage.string, "ab")
        XCTAssertEqual(storage.length, 2)
        XCTAssertEqual(delta, 0)
      case .child:
        XCTAssertEqual(storage.string, "XY")
        XCTAssertEqual(storage.length, 2)
        XCTAssertEqual(delta, 0)
      }
      // Real attribute fixing may have completed additional primitives. Last-value metadata
      // must reflect the latest one; it is never a saved outer stamp or a fabricated journal.
      XCTAssertGreaterThanOrEqual(stamp.sequence, startingSequence + (route == .child ? 2 : 1))
      phase = 3
    }
  }

  @MainActor final class NativeMacroStorageTask1APrimitiveTests: XCTestCase {
    // Break caught: scalar observation occurs before backing, after edited, or with UTF16/scalar confusion.
    func testSupplementaryPrimitiveIsVisibleBeforeProcessing() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let delegate = Task1APrimitiveDelegate(route: .supplementary, startingSequence: s)
      let original = storage.delegate
      storage.delegate = delegate
      defer {
        storage.delegate = original
        withExtendedLifetime(delegate) {}
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "😀")
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "😀b")
      XCTAssertEqual(storage.length, 3)
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.kind, .characters)
      XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
      XCTAssertEqual(stamp.beforeUTF16Count, 2)
      XCTAssertEqual(stamp.afterUTF16Count, 3)
      XCTAssertEqual(stamp.replacementUTF16Count, 2)
      XCTAssertTrue(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      XCTAssertEqual(delegate.willCalls, 0)
      editingOpen = false
      storage.endEditing()
      XCTAssertEqual(delegate.willCalls, 1)
      XCTAssertEqual(delegate.didCalls, 1)
      XCTAssertEqual(delegate.firstWillSequence, s + 1)
      XCTAssertEqual(delegate.phase, 3)
      XCTAssertFalse(delegate.overflow)
    }

    // Break caught: successful equal characters skip scalar observation or edited notification.
    func testEqualCharacterPrimitiveStillCompletesAndNotifies() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let delegate = Task1APrimitiveDelegate(route: .equal, startingSequence: s)
      let original = storage.delegate
      storage.delegate = delegate
      defer {
        storage.delegate = original
        withExtendedLifetime(delegate) {}
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "a")
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "ab")
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.kind, .characters)
      XCTAssertEqual(stamp.replacementUTF16Count, 1)
      XCTAssertFalse(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      editingOpen = false
      storage.endEditing()
      XCTAssertEqual(delegate.willCalls, 1)
      XCTAssertEqual(delegate.didCalls, 1)
      XCTAssertEqual(delegate.phase, 3)
      XCTAssertFalse(delegate.overflow)
    }

    // Break caught: attributes are mislabeled as characters or observation follows edited.
    func testAttributePrimitiveHasNoCharacterPayload() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let delegate = Task1APrimitiveDelegate(route: .attributes, startingSequence: s)
      let original = storage.delegate
      storage.delegate = delegate
      defer {
        storage.delegate = original
        withExtendedLifetime(delegate) {}
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.setAttributes([.kern: NSNumber(value: 2)], range: NSRange(location: 0, length: 2))
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "ab")
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.kind, .attributes)
      XCTAssertEqual(stamp.range, NSRange(location: 0, length: 2))
      XCTAssertEqual(stamp.beforeUTF16Count, 2)
      XCTAssertEqual(stamp.afterUTF16Count, 2)
      XCTAssertNil(stamp.replacementUTF16Count)
      XCTAssertFalse(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      XCTAssertEqual(
        (storage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 2)
      editingOpen = false
      storage.endEditing()
      XCTAssertEqual(delegate.willCalls, 1)
      XCTAssertEqual(delegate.didCalls, 1)
      XCTAssertEqual(delegate.phase, 3)
      XCTAssertFalse(delegate.overflow)
    }

    // Break caught: merely reading string/length/attributes falsely advances the primitive serial.
    func testReadOnlyAccessDoesNotCreateACompletedPrimitive() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "ab")
      XCTAssertEqual(storage.length, 2)
      _ = storage.attributes(at: 0, effectiveRange: nil)
      XCTAssertEqual(storage.nativeMacroTestPrimitiveSequence, s)
      XCTAssertEqual(storage.nativeMacroTestLastPrimitiveCommit, stamp)
      XCTAssertFalse(storage.nativeMacroTestSequenceExhausted)
    }

    // Break caught: inherited mutableString writes bypass the real character primitive.
    func testMutableStringReplacementReachesCharacterPrimitive() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.mutableString.replaceCharacters(in: NSRange(location: 0, length: 1), with: "😀")
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "😀b")
      XCTAssertEqual(storage.length, 3)
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.kind, .characters)
      XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
      XCTAssertEqual(stamp.beforeUTF16Count, 2)
      XCTAssertEqual(stamp.afterUTF16Count, 3)
      XCTAssertEqual(stamp.replacementUTF16Count, 2)
      XCTAssertTrue(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      editingOpen = false
      storage.endEditing()
    }

    // Break caught: setAttributedString changes real content/attributes without any scalar commit.
    // The inherited route may use several primitives; no one-call claim is manufactured.
    func testSetAttributedStringReachesActualPrimitiveObservation() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let replacement = NSAttributedString(string: "😀b", attributes: [.kern: NSNumber(value: 7)])
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.setAttributedString(replacement)
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "😀b")
      XCTAssertEqual(storage.length, 3)
      XCTAssertGreaterThan(storage.nativeMacroTestPrimitiveSequence, s)
      XCTAssertEqual(stamp.sequence, storage.nativeMacroTestPrimitiveSequence)
      XCTAssertEqual(stamp.afterUTF16Count, 3)
      XCTAssertFalse(stamp.backingReentry)
      XCTAssertFalse(stamp.sequenceExhausted)
      switch stamp.kind {
      case .characters:
        XCTAssertEqual(stamp.beforeUTF16Count, 2)
        XCTAssertEqual(stamp.replacementUTF16Count, 3)
        XCTAssertTrue(stamp.changedCharacters)
      case .attributes:
        XCTAssertEqual(stamp.beforeUTF16Count, 3)
        XCTAssertNil(stamp.replacementUTF16Count)
        XCTAssertFalse(stamp.changedCharacters)
      }
      XCTAssertEqual(
        (storage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 7)
      XCTAssertEqual(
        (storage.attribute(.kern, at: 2, effectiveRange: nil) as? NSNumber)?.intValue, 7)
      editingOpen = false
      storage.endEditing()
    }

    // Break caught: attributed replacement leaves stale text/attributes or bypasses metadata.
    func testAttributedReplacementPreservesSupplementaryTextAndAttributes() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let replacement = NSAttributedString(string: "😀", attributes: [.kern: NSNumber(value: 7)])
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: replacement)
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.string, "😀b")
      XCTAssertEqual(storage.length, 3)
      XCTAssertGreaterThan(storage.nativeMacroTestPrimitiveSequence, s)
      XCTAssertEqual(stamp.sequence, storage.nativeMacroTestPrimitiveSequence)
      XCTAssertEqual(stamp.afterUTF16Count, 3)
      XCTAssertFalse(stamp.backingReentry)
      XCTAssertFalse(stamp.sequenceExhausted)
      switch stamp.kind {
      case .characters:
        XCTAssertEqual(stamp.beforeUTF16Count, 2)
        XCTAssertEqual(stamp.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(stamp.replacementUTF16Count, 2)
        XCTAssertTrue(stamp.changedCharacters)
      case .attributes:
        XCTAssertEqual(stamp.beforeUTF16Count, 3)
        XCTAssertNil(stamp.replacementUTF16Count)
        XCTAssertFalse(stamp.changedCharacters)
      }
      XCTAssertEqual(
        (storage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 7)
      XCTAssertEqual(
        (storage.attribute(.kern, at: 1, effectiveRange: nil) as? NSNumber)?.intValue, 7)
      editingOpen = false
      storage.endEditing()
    }

    // Break caught: equal-content comparison incorrectly stops at its4096-unit chunk boundary.
    func testEqualComparisonCrosses4096UnitBoundary() throws {
      let storage = DocumentCommitTextStorage()
      let text = String(repeating: "x", count: 4096) + "😀"
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(in: NSRange(location: 0, length: 4098), with: text)
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.length, 4098)
      XCTAssertEqual((storage.string as NSString).character(at: 4096), 0xD83D)
      XCTAssertEqual((storage.string as NSString).character(at: 4097), 0xDE00)
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.beforeUTF16Count, 4098)
      XCTAssertEqual(stamp.afterUTF16Count, 4098)
      XCTAssertEqual(stamp.replacementUTF16Count, 4098)
      XCTAssertFalse(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      editingOpen = false
      storage.endEditing()
    }

    // Break caught: matching first chunk falsely hides a different final UTF16 unit.
    func testChangedComparisonIncludesUnitAfter4096Boundary() throws {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(
        in: NSRange(location: 0, length: 0),
        with: String(repeating: "x", count: 4096) + "a")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(
        in: NSRange(location: 0, length: 4097),
        with: String(repeating: "x", count: 4096) + "b")
      let stamp = try XCTUnwrap(storage.nativeMacroTestLastPrimitiveCommit)
      XCTAssertEqual(storage.length, 4097)
      XCTAssertEqual((storage.string as NSString).character(at: 4096), 0x0062)
      XCTAssertEqual(stamp.sequence, s + 1)
      XCTAssertEqual(stamp.beforeUTF16Count, 4097)
      XCTAssertEqual(stamp.afterUTF16Count, 4097)
      XCTAssertEqual(stamp.replacementUTF16Count, 4097)
      XCTAssertTrue(stamp.changedCharacters)
      XCTAssertFalse(stamp.backingReentry)
      editingOpen = false
      storage.endEditing()
    }

    // Break caught: depth is held across edited, so an actual processing child is
    // falsely marked backing reentry, or last-value metadata retains the outer stamp.
    func testWillProcessChildCompletesWithRestoredBackingDepth() {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let delegate = Task1APrimitiveDelegate(route: .child, startingSequence: s)
      let original = storage.delegate
      storage.delegate = delegate
      defer {
        storage.delegate = original
        withExtendedLifetime(delegate) {}
      }
      var editingOpen = true
      storage.beginEditing()
      defer { if editingOpen { storage.endEditing() } }
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
      editingOpen = false
      storage.endEditing()
      XCTAssertEqual(storage.string, "XY")
      XCTAssertEqual(delegate.firstWillSequence, s + 1)
      XCTAssertGreaterThanOrEqual(delegate.didSequence ?? 0, s + 2)
      XCTAssertEqual(delegate.willCalls, 1)
      XCTAssertEqual(delegate.didCalls, 1)
      XCTAssertEqual(delegate.phase, 3)
      XCTAssertFalse(delegate.overflow)
    }

    // Break caught: private D fails to install actual custom storage before panes,
    // or its unchanged did-process observer no longer follows the committed primitive.
    func testPrivateDocumentOwnsCustomStorageWithUnchangedSharedPaneObserver() throws {
      let document = EditorDocument()
      let text: NSTextStorage = document.storage
      let storage = try XCTUnwrap(text as? DocumentCommitTextStorage)
      document.storage.mutableString.setString("ab")
      document.savedText = "ab"
      let first = try XCTUnwrap(document.panePool.first)
      let second = try document.makePane()
      XCTAssertTrue(first.document === document)
      XCTAssertTrue(second.document === document)
      XCTAssertTrue(first.layoutManager.textStorage === storage)
      XCTAssertTrue(second.layoutManager.textStorage === storage)
      XCTAssertTrue(first.editor.textStorage === storage)
      XCTAssertTrue(second.editor.textStorage === storage)
      XCTAssertEqual(storage.layoutManagers.count, 2)
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let revision = document.editRevision
      let ownership = document.ownershipGeneration
      var callbacks = 0
      let previous = document.onCharactersChanged
      document.onCharactersChanged = {
        callbacks += 1
        XCTAssertEqual(storage.string, "😀b")
        XCTAssertGreaterThanOrEqual(storage.nativeMacroTestPrimitiveSequence, s + 1)
        XCTAssertEqual(
          storage.nativeMacroTestLastPrimitiveCommit?.sequence,
          storage.nativeMacroTestPrimitiveSequence)
      }
      defer { document.onCharactersChanged = previous }
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "😀")
      XCTAssertEqual(document.editRevision, revision + 1)
      XCTAssertEqual(callbacks, 1)
      XCTAssertTrue(document.dirty)
      XCTAssertEqual(document.ownershipGeneration, ownership)
      XCTAssertFalse(document.searchRevisionExhausted)
      XCTAssertTrue(first.layoutManager.textStorage === second.layoutManager.textStorage)
    }

    // Break caught: metadata is published after edited returns rather than before its
    // synchronous first will callback. There is no outer editing bracket to defer it.
    func testUnbracketedCharacterPrimitiveIsPublishedBeforeFirstWillProcess() {
      let storage = DocumentCommitTextStorage()
      storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
      let s = storage.nativeMacroTestPrimitiveSequence
      guard s < UInt64.max - 2 else {
        XCTFail("Fresh bounded primitive sequence is unusable")
        return
      }
      let delegate = Task1APrimitiveDelegate(route: .supplementary, startingSequence: s)
      let original = storage.delegate
      storage.delegate = delegate
      defer {
        storage.delegate = original
        withExtendedLifetime(delegate) {}
      }
      XCTAssertEqual(delegate.willCalls, 0)
      XCTAssertEqual(delegate.didCalls, 0)
      XCTAssertNil(delegate.firstWillSequence)
      XCTAssertEqual(delegate.phase, 0)
      // The unchanged real delegate reads the exact outer character stamp at first
      // will: s+1, range0/1, before2/after3/replacement2, changedtrue, exhaustedfalse,
      // backingReentryfalse and committed 😀b. Attribute fixing follows that read.
      storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "😀")
      XCTAssertEqual(storage.string, "😀b")
      XCTAssertEqual(storage.length, 3)
      XCTAssertEqual(delegate.willCalls, 1)
      XCTAssertEqual(delegate.didCalls, 1)
      XCTAssertEqual(delegate.firstWillSequence, s + 1)
      XCTAssertGreaterThanOrEqual(delegate.didSequence ?? 0, s + 1)
      XCTAssertEqual(delegate.phase, 3)
      XCTAssertFalse(delegate.overflow)
      XCTAssertFalse(storage.nativeMacroTestSequenceExhausted)
    }
  }
#endif
