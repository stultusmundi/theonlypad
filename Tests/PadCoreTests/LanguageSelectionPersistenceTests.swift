import Foundation
import XCTest

@testable import PadCore

// Independent canonical byte fixtures. No production encoder creates expectations.
final class LanguageSelectionPersistenceTests: XCTestCase {
  private let windowID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let tabID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let customID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
  private let missingID = UUID(uuidString: "FFFFFFFF-1111-4222-8333-444444444444")!

  private let v1Manual = Data(
    #"{"version":1,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[0,7],"encoding":"windows1252","id":"22222222-2222-4222-8222-222222222222","length":2,"location":9,"manualLanguage":"python","originalPath":"/synthetic/example.py","pinned":true}]}]}"#
      .utf8)
  private let v1Automatic = Data(
    #"{"version":1,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[],"encoding":"utf8","id":"22222222-2222-4222-8222-222222222222","length":0,"location":0,"pinned":false}]}]}"#
      .utf8)
  private let v2Manual = Data(
    #"{"version":2,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[0,7],"encoding":"windows1252","id":"22222222-2222-4222-8222-222222222222","manualLanguage":"python","originalPath":"/synthetic/example.py","pinned":true,"presentation":{"axis":"stacked","focusedPaneIndex":1,"panes":[{"length":2,"location":9,"scrollX":12.5,"scrollY":250},{"length":0,"location":18,"scrollX":48,"scrollY":1200}]}}]}]}"#
      .utf8)
  private let v2Automatic = Data(
    #"{"version":2,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[],"encoding":"utf8","id":"22222222-2222-4222-8222-222222222222","pinned":false,"presentation":{"axis":"sideBySide","focusedPaneIndex":0,"panes":[{"length":0,"location":0,"scrollX":0,"scrollY":0}]}}]}]}"#
      .utf8)
  private let v3Custom = Data(
    #"{"version":3,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[0,7],"encoding":"windows1252","id":"22222222-2222-4222-8222-222222222222","languageSelection":{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"manual"},"originalPath":"/synthetic/example.py","pinned":true,"presentation":{"axis":"stacked","focusedPaneIndex":1,"panes":[{"length":2,"location":9,"scrollX":12.5,"scrollY":250},{"length":0,"location":18,"scrollX":48,"scrollY":1200}]}}]}]}"#
      .utf8)
  private let v3Automatic = Data(
    #"{"version":3,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[],"encoding":"utf8","id":"22222222-2222-4222-8222-222222222222","languageSelection":{"mode":"automatic"},"pinned":false,"presentation":{"axis":"sideBySide","focusedPaneIndex":0,"panes":[{"length":0,"location":0,"scrollX":0,"scrollY":0}]}}]}]}"#
      .utf8)
  private let v3Mixed = Data(
    #"{"version":3,"windows":[{"id":"11111111-1111-4111-8111-111111111111","selectedTabID":"22222222-2222-4222-8222-222222222222","tabs":[{"bookmarks":[],"encoding":"utf8","id":"22222222-2222-4222-8222-222222222222","languageSelection":{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"manual"},"pinned":false,"presentation":{"axis":"sideBySide","focusedPaneIndex":0,"panes":[{"length":0,"location":0,"scrollX":0,"scrollY":0}]}},{"bookmarks":[],"encoding":"utf8","id":"33333333-3333-4333-8333-333333333333","languageSelection":{"mode":"automatic"},"pinned":false,"presentation":{"axis":"sideBySide","focusedPaneIndex":0,"panes":[{"length":0,"location":0,"scrollX":0,"scrollY":0}]}},{"bookmarks":[],"encoding":"utf8","id":"44444444-4444-4444-8444-444444444444","languageSelection":{"builtin":"python","mode":"manual"},"pinned":false,"presentation":{"axis":"sideBySide","focusedPaneIndex":0,"panes":[{"length":0,"location":0,"scrollX":0,"scrollY":0}]}}]}]}"#
      .utf8)

