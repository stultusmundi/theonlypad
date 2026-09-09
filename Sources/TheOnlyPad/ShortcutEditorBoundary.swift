import AppKit
import PadCore

struct ShortcutEditorSnapshot {
  let catalog: [CommandDescriptor]
  let profile: ShortcutProfile
  let catalogRevision: UUID
  let profileRevision: UUID
  var status: String? = nil
  var canApply = true
  var recoveryTitle: String? = nil
}
@MainActor struct ShortcutEditorActions {
  var apply: (ShortcutProfile, UUID, UUID) async throws -> ShortcutEditorSnapshot
  var importProfile: () async throws -> ShortcutProfile? = { nil }
  var recover: (() async throws -> ShortcutEditorSnapshot)? = nil
  var exportProfile: (ShortcutProfile) async throws -> Bool = { _ in false }
}
