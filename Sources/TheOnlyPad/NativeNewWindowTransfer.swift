import Foundation

enum NativeDocumentMoveTarget: Equatable {
  case existing(NativeDocumentMoveDestination)
  case newWindow
}

struct NativeNewWindowMoveID: Equatable {
  fileprivate let value = UUID()
}

enum NativeNewWindowPreparationResult {
  case prepared(NativeDocumentMoveDestination)
  case cancelled
  case retained(Error)
}

enum NativeNewWindowPreparationError: Error, LocalizedError {
  case busy, changed, expired, cleanupChanged
  var errorDescription: String? {
    switch self {
    case .busy: return "Finish the pending new-window preparation before continuing."
    case .changed: return "The document or workspace changed. Choose the destination again."
    case .expired: return "This new-window preparation is no longer current."
    case .cleanupChanged:
      return
        "The provisional window changed. Recovery must preserve it until its ownership is resolved."
    }
  }
}
