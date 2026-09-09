import XCTest

@testable import PadCore

final class AppCommandsTests: XCTestCase {
  func testCoreMenuCommandsAreUniqueAndDiscoverable() throws {
    let registry = try AppCommands.registry()
    XCTAssertEqual(registry.commands.filter { $0.id == "file.save" }.count, 1)
    XCTAssertEqual(registry.commands.first { $0.id == "file.save" }?.shortcut, "cmd+s")
    XCTAssertTrue(registry.commands.contains { $0.id == "edit.trimTrailingWhitespace" })
    XCTAssertEqual(Set(registry.commands.map(\.id)).count, registry.commands.count)
  }
}
