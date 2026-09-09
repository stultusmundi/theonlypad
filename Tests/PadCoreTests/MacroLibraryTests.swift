import XCTest

@testable import PadCore

final class MacroLibraryTests: XCTestCase {
  private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    func record() {
      lock.lock()
      failures += 1
      lock.unlock()
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return failures
    }
  }
  private func library() throws -> MacroLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return MacroLibrary(directory: root.appendingPathComponent("Macros"))
  }

  func testSaveReloadRenameAndDeletePreserveIdentityAndCommands() throws {
    let library = try library()
    XCTAssertEqual(try library.load(), [])
    let macro = EditorMacro(
      name: "Clean", commands: [.transform(.trimTrailingWhitespace), .transform(.uppercase)])
    try library.save(macro)
    XCTAssertEqual(try library.load(), [macro])
    try library.rename(id: macro.id, to: "Clean uppercase")
    let renamed = try XCTUnwrap(library.load().first)
    XCTAssertEqual(renamed.id, macro.id)
    XCTAssertEqual(renamed.name, "Clean uppercase")
    XCTAssertEqual(renamed.commands, macro.commands)
    try library.delete(id: macro.id)
    XCTAssertEqual(try library.load(), [])
  }

  func testDuplicateNamesAndInvalidCommandsLeaveSavedMacroUnchanged() throws {
    let library = try library()
    let macro = EditorMacro(name: "Clean", commands: [.transform(.uppercase)])
    try library.save(macro)
    XCTAssertThrowsError(
      try library.save(EditorMacro(name: "CLEAN", commands: [.transform(.lowercase)])))
    XCTAssertThrowsError(
      try library.save(EditorMacro(name: " ", commands: [.transform(.lowercase)])))
    XCTAssertThrowsError(
      try library.save(
        EditorMacro(name: "Invalid", commands: [.replace(location: -1, length: 0, text: "x")])))
    XCTAssertThrowsError(try library.save(EditorMacro(name: "Empty", commands: [])))
    XCTAssertEqual(try library.load(), [macro])
  }

  func testNamesAreNotPathsAndStorageIsPrivate() throws {
    let library = try library()
    let macro = EditorMacro(
      name: "../../outside", commands: [.replace(location: 0, length: 0, text: "synthetic")])
    try library.save(macro)
    XCTAssertEqual(try library.load(), [macro])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: library.directory.path), ["Library.json"])
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: library.directory.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(
        atPath: library.directory.appendingPathComponent("Library.json").path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
  }

  func testCorruptAndUnknownVersionLibrariesCannotBeOverwritten() throws {
    let library = try library()
    let macro = EditorMacro(name: "Original", commands: [.transform(.uppercase)])
    try library.save(macro)
    let file = library.directory.appendingPathComponent("Library.json")
    for contents in ["broken", #"{"version":99,"macros":[]}"#] {
      let data = Data(contents.utf8)
      try data.write(to: file)
      XCTAssertThrowsError(try library.load())
      XCTAssertThrowsError(try library.save(macro))
      XCTAssertThrowsError(try library.rename(id: macro.id, to: "Changed"))
      XCTAssertThrowsError(try library.delete(id: macro.id))
      XCTAssertEqual(try Data(contentsOf: file), data)
    }
  }

  func testIncompatibleMacroAndUnknownExecutableCommandAreRejected() throws {
    let library = try library()
    let macro = EditorMacro(name: "Original", commands: [.transform(.uppercase)])
    try library.save(macro)
    let file = library.directory.appendingPathComponent("Library.json")
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var entry = try XCTUnwrap((envelope["macros"] as? [[String: Any]])?.first)
    entry["version"] = 7
    envelope["macros"] = [entry]
    try JSONSerialization.data(withJSONObject: envelope).write(to: file)
    XCTAssertThrowsError(try library.load())
    entry["version"] = 1
    entry["commands"] = [["execute": ["path": "/bin/echo"]]]
    envelope["macros"] = [entry]
    try JSONSerialization.data(withJSONObject: envelope).write(to: file)
    XCTAssertThrowsError(try library.load())
  }

  func testSymlinkLibraryIsRefusedAndOriginalIsPreserved() throws {
    let library = try library()
    let macro = EditorMacro(name: "Original", commands: [.transform(.uppercase)])
    try library.save(macro)
    let file = library.directory.appendingPathComponent("Library.json")
    let original = library.directory.appendingPathComponent("Original.json")
    let bytes = try Data(contentsOf: file)
    try FileManager.default.moveItem(at: file, to: original)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
    XCTAssertThrowsError(try library.load())
    XCTAssertThrowsError(try library.delete(id: macro.id))
    XCTAssertEqual(try Data(contentsOf: original), bytes)
  }

  func testUnknownFieldsAndWorkOverflowAreRejectedWithoutMutation() throws {
    let library = try library()
    let macro = EditorMacro(name: "Original", commands: [.transform(.uppercase)])
    try library.save(macro)
    XCTAssertThrowsError(
      try library.save(
        EditorMacro(
          name: "Too many", commands: Array(repeating: .transform(.uppercase), count: 10_001))))
    XCTAssertEqual(try library.load(), [macro])
    let file = library.directory.appendingPathComponent("Library.json")
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    envelope["unknownFutureData"] = "must not be lost"
    let bytes = try JSONSerialization.data(withJSONObject: envelope)
    try bytes.write(to: file)
    XCTAssertThrowsError(try library.save(macro))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testConcurrentRecordingsAreBothPreserved() throws {
    let library = try library()
    try library.save(EditorMacro(name: "Seed", commands: [.transform(.uppercase)]))
    let failures = Failures()
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      do {
        try library.save(
          EditorMacro(name: "Concurrent \(index)", commands: [.transform(.uppercase)]))
      } catch { failures.record() }
    }
    XCTAssertEqual(failures.count, 0)
    XCTAssertEqual(try library.load().count, 21)
  }
}
