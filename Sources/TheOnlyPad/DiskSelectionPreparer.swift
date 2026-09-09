import Foundation
import PadCore

enum DiskPreparation: Sendable {
  case selections([UUID: NSRange])
  case copy(sourceName: String)
}
enum DiskPreparationResult: Sendable {
  case selections([UUID: NSRange])
  case copySeed(NativeDocumentSeed)
}
@MainActor protocol DiskSelectionPreparer: AnyObject {
  func reserve() -> UUID?
  func release(_ id: UUID)
  func prepare(
    _ id: UUID, document: DecodedDocument, preparation: DiskPreparation,
    receive: @escaping @MainActor (Result<DiskPreparationResult, Error>) -> Void)
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
    _ id: UUID, document: DecodedDocument, preparation: DiskPreparation,
    receive: @escaping @MainActor (Result<DiskPreparationResult, Error>) -> Void
  ) {
    guard reservation == id, task == nil else { preconditionFailure("Unowned CPU preparation") }
    task = Task.detached(priority: .userInitiated) { [self] in
      let result = Result<DiskPreparationResult, Error> {
        try Task<Never, Never>.checkCancellation()
        switch preparation {
        case .copy(let sourceName):
          let seed = try NativeDocumentSeed.diskCopy(sourceName: sourceName, decoded: document)
          try Task<Never, Never>.checkCancellation()
          return .copySeed(seed)
        case .selections(let selections):
          var resolved: [UUID: NSRange] = [:]
          for (pane, range) in selections {
            try Task<Never, Never>.checkCancellation()
            resolved[pane] = try RestoredViewState.resolve(
              selection: range, bookmarks: [], in: document.text
            ).selection
          }
          try Task<Never, Never>.checkCancellation()
          return .selections(resolved)
        }
      }
      await complete(id, result: result, receive: receive)
    }
  }
  private func complete(
    _ id: UUID, result: Result<DiskPreparationResult, Error>,
    receive: @escaping @MainActor (Result<DiskPreparationResult, Error>) -> Void
  ) {
    guard reservation == id else { return }
    task = nil
    reservation = nil
    receive(result)
  }
}
