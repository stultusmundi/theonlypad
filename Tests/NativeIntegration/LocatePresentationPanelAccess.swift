// FROZEN read-only facts derived from actual action records, buttons and label; no inferred authority.
struct LocatePresentationPanelFacts {
  let contextButtons: Int
  let contextHandlers: Int
  let contextEnabled: Int
  let monitorButtons: Int
  let monitorHandlers: Int
  let monitorEnabled: Int
  let closeEnabled: Bool
  let consumed: Bool
  let notice: String
}
extension DocumentDiskConflictController {
  var locatePresentationTestFacts: LocatePresentationPanelFacts {
    let pairs = Array(zip(actions, actionButtons))
    let contexts = pairs.filter { $0.0.role == .capturedContext }
    let monitors = pairs.filter { $0.0.role == .monitorControl }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let labels = window?.contentView.map { descendants($0).compactMap { $0 as? NSTextField } } ?? []
    let notice =
      labels.first { $0.accessibilityIdentifier() == "document.diskConflictExplanation" }?
      .stringValue ?? ""
    return .init(
      contextButtons: contexts.count,
      contextHandlers: contexts.filter { $0.0.handler != nil }.count,
      contextEnabled: contexts.filter { $0.1.isEnabled }.count,
      monitorButtons: monitors.count,
      monitorHandlers: monitors.filter { $0.0.handler != nil }.count,
      monitorEnabled: monitors.filter { $0.1.isEnabled }.count,
      closeEnabled: closeButton.isEnabled, consumed: consumed, notice: notice)
  }
}
