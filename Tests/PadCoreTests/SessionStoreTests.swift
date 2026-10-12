import Foundation
import XCTest

@testable import PadCore

final class SessionStoreTests: XCTestCase {
  func fixture(_ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    try body(base.appendingPathComponent("Session"))
  }
  func session(_ tabs: [SessionTab]) -> EditorSession {
    EditorSession(windows: [SessionWindow(tabs: tabs, selectedTabID: tabs.first?.id)])
  }
  func testAuthorizedSavePublishesVersionTwo() throws {
    try fixture { directory in
      try SessionStore(directory: directory).save(EditorSession(windows: []))
      let data = try Data(contentsOf: directory.appendingPathComponent("Session.json"))
      let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(wire["version"] as? Int, 2)
    }
  }
  func testRoundTripPreservesWindowTabOrderIDsAndMetadataWithoutLoadingPaths() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      XCTAssertNil(try store.load())
      let saved = SessionTab(
        originalPath: "/synthetic/missing-document", pinned: true, encoding: .windows1252,
        manualLanguage: .python, selection: NSRange(location: 9, length: 2), bookmarks: [0, 7])
      let scratch = SessionTab(selection: NSRange(location: 100, length: 0))
      let second = SessionTab(originalPath: "/synthetic/renamed-document", encoding: .utf16BE)
      let state = EditorSession(windows: [
        SessionWindow(tabs: [saved, scratch], selectedTabID: scratch.id),
        SessionWindow(tabs: [second], selectedTabID: second.id),
      ])
      try store.save(state)
      XCTAssertEqual(try store.load(), state)
      XCTAssertEqual(
        (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
          as? NSNumber)?.intValue, 0o700)
      XCTAssertEqual(
        (try FileManager.default.attributesOfItem(
          atPath: directory.appendingPathComponent("Session.json").path)[.posixPermissions]
          as? NSNumber)?.intValue, 0o600)
    }
  }
  func testInvalidMetadataRejectedBeforeCreatingState() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      let id = UUID()
      let invalid = [
        session([SessionTab(id: id), SessionTab(id: id)]),
        session([SessionTab(originalPath: "relative")]),
        session([SessionTab(originalPath: "https://example.invalid/file")]),
        session([SessionTab(originalPath: "/a/../b")]),
        session([SessionTab(selection: NSRange(location: Int.max, length: 1))]),
        session([SessionTab(bookmarks: [2, 1])]), session([SessionTab(bookmarks: [0, 0])]),
        EditorSession(windows: [SessionWindow(tabs: [SessionTab()], selectedTabID: UUID())]),
      ]
      for state in invalid {
        XCTAssertThrowsError(try store.save(state)) { error in
          guard case SessionStoreError.invalidMetadata = error else {
            return XCTFail("Expected invalid metadata")
          }
        }
      }
      XCTAssertNil(try store.load())
    }
  }
  func testTabWindowAndBookmarkCapsAreExplicit() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      XCTAssertThrowsError(try store.save(session((0..<129).map { _ in SessionTab() })))
      XCTAssertThrowsError(
        try store.save(
          EditorSession(windows: (0..<33).map { _ in SessionWindow(tabs: [], selectedTabID: nil) }))
      )
      XCTAssertThrowsError(try store.save(session([SessionTab(bookmarks: Array(0...10_000))])))
    }
  }
  func testRecentPathsRoundTripAndBounds() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      let state = EditorSession(windows: [], recentPaths: ["/synthetic/b", "/synthetic/a"])
      try store.save(state)
      XCTAssertEqual(try store.load(), state)
      for paths in [["/same", "/same"], ["relative"], (0..<51).map { "/synthetic/\($0)" }] {
        XCTAssertThrowsError(try store.save(EditorSession(windows: [], recentPaths: paths)))
      }
      XCTAssertEqual(try store.load(), state)
    }
  }
  func testAtomicFailureLeavesPreviousSessionAndNoNewStagingFiles() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      let original = session([SessionTab()])
      try store.save(original)
      let bytes = try Data(contentsOf: directory.appendingPathComponent("Session.json"))
      for fault in [SaveFault.beforeWrite, .afterWrite, .beforeReplace, .diskFull] {
        XCTAssertThrowsError(try store.save(session([SessionTab(), SessionTab()]), fault: fault))
        XCTAssertEqual(
          try Data(contentsOf: directory.appendingPathComponent("Session.json")), bytes)
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(
          try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Session.json"])
      }
    }
  }
  func testCorruptAndFutureVersionArePreservedWithoutInventedMigration() throws {
    for bytes in [Data("{broken".utf8), Data("{\"version\":4,\"windows\":[]}".utf8)] {
      try fixture { directory in
        let store = SessionStore(directory: directory)
        try store.save(EditorSession(windows: []))
        let file = directory.appendingPathComponent("Session.json")
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(session([SessionTab()])))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
  }
  func testSymlinksAndInsecurePermissionsFailWithoutTouchingTargets() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      try store.save(EditorSession(windows: []))
      let file = directory.appendingPathComponent("Session.json")
      let bytes = try Data(contentsOf: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
      XCTAssertThrowsError(try store.load())
      try FileManager.default.removeItem(at: file)
      let target = directory.deletingLastPathComponent().appendingPathComponent("synthetic-private")
      try bytes.write(to: target)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
      XCTAssertThrowsError(try store.load()) {
        XCTAssertFalse($0.localizedDescription.contains(target.path))
      }
      XCTAssertThrowsError(try store.save(EditorSession(windows: [])))
      XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
  }
  func testCanonicalSchemaAndFutureVersionErrorAreExplicit() throws {
    for text in [
      "{\"version\":1,\"version\":1,\"windows\":[]}",
      "{\"extra\":true,\"version\":1,\"windows\":[]}", "{\"version\":1,\"windows\":[] }",
      "{\"version\":99,\"windows\":[]}",
    ] {
      try fixture { directory in
        let store = SessionStore(directory: directory)
        try store.save(EditorSession(windows: []))
        let file = directory.appendingPathComponent("Session.json")
        let bytes = Data(text.utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.load()) { error in
          guard let error = error as? SessionStoreError else { return XCTFail("Unexpected error") }
          if text.contains("99") {
            guard case .unsupportedVersion(99) = error else {
              return XCTFail("Expected version refusal")
            }
          } else {
            guard case .corrupt = error else { return XCTFail("Expected corrupt refusal") }
          }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
  }
  func testDirectorySymlinkHardlinkAndOversizedFileRejected() throws {
    try fixture { directory in
      let store = SessionStore(directory: directory)
      try store.save(EditorSession(windows: []))
      let file = directory.appendingPathComponent("Session.json")
      let link = directory.deletingLastPathComponent().appendingPathComponent("alias")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
      XCTAssertThrowsError(try SessionStore(directory: link).load())
      try FileManager.default.removeItem(at: link)
      try FileManager.default.linkItem(at: file, to: link)
      XCTAssertThrowsError(try store.load())
      XCTAssertThrowsError(try store.save(EditorSession(windows: [])))
      try FileManager.default.removeItem(at: link)
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: 16_777_217)
      try handle.close()
      XCTAssertThrowsError(try store.load())
    }
  }

}
