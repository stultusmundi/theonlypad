// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import XCTest

@testable import NativeRouting

private struct ContractFailure: Error { let message: String }
private struct IdentityFacts: Codable {
  let requestedReads: Int
  let retainedReferences: Int
  let distinctIdentities: Int
  let identityGroups: [Int]
  let observedClasses: [String]
}
@MainActor
final class DocumentTextStorageTests: XCTestCase {
  private static let syntheticAttribute = NSAttributedString.Key("storage-cache.synthetic")

  private static func require(_ value: Bool, _ message: String) throws {
    guard value else { throw ContractFailure(message: message) }
  }
  private static func exact(_ value: String, _ expected: String, _ message: String) throws {
    try require(Array(value.utf8) == Array(expected.utf8), message + ": UTF8")
    try require(Array(value.utf16) == Array(expected.utf16), message + ": UTF16")
  }
  private static func exactNSString(_ value: NSString, _ expected: [UInt16]) throws {
    try require(value.length == expected.count, "retained NSString length")
    for index in expected.indices {
      // Expected length equality precedes every indexed Foundation call.
      try require(value.character(at: index) == expected[index], "retained NSString unit")
    }
  }
  @MainActor private static func isolated(_ storage: DocumentCommitTextStorage) throws {
    try require(NSApp == nil, "NSApp must remain nil")
    try require(storage.layoutManagers.isEmpty, "storage must have no layout manager")
    try require(storage.delegate == nil, "storage must have no delegate")
  }
  @MainActor private static func storage(_ text: String) throws -> DocumentCommitTextStorage {
    try require(NSApp == nil, "NSApp must be nil before construction")
    let storage = DocumentCommitTextStorage()
    try isolated(storage)
    try require(storage.length == 0, "new storage must be empty")
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    try isolated(storage)
    try require(storage.length == text.utf16.count, "population UTF16 length")
    return storage
  }
  @MainActor private static func text(
    _ storage: DocumentCommitTextStorage, _ expected: String
  ) throws {
    try isolated(storage)
    try exact(storage.string, expected, "current storage value")
    try require(storage.length == expected.utf16.count, "current UTF16 length")
  }
  @MainActor private static func replace(
    _ storage: DocumentCommitTextStorage, _ range: NSRange, _ replacement: String
  ) throws {
    let count = storage.length
    try require(
      range.location >= 0 && range.length >= 0 && range.location <= count,
      "bounded replacement start")
    try require(range.length <= count - range.location, "bounded replacement end")
    storage.replaceCharacters(in: range, with: replacement)
    try isolated(storage)
  }

  @MainActor private static func sameLengthMutation() throws {
    let value = try storage("ab")
    let a = value.string
    try replace(value, NSRange(location: 1, length: 1), "Z")
    try text(value, "aZ")
    let b = value.string
    try replace(value, NSRange(location: 1, length: 1), "b")
    try text(value, "ab")
    try replace(value, NSRange(location: 0, length: 2), "ab")
    try text(value, "ab")
    try replace(value, NSRange(location: 0, length: 0), "")
    try text(value, "ab")
    try exact(a, "ab", "retained original A")
    try exact(b, "aZ", "retained intermediate B")
  }

  @MainActor private static func retainedOldSnapshots() throws {
    let value = try storage("A😀e\u{301}\0\r\nZ")
    let oldSwift = value.string
    let oldBridge = value.string as NSString
    let selector = NSSelectorFromString("string")
    try require(value.responds(to: selector), "actual fixed getter exists")
    guard let borrowed = value.perform(selector),
      let oldObjC = borrowed.takeUnretainedValue() as? NSString
    else { throw ContractFailure(message: "actual fixed getter result type") }
    let expected: [UInt16] = [0x41, 0xD83D, 0xDE00, 0x65, 0x301, 0, 0xD, 0xA, 0x5A]
    try replace(value, NSRange(location: 0, length: 9), "q🌍")
    try text(value, "q🌍")
    try replace(value, NSRange(location: 0, length: 3), "end")
    try text(value, "end")
    try exact(oldSwift, "A😀e\u{301}\0\r\nZ", "retained Swift snapshot")
    try exactNSString(oldBridge, expected)
    try exactNSString(oldObjC, expected)
    withExtendedLifetime((oldSwift, oldBridge, oldObjC)) {}
  }

  @MainActor private static func mutableStringAdapter() throws {
    let value = try storage("ab")
    let proxy = value.mutableString
    let old = value.string
    proxy.setString("😀b")
    try text(value, "😀b")
    try require(proxy.length == 3, "actual retained proxy length before replacement")
    proxy.replaceCharacters(in: NSRange(location: 2, length: 1), with: "Z")
    try text(value, "😀Z")
    proxy.append("!")
    try text(value, "😀Z!")
    try exact(old, "ab", "old value survives retained proxy writes")
  }

  @MainActor private static func attributedReplacement() throws {
    let value = try storage("ab")
    let old = value.string
    let replacement = NSAttributedString(string: "😀", attributes: [syntheticAttribute: "seven"])
    try require(value.length == 2, "attributed replacement valid source range")
    value.replaceCharacters(in: NSRange(location: 0, length: 1), with: replacement)
    try text(value, "😀b")
    try require(value.length == 3, "attribute reads have valid indexes")
    try require(
      value.attribute(syntheticAttribute, at: 0, effectiveRange: nil) as? String == "seven",
      "replacement attribute at first surrogate")
    try require(
      value.attribute(syntheticAttribute, at: 1, effectiveRange: nil) as? String == "seven",
      "replacement attribute at second surrogate")
    let middle = value.string
    value.setAttributedString(
      NSAttributedString(string: "xy", attributes: [syntheticAttribute: "two"]))
    try text(value, "xy")
    try require(value.length == 2, "setAttributedString valid attribute index")
    try require(
      value.attribute(syntheticAttribute, at: 1, effectiveRange: nil) as? String == "two",
      "setAttributedString actual attribute")
    try exact(old, "ab", "attributed replacement old snapshot")
    try exact(middle, "😀b", "setAttributedString old snapshot")
  }

