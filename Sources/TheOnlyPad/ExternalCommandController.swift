import AppKit
import PadCore

@MainActor
final class ExternalCommandController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  private static var shuttingDown = false
  private let context: CommandContext
  private let executable = NSTextField(string: "/usr/bin/printf")
  private let arguments = NSTextView()
  private let output = NSTextView()
  private let status = NSTextField(labelWithString: "Ready — nothing runs until you choose Run.")
  private let runButton = NSButton(title: "Run", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel Command", target: nil, action: nil)
  private var runner: ExternalCommandRunner?
  private var closeWhenFinished = false
  private static var active: [UUID: (ExternalCommandRunner, Task<ExternalCommandResult, Error>)] =
    [:]

  init(context: CommandContext) {
    self.context = context
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = "External Command"
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 600, height: 520)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    window.contentView = stack
    let trust = NSTextField(
      wrappingLabelWithString:
        "Commands run with your local user permissions, without a sandbox. Choose an executable you trust. Selecting a shell such as /bin/sh intentionally enables shell interpretation of its arguments. Cancellation stops the launched process; independently spawned subprocesses may continue."
    )
    stack.addArrangedSubview(trust)
    stack.addArrangedSubview(NSTextField(labelWithString: "Absolute executable path"))
    executable.setAccessibilityLabel("Executable path")
    stack.addArrangedSubview(executable)
    let help = NSTextField(
      wrappingLabelWithString:
        "Arguments: one per line, passed literally. Use ${path}, ${selection}, or ${text} from the document snapshot. Empty lines are empty arguments; leave the entire field empty for no arguments. No command runs when a file or project opens."
    )
    stack.addArrangedSubview(help)
    let argumentScroll = configure(arguments, label: "Arguments, one per line", editable: true)
    argumentScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
    stack.addArrangedSubview(argumentScroll)
    runButton.target = self
    runButton.action = #selector(run)
    runButton.setAccessibilityLabel("Run external command")
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.isEnabled = false
    cancelButton.setAccessibilityLabel("Cancel external command")
    let controls = NSStackView(views: [runButton, cancelButton])
    controls.spacing = 10
    stack.addArrangedSubview(controls)
    status.lineBreakMode = .byTruncatingTail
    status.setAccessibilityLabel("Command status")
    stack.addArrangedSubview(status)
    let outputScroll = configure(output, label: "Command output", editable: false)
    outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    stack.addArrangedSubview(outputScroll)
    for view in [trust, executable, help, argumentScroll, status, outputScroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  private func configure(_ editor: NSTextView, label: String, editable: Bool) -> NSScrollView {
    editor.isRichText = false
    editor.isEditable = editable
    editor.isSelectable = true
    editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 8, height: 8)
    editor.setAccessibilityLabel(label)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = editor
    return scroll
  }

  @objc private func run() {
    guard !Self.shuttingDown else {
      status.stringValue = "The app is quitting; no new commands can run."
      return
    }
    guard runner == nil else { return }
    let path = executable.stringValue
    let argv = arguments.string.isEmpty ? [] : arguments.string.components(separatedBy: "\n")
    let worker = ExternalCommandRunner()
    runner = worker
    runButton.isEnabled = false
    cancelButton.isEnabled = true
    executable.isEditable = false
    arguments.isEditable = false
    output.string = ""
    status.stringValue = "Running — 30 second timeout; combined output limit 1 MB."
    let capturedContext = context
    let task = Task.detached(priority: .userInitiated) {
      try worker.run(executable: path, arguments: argv, context: capturedContext)
    }
    let id = UUID()
    Self.active[id] = (worker, task)
    Task { [self] in
      let result = await task.result
      Self.active.removeValue(forKey: id)
      self.runner = nil
      self.runButton.isEnabled = true
      self.cancelButton.isEnabled = false
      self.executable.isEditable = true
      self.arguments.isEditable = true
      switch result {
      case .success(let value):
        let exit =
          value.exitCode.map { "exit \($0)" } ?? value.signal.map { "signal \($0)" }
          ?? "not launched"
        self.status.stringValue =
          "\(value.termination.rawValue) — \(exit)"
          + (value.outputTruncated ? " — output truncated" : "")
        self.output.string =
          "Standard output:\n" + String(decoding: value.stdout, as: UTF8.self)
          + "\n\nStandard error:\n" + String(decoding: value.stderr, as: UTF8.self)
      case .failure(let error):
        self.status.stringValue = "Command could not complete"
        self.output.string = error.localizedDescription
      }
      if self.closeWhenFinished { self.close() }
    }
  }

  @objc private func cancel() {
    runner?.cancel()
    status.stringValue = "Cancelling the launched process…"
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard runner != nil else { return true }
    closeWhenFinished = true
    cancel()
    return false
  }

  func windowWillClose(_ notification: Notification) { onClose?() }

  /// App termination must await this so launched commands are not abandoned.
  static func cancelAllAndWait() async {
    shuttingDown = true
    while !active.isEmpty {
      let work = active
      for entry in work.values { entry.0.cancel() }
      for (id, entry) in work {
        _ = await entry.1.result
        active.removeValue(forKey: id)
      }
    }
  }
}
