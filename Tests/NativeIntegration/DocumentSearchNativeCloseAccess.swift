// FROZEN-ONLY effectful stage observation: chain the actual original close-owner observer.
@MainActor private final class RepairStageObservation {
  // Test observer delivery only; never native admission or completion authority.
  var enabled = true
}
extension NativeApplicationCloseCoordinator {
  func repairTestObserveStages(_ observe: @escaping @MainActor (DocumentClosingStatus) -> Void)
    -> @MainActor () -> Void
  {
    let producer = owner
    let prior = producer.onChange
    let observation = RepairStageObservation()
    producer.onChange = { [weak producer] in
      prior?()
      guard observation.enabled, let status = producer?.status else { return }
      observe(status)
    }
    return { observation.enabled = false }
  }
}
