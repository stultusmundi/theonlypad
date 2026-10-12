import Foundation

// Internal bounded mechanics for the new profile APIs. Existing built-in
// comment and LineTransform entry points retain their original implementation.
struct BoundedLanguageEditing {
  static let maximumUnits = 2_000_000
  static let maximumLines = 20_000

  enum Failure: Error { case invalidSelection, textLimit, lineLimit }
  struct Line {
    let start: Int
    let bodyEnd: Int
    let end: Int
  }
  struct Edit {
    let start: Int
    let removed: Int
    let inserted: [UInt16]
  }

  private var workSinceCheck = 0

  mutating func check(_ isCancelled: () -> Bool) throws {
    if isCancelled() { throw CancellationError() }
    workSinceCheck = 0
  }

  // Charge each explicitly visited/copied/emitted unit, including inner loops.
  // Check before the next unit after 4096; a CRLF is charged one unit at a time.
  mutating func step(_ isCancelled: () -> Bool) throws {
    if workSinceCheck == 4096 { try check(isCancelled) }
    workSinceCheck += 1
  }

  mutating func read(_ text: String, isCancelled: () -> Bool) throws -> [UInt16] {
    try check(isCancelled)
    var units: [UInt16] = []
    for unit in text.utf16 {
      try step(isCancelled)
      guard units.count < Self.maximumUnits else { throw Failure.textLimit }
      units.append(unit)
    }
    try check(isCancelled)
    return units
  }

  func validate(_ selection: NSRange, in units: [UInt16]) throws {
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= units.count, selection.length <= units.count - selection.location
    else { throw Failure.invalidSelection }
    for offset in [selection.location, selection.location + selection.length] {
      guard offset == units.count || !(0xDC00...0xDFFF).contains(units[offset]) else {
        throw Failure.invalidSelection
      }
    }
  }

  mutating func lines(in units: [UInt16], isCancelled: () -> Bool) throws -> [Line] {
    var result: [Line] = []
    var start = 0
    var cursor = 0
    while cursor < units.count {
      try step(isCancelled)
      let unit = units[cursor]
      if unit == 10 || unit == 13 {
        let bodyEnd = cursor
        cursor += 1
        if unit == 13, cursor < units.count, units[cursor] == 10 {
          try step(isCancelled)
          cursor += 1
        }
        // Every terminator creates another logical line, including the final
        // empty line. Check before allocating a record beyond the policy.
        guard result.count < Self.maximumLines - 1 else { throw Failure.lineLimit }
        result.append(Line(start: start, bodyEnd: bodyEnd, end: cursor))
        start = cursor
      } else {
        cursor += 1
      }
    }
    result.append(Line(start: start, bodyEnd: units.count, end: units.count))
    try check(isCancelled)
    return result
  }

  mutating func touched(
    _ lines: [Line], selection: NSRange, isCancelled: () -> Bool
  ) throws -> (first: Int, last: Int) {
    let endpoint =
      selection.length == 0
      ? selection.location : selection.location + selection.length - 1
    var first = 0
    var last = 0
    for index in lines.indices {
      try step(isCancelled)
      if lines[index].start <= selection.location { first = index }
      if lines[index].start <= endpoint { last = index }
    }
    return (first, last)
  }

  mutating func matches(
    _ marker: [UInt16], in units: [UInt16], at offset: Int, end: Int,
    isCancelled: () -> Bool
  ) throws -> Bool {
    guard offset >= 0, offset <= end, end <= units.count,
      marker.count <= end - offset
    else { return false }
    for index in marker.indices {
      try step(isCancelled)
      if units[offset + index] != marker[index] { return false }
    }
    return true
  }

  mutating func contains(
    _ marker: [UInt16], in units: [UInt16], range: Range<Int>, isCancelled: () -> Bool
  ) throws -> Bool {
    for offset in range {
      try step(isCancelled)
      if try matches(marker, in: units, at: offset, end: range.upperBound, isCancelled: isCancelled)
      {
        return true
      }
    }
    return false
  }

  mutating func copy(
    _ range: Range<Int>, from units: [UInt16], into result: inout [UInt16],
    isCancelled: () -> Bool
  ) throws {
    for offset in range {
      try step(isCancelled)
      guard result.count < Self.maximumUnits else { throw Failure.textLimit }
      result.append(units[offset])
    }
  }

  mutating func applying(
    _ edits: [Edit], to units: [UInt16], isCancelled: () -> Bool
  ) throws -> String {
    var length = units.count
    var lastEnd = 0
    for edit in edits {
      try step(isCancelled)
      guard edit.start >= lastEnd, edit.start <= units.count,
        edit.removed >= 0, edit.removed <= units.count - edit.start
      else { throw Failure.invalidSelection }
      length -= edit.removed
      guard edit.inserted.count <= Self.maximumUnits - length else { throw Failure.textLimit }
      length += edit.inserted.count
      lastEnd = edit.start + edit.removed
    }
    var output: [UInt16] = []
    output.reserveCapacity(length)
    var cursor = 0
    for edit in edits {
      try step(isCancelled)
      try copy(cursor..<edit.start, from: units, into: &output, isCancelled: isCancelled)
      try copy(
        0..<edit.inserted.count, from: edit.inserted, into: &output, isCancelled: isCancelled)
      cursor = edit.start + edit.removed
    }
    try copy(cursor..<units.count, from: units, into: &output, isCancelled: isCancelled)
    return try render(output, isCancelled: isCancelled)
  }

  mutating func render(_ units: [UInt16], isCancelled: () -> Bool) throws -> String {
    var text = ""
    var cursor = 0
    while cursor < units.count {
      try check(isCancelled)
      var end = min(cursor + 4096, units.count)
      if end < units.count, (0xDC00...0xDFFF).contains(units[end]) { end -= 1 }
      var chunk: [UInt16] = []
      chunk.reserveCapacity(end - cursor)
      try copy(cursor..<end, from: units, into: &chunk, isCancelled: isCancelled)
      try check(isCancelled)
      // Decode only scalar-aligned fragments <=4096 units; no whole output
      // Array/slice decoding. Foundation allocation latency is not measured.
      text += String(decoding: chunk, as: UTF16.self)
      cursor = end
    }
    try check(isCancelled)
    return text
  }

  mutating func selection(
    _ original: NSRange, lines: [Line], first: Int, last: Int, edits: [Edit],
    isCancelled: () -> Bool
  ) throws -> NSRange {
    var delta = 0
    var caret = original.location
    for edit in edits {
      try step(isCancelled)
      if original.length == 0 {
        if original.location >= edit.start + edit.removed {
          caret += edit.inserted.count - edit.removed
        } else if original.location >= edit.start {
          caret = edit.start + delta + edit.inserted.count
        }
      }
      delta += edit.inserted.count - edit.removed
    }
    if original.length == 0 { return NSRange(location: caret, length: 0) }
    return NSRange(
      location: lines[first].start,
      length: lines[last].end - lines[first].start + delta)
  }
}
