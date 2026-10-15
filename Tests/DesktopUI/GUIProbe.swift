import AppKit
import ApplicationServices
import Foundation
import XCTest

final class GUIProbe: XCTestCase {
  @MainActor
  private func fixture(prepareState: ((URL) throws -> Void)? = nil) throws -> (XCUIApplication, URL)
  {
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
    addTeardownBlock {
      await MainActor.run { self.closeFixture(app) }
    }
    try prepareState?(state)
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
  private func closeFixture(_ app: XCUIApplication) {
    guard app.state != .notRunning else { return }
    // Normal application termination handles asynchronous recovery/session writes.
    // XCTest's terminate() alone can leave this app alive after its timeout.
    app.typeKey("q", modifierFlags: .command)
    if !app.wait(for: .notRunning, timeout: 15) { app.terminate() }
  }

  @MainActor
  func testOpenEditSaveQuitRelaunch() throws {
    let (app, state) = try fixture()
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
    let selectedStatus = app.staticTexts.matching(
      NSPredicate(
        format: "value CONTAINS %@ OR label CONTAINS %@",
        "Selected 17 UTF-16 units", "Selected 17 UTF-16 units")
    ).firstMatch
    XCTAssertTrue(
      selectedStatus.waitForExistence(timeout: 5),
      "Command-A must select the complete original document before replacement")
    app.typeText("synthetic after\n")
    assertText("synthetic after\n", in: app)
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
  func testManagedDocumentSearchFromLaunchFileInlineReplacementUndoSaveQuitRelaunch() throws {
    continueAfterFailure = false
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GUI_PROBE_APP_PATH"])
    guard path.hasPrefix("/"), path.hasSuffix("/TheOnlyPad.app") else {
      throw NSError(
        domain: "DesktopUI.LaunchFile", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "An explicit test app copy is required"])
    }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TheOnlyPad-DesktopUI-LaunchFile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let original = "alpha 😀 e\u{301}\nalpha 😀 e\u{301}\nALPHA 😀 e\u{301}\n"
    let changed = "alpha! 😀 e\u{301}\nalpha! 😀 e\u{301}\nALPHA 😀 e\u{301}\n"
    let originalBytes = Data(original.utf8)
    let changedBytes = Data(changed.utf8)
    let input = state.appendingPathComponent("synthetic-managed-search.txt")
    try originalBytes.write(to: input)
    let app = XCUIApplication(url: URL(fileURLWithPath: path))
    app.launchEnvironment["THEONLYPAD_STATE_DIRECTORY"] = state.path
    app.launchArguments = [input.path]
    XCTAssertEqual(app.launchArguments, [input.path])
    addTeardownBlock {
      await MainActor.run { self.closeFixture(app) }
    }
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    let initialEditor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(initialEditor.waitForExistence(timeout: 10))
    let loaded = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let actual = (object as? XCUIElement)?.value as? String else { return false }
        return Data(actual.utf8) == originalBytes
      }, object: initialEditor)
    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    let selectedTab = app.windows.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@",
        "tab.select.", input.lastPathComponent + ", selected")
    ).firstMatch
    XCTAssertTrue(selectedTab.waitForExistence(timeout: 10))
    let originalTabIdentifier = selectedTab.identifier
    XCTAssertTrue(originalTabIdentifier.hasPrefix("tab.select."))
    XCTAssertGreaterThan(originalTabIdentifier.count, "tab.select.".count)

    // Observe ordinary command validation before the one physical Command-F.
    let edit = app.menuBars.menuBarItems["Edit"]
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.click()
    let find = edit.menus.menuItems["Find and Replace…"]
    XCTAssertTrue(find.waitForExistence(timeout: 5))
    let findReady = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: find)
    XCTAssertEqual(XCTWaiter.wait(for: [findReady], timeout: 10), .completed)
    app.typeKey(.escape, modifierFlags: [])
    assertText(original, in: app)
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("f", modifierFlags: .command)
    let panel = app.windows["Find and Replace"]
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    let query = panel.searchFields["Find text"]
    let replacement = panel.textFields["Replacement text"]
    let mode = panel.popUpButtons["Search mode"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    XCTAssertTrue(replacement.waitForExistence(timeout: 5))
    XCTAssertTrue(mode.waitForExistence(timeout: 5))
    XCTAssertEqual(mode.value as? String, "Literal")
    XCTAssertEqual(String(describing: try XCTUnwrap(panel.checkBoxes["Match case"].value)), "1")
    XCTAssertEqual(String(describing: try XCTUnwrap(panel.checkBoxes["Whole word"].value)), "0")

    func enter(_ value: String, into field: XCUIElement) {
      XCTAssertTrue(field.isEnabled)
      field.click()
      app.typeKey("a", modifierFlags: .command)
      field.typeText(value)
      XCTAssertEqual(field.value as? String, value)
    }
    func expectStatus(_ value: String, timeout: TimeInterval = 10) {
      XCTAssertTrue(panel.staticTexts[value].waitForExistence(timeout: timeout), value)
    }
    func expectInlineApproval() {
      expectStatus("Replace 2 matches?")
      let approve = panel.buttons["Replace"]
      let reject = panel.buttons["Cancel Replacement"]
      XCTAssertTrue(approve.waitForExistence(timeout: 5))
      XCTAssertTrue(reject.waitForExistence(timeout: 5))
      XCTAssertTrue(approve.isEnabled && approve.isHittable)
      XCTAssertTrue(reject.isEnabled && reject.isHittable)
      XCTAssertEqual(app.sheets.count, 0, "The managed replacement approval is inline")
      XCTAssertFalse(panel.buttons["Next"].isEnabled)
      XCTAssertFalse(panel.buttons["Previous"].isEnabled)
    }

    // Literal supplementary-Unicode search; navigation initially has no selected match.
    enter("alpha 😀", into: query)
    panel.buttons["Find All"].click()
    expectStatus("2 matches")
    XCTAssertTrue(panel.buttons["Next"].isEnabled)
    XCTAssertTrue(panel.buttons["Previous"].isEnabled)
    panel.buttons["Next"].click()
    expectStatus("Match 1 of 2 (wrap enabled)", timeout: 5)
    panel.buttons["Next"].click()
    expectStatus("Match 2 of 2 (wrap enabled)", timeout: 5)
    panel.buttons["Next"].click()
    expectStatus("Match 1 of 2 (wrap enabled)", timeout: 5)
    panel.buttons["Previous"].click()
    expectStatus("Match 2 of 2 (wrap enabled)", timeout: 5)
    assertText(original, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)

    // ICU captures preserve the actual supplementary scalar and decomposed combining sequence.
    mode.click()
    let regex = app.menuItems["Regular expression (ICU)"]
    XCTAssertTrue(regex.waitForExistence(timeout: 5))
    regex.click()
    XCTAssertEqual(mode.value as? String, "Regular expression (ICU)")
    enter("(alpha) (😀) (e\\p{M})", into: query)
    enter("$1! $2 $3", into: replacement)
    panel.buttons["Find All"].click()
    expectStatus("2 matches")
    panel.buttons["Previous"].click()
    expectStatus("Match 2 of 2 (wrap enabled)", timeout: 5)
    panel.buttons["Next"].click()
    expectStatus("Match 1 of 2 (wrap enabled)", timeout: 5)

    panel.buttons["Replace All"].click()
    expectInlineApproval()
    assertText(original, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    panel.buttons["Cancel Replacement"].click()
    expectStatus("Idle", timeout: 5)
    XCTAssertFalse(panel.buttons["Replace"].isHittable)
    XCTAssertFalse(panel.buttons["Cancel Replacement"].isHittable)
    assertText(original, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)

    // Request a fresh replacement result after cancellation; approve only its actual inline UI.
    panel.buttons["Replace All"].click()
    expectInlineApproval()
    panel.buttons["Replace"].click()
    expectStatus("Replaced 2 matches.")
    assertText(changed, in: app)
    XCTAssertEqual(
      try Data(contentsOf: input), originalBytes, "Replacement must not implicitly save")
    panel.buttons[XCUIIdentifierCloseWindow].click()
    let panelClosed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: panel)
    XCTAssertEqual(XCTWaiter.wait(for: [panelClosed], timeout: 5), .completed)
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("z", modifierFlags: .command)
    assertText(original, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    app.typeKey("z", modifierFlags: [.command, .shift])
    assertText(changed, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    app.typeKey("s", modifierFlags: .command)
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in (try? Data(contentsOf: input)) == changedBytes }, object: nil
    )
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    XCTAssertEqual(try Data(contentsOf: input), changedBytes)

    // Quit with a newly attached, completed managed search still presented.
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    expectStatus("Idle", timeout: 5)
    XCTAssertEqual(mode.value as? String, "Literal")
    enter("alpha! 😀", into: query)
    panel.buttons["Find All"].click()
    expectStatus("2 matches")
    assertText(changed, in: app)
    XCTAssertEqual(try Data(contentsOf: input), changedBytes)
    // Public XCTest launch configuration affects only the next launch, not this running app.
    app.launchArguments = []
    XCTAssertTrue(app.launchArguments.isEmpty)
    quitAndRelaunch(app)
    XCTAssertFalse(app.windows["Find and Replace"].exists)
    assertText(changed, in: app)
    XCTAssertEqual(try Data(contentsOf: input), changedBytes)
    let restoredTab = app.windows.descendants(matching: .any)
      .matching(identifier: originalTabIdentifier).firstMatch
    XCTAssertTrue(restoredTab.waitForExistence(timeout: 10))
    XCTAssertEqual(restoredTab.label, input.lastPathComponent + ", selected")
    let restoredValue = try XCTUnwrap(app.textViews["Document text"].firstMatch.value as? String)
    XCTAssertEqual(Data(restoredValue.utf8), changedBytes)
  }

  @MainActor
  func testRegexReplaceConfirmationUndoAndSave() throws {
    let (app, state) = try fixture()
    let original = "alpha 😀\nalpha e\u{301}\nALPHA\n"
    let changed = "alpha! 😀\nalpha! e\u{301}\nALPHA\n"
    let input = state.appendingPathComponent("synthetic-search.txt")
    let originalBytes = Data(original.utf8)
    let changedBytes = Data(changed.utf8)
    try originalBytes.write(to: input)
    open(input, in: app)
    assertText(original, in: app)
    app.typeKey("f", modifierFlags: .command)
    let panel = app.windows["Find and Replace"]
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    let query = panel.searchFields["Find text"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    query.click()
    query.typeText("(alpha)")
    let mode = panel.popUpButtons["Search mode"]
    XCTAssertTrue(mode.waitForExistence(timeout: 5))
    mode.click()
    let regexMode = app.menuItems["Regular expression (ICU)"]
    XCTAssertTrue(regexMode.waitForExistence(timeout: 5))
    regexMode.click()
    XCTAssertEqual(mode.value as? String, "Regular expression (ICU)")
    let matchCase = panel.checkBoxes["Match case"]
    XCTAssertEqual(String(describing: try XCTUnwrap(matchCase.value)), "1")
    matchCase.click()
    XCTAssertEqual(String(describing: try XCTUnwrap(matchCase.value)), "0")
    matchCase.click()
    XCTAssertEqual(String(describing: try XCTUnwrap(matchCase.value)), "1")
    let replacement = panel.textFields["Replacement text"]
    XCTAssertTrue(replacement.waitForExistence(timeout: 5))
    replacement.click()
    replacement.typeText("$1!")

    func expectStatus(_ value: String, timeout: TimeInterval = 10) {
      XCTAssertTrue(panel.staticTexts[value].waitForExistence(timeout: timeout), value)
    }
    func expectInlineApproval() {
      expectStatus("Replace 2 matches?")
      let approve = panel.buttons["Replace"]
      let reject = panel.buttons["Cancel Replacement"]
      XCTAssertTrue(approve.waitForExistence(timeout: 5))
      XCTAssertTrue(reject.waitForExistence(timeout: 5))
      XCTAssertTrue(approve.isEnabled && approve.isHittable)
      XCTAssertTrue(reject.isEnabled && reject.isHittable)
      XCTAssertEqual(app.sheets.count, 0, "Managed approval is inline in the utility window")
    }

    panel.buttons["Find All"].click()
    expectStatus("2 matches")
    XCTAssertTrue(panel.buttons["Next"].isEnabled)
    panel.buttons["Next"].click()
    expectStatus("Match 1 of 2 (wrap enabled)", timeout: 5)
    panel.buttons["Next"].click()
    expectStatus("Match 2 of 2 (wrap enabled)", timeout: 5)

    panel.buttons["Replace All"].click()
    expectInlineApproval()
    panel.buttons["Cancel Replacement"].click()
    expectStatus("Idle")
    XCTAssertFalse(panel.buttons["Replace"].isHittable)
    XCTAssertFalse(panel.buttons["Cancel Replacement"].isHittable)
    assertText(original, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)

    panel.buttons["Replace All"].click()
    expectInlineApproval()
    panel.buttons["Replace"].click()
    expectStatus("Replaced 2 matches.")
    assertText(changed, in: app)
    XCTAssertEqual(try Data(contentsOf: input), originalBytes)

    panel.buttons[XCUIIdentifierCloseWindow].click()
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: panel)
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("z", modifierFlags: .command)
    assertText(original, in: app)
    app.typeKey("z", modifierFlags: [.command, .shift])
    assertText(changed, in: app)
    app.typeKey("s", modifierFlags: .command)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline && (try? Data(contentsOf: input)) != changedBytes {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(try Data(contentsOf: input), changedBytes)
  }

  @MainActor
  func testScratchRecoveryAfterCommandQuit() throws {
    let (app, _) = try fixture()
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
  func testMultipleWindowsAndPinnedTabsRestore() throws {
    let (app, _) = try fixture()
    let tabPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "tab.select.")
    func selectedTabID() throws -> String {
      let selected = app.windows.descendants(matching: .any).matching(tabPredicate).matching(
        NSPredicate(format: "label CONTAINS %@", ", selected"))
      return try XCTUnwrap(selected.allElementsBoundByIndex.last?.identifier)
    }
    let firstEditor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(firstEditor.waitForExistence(timeout: 10))
    firstEditor.click()
    app.typeText("synthetic first window pinned")
    let firstID = try selectedTabID()
    let firstTab = app.descendants(matching: .any).matching(identifier: firstID).firstMatch
    firstTab.rightClick()
    let pin = app.menuItems["Pin Tab"]
    XCTAssertTrue(pin.waitForExistence(timeout: 5))
    pin.click()
    XCTAssertTrue(firstTab.label.contains(", pinned"))
    app.typeKey("n", modifierFlags: .command)
    firstEditor.click()
    app.typeText("synthetic first window second")
    let secondID = try selectedTabID()
    XCTAssertNotEqual(firstID, secondID)
    app.typeKey("n", modifierFlags: [.command, .shift])
    XCTAssertEqual(app.windows.count, 2)
    let newWindow = try XCTUnwrap(
      app.windows.allElementsBoundByIndex.first {
        !$0.descendants(matching: .any).matching(tabPredicate).allElementsBoundByIndex
          .map(\.identifier).contains(firstID)
      })
    let thirdEditor = newWindow.textViews["Document text"]
    XCTAssertTrue(thirdEditor.waitForExistence(timeout: 10))
    thirdEditor.click()
    app.typeText("synthetic second window")
    let thirdTab = newWindow.descendants(matching: .any).matching(tabPredicate).firstMatch
    let thirdID = thirdTab.identifier
    XCTAssertFalse(thirdID.isEmpty)
    XCTAssertNotEqual(thirdID, firstID)
    XCTAssertNotEqual(thirdID, secondID)

    quitAndRelaunch(app)
    let restoredTabs = app.windows.descendants(matching: .any).matching(tabPredicate)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 3"), object: restoredTabs)
        ], timeout: 10),
      .completed)
    XCTAssertEqual(app.windows.count, 2)
    XCTAssertEqual(
      Set(restoredTabs.allElementsBoundByIndex.map(\.identifier)),
      Set([firstID, secondID, thirdID]))
    // Window indexes change when focus changes; bind through the persistent tab ID.
    let restoredFirst = app.windows.containing(.any, identifier: firstID).firstMatch
    XCTAssertTrue(restoredFirst.waitForExistence(timeout: 5))
    let windowTabs = restoredFirst.descendants(matching: .any).matching(tabPredicate)
    XCTAssertEqual(windowTabs.allElementsBoundByIndex.map(\.identifier), [firstID, secondID])
    XCTAssertTrue(windowTabs.element(boundBy: 0).label.contains(", pinned"))
    XCTAssertTrue(windowTabs.element(boundBy: 1).label.contains(", selected"))
    XCTAssertEqual(
      restoredFirst.textViews["Document text"].value as? String,
      "synthetic first window second")
    // Both scratch windows share a title and the default centered frame.
    // Select through the native Window menu before clicking the covered tab.
    if !windowTabs.element(boundBy: 0).isHittable {
      let menu = app.menuBars.menuBarItems["Window"]
      menu.click()
      let entries = menu.menus.menuItems.matching(
        NSPredicate(format: "title == %@", restoredFirst.title))
      XCTAssertEqual(entries.count, 2)
      entries.element(boundBy: 0).click()
      if !windowTabs.element(boundBy: 0).isHittable {
        menu.click()
        entries.element(boundBy: 1).click()
      }
    }
    XCTAssertTrue(windowTabs.element(boundBy: 0).isHittable)
    windowTabs.element(boundBy: 0).click()
    XCTAssertEqual(
      restoredFirst.textViews["Document text"].value as? String,
      "synthetic first window pinned")
    let restoredSecond = app.windows.containing(.any, identifier: thirdID).firstMatch
    XCTAssertTrue(restoredSecond.waitForExistence(timeout: 5))
    XCTAssertEqual(
      restoredSecond.textViews["Document text"].value as? String,
      "synthetic second window")
  }

  @MainActor
  func testRecentFilesOpenClearAndPersistence() throws {
    let (app, state) = try fixture()
    let input = state.appendingPathComponent("synthetic-recent.txt")
    let bytes = Data("synthetic recent contents\n".utf8)
    try bytes.write(to: input)
    open(input, in: app)
    assertText("synthetic recent contents\n", in: app)
    app.typeKey("w", modifierFlags: .command)
    assertText("", in: app)

    func showRecentFiles() -> XCUIElement {
      let file = app.menuBars.menuBarItems["File"]
      file.click()
      let command = file.menus.menuItems["Recent Files…"]
      XCTAssertTrue(command.waitForExistence(timeout: 5))
      command.click()
      let panel = app.dialogs["Recent Files"]
      XCTAssertTrue(panel.waitForExistence(timeout: 5))
      return panel
    }
    let panel = showRecentFiles()
    let rows = panel.tables["recents.files"].descendants(matching: .tableRow)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(panel.buttons["recents.open"].isEnabled)
    app.typeKey(.return, modifierFlags: [])
    assertText("synthetic recent contents\n", in: app)
    XCTAssertEqual(try Data(contentsOf: input), bytes)

    let reopened = showRecentFiles()
    XCTAssertEqual(reopened.tables["recents.files"].descendants(matching: .tableRow).count, 1)
    reopened.buttons["recents.clear"].click()
    XCTAssertEqual(reopened.tables["recents.files"].descendants(matching: .tableRow).count, 0)
    XCTAssertEqual(try Data(contentsOf: input), bytes)
    quitAndRelaunch(app)
    let restored = showRecentFiles()
    XCTAssertEqual(restored.tables["recents.files"].descendants(matching: .tableRow).count, 0)
    XCTAssertFalse(restored.buttons["recents.open"].isEnabled)
    XCTAssertEqual(try Data(contentsOf: input), bytes)
  }

  @MainActor
  func testSessionWriteFailureVetoesQuitAndPreservesEditing() throws {
    let (app, state) = try fixture()
    let editor = app.textViews["Document text"].firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    app.typeText("synthetic before failed quit\n")
    assertText("synthetic before failed quit\n", in: app)
    // Periodic checkpoints can already have created this private fixture directory.
    // Restrict only its permissions to make the real session store refuse writes.
    let obstruction = state.appendingPathComponent("Session", isDirectory: true)
    try FileManager.default.createDirectory(
      at: obstruction, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: obstruction.path)
    defer {
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: obstruction.path)
      } catch {
        XCTFail("Could not restore synthetic session directory permissions: \(error)")
      }
    }
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
    let attributes = try FileManager.default.attributesOfItem(atPath: obstruction.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: obstruction.path)
    quitAndRelaunch(app)
    assertText("synthetic after failed quit\n", in: app)
  }

  // External-file desktop acceptance sources. These require a packaged build with
  // monitoring and an unlocked, authorized desktop; compile-only is not execution.
  @MainActor
  private func waitForDiskChange(_ app: XCUIApplication) {
    let reason = app.staticTexts.matching(
      NSPredicate(
        format: "value CONTAINS %@ OR label CONTAINS %@",
        "The file changed on disk.", "The file changed on disk.")
    ).firstMatch
    XCTAssertTrue(
      reason.waitForExistence(timeout: 40), "A real external change must become visible")
    let resolve = app.buttons["document.resolveDiskChange"]
    XCTAssertTrue(resolve.waitForExistence(timeout: 5))
    XCTAssertTrue(resolve.isEnabled)
  }

  @MainActor
  private func diskAction(_ identifier: String, in app: XCUIApplication) {
    app.buttons["document.resolveDiskChange"].click()
    let action = app.buttons[identifier]
    XCTAssertTrue(action.waitForExistence(timeout: 10))
    XCTAssertTrue(action.isEnabled)
    action.click()
  }

  @MainActor
  func testExternalFileNoticeAndExplicitCleanReloadSurviveRelaunch() throws {
    let (app, state) = try fixture()
    let file = state.appendingPathComponent("synthetic-external-clean.txt")
    let before = "synthetic saved before\n"
    let after = "synthetic external after\n"
    try Data(before.utf8).write(to: file)
    open(file, in: app)
    assertText(before, in: app)
    try Data(after.utf8).write(to: file, options: .atomic)
    waitForDiskChange(app)
    assertText(before, in: app)  // A notice must not automatically replace the buffer.
    diskAction("document.diskReload", in: app)
    assertText(after, in: app)
    XCTAssertEqual(try Data(contentsOf: file), Data(after.utf8))
    quitAndRelaunch(app)
    assertText(after, in: app)
    XCTAssertEqual(try Data(contentsOf: file), Data(after.utf8))
  }

  @MainActor
  func testExternalDirtyReloadCancelAndDiskCopyPreserveOriginal() throws {
    let (app, state) = try fixture()
    let file = state.appendingPathComponent("synthetic-external-dirty.txt")
    let saved = "synthetic saved original\n"
    let dirty = "synthetic unsaved buffer\n"
    let disk = "synthetic independent disk\n"
    try Data(saved.utf8).write(to: file)
    open(file, in: app)
    assertText(saved, in: app)
    let originalTab = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "tab.select.", file.lastPathComponent)
    ).firstMatch
    XCTAssertTrue(originalTab.waitForExistence(timeout: 10))
    let originalTabID = originalTab.identifier
    let editor = app.textViews["Document text"].firstMatch
    editor.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText(dirty)
    assertText(dirty, in: app)
    try Data(disk.utf8).write(to: file, options: .atomic)
    waitForDiskChange(app)
    assertText(dirty, in: app)
    diskAction("document.diskReload", in: app)
    let confirmation = app.dialogs.containing(.button, identifier: "Reload from Disk").element
    XCTAssertTrue(
      confirmation.waitForExistence(timeout: 10), "Dirty reload requires an actual confirmation")
    let cancel = confirmation.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.click()
    assertText(dirty, in: app)
    XCTAssertEqual(try Data(contentsOf: file), Data(disk.utf8))
    diskAction("document.diskCopy", in: app)
    assertText(disk, in: app)
    let source = app.descendants(matching: .any).matching(identifier: originalTabID).firstMatch
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    source.click()
    assertText(dirty, in: app)
    XCTAssertEqual(try Data(contentsOf: file), Data(disk.utf8))
  }

  @MainActor
  func testLocateMovedFilePreservesDirtyUndoAndSavesToChosenLocation() throws {
    let (app, state) = try fixture()
    let original = state.appendingPathComponent("synthetic-before-move.txt")
    let moved = state.appendingPathComponent("synthetic-after-move.txt")
    let saved = "synthetic saved before move\n"
    let dirty = "synthetic unsaved after move\n"
    try Data(saved.utf8).write(to: original)
    open(original, in: app)
    assertText(saved, in: app)
    let tab = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "tab.select.", original.lastPathComponent)
    ).firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    let tabID = tab.identifier
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText(dirty)
    assertText(dirty, in: app)
    try FileManager.default.moveItem(at: original, to: moved)
    let missing = app.staticTexts.matching(
      NSPredicate(
        format: "value CONTAINS %@ OR label CONTAINS %@",
        "The original file is missing.", "The original file is missing.")
    ).firstMatch
    XCTAssertTrue(missing.waitForExistence(timeout: 40))
    diskAction("document.locateFile", in: app)
    let panel = app.dialogs["open-panel"]
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    app.typeKey(.escape, modifierFlags: [])
    assertText(dirty, in: app)
    XCTAssertTrue(missing.exists, "Cancel must retain the original missing-file binding")
    XCTAssertEqual(try Data(contentsOf: moved), Data(saved.utf8))

    diskAction("document.locateFile", in: app)
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(moved.path)
    app.typeKey(.return, modifierFlags: [])
    let choose = panel.buttons["OKButton"]
    XCTAssertTrue(choose.waitForExistence(timeout: 10))
    choose.click()
    let sameTab = app.descendants(matching: .any).matching(identifier: tabID).firstMatch
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", moved.lastPathComponent),
            object: sameTab)
        ], timeout: 10), .completed)
    assertText(dirty, in: app)
    XCTAssertEqual(
      try Data(contentsOf: moved), Data(saved.utf8),
      "Locate must not write unsaved buffer contents to the selected file")
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("z", modifierFlags: .command)
    assertText(saved, in: app)
    app.typeKey("z", modifierFlags: [.command, .shift])
    assertText(dirty, in: app)
    app.typeKey("s", modifierFlags: .command)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
              (try? Data(contentsOf: moved)) == Data(dirty.utf8)
            }, object: nil)
        ], timeout: 10), .completed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    quitAndRelaunch(app)
    assertText(dirty, in: app)
    XCTAssertEqual(try Data(contentsOf: moved), Data(dirty.utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    let restoredTab = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "tab.select.", moved.lastPathComponent)
    ).firstMatch
    XCTAssertTrue(restoredTab.waitForExistence(timeout: 10))
    restoredTab.click()
    let reopened = dirty + "synthetic edit after relaunch\n"
    app.textViews["Document text"].firstMatch.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText(reopened)
    assertText(reopened, in: app)
    app.typeKey("s", modifierFlags: .command)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
              (try? Data(contentsOf: moved)) == Data(reopened.utf8)
            }, object: nil)
        ], timeout: 10), .completed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
  }

  @MainActor
  func testHelpSearchUsesEffectiveShortcutReference() throws {
    let (app, _) = try fixture { state in
      // SettingsStore.defaultDirectory uses Preferences below the isolated state root.
      // GUIProbe does not link PadCore; this literal follows ShortcutProfile's strict v1 schema.
      let preferences = state.appendingPathComponent("Preferences", isDirectory: true)
      try FileManager.default.createDirectory(
        at: preferences, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let profile = #"""
        {"version":1,"overrides":[
          {"commandID":"file.open","assignment":{
            "kind":"assigned","key":"r","modifiers":["cmd","ctrl"]}},
          {"commandID":"file.save","assignment":{"kind":"disabled"}}
        ]}
        """#
      let shortcuts = preferences.appendingPathComponent("Shortcuts.json")
      try Data(profile.utf8).write(to: shortcuts)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: shortcuts.path)
    }
    let menu = app.menuBars.menuBarItems["TheOnlyPad"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.click()
    let command = menu.menus.menuItems["Help and Shortcuts"]
    XCTAssertTrue(command.waitForExistence(timeout: 5))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: command)
        ], timeout: 10), .completed)
    XCTAssertTrue(command.isEnabled)
    command.click()

    let window = app.windows["TheOnlyPad Help"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    let text = window.textViews["help.text"]
    let search = window.searchFields["help.search"]
    let next = window.buttons["help.next"]
    let previous = window.buttons["help.previous"]
    let status = window.staticTexts["help.matchStatus"]
    for element in [text, search, next, previous, status] {
      XCTAssertTrue(element.waitForExistence(timeout: 5))
    }
    let reference = try XCTUnwrap(text.value as? String)
    let lines = Set(
      reference.components(separatedBy: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    for row in [
      "Open… — cmd+ctrl+r", "Save — No shortcut",
      "Help and Shortcuts — No shortcut", "New Tab — cmd+n",
    ] {
      XCTAssertTrue(lines.contains(row), "The real Help guide must show the effective row: \(row)")
    }
    XCTAssertFalse(lines.contains("Open… — cmd+o"))
    XCTAssertFalse(lines.contains("Save — cmd+s"))
    XCTAssertTrue(reference.contains("ctrl = Control"))
    for heading in ["Documents and recovery", "Finding text", "Split views", "Keyboard shortcuts"] {
      XCTAssertTrue(reference.contains(heading), "Search must retain the full guide: \(heading)")
    }
    XCTAssertTrue(reference.contains("ICU"))
    XCTAssertTrue(reference.contains("some expensive patterns can delay cancellation"))

    func assertSearchState(_ expectedStatus: String, navigationEnabled: Bool) {
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate { _, _ in
                (status.value as? String) == expectedStatus
                  && next.isEnabled == navigationEnabled
                  && previous.isEnabled == navigationEnabled
              }, object: nil)
          ], timeout: 5), .completed)
      XCTAssertEqual(status.value as? String, expectedStatus)
      XCTAssertEqual(next.isEnabled, navigationEnabled)
      XCTAssertEqual(previous.isEnabled, navigationEnabled)
      XCTAssertEqual(text.value as? String, reference, "Help search must not alter the guide")
    }
    func replaceQuery(_ query: String) {
      search.click()
      app.typeKey("a", modifierFlags: .command)
      app.typeKey(.delete, modifierFlags: [])
      if !query.isEmpty { search.typeText(query) }
    }
    assertSearchState("", navigationEnabled: false)
    search.click()
    search.typeText("ICU")
    // Count the literal occurrences in the actual accessible guide, independently of its search code.
    let count = reference.lowercased().components(separatedBy: "icu").count - 1
    XCTAssertGreaterThanOrEqual(count, 2, "ICU appears repeatedly in the retained guide")
    assertSearchState("1 of \(count) matches", navigationEnabled: true)
    next.click()
    assertSearchState("2 of \(count) matches", navigationEnabled: true)
    previous.click()
    assertSearchState("1 of \(count) matches", navigationEnabled: true)
    previous.click()
    assertSearchState("\(count) of \(count) matches", navigationEnabled: true)
    next.click()
    assertSearchState("1 of \(count) matches", navigationEnabled: true)
    // XCUI's text-view value is the full string; these status transitions do not claim exact selection.
    replaceQuery("synthetic-help-no-match-9f31b7")
    assertSearchState("No matches", navigationEnabled: false)
    replaceQuery("")
    assertSearchState("", navigationEnabled: false)
  }

  @MainActor
  func testCustomShortcutRecordingPersistenceAndRestoreDefaults() throws {
    let (app, _) = try fixture()
    func shortcuts() -> XCUIElement {
      let menu = app.menuBars.menuBarItems["TheOnlyPad"]
      menu.click()
      let command = menu.menus.menuItems.matching(
        NSPredicate(format: "title BEGINSWITH %@", "Keyboard Shortcuts")
      ).firstMatch
      XCTAssertTrue(command.waitForExistence(timeout: 10))
      XCTAssertTrue(command.isEnabled)
      command.click()
      let window = app.windows["Keyboard Shortcuts"]
      XCTAssertTrue(window.waitForExistence(timeout: 10))
      return window
    }
    func tabCount() -> Int {
      app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "tab.select.")
      ).count
    }
    func assertTabCountRemains(_ count: Int) {
      let changed = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in tabCount() != count }, object: nil)
      changed.isInverted = true
      XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
      XCTAssertEqual(tabCount(), count)
    }
    func assertApplied(in window: XCUIElement) {
      let status = window.textViews["shortcuts.status"]
      XCTAssertTrue(status.waitForExistence(timeout: 5))
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "value CONTAINS %@", "Shortcut settings saved."),
              object: status)
          ], timeout: 10), .completed)
    }
    let window = shortcuts()
    let search = window.searchFields["shortcuts.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("New Tab")
    let row = window.tables["shortcuts.commands"].staticTexts["New Tab"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.click()
    let record = window.buttons["shortcuts.record"]
    XCTAssertTrue(record.isEnabled)
    record.click()
    app.typeKey("n", modifierFlags: [.command, .option])
    let apply = window.buttons["shortcuts.apply"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: apply)
        ], timeout: 10), .completed)
    apply.click()
    assertApplied(in: window)
    window.buttons["shortcuts.cancel"].click()
    app.textViews["Document text"].firstMatch.click()
    let before = tabCount()
    app.typeKey("n", modifierFlags: .command)
    assertTabCountRemains(before)
    assertText("", in: app)
    app.typeKey("n", modifierFlags: [.command, .option])
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabCount() == before + 1 }, object: nil)
        ],
        timeout: 10), .completed)
    app.textViews["Document text"].firstMatch.click()
    app.typeText("synthetic customized shortcut tab")
    assertText("synthetic customized shortcut tab", in: app)
    quitAndRelaunch(app)
    assertText("synthetic customized shortcut tab", in: app)
    let restoredCount = tabCount()
    app.typeKey("n", modifierFlags: [.command, .option])
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabCount() == restoredCount + 1 }, object: nil)
        ],
        timeout: 10), .completed)
    assertText("", in: app)
    let reset = shortcuts()
    reset.buttons["shortcuts.reset"].click()
    XCTAssertTrue(reset.buttons["shortcuts.apply"].isEnabled)
    reset.buttons["shortcuts.apply"].click()
    assertApplied(in: reset)
    reset.buttons["shortcuts.cancel"].click()
    let resetCount = tabCount()
    app.typeKey("n", modifierFlags: [.command, .option])
    assertTabCountRemains(resetCount)
    app.typeKey("n", modifierFlags: .command)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in tabCount() == resetCount + 1 }, object: nil)
        ],
        timeout: 10), .completed)
  }
}

// Desktop controls require actual event/AX access; unavailable permission is explicit.
@MainActor
extension GUIProbe {
  private func controlTabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.windows.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab.select."))
  }

  private func assertExactlyOneNewTab(_ app: XCUIApplication, before: Set<String>) {
    let tabs = controlTabs(app)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", before.count + 1), object: tabs)
        ],
        timeout: 10), .completed)
    let after = Set(tabs.allElementsBoundByIndex.map(\.identifier))
    XCTAssertTrue(before.isSubset(of: after))
    XCTAssertEqual(after.subtracting(before).count, 1)
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in tabs.count != before.count + 1 }, object: nil)
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
    XCTAssertEqual(tabs.count, before.count + 1)
  }

  func testOptionHeldFileNewMenuClickAddsExactlyOneTab() throws {
    let (app, _) = try fixture()
    let tabs = controlTabs(app)
    XCTAssertEqual(tabs.count, 1)
    let before = Set(tabs.allElementsBoundByIndex.map(\.identifier))
    let file = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(file.waitForExistence(timeout: 5))
    XCUIElement.perform(withKeyModifiers: .option) {
      file.click()
      let new = file.menus.menuItems.matching(NSPredicate(format: "title == %@", "New Tab"))
        .firstMatch
      XCTAssertTrue(new.waitForExistence(timeout: 5))
      XCTAssertTrue(new.isEnabled)
      new.click()
    }
    assertExactlyOneNewTab(app, before: before)
  }

  func testExactOwnedApplicationAXPressFileNewAddsExactlyOneTab() throws {
    guard AXIsProcessTrusted() else {
      throw XCTSkip(
        "MISSING ACCESS: AX API is not trusted for this XCTest runner; AXPress untested")
    }
    let (app, _) = try fixture()
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GUI_PROBE_APP_PATH"])
    let expected = URL(fileURLWithPath: path).standardizedFileURL
    let matches = NSWorkspace.shared.runningApplications.filter {
      !$0.isTerminated && $0.bundleURL?.standardizedFileURL == expected
    }
    XCTAssertEqual(matches.count, 1, "AX control requires exactly this run's app URL")
    let owned = try XCTUnwrap(matches.first)
    let pid = owned.processIdentifier
    func requireOwned() throws {
      guard !owned.isTerminated, owned.bundleURL?.standardizedFileURL == expected,
        NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL == expected
      else {
        throw NSError(
          domain: "OwnedAXControl", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Exact test app ownership changed"])
      }
    }
    func checked(_ status: AXError, _ operation: String) throws {
      if status == .apiDisabled {
        throw XCTSkip("MISSING ACCESS: AX apiDisabled during \(operation); AXPress untested")
      }
      guard status == .success else {
        throw NSError(
          domain: "OwnedAXControl", code: Int(status.rawValue),
          userInfo: [NSLocalizedDescriptionKey: "AX \(operation) failed: \(status.rawValue)"])
      }
    }
    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
      try requireOwned()
      var value: CFTypeRef?
      try checked(AXUIElementCopyAttributeValue(element, name as CFString, &value), name)
      return try XCTUnwrap(value)
    }
    func children(_ element: AXUIElement) throws -> [AXUIElement] {
      try XCTUnwrap(try attribute(element, kAXChildrenAttribute) as? [AXUIElement])
    }
    func exactChild(_ element: AXUIElement, title: String) throws -> AXUIElement {
      let values = try children(element).filter { child in
        try requireOwned()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &value)
        if status == .noValue || status == .attributeUnsupported { return false }
        try checked(status, "child title")
        return value as? String == title
      }
      XCTAssertEqual(values.count, 1, "AX requires one exact \(title) child")
      return try XCTUnwrap(values.first)
    }
    func press(_ element: AXUIElement) throws {
      try requireOwned()
      var names: CFArray?
      try checked(AXUIElementCopyActionNames(element, &names), "copy action names")
      let actions = try XCTUnwrap(names as? [String])
      XCTAssertTrue(actions.contains(kAXPressAction), "AXPress must be advertised")
      try requireOwned()
      try checked(AXUIElementPerformAction(element, kAXPressAction as CFString), "AXPress")
    }
    let tabs = controlTabs(app)
    XCTAssertEqual(tabs.count, 1)
    let before = Set(tabs.allElementsBoundByIndex.map(\.identifier))
    try requireOwned()
    let axApp = AXUIElementCreateApplication(pid)
    try checked(AXUIElementSetMessagingTimeout(axApp, 3), "set messaging timeout")
    let menuBarValue = try attribute(axApp, kAXMenuBarAttribute)
    guard CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
      throw NSError(
        domain: "OwnedAXControl", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Owned application's menu bar is not an AX element"])
    }
    let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
    let file = try exactChild(menuBar, title: "File")
    try press(file)
    let menus = try children(file)
    XCTAssertEqual(menus.count, 1, "File must expose exactly its own menu")
    let menu = try XCTUnwrap(menus.first)
    let new = try exactChild(menu, title: "New Tab")
    XCTAssertEqual(try attribute(new, kAXEnabledAttribute) as? Bool, true)
    try press(new)
    assertExactlyOneNewTab(app, before: before)
  }
}