  @MainActor private static func attributeOnlyText() throws {
    let value = try storage("ab")
    let old = value.string
    try require(value.length == 2, "attribute-only valid range")
    value.setAttributes([syntheticAttribute: "one"], range: NSRange(location: 0, length: 2))
    try text(value, "ab")
    try require(
      value.attribute(syntheticAttribute, at: 0, effectiveRange: nil) as? String == "one",
      "actual setAttributes value")
    value.addAttribute(syntheticAttribute, value: "two", range: NSRange(location: 0, length: 2))
    try text(value, "ab")
    try require(
      value.attribute(syntheticAttribute, at: 1, effectiveRange: nil) as? String == "two",
      "actual addAttribute value")
    value.removeAttribute(syntheticAttribute, range: NSRange(location: 0, length: 2))
    try text(value, "ab")
    try require(
      value.attribute(syntheticAttribute, at: 1, effectiveRange: nil) == nil,
      "actual removeAttribute value")
    try exact(old, "ab", "attribute-only old snapshot")
  }

  @MainActor private static func deleteReinsertUnicode() throws {
    let value = try storage("😀e\u{301}\0\r\n")
    let old = value.string
    try require(value.length == 7, "Unicode original valid delete range")
    value.deleteCharacters(in: NSRange(location: 0, length: 2))
    try text(value, "e\u{301}\0\r\n")
    try require(value.length == 5, "combining pair valid delete range")
    value.deleteCharacters(in: NSRange(location: 0, length: 2))
    try text(value, "\0\r\n")
    value.insert(NSAttributedString(string: "🌍e\u{301}"), at: 0)
    try text(value, "🌍e\u{301}\0\r\n")
    try require(
      Array(value.string.utf16) == [0xD83C, 0xDF0D, 0x65, 0x301, 0, 0xD, 0xA],
      "independent final Unicode units")
    try exact(old, "😀e\u{301}\0\r\n", "Unicode deleted/reinserted old snapshot")
  }

  @MainActor private static func repeatedReadIdentity() throws -> IdentityFacts {
    // Same bounded input and16/16 read routes as the existing no-layout diagnostic.
    let value = try storage(String(repeating: "x", count: 65_536))
    let selector = NSSelectorFromString("string")
    try require(value.responds(to: selector), "actual fixed getter exists")
    var retained: [NSString] = []
    retained.reserveCapacity(32)
    var groups: [ObjectIdentifier: Int] = [:]
    var sequence: [Int] = []
    var classes: Set<String> = []
    for index in 0..<32 {
      try isolated(value)
      let result: NSString
      if index % 2 == 0 {
        result = value.string as NSString
      } else {
        guard let borrowed = value.perform(selector),
          let actual = borrowed.takeUnretainedValue() as? NSString
        else { throw ContractFailure(message: "actual fixed getter result type") }
        result = actual
      }
      try require(result.length == 65_536, "requested read UTF16 length")
      try require(
        result.character(at: 0) == 0x78 && result.character(at: 32_768) == 0x78
          && result.character(at: 65_535) == 0x78, "requested read scalar samples")
      retained.append(result)
      let id = ObjectIdentifier(result)
      let group: Int
      if let existing = groups[id] {
        group = existing
      } else {
        group = groups.count
        groups[id] = group
      }
      sequence.append(group)
      classes.insert(NSStringFromClass(type(of: result)))
      try isolated(value)
    }
    try require(retained.count == 32 && sequence.count == 32, "all32 retained together")
    return withExtendedLifetime((value, retained)) {
      IdentityFacts(
        requestedReads: 32, retainedReferences: 32,
        distinctIdentities: groups.count, identityGroups: sequence,
        observedClasses: classes.sorted())
    }
  }

  private func runContract(
    file: StaticString = #filePath, line: UInt = #line,
    _ body: @MainActor () throws -> Void
  ) {
    do { try autoreleasepool { try body() } } catch {
      let message = (error as? ContractFailure)?.message ?? "unexpected Swift error"
      XCTFail(message, file: file, line: line)
    }
  }

  func testSameLengthMutationABAAndNoOp() {
    runContract { try Self.sameLengthMutation() }
  }

  func testRetainedOldSnapshotImmutability() {
    runContract { try Self.retainedOldSnapshots() }
  }

  func testMutableStringAdapterInvalidatesSnapshot() {
    runContract { try Self.mutableStringAdapter() }
  }

  func testAttributedReplacementInvalidatesSnapshot() {
    runContract { try Self.attributedReplacement() }
  }

  func testAttributeOnlyChangesPreserveText() {
    runContract { try Self.attributeOnlyText() }
  }

  func testDeleteReinsertUnicode() {
    runContract { try Self.deleteReinsertUnicode() }
  }

  func testRepeated32NSStringReadsRetainAtMostOneIdentity() {
    do {
      let facts = try autoreleasepool { try Self.repeatedReadIdentity() }
      XCTAssertLessThanOrEqual(
        facts.distinctIdentities, 1,
        "32 retained requested reads; groups=\(facts.identityGroups), classes=\(facts.observedClasses)"
      )
    } catch {
      let message = (error as? ContractFailure)?.message ?? "unexpected Swift error"
      XCTFail(message)
    }
  }
}
