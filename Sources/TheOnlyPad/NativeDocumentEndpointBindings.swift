import Foundation
import PadCore

enum NativeEndpointBindingError: Error {
  case invalidCapacity, capacity, stale, busy, reconciliationRequired
}
enum NativeEndpointBindingStatus {
  case detached
  case failed(Error)
}

/// Retains monitor authority, not document ownership. The registry/history/intake owns models.
@MainActor final class NativeDocumentEndpointBindings {
  nonisolated static let maximumRecords = 448
  @MainActor private struct Fence {
    let id: UUID
    let binding: UUID
    let revision: UInt64
    let ownership: UUID
    let literalURL: String?
    init(_ model: EditorDocument) {
      id = model.id
      binding = model.fileBindingID
      revision = model.baselineRevision
      ownership = model.ownershipGeneration
      literalURL = model.url?.absoluteString
    }
    func sameURL(_ url: URL?) -> Bool {
      switch (literalURL, url?.absoluteString) {
      case (nil, nil): return true
      case (.some(let old), .some(let new)): return old.utf8.elementsEqual(new.utf8)
      default: return false
      }
    }
    func matches(_ model: EditorDocument) -> Bool {
      model.id == id && model.fileBindingID == binding && model.baselineRevision == revision
        && model.ownershipGeneration == ownership && sameURL(model.url)
    }
    func matches(_ value: FileStateLiveContext) -> Bool {
      value.documentID == id && value.bindingID == binding && value.baselineRevision == revision
        && value.ownershipGeneration == ownership && sameURL(value.url)
    }
    func matches(_ value: FileStateBindingIdentity) -> Bool {
      value.documentID == id && value.bindingID == binding && value.baselineRevision == revision
        && value.ownershipGeneration == ownership && sameURL(value.url)
    }
  }
  @MainActor private final class Entry {
    weak var model: EditorDocument?
    let bridge: DocumentFileStateController
    let fence: Fence
    var receipt: FileStateEndpointDetachment?
    var error: Error?
    var transition = false
    var blocked = false
    init(_ model: EditorDocument, bridge: DocumentFileStateController) {
      self.model = model
      self.bridge = bridge
      fence = Fence(model)
    }
  }
  private final class Delivery {
    var enabled = false
    var pending = false
    var firstContextAccepted = false
    var contextCalled = false
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func receive() {
      if enabled { callback() } else { pending = true }
    }
    func activate() {
      enabled = true
      let shouldDeliver = pending
      pending = false
      if shouldDeliver { callback() }
    }
  }
  private let capacity: Int
  private var entries: [UUID: Entry] = [:]
  var retainedCount: Int { entries.count }
  init(maximumRecords: Int = NativeDocumentEndpointBindings.maximumRecords) throws {
    guard (1...Self.maximumRecords).contains(maximumRecords) else {
      throw NativeEndpointBindingError.invalidCapacity
    }
    capacity = maximumRecords
  }
  func status(documentID: UUID) -> NativeEndpointBindingStatus? {
    guard let entry = entries[documentID] else { return nil }
    return entry.error.map { .failed($0) } ?? .detached
  }
  func purgeReleasedModels() {
    entries = entries.filter { $0.value.model != nil }
  }
  private func validate(_ entry: Entry, model: EditorDocument) throws {
    guard entry.model === model, model.fileState === entry.bridge, entry.fence.matches(model) else {
      throw NativeEndpointBindingError.stale
    }
  }
  func detach(_ document: EditorDocument) throws {
    purgeReleasedModels()
    let entry: Entry
    if let existing = entries[document.id] {
      entry = existing
    } else {
      guard let bridge = document.fileState else { return }
      guard entries.count < capacity else { throw NativeEndpointBindingError.capacity }
      entry = Entry(document, bridge: bridge)
      entries[document.id] = entry
    }
    guard !entry.transition else { throw NativeEndpointBindingError.busy }
    entry.transition = true
    defer { entry.transition = false }
    do {
      try validate(entry, model: document)
      guard !entry.blocked else { throw NativeEndpointBindingError.reconciliationRequired }
      if entry.receipt == nil {
        let receipt = try entry.bridge.detachEndpoint()
        entry.receipt = receipt  // Retain authority before any later validation can fail.
        guard entry.fence.matches(receipt.binding) else { throw NativeEndpointBindingError.stale }
      }
      try validate(entry, model: document)
      entry.error = nil
    } catch {
      entry.error = error
      throw error
    }
  }
  func reattach(
    _ document: EditorDocument, liveContext: @escaping () -> FileStateLiveContext?,
    onChange: @escaping () -> Void
  ) throws {
    purgeReleasedModels()
    guard let entry = entries[document.id] else {
      if document.fileState == nil { return }
      throw NativeEndpointBindingError.stale
    }
    guard !entry.transition else { throw NativeEndpointBindingError.busy }
    entry.transition = true
    let delivery = Delivery(onChange)
    do {
      try validate(entry, model: document)
      guard !entry.blocked else { throw NativeEndpointBindingError.reconciliationRequired }
      guard let receipt = entry.receipt, entry.fence.matches(receipt.binding) else {
        throw NativeEndpointBindingError.stale
      }
      let fence = entry.fence
      let bridge = entry.bridge
      let guardedContext: () -> FileStateLiveContext? = { [weak document, weak bridge] in
        guard let document, let bridge, document.fileState === bridge,
          document.id == fence.id, document.ownershipGeneration == fence.ownership
        else {
          return nil
        }
        // Freeze only the transition. Later acknowledged saves have a new live baseline.
        let expected = delivery.enabled ? Fence(document) : fence
        guard expected.matches(document) else { return nil }
        let value = liveContext()
        let valid =
          document.fileState === bridge && expected.matches(document)
          && value.map { expected.matches($0) && !$0.closed && !$0.quitting } == true
        if !delivery.contextCalled {
          delivery.contextCalled = true
          delivery.firstContextAccepted = valid
        }
        return valid ? value : nil
      }
      try bridge.reattachEndpoint(
        receipt, expectedBinding: receipt.binding,
        liveContext: guardedContext, onChange: { delivery.receive() })
      try validate(entry, model: document)
      guard entries[document.id] === entry else { throw NativeEndpointBindingError.stale }
      entries[document.id] = nil
      entry.transition = false
    } catch {
      // Once the bridge accepted the first context, a later failure may have consumed the receipt.
      // Retain explicit reconciliation state; never manufacture or guess a replacement token.
      if delivery.firstContextAccepted { entry.blocked = true }
      entry.error = error
      entry.transition = false
      throw error
    }
    delivery.activate()
    // No cleanup after external rendering: it may already have installed a newer detachment.
  }
}
