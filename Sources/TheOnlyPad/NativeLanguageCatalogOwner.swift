// SPDX-License-Identifier: MIT
import Foundation
import PadCore

enum NativeLanguageCatalogLifetime { case active, invalidated }
struct NativeLanguageCatalogPublication {
  let id: UUID
  let requestID: UUID
  let catalog: LanguageCatalogSnapshot
}
struct NativeLanguageCatalogFailure {
  let requestID: UUID
  let underlyingError: any Error
}
struct NativeLanguageCatalogState {
  let lifetime: NativeLanguageCatalogLifetime
  let activeRequestID: UUID?
  let lastSettledRequestID: UUID?
  let current: NativeLanguageCatalogPublication?
  let failure: NativeLanguageCatalogFailure?
}
enum NativeLanguageCatalogAdmission {
  case started(requestID: UUID)
  case busy(activeRequestID: UUID)
  case invalidated
}

/// Owns read-only catalog truth. Invalidation withdraws authority before joining real I/O.
@MainActor final class NativeLanguageCatalogOwner {
  private struct Confirmation {
    let receipt: LoadedLanguageCatalog
    let publicationID: UUID
    let requestID: UUID
  }
  private struct Worker {
    let requestID: UUID
    let producer: Task<LoadedLanguageCatalog, Error>
    let settlement: Task<Void, Never>
  }

  private let read: @Sendable () throws -> LoadedLanguageCatalog
  private var lifetime = NativeLanguageCatalogLifetime.active
  private var activeRequestID: UUID?
  private var lastSettledRequestID: UUID?
  private var confirmed: Confirmation?
  private var failure: NativeLanguageCatalogFailure?
  private var worker: Worker?
  private var observer: (@MainActor (NativeLanguageCatalogState) -> Void)?

  init(store: CustomLanguageStore) {
    read = { try store.load() }
  }
  init(read: @escaping @Sendable () throws -> LoadedLanguageCatalog) {
    self.read = read
  }

  var state: NativeLanguageCatalogState {
    let current = confirmed.map {
      NativeLanguageCatalogPublication(
        id: $0.publicationID, requestID: $0.requestID, catalog: $0.receipt.snapshot)
    }
    return NativeLanguageCatalogState(
      lifetime: lifetime, activeRequestID: activeRequestID,
      lastSettledRequestID: lastSettledRequestID, current: current, failure: failure)
  }
  var onChange: (@MainActor (NativeLanguageCatalogState) -> Void)? {
    get { observer }
    set {
      guard case .active = lifetime else { return }
      observer = newValue
    }
  }

  func requestLoad() -> NativeLanguageCatalogAdmission {
    guard case .active = lifetime else { return .invalidated }
    if let activeRequestID { return .busy(activeRequestID: activeRequestID) }
    let requestID = UUID()
    activeRequestID = requestID
    notify()
    // The loading observer can withdraw authority before any read is launched.
    guard case .active = lifetime, activeRequestID == requestID else { return .invalidated }

    let load = read
    let producer = Task.detached(priority: .utility) { [load] in try load() }
    let settlement = Task<Void, Never> { @MainActor [weak self, producer] in
      let result = await producer.result
      // Do not retain the owner across a potentially stalled synchronous read.
      guard let self else { return }
      self.settle(result, requestID: requestID)
    }
    // This synchronous MainActor method has not suspended since launch. Both handles
    // are installed before settlement can run and before started is returned.
    worker = Worker(requestID: requestID, producer: producer, settlement: settlement)
    return .started(requestID: requestID)
  }

  func invalidate() {
    lifetime = .invalidated
    observer = nil
    confirmed = nil
    failure = nil
    activeRequestID = nil
    lastSettledRequestID = nil
    // Retain a running read and its settlement until real completion; no hard cancel.
  }

  func invalidateAndWait() async {
    let settlement = worker?.settlement
    invalidate()
    if let settlement { await settlement.value }
  }

  private func settle(_ result: Result<LoadedLanguageCatalog, Error>, requestID: UUID) {
    guard worker?.requestID == requestID else { return }
    // Producer completion is already awaited. Retire this record before any callout,
    // allowing a terminal observer's new request to own a distinct worker safely.
    worker = nil
    guard case .active = lifetime, activeRequestID == requestID else { return }
    activeRequestID = nil
    lastSettledRequestID = requestID
    switch result {
    case .success(let loaded):
      confirmed = Confirmation(receipt: loaded, publicationID: UUID(), requestID: requestID)
      failure = nil
    case .failure(let error):
      // Failed reconciliation preserves the exact last confirmed receipt/publication.
      failure = NativeLanguageCatalogFailure(requestID: requestID, underlyingError: error)
    }
    // Final old-frame operation: the observer may invalidate or synchronously launch
    // a successor. No deferred cleanup or state mutation follows this delivery.
    notify()
  }

  private func notify() {
    let snapshot = state
    let callback = observer
    callback?(snapshot)
  }
}
