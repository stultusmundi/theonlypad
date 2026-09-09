import Foundation
import PadCore

extension ApplicationSessionCheckpoints {
  /// Existing AppDelegate/standalone compatibility. Managed activation uses the explicit sources initializer.
  convenience init(
    session: SessionCoordinator, windows: @escaping () -> [EditorWindowController],
    recovery: RecoveryCoordinator = .shared, onRetry: (() -> Void)? = nil
  ) {
    self.init(
      session: session, recovery: recovery,
      legacy: .init(
        capture: {
          try EditorWindowController.assertNoPendingCloses()
          let current = windows()
          guard current.count <= 32,
            current.reduce(0, { $0 + $1.sessionMetadata.tabs.count }) <= 128,
            current.reduce(0, { $0 + $1.checkpointRecoveryUTF16Count }) <= 100_000_000
          else { throw RecoveryError.resourceLimit }
          return try current.map {
            let pair = try $0.captureSessionCheckpoint()
            return ManagedWindowCheckpointCapture(
              window: pair.window, liveTabIDs: pair.liveTabIDs, recovery: pair.recovery)
          }
        }, prepare: { try await EditorWindowController.drainPendingCloses() },
        renderStatus: { message, retry in
          for window in windows() {
            window.updateSessionCheckpointStatus(message: message, retry: retry)
          }
        }), onRetry: onRetry)
  }
}
