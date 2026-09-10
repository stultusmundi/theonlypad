import Foundation
import XCTest

// Compile-only acceptance source until executed on an authorized desktop runner.
// Uses an explicit packaged app copy and private synthetic state. No runtime claim.
final class PaneSessionTests: XCTestCase {
  @MainActor
  private func fixture() throws -> (XCUIApplication, URL) {
    continueAfterFailure = false
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GUI_PROBE_APP_PATH"])
    guard path.hasPrefix("/"), path.hasSuffix("/TheOnlyPad.app") else {
      throw NSError(
        domain: "PaneSessionDesktop", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "An explicit packaged test app copy is required"
        ])
    }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-PaneSession-\(UUID().uuidString)", isDirectory: true)
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
    let views = editors(app).allElementsBoundByIndex
    XCTAssertNotEqual(views[0].identifier, views[1].identifier)
    // Text view frames move with document scrolling. Order the fixed pane containers.
    let panes = try views.map { view -> (view: XCUIElement, container: XCUIElement) in
      let suffix = String(view.identifier.dropFirst("editor.text.".count))
      _ = try XCTUnwrap(UUID(uuidString: suffix))
      let container = app.windows.descendants(matching: .any)
        .matching(identifier: "editor.pane." + suffix).firstMatch
      XCTAssertTrue(container.waitForExistence(timeout: 5))
      XCTAssertGreaterThan(container.frame.width, 0)
      XCTAssertGreaterThan(container.frame.height, 0)
      XCTAssertTrue(view.isHittable)
      return (view, container)
    }.sorted {
      sideBySide
        ? $0.container.frame.midX < $1.container.frame.midX
        : $0.container.frame.midY < $1.container.frame.midY
    }
    let first = panes[0].container.frame
    let second = panes[1].container.frame
    if sideBySide {
      XCTAssertLessThanOrEqual(first.maxX, second.minX + 2)
      XCTAssertLessThan(abs(first.midY - second.midY), 5)
    } else {
      XCTAssertLessThanOrEqual(first.maxY, second.minY + 2)
      XCTAssertLessThan(abs(first.midX - second.midX), 5)
    }
    return panes.map(\.view)
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
    struct Tab: Decodable {
      let id: UUID
      let originalPath: String?
      let presentation: Presentation
    }
    struct Presentation: Decodable {
      let axis: String
      let focusedPaneIndex: Int
      let panes: [Pane]
    }
    struct Pane: Decodable {
      let location: Int
      let length: Int
      let scrollX: Double
      let scrollY: Double
    }
  }

  private func savedTab(_ state: URL, identifier: String) throws -> SessionWire.Tab {
    let wire = try JSONDecoder().decode(
      SessionWire.self,
      from: Data(contentsOf: state.appendingPathComponent("Session/Session.json")))
    XCTAssertEqual(wire.version, 2)
    XCTAssertEqual(wire.windows.count, 1)
    let window = try XCTUnwrap(wire.windows.first)
    XCTAssertEqual(window.tabs.count, 1, "A split scratch document remains one logical record")
    let tab = try XCTUnwrap(window.tabs.first)
    let id = try XCTUnwrap(UUID(uuidString: String(identifier.dropFirst("tab.select.".count))))
    XCTAssertEqual(tab.id, id)
    XCTAssertEqual(window.selectedTabID, id)
    XCTAssertNil(tab.originalPath, "Recovery must not invent a saved path for a dirty scratch tab")
    return tab
  }

  @MainActor
  private func exercisePersistence(sideBySide: Bool) throws {
    let (app, state) = try fixture()
    waitCount(tabs(app), 1)
    let tabID = tabs(app).firstMatch.identifier
    let text = "ALPHA\n" + (0..<100).map { "row \($0) synthetic\n" }.joined() + "OMEGA"
    editors(app).firstMatch.click()
    app.typeText(text)
    exact(text, in: editors(app).firstMatch)
    menu(app, "View", sideBySide ? "Split Side by Side" : "Split Top and Bottom")
    let panes = try arrangement(app, sideBySide: sideBySide)
    exactBoth(text, app)

    // Keyboard actions operate through the actual accessibility target, not stored JSON edits.
    panes[0].click()
    app.typeKey(.upArrow, modifierFlags: .command)
    for _ in 0..<5 { app.typeKey(.rightArrow, modifierFlags: .shift) }
    panes[0].scroll(byDeltaX: 0, deltaY: -240)
    panes[1].click()
    app.typeKey(.downArrow, modifierFlags: .command)
    for _ in 0..<5 { app.typeKey(.leftArrow, modifierFlags: .shift) }
    panes[1].scroll(byDeltaX: 0, deltaY: 120)
    quit(app)

    let before = try savedTab(state, identifier: tabID).presentation
    XCTAssertEqual(before.axis, sideBySide ? "sideBySide" : "stacked")
    XCTAssertEqual(before.focusedPaneIndex, 1)
    XCTAssertEqual(before.panes.count, 2)
    guard before.panes.count == 2 else { return }
    XCTAssertEqual(before.panes[0].location, 0)
    XCTAssertEqual(before.panes[0].length, 5)
    XCTAssertEqual(before.panes[1].location, (text as NSString).length - 5)
    XCTAssertEqual(before.panes[1].length, 5)
    XCTAssertGreaterThan(
      before.panes[0].scrollY, 0, "First pane scroll event must actually take effect")
    XCTAssertGreaterThan(before.panes[1].scrollY, before.panes[0].scrollY + 50)

    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    _ = try arrangement(app, sideBySide: sideBySide)
    exactBoth(text, app)
    waitCount(tabs(app), 1)
    XCTAssertEqual(tabs(app).firstMatch.identifier, tabID)
    // No click/navigation after relaunch: capture what the native restore actually installed.
    // This checks recaptured document coordinates, not pixel occlusion or a visible top line.
    quit(app)
    let recaptured = try savedTab(state, identifier: tabID).presentation
    XCTAssertEqual(recaptured.axis, before.axis)
    XCTAssertEqual(recaptured.focusedPaneIndex, before.focusedPaneIndex)
    XCTAssertEqual(recaptured.panes.count, 2)
    guard recaptured.panes.count == 2 else { return }
    for index in 0..<2 {
      XCTAssertEqual(recaptured.panes[index].location, before.panes[index].location)
      XCTAssertEqual(recaptured.panes[index].length, before.panes[index].length)
      XCTAssertEqual(recaptured.panes[index].scrollX, before.panes[index].scrollX, accuracy: 2)
      XCTAssertEqual(recaptured.panes[index].scrollY, before.panes[index].scrollY, accuracy: 2)
    }

    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    _ = try arrangement(app, sideBySide: sideBySide)
    exactBoth(text, app)
    // Replacement proves both selection length and preferred focus, without clicking a pane.
    app.typeText("preferred")
    exactBoth(String(text.dropLast(5)) + "preferred", app)
    menu(app, "Edit", "Undo")
    exactBoth(text, app)
    menu(app, "View", "Focus Other Pane")
    app.typeText("other")
    exactBoth("other" + String(text.dropFirst(5)), app)
    menu(app, "Edit", "Undo")
    exactBoth(text, app)
    waitCount(tabs(app), 1)
    XCTAssertEqual(tabs(app).firstMatch.identifier, tabID)
    quit(app)
    _ = try savedTab(state, identifier: tabID)
  }

  @MainActor
  func testSideBySideScratchSelectionsScrollAndPreferredPaneSurviveQuit() throws {
    try exercisePersistence(sideBySide: true)
  }

  @MainActor
  func testStackedScratchSelectionsScrollAndPreferredPaneSurviveQuit() throws {
    try exercisePersistence(sideBySide: false)
  }
}
