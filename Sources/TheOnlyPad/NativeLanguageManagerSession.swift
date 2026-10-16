// SPDX-License-Identifier: MIT
import Foundation
import PadCore

struct NativeLanguageManagerCatalogSnapshot {
  let deliveryID: UUID
  let read: NativeLanguageCatalogState
  let mutation: NativeLanguageCatalogMutationState
}

enum NativeLanguageManagerRefreshAdmission {
  case forwarded(NativeLanguageCatalogAdmission)
  case unavailable
}

/// Presentation lifetime only. App owns observation; the existing catalog owner owns all work.
@MainActor final class NativeLanguageManagerSession {
  private let owner: NativeLanguageCatalogOwner
  private var current: (@MainActor () -> Bool)?
  private(set) var snapshot: NativeLanguageManagerCatalogSnapshot?
  private(set) var isAttached = true
  private var observer: (@MainActor (NativeLanguageManagerCatalogSnapshot) -> Void)?
  var onChange: (@MainActor (NativeLanguageManagerCatalogSnapshot) -> Void)? {
    get { observer }
    set {
      guard isAttached else { return }
      let previous = observer
      observer = newValue
      withExtendedLifetime(previous) {}
    }
  }

  init(owner: NativeLanguageCatalogOwner) { self.owner = owner }

  func receive(
    _ snapshot: NativeLanguageManagerCatalogSnapshot,
    isCurrent: @escaping @MainActor () -> Bool
  ) {
    guard isAttached else { return }
    let previous = (self.snapshot, current)
    defer { withExtendedLifetime(previous) {} }
    self.snapshot = snapshot
    current = isCurrent
    guard isCurrentDelivery(snapshot.deliveryID) else { return }
    let callback = observer
    callback?(snapshot)
    // A callback can close this session or synchronously deliver its successor. No later mutation.
  }

  func isCurrentDelivery(_ id: UUID) -> Bool {
    guard isAttached, snapshot?.deliveryID == id, let current else { return false }
    let accepted = current()
    return accepted && isAttached && snapshot?.deliveryID == id
  }

  func requestRefresh() -> NativeLanguageManagerRefreshAdmission {
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID),
      case .active = owner.state.lifetime
    else { return .unavailable }
    let mutation = owner.mutationState
    guard mutation.activeOperation == nil, mutation.preparedQuitID == nil,
      mutation.unresolved == nil
    else { return .unavailable }
    // Synchronous admission may call back into App. This session does no work afterward.
    return .forwarded(owner.requestLoad())
  }

  func detach() {
    guard isAttached else { return }
    let previous = (snapshot, current, observer)
    isAttached = false
    snapshot = nil
    current = nil
    observer = nil
    // All bindings are retired before releasing captures, whose destruction may itself call out.
    withExtendedLifetime(previous) {}
  }
}
