import Foundation
import PadCore

@MainActor protocol DiskSelectionPreparer: AnyObject {
  func reserve() -> UUID?
  func release(_ id: UUID)
  func prepare(
    _ id: UUID, text: String, selections: [UUID: NSRange],
    receive: @escaping @MainActor (Result<[UUID: NSRange], Error>) -> Void)
}

/// One process-wide CPU slot. Cancelling a running job does not release its slot early.
@MainActor final class NativeDiskSelectionPreparer: DiskSelectionPreparer {
  static let shared = NativeDiskSelectionPreparer()
  private init() {}
  private var reservation: UUID?
  private var task: Task<Void, Never>?
  func reserve() -> UUID? {
    guard reservation == nil else { return nil }
    let id = UUID()
    reservation = id
    return id
  }
  func release(_ id: UUID) {
    guard reservation == id else { return }
    if let task { task.cancel() } else { reservation = nil }
  }
  func prepare(
    _ id: UUID, text: String, selections: [UUID: NSRange],
    receive: @escaping @MainActor (Result<[UUID: NSRange], Error>) -> Void
  ) {
    guard reservation == id, task == nil else { preconditionFailure("Unowned CPU preparation") }
    task = Task.detached(priority: .userInitiated) { [self] in
      let result = Result<[UUID: NSRange], Error> {
        var resolved: [UUID: NSRange] = [:]
        for (pane, range) in selections {
          try Task<Never, Never>.checkCancellation()
          resolved[pane] = try RestoredViewState.resolve(selection: range, bookmarks: [], in: text)
            .selection
        }
        try Task<Never, Never>.checkCancellation()
        return resolved
      }
      await complete(id, result: result, receive: receive)
    }
  }
  private func complete(
    _ id: UUID, result: Result<[UUID: NSRange], Error>,
    receive: @escaping @MainActor (Result<[UUID: NSRange], Error>) -> Void
  ) {
    guard reservation == id else { return }
    task = nil
    reservation = nil
    receive(result)
  }
}
