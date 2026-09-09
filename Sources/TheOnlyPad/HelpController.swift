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

      While editing, session checkpoints save recovery copies and tab metadata without saving your original files. The session recovery status reports pending work or failures; use Retry when a failure is resolved. Quit waits for a final checkpoint. Recovery opens unsaved content as scratch tabs so historical paths are not overwritten. Closing a dirty tab explicitly asks whether to discard it.

      Changes after the latest checkpoint can still be lost if the app is force-terminated. Recovery text and session metadata are separate files, so an interrupted checkpoint can restore newer text with older tab metadata. Optional autosave of original files is not implemented.

      Finding text
      Find and Replace supports literal, escaped-text and ICU regular-expression modes. Replacement templates accept numbered capture references such as $1. Search bounds and cancellation can stop expensive queries. The ICU dialect differs from Notepad++ Boost regex.

      Split views
      View > Split Side by Side or Split Top and Bottom shows two views of the current document. They share text, undo and one save/recovery identity, with independent carets and scrolling. Focus Other Pane switches the active view; Close Other Pane keeps the focused view and shared undo history. Finish text composition before changing panes.

      Adding a split is currently limited to 2 million UTF-16 units. Each tab remembers its arrangement while the app is running; restarting restores one view per tab. Moving documents between pane groups or windows and linked scrolling are not implemented.

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
