// SPDX-License-Identifier: MIT
// SOURCE ONLY. Independent version1 literal serialization and replay clients.
import Foundation
import XCTest

@testable import PadCore

final class MacroChronologyReplayTests: XCTestCase {
  func testLiteralChronologicalUnicodePrefixesAndSerializedReplay() throws {
    let expectedForward: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    let expectedUndo: MacroCommand = .replace(location: 0, length: 3, text: "😀x")
    let expectedRedo: MacroCommand = .replace(location: 0, length: 3, text: "😀y")
    let rows: [([MacroCommand], String)] = [
      ([expectedForward], "😀y"), ([expectedForward, expectedUndo], "😀x"),
      ([expectedForward, expectedUndo, expectedRedo], "😀y"),
    ]
    let id: UUID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
    for (commands, target) in rows {
      let original: EditorMacro = EditorMacro(
        name: "Synthetic chronology", commands: commands, id: id)
      let data: Data = try JSONEncoder().encode(original)
      let restored: EditorMacro = try JSONDecoder().decode(EditorMacro.self, from: data)
      XCTAssertEqual(restored, original)
      XCTAssertEqual(restored.version, 1)
      XCTAssertEqual(restored.commands, commands)
      XCTAssertEqual(try MacroPlayer.replay(original, on: "😀x"), target)
      XCTAssertEqual(try MacroPlayer.replay(restored, on: "😀x"), target)
    }
  }

  func testLiteralInsertionUndoContinueDiffersFromFlagOnlyExclusion() throws {
    let expectedInsertion: MacroCommand = .replace(location: 0, length: 0, text: "X")
    let expectedDeletion: MacroCommand = .replace(location: 0, length: 1, text: "")
    let expectedReplacement: MacroCommand = .replace(location: 0, length: 1, text: "Q")
    let id: UUID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
    let chronological = EditorMacro(
      name: "Synthetic chronology",
      commands: [expectedInsertion, expectedDeletion, expectedReplacement], id: id)
    let excluded = EditorMacro(
      name: "Synthetic omission", commands: [expectedInsertion, expectedReplacement], id: id)
    XCTAssertEqual(try MacroPlayer.replay(chronological, on: "ab"), "Qb")
    XCTAssertEqual(try MacroPlayer.replay(excluded, on: "ab"), "Qab")
  }

  func testLiteralWholeSourceUndoContinueDiffersFromFlagOnlyExclusion() throws {
    let expectedCommandA: MacroCommand = .replace(location: 0, length: 2, text: "Xab")
    let expectedCommandB: MacroCommand = .replace(location: 0, length: 3, text: "ab")
    let expectedCommandC: MacroCommand = .replace(location: 0, length: 2, text: "Qb")
    let id: UUID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000601"))
    let faithful = EditorMacro(
      name: "Synthetic chronology",
      commands: [expectedCommandA, expectedCommandB, expectedCommandC], id: id)
    let excluded = EditorMacro(
      name: "Synthetic omission", commands: [expectedCommandA, expectedCommandC], id: id)
    let startedLater = EditorMacro(
      name: "Synthetic later recording", commands: [expectedCommandB, expectedCommandC], id: id)
    XCTAssertEqual(try MacroPlayer.replay(faithful, on: "ab"), "Qb")
    XCTAssertEqual(try MacroPlayer.replay(excluded, on: "ab"), "Qbb")
    XCTAssertEqual(try MacroPlayer.replay(startedLater, on: "Xab"), "Qb")
  }
}
