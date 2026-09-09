import AppKit
import PadCore

/// Pure presentation. The owner validates live action authority when a button is invoked.
@MainActor final class DocumentDiskStatusView: NSStackView {
  enum Action: Equatable { case checkAgain, resolve, retryMonitoring }
  private let message = NSTextField(wrappingLabelWithString: "")
  private let checkButton = NSButton(title: "", target: nil, action: nil)
  private let resolveButton = NSButton(title: "", target: nil, action: nil)
  private let retryButton = NSButton(title: "", target: nil, action: nil)
  private let onAction: (Action) -> Void

  init(onAction: @escaping (Action) -> Void) {
    self.onAction = onAction
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 8
    edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    setAccessibilityIdentifier("document.diskStatus")
    message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    message.setContentHuggingPriority(.defaultLow, for: .horizontal)
    addArrangedSubview(message)
    configure(checkButton, title: "Check Again", label: "Check Again", id: "document.checkDisk")
    configure(
      resolveButton, title: "Resolve…", label: "Resolve Disk Change",
      id: "document.resolveDiskChange")
    configure(
      retryButton, title: "Retry Monitoring", label: "Retry Monitoring",
      id: "document.retryMonitoring")
    render(
      state: ObservedFileState(), manualNotice: nil, failure: nil, hasSource: false, enabled: false)
  }
  required init?(coder: NSCoder) { fatalError("Use action initializer") }

  private func localized(_ text: String) -> String {
    NSLocalizedString(text, comment: "Document file status")
  }
  private func configure(_ button: NSButton, title: String, label: String, id: String) {
    button.title = localized(title)
    button.bezelStyle = .rounded
    button.target = self
    button.action = #selector(invoke(_:))
    button.setAccessibilityIdentifier(id)
    button.setAccessibilityLabel(localized(label))
    addArrangedSubview(button)
  }
  func render(
    state: ObservedFileState, manualNotice: String?, failure: MonitorFailure?,
    hasSource: Bool, enabled: Bool
  ) {
    var reasons: [String] = []
    if state.noticeIsProminent, let observation = state.observation {
      if observation.content == .differsFromBaseline {
        reasons.append(localized("The file changed on disk."))
      }
      if observation.readOnlyHint { reasons.append(localized("The file or folder is read-only.")) }
      if let problem = observation.locationProblem {
        let reason: String
        switch problem {
        case .missing: reason = "The original file is missing."
        case .inaccessible: reason = "The file cannot be accessed."
        case .symbolicLink: reason = "The source is now a symbolic link."
        case .nonregular: reason = "The source is not a regular file."
        case .parentChanged: reason = "The source folder changed."
        case .changedDuringRead: reason = "The file changed while it was being checked."
        case .unsupportedVolume: reason = "Automatic checking is unsupported on this volume."
        case .tooLarge: reason = "The file exceeds the 100 MB checking limit."
        case .checkDelayed: reason = "Checking the file is delayed or unavailable."
        case .notDownloaded:
          reason = "The file is not downloaded. Download it explicitly before checking again."
        }
        reasons.append(localized(reason))
      } else if observation.content == .unavailable || observation.metadata == nil {
        reasons.append(localized("The file status could not be verified."))
      }
      if observation.movedCandidate != nil {
        reasons.append(localized("The file may have moved. Resolve to review its location."))
      }
    }
    if let manualNotice {
      reasons.append(
        manualNotice.isEmpty
          ? localized("Automatic monitoring is unavailable. Use manual checks.") : manualNotice)
    }
    var retryRelevant = manualNotice != nil
    if let failure {
      switch failure {
      case .capacity:
        reasons.append(localized("The automatic monitoring limit was reached."))
        retryRelevant = true
      case .unavailable:
        reasons.append(localized("Automatic monitoring is unavailable."))
        retryRelevant = true
      case .cancelled:
        reasons.append(localized("The file check was cancelled."))
      }
    }
    isHidden = !hasSource || reasons.isEmpty
    let explanation = isHidden ? "" : reasons.joined(separator: " ")
    message.stringValue = explanation
    setAccessibilityLabel(explanation)
    checkButton.isHidden = isHidden
    resolveButton.isHidden = isHidden || !state.noticeIsProminent
    retryButton.isHidden = isHidden || !retryRelevant
    for button in [checkButton, resolveButton, retryButton] {
      button.isEnabled = enabled && !isHidden && !button.isHidden
    }
  }
  @objc private func invoke(_ sender: NSButton) {
    guard !isHiddenOrHasHiddenAncestor, !sender.isHidden, sender.isEnabled else { return }
    if sender === checkButton {
      onAction(.checkAgain)
    } else if sender === resolveButton {
      onAction(.resolve)
    } else if sender === retryButton {
      onAction(.retryMonitoring)
    }
  }
}
