import Foundation
import PadCore

struct ManagedWindowCheckpointCapture: Sendable {
  let window: SessionWindow
  let liveTabIDs: Set<UUID>
  let recovery: [RecoveryCheckpointItem]
}

@MainActor struct ManagedCheckpointSources {
  let registry: ApplicationDocuments
  /// Per-document intake settlement only; excludes the publisher's own activation token.
  let requireIntakeSettled: () throws -> Void
  let requireCloseSettled: () throws -> Void
  let validateProjection: ([DocumentWindowSnapshot]) throws -> Void
  let captureWindow: (DocumentWindowSnapshot) throws -> ManagedWindowCheckpointCapture
  let preflightResources: ([DocumentWindowSnapshot]) throws -> Void
  let renderStatus: (String, (() -> Void)?) -> Void
}

struct ManagedPublisherActivation: Equatable {
  let owner: UUID
  let request: UUID
  let pause: CheckpointPauseToken
}

enum ApplicationPublisherPhase: Equatable {
  case legacy, restoring
  case activating(UUID)
  case failedActivation(UUID)
  case managed
  case preparingQuit(UUID)
  case finalReady(UUID)
  case finalizing(UUID)
}

enum ApplicationCheckpointError: Error, LocalizedError {
  case invalidPhase, invalidActivation, unsettled, invalidProjection
  var errorDescription: String? {
    switch self {
    case .invalidPhase:
      return
        "Session publication is paused for startup, close, or quit. Finish that operation and retry."
    case .invalidActivation: return "The session activation request is no longer current."
    case .unsettled:
      return
        "Document ownership has not settled. Resolve pending adoption or close before saving the session."
    case .invalidProjection:
      return
        "The displayed documents do not match session ownership. Retry after the window update completes."
    }
  }
}

/// Native compatibility adapter. Managed mode never invokes these standalone hooks.
@MainActor struct LegacyCheckpointSources {
  let capture: () throws -> [ManagedWindowCheckpointCapture]
  let prepare: () async throws -> Void
  let renderStatus: (String, (() -> Void)?) -> Void
}
