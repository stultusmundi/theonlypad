import AppKit
import PadCore

@MainActor
final class SearchPanelController: NSWindowController, NSWindowDelegate {
  typealias SearchOperation =
    @Sendable (
      SearchQuery, String, String, Bool
    ) throws -> ([NSRange], String?)

  private let queryField = NSSearchField()
  private let replacementField = NSTextField()
  private let mode = NSPopUpButton()
  private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
  private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
  private let status = NSTextField(labelWithString: "Search the document that opened this panel.")
  private let snapshot: () -> String?
  private let select: (NSRange, String) -> Bool
  private let replace: (String, String) -> Bool
  private let search: SearchOperation
  private var generation = 0
  private var job: Task<SearchOutput, Error>?
  private var matches: [NSRange] = []
  private var matchedText = ""
  private var matchIndex = -1
  private struct SearchOutput: Sendable {
    let matches: [NSRange]
    let replacement: String?
  }

  init(
    snapshot: @escaping () -> String?, select: @escaping (NSRange, String) -> Bool,
    replace: @escaping (String, String) -> Bool, search: SearchOperation? = nil
  ) {
    self.snapshot = snapshot
    self.select = select
    self.replace = replace
    self.search =
      search ?? { query, text, replacement, replacing in
        let service = SearchService(
          maxTextUTF16: 100_000_000, maxOutputUTF16: 100_000_000,
          isCancelled: { withUnsafeCurrentTask { $0?.isCancelled ?? false } })
        let matches = try service.matches(query, in: text)
        let changed = replacing ? try service.replacing(query, in: text, with: replacement) : nil
        return (matches, changed)
      }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 230), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init(window: panel)
    panel.delegate = self
    panel.title = "Find and Replace"
    panel.isReleasedWhenClosed = false
    queryField.placeholderString = "Find"
    queryField.setAccessibilityLabel("Find text")
    replacementField.placeholderString = "Replace with"
    replacementField.setAccessibilityLabel("Replacement text")
    mode.addItems(withTitles: ["Literal", "Escaped text", "Regular expression (ICU)"])
    mode.setAccessibilityLabel("Search mode")
    let options = NSStackView(views: [mode, matchCase, wholeWord])
    let buttons = NSStackView()
    for (title, action) in [
      ("Find All", #selector(find)), ("Previous", #selector(previous)), ("Next", #selector(next)),
      ("Replace All…", #selector(replaceAll)), ("Cancel Search", #selector(cancel)),
    ] {
      buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
    }
    let stack = NSStackView(views: [queryField, replacementField, options, buttons, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    panel.contentView = stack
    for field in [queryField, replacementField] {
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    queryField.target = self
    queryField.action = #selector(find)
    panel.initialFirstResponder = queryField
    panel.center()
  }
  required init?(coder: NSCoder) { nil }
  override func close() {
    cancel()
    super.close()
  }
  func windowWillClose(_ notification: Notification) { cancel() }
  @objc private func find() { start(replacing: false) }
  @objc private func replaceAll() { start(replacing: true) }
  @objc private func cancel() {
    generation += 1
    job?.cancel()
    job = nil
    status.stringValue = "Search cancelled."
  }
  private func start(replacing: Bool) {
    job?.cancel()
    generation += 1
    let revision = generation
    guard let text = snapshot() else {
      status.stringValue = "The source document is closed or busy."
      return
    }
    let searchMode: SearchMode =
      mode.indexOfSelectedItem == 2 ? .regex : mode.indexOfSelectedItem == 1 ? .escaped : .literal
    let query = SearchQuery(
      pattern: queryField.stringValue, mode: searchMode, caseSensitive: matchCase.state == .on,
      wholeWord: wholeWord.state == .on)
    let replacement = replacementField.stringValue
    let search = search
    status.stringValue = "Searching…"
    let worker = Task.detached(priority: .userInitiated) {
      let (matches, changed) = try search(query, text, replacement, replacing)
      return SearchOutput(matches: matches, replacement: changed)
    }
    job = worker
    Task { [weak self] in
      do {
        let output = try await worker.value
        guard let self, self.generation == revision else { return }
        self.matches = output.matches
        self.matchedText = text
        self.matchIndex = -1
        self.status.stringValue = "\(output.matches.count) matches"
        if let changed = output.replacement {
          guard !output.matches.isEmpty else { return }
          let confirmation = NSAlert()
          confirmation.messageText = "Replace \(output.matches.count) matches?"
          confirmation.informativeText = "The entire document change can be undone in one step."
          confirmation.addButton(withTitle: "Replace All")
          confirmation.addButton(withTitle: "Cancel")
          guard confirmation.runModal() == .alertFirstButtonReturn else { return }
          guard self.generation == revision else { return }
          if self.replace(text, changed) {
            self.status.stringValue = "Replaced \(output.matches.count) matches."
            self.matches = []
          } else {
            self.status.stringValue = "The document changed. Search again before replacing."
          }
        } else {
          self.next()
        }
      } catch {
        guard let self, self.generation == revision else { return }
        self.status.stringValue = "Search stopped: \(Self.message(error))"
        self.matches = []
      }
    }
  }
  @objc private func next() { navigate(1) }
  @objc private func previous() { navigate(-1) }
  private func navigate(_ delta: Int) {
    guard !matches.isEmpty else { return }
    matchIndex = (matchIndex + delta + matches.count) % matches.count
    if select(matches[matchIndex], matchedText) {
      status.stringValue = "Match \(matchIndex + 1) of \(matches.count) (wrap enabled)"
    } else {
      matches = []
      status.stringValue = "The document changed. Search again."
    }
  }
  private static func message(_ error: Error) -> String {
    switch error {
    case SearchError.engineFailure:
      return "The search engine could not finish. Narrow the pattern and try again."
    case SearchError.invalidPattern: return "Invalid ICU regular expression."
    case SearchError.invalidEscape: return "Escaped mode supports \\n, \\r, \\t, \\0 and \\\\."
    case SearchError.timedOut: return "Time limit reached; narrow the pattern."
    case SearchError.cancelled: return "Cancelled."
    case SearchError.matchLimit: return "Too many matches; narrow the pattern."
    case SearchError.textLimit, SearchError.outputLimit:
      return "Input or replacement exceeds this build's search limit."
    default: return String(describing: error)
    }
  }
}
