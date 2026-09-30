// Fixed unrelated Foundation peer; only the accepted watchdog bounds its life.
import Darwin

guard CommandLine.arguments.count == 1 else { Darwin._exit(64) }
let marker: [UInt8] = [82, 69, 65, 68, 89, 10]
var offset = 0
for _ in 0..<256 {
  if offset == marker.count { break }
  let count = marker.withUnsafeBytes {
    Darwin.write(1, $0.baseAddress!.advanced(by: offset), $0.count - offset)
  }
  if count > 0 {
    offset += count
  } else if count < 0 && errno == EINTR {
    continue
  } else {
    Darwin._exit(70)
  }
}
guard offset == marker.count else { Darwin._exit(70) }
while true {
  var byte: UInt8 = 0
  let count = Darwin.read(0, &byte, 1)
  if count == 0 { Darwin._exit(0) }
  if count == -1 && errno == EINTR { continue }
  Darwin._exit(70)
}