  private func fixture(_ body: (SessionStore, URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("Session")
    try body(SessionStore(directory: directory), directory.appendingPathComponent("Session.json"))
  }
  private func install(_ bytes: Data, store: SessionStore, file: URL) throws {
    // Real store creates the private directory/600 leaf; replacement supplies fixed test bytes.
    try store.save(EditorSession(windows: []))
    try bytes.write(to: file)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  private func state(_ tab: SessionTab) -> EditorSession {
    EditorSession(windows: [SessionWindow(id: windowID, tabs: [tab], selectedTabID: tab.id)])
  }
  private func presentation() -> SessionPresentation {
    .init(
      axis: .stacked,
      panes: [
        .init(selection: NSRange(location: 9, length: 2), scrollOrigin: .init(x: 12.5, y: 250)),
        .init(selection: NSRange(location: 18, length: 0), scrollOrigin: .init(x: 48, y: 1200)),
      ], focusedPaneIndex: 1)
  }
  private func customTab(_ id: UUID) -> SessionTab {
    SessionTab(
      id: tabID, originalPath: "/synthetic/example.py", pinned: true,
      encoding: .windows1252, bookmarks: [0, 7], presentation: presentation(),
      languageSelection: .manual(.custom(id)))
  }
  private func loadWithoutThrow(_ store: SessionStore) -> EditorSession? {
    do { return try store.load() } catch {
      XCTFail("A complete canonical supported session must load: \(error)")
      return nil
    }
  }
  private func assertCorruptPreserved(_ bytes: Data, store: SessionStore, file: URL) throws {
    try install(bytes, store: store, file: file)
    for action in [{ _ = try store.load() }, { try store.save(EditorSession(windows: [])) }] {
      XCTAssertThrowsError(try action()) { error in
        guard case SessionStoreError.corrupt = error else {
          return XCTFail("Known V3 malformed selection must be corrupt, not discarded: \(error)")
        }
      }
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
      ["Session.json"])
  }

  func testLegacyInitializerAndExplicitSelectionHaveOneAuthority() {
    XCTAssertEqual(SessionTab().languageSelection, .automatic)
    XCTAssertNil(SessionTab().manualLanguage)
    for language in DocumentLanguage.allCases {
      let tab = SessionTab(manualLanguage: language)
      XCTAssertEqual(tab.languageSelection, .manual(.builtIn(language)))
      XCTAssertEqual(tab.manualLanguage, language)
    }
    let custom = SessionTab(manualLanguage: .python, languageSelection: .manual(.custom(customID)))
    XCTAssertEqual(custom.languageSelection, .manual(.custom(customID)))
    XCTAssertNil(custom.manualLanguage)
    let automatic = SessionTab(manualLanguage: .python, languageSelection: .automatic)
    XCTAssertEqual(automatic.languageSelection, .automatic)
    XCTAssertNil(automatic.manualLanguage)
  }

  func testFixedV1ManualBytesLoadWithoutRewriteOrMetadataLoss() throws {
    try fixture { store, file in
      try install(v1Manual, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      let tab = try XCTUnwrap(loaded.windows.first?.tabs.first)
      XCTAssertEqual(loaded.windows[0].id, windowID)
      XCTAssertEqual(loaded.windows[0].selectedTabID, tabID)
      XCTAssertEqual(tab.id, tabID)
      XCTAssertEqual(tab.languageSelection, .manual(.builtIn(.python)))
      XCTAssertEqual(tab.manualLanguage, .python)
      XCTAssertEqual(tab.encoding, .windows1252)
      XCTAssertEqual(tab.originalPath, "/synthetic/example.py")
      XCTAssertTrue(tab.pinned)
      XCTAssertEqual(tab.bookmarks, [0, 7])
      XCTAssertEqual(tab.presentation, .single(selection: NSRange(location: 9, length: 2)))
      XCTAssertEqual(try Data(contentsOf: file), v1Manual)
      XCTAssertEqual(loaded.recentPaths, [])
    }
  }

  func testFixedV1AutomaticRemainsAutomaticWithoutRewrite() throws {
    try fixture { store, file in
      try install(v1Automatic, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      let tab = try XCTUnwrap(loaded.windows.first?.tabs.first)
      XCTAssertEqual(tab.languageSelection, .automatic)
      XCTAssertNil(tab.manualLanguage)
      XCTAssertEqual(tab.selection, NSRange(location: 0, length: 0))
      XCTAssertEqual(try Data(contentsOf: file), v1Automatic)
    }
  }

  func testFixedV2ManualLoadAndSaveRetainExactBytesAndBothPanes() throws {
    try fixture { store, file in
      try install(v2Manual, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      let tab = try XCTUnwrap(loaded.windows.first?.tabs.first)
      XCTAssertEqual(tab.languageSelection, .manual(.builtIn(.python)))
      XCTAssertEqual(tab.manualLanguage, .python)
      XCTAssertEqual(tab.presentation, presentation())
      XCTAssertEqual(tab.selection, NSRange(location: 18, length: 0))
      XCTAssertEqual(tab.encoding, .windows1252)
      XCTAssertEqual(tab.originalPath, "/synthetic/example.py")
      XCTAssertTrue(tab.pinned)
      XCTAssertEqual(tab.bookmarks, [0, 7])
      XCTAssertEqual(try Data(contentsOf: file), v2Manual)
      try store.save(loaded)
      XCTAssertEqual(try Data(contentsOf: file), v2Manual)
      XCTAssertEqual(try store.load(), loaded)
    }
  }

  func testRepresentableAutomaticSaveUsesExactFixedV2Bytes() throws {
    try fixture { store, file in
      let saved = state(SessionTab(id: tabID, languageSelection: .automatic))
      try store.save(saved)
      XCTAssertEqual(try Data(contentsOf: file), v2Automatic)
      XCTAssertEqual(try store.load(), saved)
      let tab = try XCTUnwrap(store.load()?.windows.first?.tabs.first)
      XCTAssertEqual(tab.languageSelection, .automatic)
      XCTAssertNil(tab.manualLanguage)
    }
  }

  func testManualBuiltInIncludingPlainTextRoundTripsAsVersionTwo() throws {
    try fixture { store, file in
      for language in DocumentLanguage.allCases {
        let saved = state(SessionTab(id: tabID, languageSelection: .manual(.builtIn(language))))
        try store.save(saved)
        XCTAssertEqual(try store.load(), saved)
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        let tab = try XCTUnwrap(store.load()?.windows.first?.tabs.first)
        XCTAssertEqual(tab.languageSelection, .manual(.builtIn(language)))
        XCTAssertEqual(tab.manualLanguage, language)
      }
    }
  }

  func testManualCustomSaveWritesFixedV3AndRoundTripsEveryTabField() throws {
    try fixture { store, file in
      let saved = state(customTab(customID))
      try store.save(saved)
      XCTAssertEqual(
        try Data(contentsOf: file), v3Custom, "A custom UUID requires V3, not a V2 plain fallback")
      let loaded = try XCTUnwrap(store.load())
      XCTAssertEqual(loaded, saved)
      let tab = try XCTUnwrap(loaded.windows.first?.tabs.first)
      XCTAssertEqual(tab.languageSelection, .manual(.custom(customID)))
      XCTAssertNil(tab.manualLanguage)
      XCTAssertEqual(tab.presentation, presentation())
      XCTAssertEqual(tab.bookmarks, [0, 7])
      XCTAssertEqual(tab.encoding, .windows1252)
      XCTAssertEqual(tab.originalPath, "/synthetic/example.py")
    }
  }

  func testFixedV3CustomLoadAndResaveKeepCanonicalBytes() throws {
    try fixture { store, file in
      try install(v3Custom, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      XCTAssertEqual(loaded, state(customTab(customID)))
      XCTAssertEqual(try Data(contentsOf: file), v3Custom)
      try store.save(loaded)
      XCTAssertEqual(try Data(contentsOf: file), v3Custom)
    }
  }

  func testFixedV3MixedSelectionsNeverFreezeAutomaticDetection() throws {
    try fixture { store, file in
      try install(v3Mixed, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      let tabs = try XCTUnwrap(loaded.windows.first?.tabs)
      XCTAssertEqual(tabs.count, 3)
      guard tabs.count == 3 else { return }
      XCTAssertEqual(
        tabs.map(\.languageSelection),
        [.manual(.custom(customID)), .automatic, .manual(.builtIn(.python))])
      XCTAssertNil(tabs[0].manualLanguage)
      XCTAssertNil(tabs[1].manualLanguage)
      XCTAssertEqual(tabs[2].manualLanguage, .python)
      XCTAssertEqual(loaded.windows[0].selectedTabID, tabID)
      XCTAssertEqual(
        tabs.map(\.id),
        [
          tabID,
          UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
          UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        ])
      try store.save(loaded)
      XCTAssertEqual(try Data(contentsOf: file), v3Mixed)
    }
  }

  func testMissingCustomIDIsRetainedWhilePureResolverShowsPlainFallback() throws {
    try fixture { store, file in
      let saved = state(customTab(missingID))
      try store.save(saved)
      let loaded = try XCTUnwrap(store.load())
      let tab = try XCTUnwrap(loaded.windows.first?.tabs.first)
      XCTAssertEqual(tab.languageSelection, .manual(.custom(missingID)))
      XCTAssertNil(tab.manualLanguage)
      let emptyCatalog = try LanguageCatalogSnapshot(definitions: [], overrides: [], generation: 1)
      let resolved = emptyCatalog.resolve(
        selection: tab.languageSelection,
        filename: "example.py", builtinDetected: .python)
      XCTAssertEqual(resolved.requestedID, .custom(missingID))
      XCTAssertEqual(resolved.warning, .missingProfile(missingID))
      XCTAssertEqual(resolved.builtinLanguage, .plainText)
      XCTAssertNil(resolved.editing.lineComment)
      XCTAssertEqual(resolved.editing.indentation, .legacy)
      try store.save(loaded)
      let reread = try XCTUnwrap(store.load()?.windows.first?.tabs.first)
      XCTAssertEqual(reread.languageSelection, .manual(.custom(missingID)))
      let expected = Data(
        String(decoding: v3Custom, as: UTF8.self)
          .replacingOccurrences(of: customID.uuidString, with: missingID.uuidString).utf8)
      XCTAssertEqual(try Data(contentsOf: file), expected)
    }
  }

  func testExplicitSaveOfRepresentableV3AutomaticReturnsExactV2() throws {
    try fixture { store, file in
      try install(v3Automatic, store: store, file: file)
      guard let loaded = loadWithoutThrow(store) else { return }
      XCTAssertEqual(loaded, state(SessionTab(id: tabID, languageSelection: .automatic)))
      XCTAssertEqual(try Data(contentsOf: file), v3Automatic, "Loading cannot migrate on disk")
      try store.save(loaded)
      XCTAssertEqual(try Data(contentsOf: file), v2Automatic)
    }
  }

  func testCustomSaveFaultPreservesV2AndRetryPublishesOriginalID() throws {
    try fixture { store, file in
      try install(v2Manual, store: store, file: file)
      let saved = state(customTab(customID))
      for fault in [SaveFault.beforeWrite, .afterWrite, .beforeReplace, .diskFull] {
        XCTAssertThrowsError(try store.save(saved, fault: fault))
        XCTAssertEqual(try Data(contentsOf: file), v2Manual)
        XCTAssertEqual(
          try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path), ["Session.json"])
      }
      try store.save(saved)
      XCTAssertEqual(try Data(contentsOf: file), v3Custom)
      XCTAssertEqual(try store.load(), saved)
    }
  }

  func testInvalidCustomUUIDAndPayloadTypesRefuseWithoutReplacement() throws {
    let original = String(decoding: v3Custom, as: UTF8.self)
    for payload in ["\"\"", "\"not-a-uuid\"", "17", "null", "[]", "{}"] {
      let changed = original.replacingOccurrences(
        of: #""AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE""#, with: payload)
      XCTAssertNotEqual(changed, original)
      try fixture { store, file in
        try assertCorruptPreserved(Data(changed.utf8), store: store, file: file)
      }
    }
  }

  func testConflictingOrMisplacedLegacySelectionFieldsRefuseWithoutReplacement() throws {
    let original = String(decoding: v3Custom, as: UTF8.self)
    let malformed = [
      original.replacingOccurrences(
        of: #""originalPath":"#, with: #""manualLanguage":"python","originalPath":"#),
      original.replacingOccurrences(of: #""customID":"#, with: #""builtin":"python","customID":"#),
      original.replacingOccurrences(of: #""customID":"#, with: #""manualCustomID":"#),
      String(decoding: v2Manual, as: UTF8.self).replacingOccurrences(
        of: #""manualLanguage":"#,
        with: #""languageSelection":{"mode":"automatic"},"manualLanguage":"#),
    ]
    for changed in malformed {
      try fixture { store, file in
        try assertCorruptPreserved(Data(changed.utf8), store: store, file: file)
      }
    }
  }

  func testKnownV3UnknownDuplicateAndIncompleteSelectionMetadataRefuses() throws {
    let original = String(decoding: v3Custom, as: UTF8.self)
    let selection = #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"manual"}"#
    let malformed = [
      original.replacingOccurrences(of: #"{"version":3,"#, with: #"{"future":true,"version":3,"#),
      original.replacingOccurrences(
        of: #""languageSelection":"#, with: #""future":0,"languageSelection":"#),
      original.replacingOccurrences(
        of: selection,
        with: #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","future":true,"mode":"manual"}"#),
      original.replacingOccurrences(
        of: selection,
        with:
          #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"manual","mode":"manual"}"#),
      original.replacingOccurrences(of: selection, with: #"{"mode":"manual"}"#),
      original.replacingOccurrences(
        of: selection, with: #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"}"#),
      original.replacingOccurrences(
        of: selection,
        with: #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"automatic"}"#),
      original.replacingOccurrences(
        of: selection, with: #"{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","mode":"future"}"#
      ),
      original.replacingOccurrences(of: selection, with: "null"),
    ]
    for changed in malformed {
      XCTAssertNotEqual(changed, original)
      try fixture { store, file in
        try assertCorruptPreserved(Data(changed.utf8), store: store, file: file)
      }
    }
  }

  func testUnknownFutureVersionRemainsTypedAndUnchanged() throws {
    try fixture { store, file in
      let bytes = Data(
        #"{"futureLanguageSelection":{"customID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"},"version":99,"windows":[]}"#
          .utf8)
      try install(bytes, store: store, file: file)
      for action in [{ _ = try store.load() }, { try store.save(EditorSession(windows: [])) }] {
        XCTAssertThrowsError(try action()) { error in
          guard case SessionStoreError.unsupportedVersion(99) = error else {
            return XCTFail("Future schema must retain explicit unsupportedVersion")
          }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
      }
    }
  }
}
