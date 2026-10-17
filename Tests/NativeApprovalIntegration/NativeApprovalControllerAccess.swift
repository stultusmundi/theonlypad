// SPDX-License-Identifier: MIT
// Test-only reads of existing recorder/preparation/context state; no acceptance hooks.
struct NestedStringRecorderState {
  let epoch: UUID?
  let active: Bool
  let complete: Bool
  let reason: MacroRecordingGap?
  let commands: [MacroCommand]
  let hasPreparation: Bool
  let hasExplicitFrame: Bool
}
@MainActor extension EditorWindowController {
  func nestedStringTestState() -> NestedStringRecorderState {
    NestedStringRecorderState(
      epoch: recordingIntegrity?.epoch,
      active: recordingIntegrity?.active ?? false,
      complete: recordingIntegrity != nil && recordingIntegrity?.firstReason == nil,
      reason: recordingIntegrity?.firstReason, commands: recordedCommands,
      hasPreparation: nativeEditPreparation != nil,
      hasExplicitFrame: Self.macroCommitContext?.hasActiveExplicitFrame ?? false)
  }
  static func nestedStringTestContext() -> (broker: Int, context: Int, overflow: Bool) {
    (
      approvedViewBroker.nestedStringTestRetainedEntryCount,
      macroCommitContext?.entryCount ?? 0, macroCommitContext?.overflowBarrierIsActive ?? false
    )
  }
}
