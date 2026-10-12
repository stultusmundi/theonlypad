import Foundation
import XCTest

@testable import PadCore

final class SessionPresentationTests: XCTestCase {
  private func fixture(_ body: (SessionStore, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("Session")
    try body(SessionStore(directory: directory), directory)
  }
  private func state(_ presentation: SessionPresentation) -> EditorSession {
    let tab = SessionTab(presentation: presentation)
    return EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)])
  }
  private func pane(_ location: Int = 0, _ length: Int = 0, x: Double = 0, y: Double = 0)
    -> SessionPaneState
  {
    SessionPaneState(
      selection: NSRange(location: location, length: length), scrollOrigin: .init(x: x, y: y))
  }
  func testBothPaneOrdersAxesAndFocusedSelectionRoundTrip() throws {
    try fixture { store, directory in
      for axis in [SessionPaneAxis.sideBySide, .stacked] {
        for focus in 0...1 {
          let presentation = SessionPresentation(
            axis: axis, panes: [pane(7, 2, x: 12.5, y: 250), pane(18, 3, x: 48, y: 1200)],
            focusedPaneIndex: focus)
          let session = state(presentation)
          try store.save(session)
          XCTAssertEqual(try store.load(), session)
          XCTAssertEqual(
            try store.load()?.windows[0].tabs[0].selection, presentation.panes[focus].selection)
          let data = try Data(contentsOf: directory.appendingPathComponent("Session.json"))
          let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
          XCTAssertEqual(wire["version"] as? Int, 2)
        }
      }
    }
  }
  func testLegacyInitializerAndExplicitPresentationPrecedence() {
    let selection = NSRange(location: 8, length: 4)
    XCTAssertEqual(SessionTab(selection: selection).presentation, .single(selection: selection))
    let explicit = SessionPresentation(axis: .stacked, panes: [pane(5)], focusedPaneIndex: 0)
    XCTAssertEqual(SessionTab(selection: selection, presentation: explicit).selection.location, 5)
  }
  func testInvalidPresentationRejectsBeforeFilesystemAndInDirectPlan() throws {
    var invalid = [
      SessionPresentation(axis: .stacked, panes: [], focusedPaneIndex: 0),
      SessionPresentation(axis: .stacked, panes: [pane(), pane(), pane()], focusedPaneIndex: 0),
    ]
    for index in [-1, 1, Int.max] {
      let value = SessionPresentation(axis: .stacked, panes: [pane(9)], focusedPaneIndex: index)
      XCTAssertEqual(SessionTab(presentation: value).selection, NSRange(location: 0, length: 0))
      invalid.append(value)
    }
    XCTAssertEqual(SessionTab(presentation: invalid[0]).selection, NSRange(location: 0, length: 0))
    for (location, length) in [
      (-1, 0), (0, -1), (Int.max, 1), (0, Int.max), (100_000_000, 1), (100_000_001, 0),
    ] {
      invalid.append(
        .init(axis: .sideBySide, panes: [pane(), pane(location, length)], focusedPaneIndex: 0))
    }
    for value in [-1.0, Double.nan, .infinity, -.infinity, 1_000_000_001] {
      invalid.append(.init(axis: .stacked, panes: [pane(x: value)], focusedPaneIndex: 0))
      invalid.append(.init(axis: .stacked, panes: [pane(), pane(y: value)], focusedPaneIndex: 0))
    }
    for presentation in invalid {
      try fixture { store, directory in
        XCTAssertThrowsError(try presentation.validate()) { error in
          guard case SessionStoreError.invalidMetadata = error else {
            return XCTFail("Wrong validation error")
          }
        }
        XCTAssertThrowsError(try store.save(state(presentation)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(
          try SessionRestoration.plan(session: state(presentation), recoveries: []))
      }
    }
  }
  func testExactBoundsAndSignedZeroRemainValid() throws {
    try fixture { store, _ in
      let presentation = SessionPresentation(
        axis: .stacked,
        panes: [pane(100_000_000, x: 1_000_000_000, y: -0.0), pane(0, 100_000_000)],
        focusedPaneIndex: 1)
      try presentation.validate()
      let session = state(presentation)
      try store.save(session)
      XCTAssertEqual(try store.load(), session)
      XCTAssertEqual(try SessionRestoration.plan(session: session, recoveries: []).windows.count, 1)
    }
  }
  // Exact canonical output shape of the former v1 encoder, independent of the new public model.
  private let legacy = Data(
    #"{"version":1,"windows":[{"id":"11111111-1111-1111-1111-111111111111","selectedTabID":"22222222-2222-2222-2222-222222222222","tabs":[{"bookmarks":[0,7],"encoding":"windows1252","id":"22222222-2222-2222-2222-222222222222","length":2,"location":9,"manualLanguage":"python","originalPath":"/synthetic/é.txt","pinned":true}]}]}"#
      .utf8)
  private func install(_ bytes: Data, store: SessionStore, directory: URL) throws -> URL {
    try store.save(EditorSession(windows: []))
    let file = directory.appendingPathComponent("Session.json")
    try bytes.write(to: file)
    return file
  }
  func testLegacyCanonicalMigrationNeverWritesOnLoadAndFaultPreservesOriginalBytes() throws {
    try fixture { store, directory in
      let file = try install(legacy, store: store, directory: directory)
      let session = try XCTUnwrap(store.load())
      let tab = session.windows[0].tabs[0]
      XCTAssertEqual(tab.id.uuidString, "22222222-2222-2222-2222-222222222222")
      XCTAssertEqual(tab.originalPath, "/synthetic/é.txt")
      XCTAssertTrue(tab.pinned)
      XCTAssertEqual(tab.encoding, .windows1252)
      XCTAssertEqual(tab.manualLanguage, .python)
      XCTAssertEqual(tab.bookmarks, [0, 7])
      XCTAssertEqual(tab.presentation, .single(selection: NSRange(location: 9, length: 2)))
      XCTAssertEqual(try Data(contentsOf: file), legacy)
      XCTAssertThrowsError(try store.save(session, fault: .beforeReplace))
      XCTAssertEqual(try Data(contentsOf: file), legacy)
      try store.save(session)
      XCTAssertEqual(try store.load(), session)
      XCTAssertNotEqual(try Data(contentsOf: file), legacy)
    }
  }
  func testLegacyOptionalRecentPathsCanonicalDistinction() throws {
    for text in [#"{"version":1,"windows":[]}"#, #"{"recentPaths":[],"version":1,"windows":[]}"#] {
      try fixture { store, directory in
        let bytes = Data(text.utf8)
        let file = try install(bytes, store: store, directory: directory)
        XCTAssertEqual(try store.load(), EditorSession(windows: []))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
    try fixture { store, directory in
      let bytes = Data(#"{"recentPaths":null,"version":1,"windows":[]}"#.utf8)
      let file = try install(bytes, store: store, directory: directory)
      XCTAssertThrowsError(try store.load())
      XCTAssertThrowsError(try store.save(EditorSession(windows: [])))
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
  }
  func testUnsupportedZeroAndFutureVersionsHaveTypedRefusalAndPreserveBytes() throws {
    for version in [0, 4, 99] {
      try fixture { store, directory in
        let bytes = Data("{\"version\":\(version)}".utf8)
        let file = try install(bytes, store: store, directory: directory)
        for action in [{ _ = try store.load() }, { try store.save(EditorSession(windows: [])) }] {
          XCTAssertThrowsError(try action()) { error in
            guard case SessionStoreError.unsupportedVersion(let observed) = error else {
              return XCTFail("Expected version refusal")
            }
            XCTAssertEqual(observed, version)
          }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
  }
  func testTwoPaneRecoveryMergeStillUsesOneLogicalTabAndPreservesPresentation() throws {
    let presentation = SessionPresentation(
      axis: .stacked, panes: [pane(2), pane(5)], focusedPaneIndex: 1)
    let tab = SessionTab(originalPath: "/synthetic/original", presentation: presentation)
    let session = EditorSession(windows: [SessionWindow(tabs: [tab], selectedTabID: tab.id)])
    let recovery = RecoverySnapshot(
      id: tab.id, text: "new unsaved", encoding: .utf8, hasBOM: false,
      originalPath: "/synthetic/original")
    let plan = try SessionRestoration.plan(session: session, recoveries: [recovery])
    XCTAssertEqual(plan.windows.count, 1)
    XCTAssertEqual(plan.windows[0].tabs.count, 1)
    XCTAssertEqual(plan.windows[0].tabs[0].metadata.presentation, presentation)
    XCTAssertEqual(plan.windows[0].tabs[0].source, .recovery(recovery))
  }
  func testKnownVersionNestedUnknownDuplicateAndMissingFieldsAreCorrupt() throws {
    try fixture { store, directory in
      try store.save(state(.init(axis: .stacked, panes: [pane(), pane(8)], focusedPaneIndex: 1)))
      let file = directory.appendingPathComponent("Session.json")
      let valid = try String(contentsOf: file, encoding: .utf8)
      let malformed = [
        valid.replacingOccurrences(of: "\"axis\":\"stacked\"", with: "\"axis\":\"other\""),
        valid.replacingOccurrences(of: "\"axis\":", with: "\"extra\":0,\"axis\":"),
        valid.replacingOccurrences(
          of: "\"focusedPaneIndex\":1", with: "\"focusedPaneIndex\":1,\"focusedPaneIndex\":1"),
        valid.replacingOccurrences(of: "\"scrollX\":0", with: "\"scrollX\":0,\"scrollX\":0"),
        valid.replacingOccurrences(of: "\"scrollY\":0", with: "\"scrollY\":0,\"extra\":false"),
        valid.replacingOccurrences(of: "\"scrollX\":0", with: "\"scrollX\":1e999"),
        valid.replacingOccurrences(of: "\"focusedPaneIndex\":1", with: "\"focusedPaneIndex\":-1"),
        valid.replacingOccurrences(
          of: "\"presentation\":", with: "\"location\":0,\"length\":0,\"presentation\":"),
        valid.replacingOccurrences(of: "\"presentation\":", with: "\"unknownPresentation\":"),
      ]
      for text in malformed {
        XCTAssertNotEqual(text, valid, "Mutation must exercise actual v2 structure")
        let bytes = Data(text.utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.load()) { error in
          guard case SessionStoreError.corrupt = error else {
            return XCTFail("Expected known-schema corrupt")
          }
        }
        XCTAssertThrowsError(try store.save(EditorSession(windows: [])))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
  }
}
