import Darwin
import Foundation
import XCTest

@testable import PadCore

enum CatalogTestFixture {
  static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
  static let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
  // Original synthetic literals, not produced by the candidate encoder.
  static let definitionText =
    ##"{"version":1,"id":"00000000-0000-4000-8000-000000000004","name":"Demo","fileExtensions":["demo"],"keywords":["café","cafe\u0301"],"lineComment":"#","blockComment":null,"quotes":[],"highlightDecimalNumbers":true,"indentation":{"kind":"legacy"}}"##
  static let originalText =
    #"{"version":1,"generation":7,"profiles":[{"revision":3,"definition":"#
    + definitionText
    + #"}],"overrides":[{"language":"swift","lineComment":{"kind":"disabled"},"blockComment":{"kind":"inherit"},"indentation":{"kind":"tabs","width":3}}]}"#
  static let originalBytes = Data(originalText.utf8)
  static func changed(_ old: String, _ new: String) -> Data {
    precondition(originalText.contains(old), "Independent fixture field must exist")
    var text = originalText
    let range = text.range(of: old)!
    text.replaceSubrange(range, with: new)
    return Data(text.utf8)
  }
  static func definition(name: String = "Demo", ext: String = "demo") throws
    -> LiteralLanguageDefinition
  {
    try LiteralLanguageDefinition(
      id: id, name: name, fileExtensions: [ext], keywords: ["café", "cafe\u{301}"],
      lineComment: "#", blockComment: nil, quotes: [],
      highlightDecimalNumbers: true, indentation: .legacy)
  }
  static func draft(generation: UInt64, name: String = "Demo") throws
    -> LanguageCatalogSnapshot
  {
    try LanguageCatalogSnapshot(
      definitions: [definition(name: name)], overrides: [], generation: generation)
  }
  static func profile(_ snapshot: LanguageCatalogSnapshot) -> ResolvedLanguageProfile {
    snapshot.resolve(
      selection: .manual(.custom(id)), filename: "file.swift", builtinDetected: .swift)
  }
}

extension XCTestCase {
  func catalogPrivateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func catalogPrivateDirectory() throws -> URL {
    let root = try catalogPrivateRoot()
    let directory = root.appendingPathComponent("Languages")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
  }
  func catalogInstall(_ bytes: Data, in directory: URL) throws {
    let file = directory.appendingPathComponent("Profiles.json")
    try bytes.write(to: file)
    XCTAssertEqual(chmod(file.path, 0o600), 0)
  }
  func catalogRejects(
    _ operation: () throws -> Void, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    do {
      try operation()
      XCTFail("Invalid catalog operation accepted: \(label)", file: file, line: line)
    } catch {
      XCTAssertNotEqual(
        error as? CustomLanguageStoreError, .unimplemented, label, file: file, line: line)
      XCTAssertNotEqual(
        error as? LanguageProfileError, .unimplemented, label, file: file, line: line)
      XCTAssertNotEqual(
        error as? BoundedProfileJSON.Failure, .unimplemented, label, file: file, line: line)
    }
  }
  func catalogLoad(
    _ store: CustomLanguageStore, file: StaticString = #filePath, line: UInt = #line
  ) -> LoadedLanguageCatalog? {
    do { return try store.load() } catch {
      XCTFail("Valid owned catalog load refused: \(error)", file: file, line: line)
      return nil
    }
  }
}
