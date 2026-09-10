import Darwin
import Foundation

// Foundation-only service benchmark. Compile with a frozen committed LargeFileReader.swift.
@main
struct StreamingCoreBenchmark {
  static let marker = Array("THEONLYPAD-MATCH!".utf8)
  static let row = Array("abcdefghijklmnop0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n".utf8)
  static let chunk = 1_048_576
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let size = Int64(args[2]), size >= 1_000_000,
      ["rows", "longline"].contains(args[3])
    else { fatalError("Invalid benchmark arguments") }
    let shape = args[3]
    let positions = [min(Int64(chunk - 8), size / 2), size - Int64(marker.count)]
    let started = ProcessInfo.processInfo.systemUptime
    let reader = try LargeFileReader(url: URL(fileURLWithPath: args[1]))
    try emit(["stage": "open", "seconds": elapsed(started), "bytes": size])
    guard reader.identity.size == size else { throw Failure.oracle }
    for offset in [Int64(0), size / 2, size - 65_536] {
      let start = ProcessInfo.processInfo.systemUptime
      let data = try reader.readWindow(offset: offset, length: 65_536)
      let decoded = String(decoding: data, as: UTF8.self)
      let duration = elapsed(start)
      let expected = (0..<65_536).map { index -> UInt8 in
        let absolute = offset + Int64(index)
        for position in positions
        where absolute >= position && absolute < position + Int64(marker.count) {
          return marker[Int(absolute - position)]
        }
        return shape == "rows" ? row[Int(absolute % Int64(row.count))] : 97
      }
      guard data.elementsEqual(expected), decoded.utf8.elementsEqual(expected),
        decoded.utf16.count == 65_536
      else { throw Failure.oracle }
      try emit([
        "stage": "window", "offset": offset, "sourceBytes": data.count,
        "decodedUTF16": decoded.utf16.count, "seconds": duration,
      ])
    }
    let scan = ProcessInfo.processInfo.systemUptime
    let matches = try reader.searchLiteral(Data(marker), limit: 10)
    let scanTime = elapsed(scan)
    guard matches == positions else { throw Failure.oracle }
    try emit(["stage": "search", "seconds": scanTime, "matches": matches])
    var polls = 0
    var requestedAt: Double?
    let cancelStart = ProcessInfo.processInfo.systemUptime
    do {
      _ = try reader.searchLiteral(
        Data(marker),
        cancellation: {
          polls += 1
          if polls == 5 {
            requestedAt = ProcessInfo.processInfo.systemUptime
            return true
          }
          return false
        })
      throw Failure.cancellation
    } catch LargeFileError.cancelled {}
    guard let requestedAt, polls == 5 else { throw Failure.cancellation }
    let returned = ProcessInfo.processInfo.systemUptime
    try emit([
      "stage": "cancel", "polls": polls, "totalSeconds": returned - cancelStart,
      "requestToThrowSeconds": returned - requestedAt,
    ])
    do {
      _ = try reader.searchLiteral(Data([97]), limit: 1)
      throw Failure.limit
    } catch LargeFileError.resultLimit {}
    try emit(["stage": "complete", "resultLimitRefused": true])
  }
  static func elapsed(_ start: Double) -> Double { ProcessInfo.processInfo.systemUptime - start }
  static func emit(_ value: [String: Any]) throws {
    var value = value
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.usage }
    value["peakRSSBytes"] = Int64(usage.ru_maxrss)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
  }
  enum Failure: Error { case oracle, cancellation, limit, usage }
}
