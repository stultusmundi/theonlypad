import AppKit
import PadCore

@MainActor final class HelpController: NSWindowController {
  init(commands: [CommandDescriptor]) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = AppIdentity.name + " Help"
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.font = .systemFont(ofSize: 14)
    text.textContainerInset = NSSize(width: 20, height: 20)
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel("Help and keyboard shortcuts")
    let shortcuts = commands.compactMap { command -> String? in
      guard let shortcut = command.shortcut else { return nil }
      return command.title + " — " + shortcut
    }.joined(separator: "\n")
    text.string = """
      \(AppIdentity.name) \(AppIdentity.version)

      An offline native text editor. This development build is incomplete; keep separate copies of important files.

      Documents and recovery
      File > Open loads text documents. Each tab keeps its own native undo history. Save As currently requires a new filename. If a file changes externally, saving refuses to overwrite the changed version; use a new filename or explicitly revert.

      App quit snapshots scratch and unsaved documents. Recovery opens them as scratch tabs so historical paths are not overwritten. Closing a dirty tab explicitly asks whether to discard it.

      Finding text
      Find and Replace supports literal, escaped-text and ICU regular-expression modes. Replacement templates accept numbered capture references such as $1. Search bounds and cancellation can stop expensive queries. The ICU dialect differs from Notepad++ Boost regex.

      Encodings
      Open with Encoding interprets original bytes. Encoding and Line Endings separates conversion of future saves from reopening bytes. Invalid or lossy conversions report an error.

      Large files
      Files above 100 MB use a read-only byte-window viewer up to 1 GB. Highlighting is disabled above 2 million UTF-16 units. These bounds do not guarantee normal editing latency for every document.

      Automation
      Macro recording captures editing operations. Manage and Replay Macros saves, renames, deletes and repeats named recordings. External commands run only after you choose Run and use your local user permissions. Declarative extensions expose listed built-in text transformations; Windows plugin binaries are unsupported.

      Printing and PDF
      File > Print opens the system print panel, which includes PDF export. Printing is limited to 2 million UTF-16 units.

      Keyboard shortcuts
      cmd = Command; alt = Option; shift = Shift.

      \(shortcuts)

      Menus and Command Palette list every registered command. Native editing shortcuts act on the focused text control.
      """
    scroll.documentView = text
    window.contentView = scroll
    window.minSize = NSSize(width: 400, height: 320)
    window.setContentSize(NSSize(width: 700, height: 600))
    window.center()
  }
  required init?(coder: NSCoder) { nil }
}
