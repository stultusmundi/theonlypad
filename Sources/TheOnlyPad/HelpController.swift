import AppKit
import PadCore

@MainActor final class HelpController: NSWindowController, NSSearchFieldDelegate {
  private let search = NSSearchField()
  private let previous = NSButton()
  private let next = NSButton()
  private let status = NSTextField(labelWithString: "")
  private let text = NSTextView()
  private var matches: [NSRange] = []
  private var matchIndex = 0

  init(commands: [CommandDescriptor]) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = AppIdentity.name + " Help"
    window.isReleasedWhenClosed = false
    let content = NSView(frame: window.contentView!.bounds)
    let scroll = NSScrollView(frame: content.bounds)
    scroll.hasVerticalScroller = true
    text.frame = scroll.bounds
    text.isEditable = false
    text.isSelectable = true
    text.font = .systemFont(ofSize: 14)
    text.textContainerInset = NSSize(width: 20, height: 20)
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel("Help and keyboard shortcuts")
    text.setAccessibilityIdentifier("help.text")
    let shortcuts = commands.map { command in
      command.title + " — "
        + (command.shortcut
          ?? NSLocalizedString(
            "No shortcut", comment: "Help reference command without a keyboard assignment"))
    }.joined(separator: "\n")
    text.string = """
      \(AppIdentity.name) \(AppIdentity.version)

      An offline native text editor. This development build is incomplete; keep separate copies of important files.

      Documents and recovery
      File > Open loads text documents. Each tab keeps its own native undo history. Save As currently requires a new filename. If a file changes externally, saving refuses to overwrite the changed version; use a new filename or explicitly revert.

      While editing, session checkpoints save recovery copies and tab metadata without saving your original files. The session recovery status reports pending work or failures; use Retry when a failure is resolved. Quit waits for a final checkpoint. Recovery opens unsaved content as scratch tabs so historical paths are not overwritten. Closing a dirty tab explicitly asks whether to discard it.

      Changes after the latest checkpoint can still be lost if the app is force-terminated. Recovery text and session metadata are separate files, so an interrupted checkpoint can restore newer text with older tab metadata. Optional autosave of original files is not implemented.

      Finding text
      Find and Replace supports literal, escaped-text and ICU regular-expression modes. Replacement templates accept numbered capture references such as $1. Cancellation and time limits currently depend on the regex engine returning control; some expensive patterns can delay cancellation. The ICU dialect differs from Notepad++ Boost regex.

      Split views
      View > Split Side by Side or Split Top and Bottom shows two views of the current document. They share text, undo and one save/recovery identity, with independent carets and scrolling. Focus Other Pane switches the active view; Close Other Pane keeps the focused view and shared undo history. Finish text composition before changing panes.

      Adding a split is currently limited to 2 million UTF-16 units. Session checkpoints retain the split orientation, preferred pane, selections and scroll positions. Scroll restoration is best effort when window geometry or settings change. Saved splits above the size limit stay deferred in one pane until you restore or discard the saved arrangement.

      File > Move Document to Window moves the current editable tab and its undo history to an existing or new window without saving the original file. Independent document groups, moving read-only streaming views and linked scrolling are not implemented.

      Encodings
      Open with Encoding interprets original bytes. Encoding and Line Endings separates conversion of future saves from reopening bytes. Invalid or lossy conversions report an error.

      Large files
      Files above 100 MB use a read-only byte-window viewer up to 1 GB. Highlighting is disabled above 2 million UTF-16 units. These bounds do not guarantee normal editing latency for every document.

      Automation
      Macro recording captures editing operations. Manage and Replay Macros saves, renames, deletes and repeats named recordings. External commands run only after you choose Run and use your local user permissions. Declarative extensions expose listed built-in text transformations; Windows plugin binaries are unsupported.

      Printing and PDF
      File > Print opens the system print panel, which includes PDF export. Printing is limited to 2 million UTF-16 units.

      Keyboard shortcuts
      \(AppIdentity.name) > Keyboard Shortcuts (also linked from Settings) edits command assignments as a draft. Record a Command-key combination, resolve conflicts and Apply to save. Standard native editing and Close bindings remain protected. Import changes only the draft; Export requires a new filename. Restore Defaults also requires Apply.

      If stored shortcuts cannot be applied, the shortcut editor explains why and retains them. Recover Stored Settings offers explicit reload or a checked retry of an unconfirmed save. The app waits for you to resolve an unconfirmed settings save before quitting.

      cmd = Command; alt = Option; shift = Shift; ctrl = Control.

      \(shortcuts)

      Menus and Command Palette list every registered command. Native editing shortcuts act on the focused text control.
      """
    scroll.documentView = text
    search.placeholderString = NSLocalizedString(
      "Search help and commands", comment: "Help search placeholder")
    search.setAccessibilityLabel(search.placeholderString)
    search.setAccessibilityIdentifier("help.search")
    search.delegate = self
    // Text changes select the first match; only Return/search-button actions advance it.
    search.sendsWholeSearchString = true
    search.target = self
    search.action = #selector(findNext)
    previous.title = NSLocalizedString("Previous", comment: "Previous help search match")
    previous.target = self
    previous.action = #selector(findPrevious)
    previous.setAccessibilityIdentifier("help.previous")
    next.title = NSLocalizedString("Next", comment: "Next help search match")
    next.target = self
    next.action = #selector(findNext)
    next.setAccessibilityIdentifier("help.next")
    status.setAccessibilityLabel(
      NSLocalizedString("Help search matches", comment: "Help match status"))
    status.setAccessibilityIdentifier("help.matchStatus")
    status.textColor = .secondaryLabelColor
    for view in [search, previous, next, status, scroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      previous.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 8),
      previous.centerYAnchor.constraint(equalTo: search.centerYAnchor),
      next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 8),
      next.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      next.centerYAnchor.constraint(equalTo: search.centerYAnchor),
      status.leadingAnchor.constraint(equalTo: search.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: next.trailingAnchor),
      status.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
      scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    window.initialFirstResponder = search
    updateSearch()
    window.minSize = NSSize(width: 400, height: 320)
    window.setContentSize(NSSize(width: 700, height: 600))
    window.center()
  }
  required init?(coder: NSCoder) { nil }

  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as? NSSearchField === search else { return }
    updateSearch()
  }

  private func updateSearch() {
    matches = []
    matchIndex = 0
    let query = search.stringValue
    let source = text.string as NSString
    if !query.isEmpty {
      var offset = 0
      while offset < source.length {
        let range = source.range(
          of: query, options: [.caseInsensitive],
          range: NSRange(location: offset, length: source.length - offset))
        guard range.location != NSNotFound, range.length > 0 else { break }
        matches.append(range)
        offset = NSMaxRange(range)
      }
    }
    previous.isEnabled = !matches.isEmpty
    next.isEnabled = !matches.isEmpty
    if matches.isEmpty {
      status.stringValue =
        query.isEmpty
        ? ""
        : NSLocalizedString(
          "No matches", comment: "Help search has no matching text")
      text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0))
    } else {
      showMatch()
    }
  }

  @objc private func findNext() {
    guard !matches.isEmpty else { return }
    matchIndex = (matchIndex + 1) % matches.count
    showMatch()
  }

  @objc private func findPrevious() {
    guard !matches.isEmpty else { return }
    matchIndex = (matchIndex + matches.count - 1) % matches.count
    showMatch()
  }

  private func showMatch() {
    let range = matches[matchIndex]
    text.setSelectedRange(range)
    text.scrollRangeToVisible(range)
    status.stringValue = String(
      format: NSLocalizedString(
        "%ld of %ld matches", comment: "Current and total help search matches"),
      matchIndex + 1, matches.count)
  }
}
