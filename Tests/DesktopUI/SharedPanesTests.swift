import Foundation
import XCTest

// Desktop acceptance coverage; execution requires the packaged split implementation
// and macOS UI Automation access. See docs/verification/shared-document-panes.md.
final class SharedPanesTests: XCTestCase {
  @MainActor
  private func fixture() throws -> (XCUIApplication, URL) {
    continueAfterFailure = false
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GUI_PROBE_APP_PATH"])
    guard path.hasPrefix("/"), path.hasSuffix("/TheOnlyPad.app") else {
      throw NSError(
        domain: "SharedPanesDesktop", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "An explicit packaged test app copy is required"
        ])
    }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-SharedPanes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let app = XCUIApplication(url: URL(fileURLWithPath: path))
    app.launchEnvironment["THEONLYPAD_STATE_DIRECTORY"] = state.path
    addTeardownBlock {
      await MainActor.run {
        if app.state != .notRunning {
          app.typeKey("q", modifierFlags: .command)
          if !app.wait(for: .notRunning, timeout: 15) { app.terminate() }
        }
      }
    }
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    return (app, state)
  }

  @MainActor
  private func editors(_ app: XCUIApplication) -> XCUIElementQuery {
    app.windows.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editor.text."))
  }

  @MainActor
  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.windows.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab.select."))
  }

  @MainActor
  private func waitCount(_ query: XCUIElementQuery, _ count: Int) {
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", count), object: query)
        ], timeout: 10), .completed)
  }

  @MainActor
  private func menu(_ app: XCUIApplication, _ section: String, _ title: String) {
    let menu = app.menuBars.menuBarItems[section]
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.click()
    let item = menu.menus.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing actual menu action: \(title)")
    XCTAssertTrue(item.isEnabled)
    item.click()
  }

  @MainActor
  private func exact(_ text: String, in view: XCUIElement) {
    XCTAssertTrue(view.waitForExistence(timeout: 10))
    let expected = Data(text.utf8)
    let predicate = NSPredicate { object, _ in
      guard let actual = (object as? XCUIElement)?.value as? String else { return false }
      return Data(actual.utf8) == expected
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: predicate, object: view)
        ], timeout: 10), .completed,
      "Pane must expose the exact expected Unicode bytes")
  }

  @MainActor
  private func exactBoth(_ text: String, _ app: XCUIApplication) {
    waitCount(editors(app), 2)
    for view in editors(app).allElementsBoundByIndex { exact(text, in: view) }
  }

  @MainActor
  private func arrangement(_ app: XCUIApplication, sideBySide: Bool) throws -> [XCUIElement] {
    waitCount(editors(app), 2)
    let views = editors(app).allElementsBoundByIndex.sorted {
      sideBySide ? $0.frame.midX < $1.frame.midX : $0.frame.midY < $1.frame.midY
    }
    XCTAssertNotEqual(views[0].identifier, views[1].identifier)
    let containers = try views.map { view -> XCUIElement in
      let suffix = String(view.identifier.dropFirst("editor.text.".count))
      _ = try XCTUnwrap(UUID(uuidString: suffix))
      let container = app.windows.descendants(matching: .any)
        .matching(identifier: "editor.pane." + suffix).firstMatch
      XCTAssertTrue(container.waitForExistence(timeout: 5))
      XCTAssertGreaterThan(container.frame.width, 0)
      XCTAssertGreaterThan(container.frame.height, 0)
      XCTAssertTrue(view.isHittable)
      return container
    }
    let first = containers[0].frame
    let second = containers[1].frame
    if sideBySide {
      XCTAssertLessThanOrEqual(first.maxX, second.minX + 2)
      XCTAssertLessThan(abs(first.midY - second.midY), 5)
    } else {
      XCTAssertLessThanOrEqual(first.maxY, second.minY + 2)
      XCTAssertLessThan(abs(first.midX - second.midX), 5)
    }
    return views
  }

  @MainActor
  private func append(_ marker: String, through view: XCUIElement, app: XCUIApplication) {
    XCTAssertTrue(view.waitForExistence(timeout: 10))
    view.click()
    app.typeKey(.downArrow, modifierFlags: .command)
    app.typeText(marker)
  }

  @MainActor
  private func quit(_ app: XCUIApplication) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Native asynchronous quit must complete")
  }

  private struct SessionWire: Decodable {
    let version: Int
    let windows: [Window]
    struct Window: Decodable {
      let tabs: [Tab]
      let selectedTabID: UUID?
    }
    struct Tab: Decodable { let id: UUID }
  }

  private func assertOnePersistedTab(_ state: URL, tabIdentifier: String) throws {
    let wire = try JSONDecoder().decode(
      SessionWire.self,
      from: Data(contentsOf: state.appendingPathComponent("Session/Session.json")))
    XCTAssertEqual(wire.version, 2)
    XCTAssertEqual(wire.windows.count, 1)
    let window = try XCTUnwrap(wire.windows.first)
    XCTAssertEqual(window.tabs.count, 1)
    let id = try XCTUnwrap(UUID(uuidString: String(tabIdentifier.dropFirst("tab.select.".count))))
    XCTAssertEqual(window.tabs.first?.id, id)
    XCTAssertEqual(window.selectedTabID, id)
  }

  @MainActor
  func testSharedEditsUndoOrientationCollapseSaveAndRestart() throws {
    let (app, state) = try fixture()
    waitCount(tabs(app), 1)
    let initialTab = tabs(app).firstMatch.identifier
    let file = state.appendingPathComponent("synthetic-shared.txt")
    let base = "synthetic 😀 e\u{301}\nsecond line\n"
    try Data(base.utf8).write(to: file)
    app.typeKey("o", modifierFlags: .command)
    XCTAssertTrue(app.dialogs["open-panel"].waitForExistence(timeout: 10))
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(file.path)
    app.typeKey(.return, modifierFlags: [])
    let open = app.dialogs["open-panel"].buttons["OKButton"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    exact(base, in: editors(app).firstMatch)
    waitCount(tabs(app), 2)
    app.windows.descendants(matching: .any).matching(
      identifier:
        initialTab.replacingOccurrences(of: "tab.select.", with: "tab.close.")
    ).firstMatch.click()
    waitCount(tabs(app), 1)
    let tabID = tabs(app).firstMatch.identifier

    menu(app, "View", "Split Side by Side")
    let horizontal = try arrangement(app, sideBySide: true)
    let paneIDs = Set(horizontal.map(\.identifier))
    append("L", through: horizontal[0], app: app)
    exactBoth(base + "L", app)
    append("R", through: horizontal[1], app: app)
    exactBoth(base + "LR", app)
    menu(app, "Edit", "Undo")
    exactBoth(base + "L", app)
    app.typeKey("z", modifierFlags: .command)
    exactBoth(base, app)
    app.typeKey("z", modifierFlags: [.command, .shift])
    exactBoth(base + "L", app)
    menu(app, "Edit", "Redo")
    exactBoth(base + "LR", app)

    menu(app, "View", "Split Top and Bottom")
    let vertical = try arrangement(app, sideBySide: false)
    let survivingPaneID = vertical[0].identifier
    XCTAssertEqual(
      Set(vertical.map(\.identifier)), paneIDs, "Orientation must not create more panes")
    append("T", through: vertical[1], app: app)
    exactBoth(base + "LRT", app)
    vertical[0].click()
    app.typeKey(.upArrow, modifierFlags: .command)
    vertical[1].click()
    app.typeKey(.downArrow, modifierFlags: .command)
    menu(app, "View", "Focus Other Pane")
    app.typeText("F")
    exactBoth("F" + base + "LRT", app)
    menu(app, "View", "Close Other Pane")
    waitCount(editors(app), 1)
    XCTAssertEqual(editors(app).firstMatch.identifier, survivingPaneID)
    menu(app, "Edit", "Undo")
    exact(base + "LRT", in: editors(app).firstMatch)
    menu(app, "Edit", "Undo")
    exact(base + "LR", in: editors(app).firstMatch)
    menu(app, "Edit", "Redo")
    let expected = base + "LRT"
    exact(expected, in: editors(app).firstMatch)
    app.typeKey("s", modifierFlags: .command)
    let saved = NSPredicate { _, _ in (try? Data(contentsOf: file)) == Data(expected.utf8) }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: saved, object: nil)],
        timeout: 10), .completed)
    XCTAssertEqual(try Data(contentsOf: file), Data(expected.utf8))
    menu(app, "View", "Split Side by Side")
    exactBoth(expected, app)
    waitCount(tabs(app), 1)
    quit(app)
    try assertOnePersistedTab(state, tabIdentifier: tabID)
    app.launch()
    waitCount(editors(app), 1)
    waitCount(tabs(app), 1)
    XCTAssertEqual(tabs(app).firstMatch.identifier, tabID)
    exact(expected, in: editors(app).firstMatch)
    XCTAssertEqual(try Data(contentsOf: file), Data(expected.utf8))
  }

  @MainActor
  func testTwoScratchPanesRestoreAsOneLogicalTab() throws {
    let (app, state) = try fixture()
    waitCount(tabs(app), 1)
    let tabID = tabs(app).firstMatch.identifier
    append("scratch shared\n", through: editors(app).firstMatch, app: app)
    menu(app, "View", "Split Top and Bottom")
    let panes = try arrangement(app, sideBySide: false)
    append("unsaved marker", through: panes[1], app: app)
    let expected = "scratch shared\nunsaved marker"
    exactBoth(expected, app)
    waitCount(tabs(app), 1)
    quit(app)
    try assertOnePersistedTab(state, tabIdentifier: tabID)
    app.launch()
    waitCount(editors(app), 1)
    waitCount(tabs(app), 1)
    XCTAssertEqual(tabs(app).firstMatch.identifier, tabID)
    exact(expected, in: editors(app).firstMatch)
  }
}
