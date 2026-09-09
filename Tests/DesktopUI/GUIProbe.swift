import Foundation
import XCTest

final class GUIProbe: XCTestCase {
  @MainActor
  private func fixture() throws -> (XCUIApplication, URL) {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let path = try XCTUnwrap(environment["GUI_PROBE_APP_PATH"])
    guard path.hasPrefix("/"), path.hasSuffix("/TheOnlyPad.app") else {
      throw NSError(
        domain: "DesktopUI", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "An explicit test app copy is required"])
    }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-DesktopUI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let app = XCUIApplication(url: URL(fileURLWithPath: path))
    app.launchEnvironment["THEONLYPAD_STATE_DIRECTORY"] = state.path
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    return (app, state)
  }

  @MainActor
  private func open(_ file: URL, in app: XCUIApplication) {
    app.typeKey("o", modifierFlags: .command)
    XCTAssertTrue(app.dialogs["open-panel"].waitForExistence(timeout: 10))
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(file.path)
    app.typeKey(.return, modifierFlags: [])
    let button = app.dialogs["open-panel"].buttons["OKButton"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    button.click()
  }

  @MainActor
  private func assertText(_ text: String, in app: XCUIApplication) {
    let editor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let predicate = NSPredicate(format: "value == %@", text)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: editor)], timeout: 10),
      .completed)
  }

  @MainActor
  private func quitAndRelaunch(_ app: XCUIApplication) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(
      app.wait(for: .notRunning, timeout: 15),
      "Command-Q must complete the application's quit workflow")
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
  }

  @MainActor
  func testOpenEditSaveQuitRelaunch() throws {
    let (app, state) = try fixture()
    defer { app.terminate() }
    let input = state.appendingPathComponent("synthetic-input.txt")
    try Data("synthetic before\n".utf8).write(to: input)
    app.menuBars.menuBarItems["File"].click()
    XCTAssertTrue(
      app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Open")).firstMatch
        .waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    open(input, in: app)
    assertText("synthetic before\n", in: app)
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText("synthetic after\n")
    app.typeKey("s", modifierFlags: .command)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && (try? Data(contentsOf: input)) != Data("synthetic after\n".utf8) {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(try Data(contentsOf: input), Data("synthetic after\n".utf8))
    quitAndRelaunch(app)
    open(input, in: app)
    assertText("synthetic after\n", in: app)
    XCTAssertEqual(try Data(contentsOf: input), Data("synthetic after\n".utf8))
  }

  @MainActor
  func testScratchRecoveryAfterCommandQuit() throws {
    let (app, _) = try fixture()
    defer { app.terminate() }
    let editor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    app.typeText("synthetic scratch recovery\n")
    assertText("synthetic scratch recovery\n", in: app)
    quitAndRelaunch(app)
    assertText("synthetic scratch recovery\n", in: app)
  }
  @MainActor
  func testUndoRedoTabIsolationAndAppearanceReset() throws {
    let (app, state) = try fixture()
    defer { app.terminate() }
    let editor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    app.typeText("synthetic first tab")
    assertText("synthetic first tab", in: app)

    func menuAction(_ title: String) {
      let edit = app.menuBars.menuBarItems["Edit"]
      edit.click()
      let item = edit.menus.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      XCTAssertTrue(item.isEnabled)
      item.click()
    }
    menuAction("Undo")
    assertText("", in: app)
    menuAction("Redo")
    assertText("synthetic first tab", in: app)
    app.typeKey("z", modifierFlags: .command)
    assertText("", in: app)
    app.typeKey("z", modifierFlags: [.command, .shift])
    assertText("synthetic first tab", in: app)

    let tabs = app.windows.firstMatch.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab.select."))
    XCTAssertEqual(tabs.count, 1)
    let firstID = tabs.element(boundBy: 0).identifier
    XCTAssertFalse(firstID.isEmpty)
    app.typeKey("n", modifierFlags: .command)
    XCTAssertEqual(tabs.count, 2)
    assertText("", in: app)
    editor.click()
    app.typeText("synthetic second tab")
    assertText("synthetic second tab", in: app)
    let secondID = tabs.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertEqual(
      tabs.matching(NSPredicate(format: "label CONTAINS %@", ", selected")).firstMatch.identifier,
      firstID)
    assertText("synthetic first tab", in: app)
    app.typeKey("]", modifierFlags: [.command, .shift])
    XCTAssertEqual(
      tabs.matching(NSPredicate(format: "label CONTAINS %@", ", selected")).firstMatch.identifier,
      secondID)
    assertText("synthetic second tab", in: app)
    app.typeKey("z", modifierFlags: .command)
    assertText("", in: app)
    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertEqual(
      tabs.matching(NSPredicate(format: "label CONTAINS %@", ", selected")).firstMatch.identifier,
      firstID)
    assertText("synthetic first tab", in: app)
    app.typeKey("]", modifierFlags: [.command, .shift])
    XCTAssertEqual(
      tabs.matching(NSPredicate(format: "label CONTAINS %@", ", selected")).firstMatch.identifier,
      secondID)
    app.typeKey("z", modifierFlags: [.command, .shift])
    assertText("synthetic second tab", in: app)

    app.typeKey(",", modifierFlags: .command)
    let preferences = app.windows["Preferences"]
    XCTAssertTrue(preferences.waitForExistence(timeout: 10))
    let appearance = preferences.popUpButtons["Appearance"]
    XCTAssertTrue(appearance.waitForExistence(timeout: 10))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"), object: appearance)
        ], timeout: 10), .completed)
    appearance.click()
    app.typeKey(.end, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    let settingsURL = state.appendingPathComponent("Preferences/Settings.json")
    func savedTheme() -> String? {
      guard let data = try? Data(contentsOf: settingsURL),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return (object["settings"] as? [String: Any])?["theme"] as? String
    }
    let deadline = Date().addingTimeInterval(10)
    while savedTheme() != "dark" && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(savedTheme(), "dark")
    XCTAssertEqual(appearance.value as? String, "Dark")
    preferences.buttons["Reset…"].click()
    let reset = preferences.sheets.buttons["Reset"]
    XCTAssertTrue(reset.waitForExistence(timeout: 5))
    reset.click()
    let resetDeadline = Date().addingTimeInterval(10)
    while savedTheme() != "system" && Date() < resetDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(savedTheme(), "system")
    XCTAssertEqual(appearance.value as? String, "System")
    preferences.buttons[XCUIIdentifierCloseWindow].click()
    assertText("synthetic second tab", in: app)
    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertEqual(
      tabs.matching(NSPredicate(format: "label CONTAINS %@", ", selected")).firstMatch.identifier,
      firstID)
    assertText("synthetic first tab", in: app)
  }

  @MainActor
  func testSessionWriteFailureVetoesQuitAndPreservesEditing() throws {
    let (app, state) = try fixture()
    defer { app.terminate() }
    let editor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    app.typeText("synthetic before failed quit\n")
    assertText("synthetic before failed quit\n", in: app)
    // A synthetic regular file in place of the not-yet-created session directory
    // makes the real private-store write fail without changing system permissions.
    let obstruction = state.appendingPathComponent("Session")
    XCTAssertFalse(FileManager.default.fileExists(atPath: obstruction.path))
    try Data("synthetic obstruction".utf8).write(to: obstruction, options: .withoutOverwriting)
    app.typeKey("q", modifierFlags: .command)
    let alert = app.dialogs.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 10))
    let ok = alert.buttons["OK"]
    XCTAssertTrue(ok.waitForExistence(timeout: 5))
    ok.click()
    XCTAssertNotEqual(app.state, .notRunning)
    assertText("synthetic before failed quit\n", in: app)
    editor.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText("synthetic after failed quit\n")
    assertText("synthetic after failed quit\n", in: app)
    XCTAssertEqual(try Data(contentsOf: obstruction), Data("synthetic obstruction".utf8))
    try FileManager.default.removeItem(at: obstruction)
    quitAndRelaunch(app)
    assertText("synthetic after failed quit\n", in: app)
  }
}
