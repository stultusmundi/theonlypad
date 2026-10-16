// FROZEN read-only scheduling facts; no pause, checkpoint request, permission, or publication synthesis.
extension NativeApplicationDocuments {
  var locatePresentationTestCheckpointIdle: Bool {
    checkpoints.lastAcknowledgedGeneration > 0 && !checkpoints.hasPendingChanges
  }
}
