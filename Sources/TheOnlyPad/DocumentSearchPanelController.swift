// SPDX-License-Identifier: MIT
import AppKit
import PadCore
import SearchExecution

@MainActor
final class DocumentSearchPanelController: NSWindowController, NSWindowDelegate,
  NSSearchFieldDelegate
{
  private let queryField = NSSearchField()
  private let replacementField = NSTextField()
  private let mode = NSPopUpButton()
  private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
  private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
  private let findButton = NSButton(title: "Find All", target: nil, action: nil)
  private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
  private let nextButton = NSButton(title: "Next", target: nil, action: nil)
  private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel Search", target: nil, action: nil)
  private let status = NSTextField(labelWithString: "Idle")
  private let approvalRow = NSStackView()
  private let approveButton = NSButton(title: "Replace", target: nil, action: nil)
  private let rejectButton = NSButton(title: "Cancel Replacement", target: nil, action: nil)
  private var session: DocumentSearchSession?
  private var renderedState: DocumentSearchSessionState = .idle
  private var displayedApproval: DocumentSearchApprovalToken?
  private var logicallyClosed = false
  private var renderIntent = UUID()
  private let onClose: @MainActor (DocumentSearchPanelController) -> Void

  init(
    owner: ApplicationSearchOwner, window: ApplicationSearchWindowID,
    source: any ApplicationDocumentSearchSource,
    onClose: @escaping @MainActor (DocumentSearchPanelController) -> Void = { _ in }
  ) throws {
    self.onClose = onClose
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
      styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    panel.title = "Find and Replace"
    panel.delegate = self
    queryField.placeholderString = "Find"
    queryField.setAccessibilityLabel("Find text")
    replacementField.placeholderString = "Replace with"
    replacementField.setAccessibilityLabel("Replacement text")
    mode.addItems(withTitles: ["Literal", "Escaped text", "Regular expression (ICU)"])
    mode.setAccessibilityLabel("Search mode")
    matchCase.state = .on
    queryField.delegate = self
    replacementField.delegate = self
    let bindings: [(NSControl, Selector)] = [
      (queryField, #selector(find)), (findButton, #selector(find)),
      (replaceButton, #selector(replaceAll)), (nextButton, #selector(next)),
      (previousButton, #selector(previous)), (cancelButton, #selector(cancelSearch)),
      (mode, #selector(optionsChanged)), (matchCase, #selector(optionsChanged)),
      (wholeWord, #selector(optionsChanged)), (approveButton, #selector(approveReplacement)),
      (rejectButton, #selector(rejectReplacement)),
    ]
    for (control, action) in bindings {
      control.target = self
      control.action = action
    }
    approvalRow.addArrangedSubview(approveButton)
    approvalRow.addArrangedSubview(rejectButton)
    let options = NSStackView(views: [mode, matchCase, wholeWord])
    let actions = NSStackView(views: [
      findButton, previousButton, nextButton, replaceButton, cancelButton,
    ])
    let stack = NSStackView(views: [
      queryField, replacementField, options, actions, status, approvalRow,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    panel.contentView = stack
    for field in [queryField, replacementField] {
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    panel.initialFirstResponder = queryField
    render(.idle)
    do {
      session = try DocumentSearchSession(
        owner: owner, window: window, source: source,
        onState: { [weak self] state in self?.render(state) })
    } catch {
      // Attachment owns no parent ticket; failed duplicate admission must preserve its occupant.
      panel.delegate = nil
      super.close()
      throw error
    }
  }

  required init?(coder: NSCoder) { nil }

  override func close() {
    retire()
    super.close()
  }

  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === window else { return }
    retire()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      field === queryField || field === replacementField
    else { return }
    cancelSearch()
  }

  @objc private func find() { start(replacing: false) }
  @objc private func replaceAll() { start(replacing: true) }
  @objc private func next() {
    guard !logicallyClosed else { return }
    _ = session?.next()
  }
  @objc private func previous() {
    guard !logicallyClosed else { return }
    _ = session?.previous()
  }
  @objc private func cancelSearch() {
    guard !logicallyClosed else { return }
    guard clearApproval() else { return }
    session?.cancel()
  }
  @objc private func optionsChanged() { cancelSearch() }
  @objc private func approveReplacement() {
    guard let token = displayedApproval else { return }
    _ = respondToApproval(token, approved: true)
  }
  @objc private func rejectReplacement() {
    guard let token = displayedApproval else { return }
    _ = respondToApproval(token, approved: false)
  }

  private func start(replacing: Bool) {
    guard !logicallyClosed, let session else { return }
    let searchMode: SearchMode =
      mode.indexOfSelectedItem == 2 ? .regex : mode.indexOfSelectedItem == 1 ? .escaped : .literal
    let query = SearchQuery(
      pattern: queryField.stringValue, mode: searchMode,
      caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on)
    let operation: SearchExecutionOperation =
      replacing ? .replace(template: replacementField.stringValue) : .find
    guard clearApproval() else { return }
    do {
      let limits = try SearchWireLimits(
        maxTextUTF16: 100_000_000, maxOutputUTF16: 100_000_000,
        maxMatches: 100_000, cooperativeMilliseconds: 1000)
      try session.start(query: query, operation: operation, scope: nil, limits: limits)
    } catch {
      // Session publishes its genuine failure or a newer reentrant state. Never overwrite either.
    }
  }

  private func respondToApproval(_ token: DocumentSearchApprovalToken, approved: Bool) -> Bool {
    guard !logicallyClosed, displayedApproval == token, let session else { return false }
    guard clearApproval() else { return false }
    return session.resolveApproval(token, approved: approved)
  }

  private func clearApproval() -> Bool {
    guard !logicallyClosed else { return false }
    let intent = UUID()
    renderIntent = intent
    displayedApproval = nil
    approvalRow.isHidden = true
    guard renderIntent == intent, !logicallyClosed else { return false }
    approveButton.isEnabled = false
    guard renderIntent == intent, !logicallyClosed else { return false }
    rejectButton.isEnabled = false
    return renderIntent == intent && !logicallyClosed
  }

  private func retire() {
    guard !logicallyClosed else { return }
    logicallyClosed = true
    render(.closed)
    session?.close()
    // The real session closes its consumer before this callback can reenter.
    onClose(self)
  }

  private func render(_ value: DocumentSearchSessionState) {
    guard !logicallyClosed || value == .closed else { return }
    let intent = UUID()
    renderIntent = intent
    renderedState = value
    let closed = value == .closed
    let navigation: Bool
    let token: DocumentSearchApprovalToken?
    let message: String
    switch value {
    case .idle:
      navigation = false
      token = nil
      message = "Idle"
    case .searching:
      navigation = false
      token = nil
      message = "Searching…"
    case .results(let count, let selected):
      navigation = count > 0
      token = nil
      message = selected.map { "Match \($0 + 1) of \(count) (wrap enabled)" } ?? "\(count) matches"
    case .awaitingApproval(let approval, let count):
      navigation = false
      token = approval
      message = "Replace \(count) matches?"
    case .replaced(let count):
      navigation = false
      token = nil
      message = "Replaced \(count) matches."
    case .failed:
      navigation = false
      token = nil
      message = "Search stopped. Check the query or search again."
    case .closed:
      navigation = false
      token = nil
      message = "Closed"
    }
    displayedApproval = token
    let interactive: [NSControl] = [
      queryField, replacementField, mode, matchCase, wholeWord,
      findButton, replaceButton, cancelButton,
    ]
    for control in interactive {
      guard renderIntent == intent else { return }
      control.isEnabled = !closed
    }
    guard renderIntent == intent else { return }
    previousButton.isEnabled = navigation
    guard renderIntent == intent else { return }
    nextButton.isEnabled = navigation
    guard renderIntent == intent else { return }
    approvalRow.isHidden = token == nil
    guard renderIntent == intent else { return }
    approveButton.isEnabled = token != nil
    guard renderIntent == intent else { return }
    rejectButton.isEnabled = token != nil
    guard renderIntent == intent else { return }
    status.stringValue = message
  }
}
