import Foundation
import PadCore

struct NativeEndpointOwnershipTransferReceipt {
  fileprivate let owner: UUID
  fileprivate let issuance: UUID
  let transactionID: UUID
  let documentID: UUID
}
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
  @MainActor private final class TransferEntry {
    weak var model: EditorDocument?
    let bridge: DocumentFileStateController
    let fence: Fence
    let receipt: NativeEndpointOwnershipTransferReceipt
    let bridgeReceipt: FileStateOwnershipTransferReceipt
    var transition = false
    var error: Error?
    var delivery: Delivery?
    init(
      _ model: EditorDocument, bridge: DocumentFileStateController,
      receipt: NativeEndpointOwnershipTransferReceipt,
      bridgeReceipt: FileStateOwnershipTransferReceipt
    ) {
      self.model = model
      self.bridge = bridge
      fence = Fence(model)
      self.receipt = receipt
      self.bridgeReceipt = bridgeReceipt
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
  private let transferOwner = UUID()
  private var transfers: [UUID: TransferEntry] = [:]
  private let capacity: Int
  private var entries: [UUID: Entry] = [:]
  var retainedCount: Int { entries.count + transfers.count }
  init(maximumRecords: Int = NativeDocumentEndpointBindings.maximumRecords) throws {
    guard (1...Self.maximumRecords).contains(maximumRecords) else {
      throw NativeEndpointBindingError.invalidCapacity
    }
    capacity = maximumRecords
  }
  /// Pure reservation; caller retains the receipt before invoking any lease or endpoint callback.
  func reserveTransfer(_ document: EditorDocument, transactionID: UUID) throws
    -> NativeEndpointOwnershipTransferReceipt?
  {
    guard entries[document.id] == nil, transfers[document.id] == nil else {
      throw NativeEndpointBindingError.busy
    }
    guard let bridge = document.fileState else { return nil }
    guard retainedCount < capacity else { throw NativeEndpointBindingError.capacity }
    let receipt = NativeEndpointOwnershipTransferReceipt(
      owner: transferOwner, issuance: UUID(), transactionID: transactionID, documentID: document.id)
    let bridgeReceipt = try bridge.reserveOwnershipTransfer(
      transactionID: transactionID, expectedOwnership: document.ownershipGeneration)
    let entry = TransferEntry(
      document, bridge: bridge, receipt: receipt, bridgeReceipt: bridgeReceipt)
    transfers[document.id] = entry
    guard entry.fence.matches(bridgeReceipt.binding) else {
      entry.error = NativeEndpointBindingError.stale
      throw NativeEndpointBindingError.stale
    }
    return receipt
  }
  func retainedTransfer(documentID: UUID) -> NativeEndpointOwnershipTransferReceipt? {
    transfers[documentID]?.receipt
  }
  private func transfer(_ receipt: NativeEndpointOwnershipTransferReceipt) throws -> TransferEntry {
    guard receipt.owner == transferOwner, let entry = transfers[receipt.documentID],
      entry.receipt.issuance == receipt.issuance,
      entry.receipt.transactionID == receipt.transactionID, !entry.transition
    else { throw NativeEndpointBindingError.stale }
    return entry
  }
  private func validateTransfer(_ entry: TransferEntry) throws -> EditorDocument {
    guard let model = entry.model, model.fileState === entry.bridge, model.id == entry.fence.id,
      model.fileBindingID == entry.fence.binding, model.baselineRevision == entry.fence.revision,
      entry.fence.sameURL(model.url)
    else { throw NativeEndpointBindingError.stale }
    return model
  }
  func transferOwnership(_ receipt: NativeEndpointOwnershipTransferReceipt) throws -> UUID {
    let entry = try transfer(receipt)
    return try entry.bridge.currentTransferOwnership(entry.bridgeReceipt)
  }
  func suspendTransfer(
    _ receipt: NativeEndpointOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let entry = try transfer(receipt)
    entry.transition = true
    defer { entry.transition = false }
    do {
      _ = try validateTransfer(entry)
      try entry.bridge.suspendOwnershipTransfer(
        entry.bridgeReceipt,
        validateLease: {
          try validateLease()
          _ = try self.validateTransfer(entry)
        })
      entry.delivery = nil
      entry.error = nil
    } catch {
      entry.error = error
      throw error
    }
  }
  func attachTransfer(
    _ receipt: NativeEndpointOwnershipTransferReceipt, expectedPreviousOwnership: UUID,
    newOwnership: UUID, liveContext: @escaping () -> FileStateLiveContext?,
    onChange: @escaping () -> Void, validateLease: () throws -> Void
  ) throws {
    let entry = try transfer(receipt)
    entry.transition = true
    defer { entry.transition = false }
    let delivery = Delivery(onChange)
    do {
      let model = try validateTransfer(entry)
      guard model.ownershipGeneration == newOwnership else {
        throw NativeEndpointBindingError.stale
      }
      let bridge = entry.bridge
      let fence = entry.fence
      let guardedContext: () -> FileStateLiveContext? = { [weak model, weak bridge] in
        guard let model, let bridge, model.fileState === bridge, model.id == fence.id,
          model.ownershipGeneration == newOwnership
        else { return nil }
        let expected = delivery.enabled ? Fence(model) : fence
        guard model.fileBindingID == expected.binding, model.baselineRevision == expected.revision,
          expected.sameURL(model.url)
        else { return nil }
        let value = liveContext()
        guard model.fileState === bridge, model.ownershipGeneration == newOwnership,
          model.fileBindingID == expected.binding, model.baselineRevision == expected.revision,
          expected.sameURL(model.url),
          let value, value.documentID == model.id, value.ownershipGeneration == newOwnership,
          value.bindingID == expected.binding, value.baselineRevision == expected.revision,
          expected.sameURL(value.url), !value.closed, !value.quitting
        else { return nil }
        return value
      }
      entry.delivery = delivery
      try bridge.attachOwnershipTransfer(
        entry.bridgeReceipt, expectedPreviousOwnership: expectedPreviousOwnership,
        newOwnership: newOwnership, liveContext: guardedContext, onChange: { delivery.receive() },
        validateLease: {
          try validateLease()
          let current = try self.validateTransfer(entry)
          guard current.ownershipGeneration == newOwnership else {
            throw NativeEndpointBindingError.stale
          }
        })
      entry.error = nil
    } catch {
      entry.error = error
      throw error
    }
  }
  func finishTransfer(
    _ receipt: NativeEndpointOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let entry = try transfer(receipt)
    entry.transition = true
    do {
      let expected = try entry.bridge.currentTransferOwnership(entry.bridgeReceipt)
      try entry.bridge.finishOwnershipTransfer(
        entry.bridgeReceipt,
        validateLease: {
          try validateLease()
          let model = try self.validateTransfer(entry)
          guard model.ownershipGeneration == expected else {
            throw NativeEndpointBindingError.stale
          }
        })
      transfers[receipt.documentID] = nil
      entry.transition = false
    } catch {
      entry.error = error
      entry.transition = false
      throw error
    }
    entry.delivery?.activate()
  }
  func resolveTransferInvalidation(
    _ receipt: NativeEndpointOwnershipTransferReceipt, validateLease: () throws -> Void
  ) throws {
    let entry = try transfer(receipt)
    entry.transition = true
    defer { entry.transition = false }
    try entry.bridge.resolveOwnershipTransferInvalidation(
      entry.bridgeReceipt,
      validateLease: {
        try validateLease()
        _ = try self.validateTransfer(entry)
      })
  }
  func invalidateTransfer(
    _ receipt: NativeEndpointOwnershipTransferReceipt, validateDisposal: () throws -> Void
  ) throws {
    let entry = try transfer(receipt)
    entry.transition = true
    do {
      try entry.bridge.invalidateOwnershipTransfer(
        entry.bridgeReceipt, validateDisposal: validateDisposal)
      transfers[receipt.documentID] = nil
      entry.transition = false
    } catch {
      entry.error = error
      entry.transition = false
      throw error
    }
  }
  func status(documentID: UUID) -> NativeEndpointBindingStatus? {
    if let transfer = transfers[documentID] {
      return transfer.error.map { .failed($0) } ?? .detached
    }
    guard let entry = entries[documentID] else { return nil }
    return entry.error.map { .failed($0) } ?? .detached
  }
  func purgeReleasedModels() {
    entries = entries.filter { $0.value.model != nil }
    for entry in Array(transfers.values) where entry.model == nil && !entry.transition {
      do {
        try invalidateTransfer(
          entry.receipt,
          validateDisposal: {
            guard entry.model == nil else { throw NativeEndpointBindingError.stale }
          })
      } catch { entry.error = error }
    }
  }
  private func validate(_ entry: Entry, model: EditorDocument) throws {
    guard entry.model === model, model.fileState === entry.bridge, entry.fence.matches(model) else {
      throw NativeEndpointBindingError.stale
    }
  }
  func detach(_ document: EditorDocument) throws {
    guard transfers[document.id] == nil else { throw NativeEndpointBindingError.busy }
    purgeReleasedModels()
    let entry: Entry
    if let existing = entries[document.id] {
      entry = existing
    } else {
      guard let bridge = document.fileState else { return }
      guard retainedCount < capacity else { throw NativeEndpointBindingError.capacity }
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
    guard transfers[document.id] == nil else { throw NativeEndpointBindingError.busy }
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
