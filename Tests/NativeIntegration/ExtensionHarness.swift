import AppKit
import PadCore

private func extensionDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(extensionDescendants)
}

@main struct ExtensionHarness {
  @MainActor static func main() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    precondition(CommandLine.arguments.count == 2)
    let catalog = ExtensionCatalog(directory: ExtensionCatalog.defaultDirectory)
    let installed = try catalog.install(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    try catalog.setEnabled(id: installed.id, enabled: true)
    var text = "hello  \nworld\t"
    var calls = 0
    let manager = ExtensionManagerController { _, transform in
      text = transform.apply(to: text)
      calls += 1
    }
    let views = extensionDescendants(manager.window!.contentView!)
    let table = views.compactMap { $0 as? NSTableView }.first!
    let run = views.compactMap { $0 as? NSButton }.first { $0.title == "Run Command" }!
    let reload = views.compactMap { $0 as? NSButton }.first { $0.title == "Reload" }!
    func wait(_ condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(5)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      precondition(condition(), "Native extension operation did not complete")
    }
    wait { table.numberOfRows == 1 && run.isEnabled }
    run.performClick(nil)
    wait { calls == 1 }
    precondition(text == "hello\nworld", "Sample command must reach the actual native Run callback")
    try catalog.setEnabled(id: installed.id, enabled: false)
    manager.reload()
    wait { reload.isEnabled }
    precondition(!run.isEnabled, "Disabled extension must not expose runnable controls")
    run.performClick(nil)
    precondition(calls == 1)
    try catalog.uninstall(id: installed.id)
    manager.reload()
    wait { table.numberOfRows == 0 && reload.isEnabled }
    print("PASS bundled extension install, enable, native Run callback, disable and uninstall")
  }
}
