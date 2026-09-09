import Foundation
import XCTest

@testable import PadCore

final class SessionRestorationTests: XCTestCase {
  func recovery(_ id: UUID = UUID()) -> RecoverySnapshot {
    RecoverySnapshot(
      id: id, text: "unsaved 😀", encoding: .utf16LE, hasBOM: true,
      originalPath: "/synthetic/original")
  }
  func testRecoveryWinsAsScratchPreservingMetadataAndWindowOrder() throws {
    let tab = SessionTab(
      originalPath: "/synthetic/file", pinned: true, encoding: .windows1252,
      manualLanguage: .python, selection: NSRange(location: 4, length: 2), bookmarks: [0, 3])
    let missing = SessionTab()
    let saved = SessionTab(originalPath: "/synthetic/missing-file")
    let a = SessionWindow(tabs: [tab, missing], selectedTabID: missing.id)
    let b = SessionWindow(tabs: [saved], selectedTabID: saved.id)
    let snapshot = recovery(tab.id)
    let result = try SessionRestoration.plan(
      session: EditorSession(windows: [a, b], recentPaths: ["/synthetic/recent"]),
      recoveries: [snapshot])
    XCTAssertEqual(result.windows.map(\.id), [a.id, b.id])
    XCTAssertEqual(result.windows[0].tabs.map(\.metadata), [tab, missing])
    XCTAssertEqual(result.windows[0].selectedTabID, missing.id)
    XCTAssertEqual(result.windows[0].tabs[0].source, .recovery(snapshot))
    XCTAssertEqual(result.windows[0].tabs[1].source, .missingRecovery)
    XCTAssertEqual(
      result.windows[1].tabs[0].source, .file(path: "/synthetic/missing-file", encoding: .utf8))
    XCTAssertEqual(result.missingRecoveryIDs, [missing.id])
    XCTAssertEqual(result.recentPaths, ["/synthetic/recent"])
    XCTAssertTrue(result.needsResolution)
  }
  func testInitialSessionAndOrphansKeepInputOrder() throws {
    let snapshots = [recovery(), recovery()]
    let windowID = UUID()
    let result = try SessionRestoration.plan(
      session: nil, recoveries: snapshots, orphanWindowID: windowID)
    XCTAssertEqual(result.windows.map(\.id), [windowID])
    XCTAssertEqual(result.windows[0].tabs.map { $0.metadata.id }, snapshots.map(\.id))
    XCTAssertEqual(result.windows[0].selectedTabID, snapshots[0].id)
    XCTAssertTrue(result.windows[0].tabs.allSatisfy { $0.metadata.originalPath == nil })
    XCTAssertFalse(result.needsResolution)
    XCTAssertTrue(try SessionRestoration.plan(session: nil, recoveries: []).windows.isEmpty)
  }
  func testDuplicateAndCollidingIDsRejected() {
    let r = recovery()
    XCTAssertThrowsError(try SessionRestoration.plan(session: nil, recoveries: [r, r])) {
      XCTAssertEqual($0 as? SessionRestorationError, .duplicateID)
    }
    let tab = SessionTab(id: r.id)
    let window = SessionWindow(id: r.id, tabs: [tab], selectedTabID: tab.id)
    XCTAssertThrowsError(
      try SessionRestoration.plan(session: EditorSession(windows: [window]), recoveries: []))
    XCTAssertThrowsError(
      try SessionRestoration.plan(session: nil, recoveries: [r], orphanWindowID: r.id))
    let invalid = SessionWindow(tabs: [SessionTab()], selectedTabID: UUID())
    XCTAssertThrowsError(
      try SessionRestoration.plan(session: EditorSession(windows: [invalid]), recoveries: []))
  }
  func testOrphansBeyondPersistenceCapacityArePreservedAndFlagged() throws {
    let tabs = (0..<128).map { _ in SessionTab(originalPath: "/synthetic/file") }
    let window = SessionWindow(tabs: tabs, selectedTabID: tabs[0].id)
    let snapshots = (0..<128).map { _ in recovery() }
    let result = try SessionRestoration.plan(
      session: EditorSession(windows: [window]), recoveries: snapshots)
    XCTAssertEqual(result.windows.reduce(0) { $0 + $1.tabs.count }, 256)
    XCTAssertTrue(result.exceedsPersistenceCapacity)
    XCTAssertTrue(result.needsResolution)
    XCTAssertThrowsError(
      try SessionRestoration.plan(
        session: EditorSession(windows: [window]), recoveries: snapshots + [recovery()]))
    let windows = (0..<32).map { _ in SessionWindow(tabs: [], selectedTabID: nil) }
    let overWindows = try SessionRestoration.plan(
      session: EditorSession(windows: windows), recoveries: [recovery()])
    XCTAssertEqual(overWindows.windows.count, 33)
    XCTAssertTrue(overWindows.exceedsPersistenceCapacity)
    XCTAssertThrowsError(
      try SessionRestoration.plan(
        session: EditorSession(windows: windows + [SessionWindow(tabs: [], selectedTabID: nil)]),
        recoveries: []))
  }
  func testMatchedRecoveryDoesNotConsumeExtraSlotsAndOrphansFollowExistingWindows() throws {
    let snapshots = (0..<128).map { _ in recovery() }
    let tabs = snapshots.map { SessionTab(id: $0.id) }
    let window = SessionWindow(tabs: tabs, selectedTabID: tabs.last?.id)
    let result = try SessionRestoration.plan(
      session: EditorSession(windows: [window]), recoveries: snapshots.reversed())
    XCTAssertEqual(result.windows.count, 1)
    XCTAssertEqual(result.windows[0].tabs.map { $0.metadata.id }, tabs.map(\.id))
    XCTAssertEqual(result.windows[0].selectedTabID, tabs.last?.id)
    XCTAssertFalse(result.needsResolution)
    let orphan = recovery()
    let extra = try SessionRestoration.plan(
      session: EditorSession(windows: [window]), recoveries: [orphan] + snapshots)
    XCTAssertEqual(extra.windows.first?.id, window.id)
    XCTAssertEqual(extra.windows.last?.tabs.first?.source, .recovery(orphan))
  }
  func testMalformedMetadataRefusedWithoutDocumentIO() {
    let cases = [
      SessionTab(originalPath: "relative"),
      SessionTab(selection: NSRange(location: Int.max, length: 1)), SessionTab(bookmarks: [1, 0]),
    ]
    for tab in cases {
      let window = SessionWindow(tabs: [tab], selectedTabID: tab.id)
      XCTAssertThrowsError(
        try SessionRestoration.plan(session: EditorSession(windows: [window]), recoveries: [])
      ) {
        XCTAssertEqual($0 as? SessionRestorationError, .invalidMetadata)
      }
    }
  }

}
