import Foundation
import PadCore

/// Connects the single checkpoint writer to live windows and session metadata.
/// Capture and rendering run on MainActor; filesystem work stays on the recovery actor.
@MainActor final class ApplicationSessionCheckpoints {
  private let session: SessionCoordinator
  private let windows: () -> [EditorWindowController]
  private let recovery: RecoveryCoordinator
  private let onRetry: (() -> Void)?
  private lazy var scheduler = makeScheduler()

  init(
    session: SessionCoordinator, windows: @escaping () -> [EditorWindowController],
    recovery: RecoveryCoordinator = .shared, onRetry: (() -> Void)? = nil
  ) {
    self.session = session
    self.windows = windows
    self.recovery = recovery
    self.onRetry = onRetry
  }

  var lastAcknowledgedGeneration: UInt64 { scheduler.lastAcknowledgedGeneration }
  var lastError: Error? { scheduler.lastError }
  var hasPendingChanges: Bool { scheduler.hasPendingChanges }

  func startAfterRestoration() {
    scheduler.startAfterRestoration()
    renderStatus()
  }
  func requestCheckpoint() {
    scheduler.requestCheckpoint()
    renderStatus()
  }
  func pauseAndDrain() async {
    await scheduler.pauseAndDrain()
    renderStatus()
  }
  func resumeAfterVeto() {
    scheduler.resumeAfterVeto()
    renderStatus()
  }
  func commitFinal() async throws -> SessionCheckpointReceipt {
    try await scheduler.commitFinal()
  }

  private func makeScheduler() -> SessionCheckpointCoordinator {
    let recovery = recovery
    let coordinator = SessionCheckpointCoordinator(
      capture: { [weak self] generation in
        guard let self else { throw CancellationError() }
        try EditorWindowController.assertNoPendingCloses()
        let windows = self.windows()
        guard windows.count <= 32,
          windows.reduce(0, { $0 + $1.sessionMetadata.tabs.count }) <= 128,
          windows.reduce(0, { $0 + $1.checkpointRecoveryUTF16Count }) <= 100_000_000
        else { throw RecoveryError.resourceLimit }
        let pairs = try windows.map { try $0.captureSessionCheckpoint() }
        // There is no suspension between the paired editor captures and the session merge.
        let session = try self.session.captureSession(windows: pairs.map(\.window))
        return SessionCheckpointCapture(
          generation: generation, liveTabIDs: Set(pairs.flatMap { $0.liveTabIDs }),
          recovery: pairs.flatMap(\.recovery), session: session)
      },
      commit: { capture in
        // Readback only permits a new attempt; the actor must still publish a fresh receipt.
        try await recovery.validateUncertainCheckpoint()
        return try await recovery.commitSessionCheckpoint(capture)
      },
      prepareCapture: { [weak self] in
        guard let self else { throw CancellationError() }
        try await EditorWindowController.drainPendingCloses()
        try await self.session.drainPendingRemovals()
      })
    coordinator.onStateChanged = { [weak self] in self?.renderStatus() }
    return coordinator
  }

  private func renderStatus() {
    let message: String
    let retry: (() -> Void)?
    if let error = scheduler.lastError {
      message = "Session recovery needs attention: " + error.localizedDescription
      retry = { [weak self] in
        guard let self else { return }
        if let onRetry = self.onRetry { onRetry() } else { self.requestCheckpoint() }
      }
    } else {
      message =
        scheduler.hasPendingChanges || scheduler.lastAcknowledgedGeneration == 0
        ? "Session recovery pending" : "Session recovery saved"
      retry = nil
    }
    for window in windows() {
      window.updateSessionCheckpointStatus(message: message, retry: retry)
    }
  }
}
