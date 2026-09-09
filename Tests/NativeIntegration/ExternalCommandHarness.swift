import AppKit
import PadCore

func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
@main struct ExternalCommandHarness {
  @MainActor static func main() {
    _ = NSApplication.shared
    let controller = ExternalCommandController(
      context: CommandContext(path: nil, selection: "literal $(do-not-execute)"))
    let views = descendants(controller.window!.contentView!)
    let argument = views.compactMap { $0 as? NSTextView }.first { $0.isEditable }!
    let output = views.compactMap { $0 as? NSTextView }.first { !$0.isEditable }!
    let executable = views.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    let run = views.compactMap { $0 as? NSButton }.first { $0.title == "Run" }!
    let cancel = views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel Command" }!
    precondition(output.string.isEmpty && run.isEnabled && !cancel.isEnabled)
    argument.string = "%s\n${selection}"
    run.performClick(nil)
    precondition(!run.isEnabled && cancel.isEnabled)
    let deadline = Date().addingTimeInterval(5)
    while !run.isEnabled && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(output.string.contains("literal $(do-not-execute)"))
    precondition(run.isEnabled && !cancel.isEnabled)
    executable.stringValue = "/bin/sh"
    argument.string = "-c\nwhile :; do :; done"
    run.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    cancel.performClick(nil)
    let cancelledDeadline = Date().addingTimeInterval(3)
    while !run.isEnabled && Date() < cancelledDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(run.isEnabled)
    precondition(
      views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("cancelled") })
    run.performClick(nil)
    let idle = ExternalCommandController(context: CommandContext(path: nil, selection: ""))
    let idleViews = descendants(idle.window!.contentView!)
    let idleRun = idleViews.compactMap { $0 as? NSButton }.first { $0.title == "Run" }!
    var done = false
    Task {
      await ExternalCommandController.cancelAllAndWait()
      done = true
    }
    let quitDeadline = Date().addingTimeInterval(3)
    while !done && Date() < quitDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(done)
    idleRun.performClick(nil)
    precondition(idleRun.isEnabled)
    precondition(
      idleViews.compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("no new commands")
      })
    print("PASS external panel: manual literal run, selectable output, cancel and shutdown drain")
  }

}
