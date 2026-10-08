// Synthetic bootstrap/transport/lifetime fixture, not a search worker.
// Only fixed named modes exist. The owning test watchdog bounds blocking I/O.
import Darwin
import Foundation
import SearchExecution

func refuse() -> Never { Darwin._exit(70) }
let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 5,
  arguments[1] == "--generation", let generation = UUID(uuidString: arguments[2]),
  generation.uuidString == arguments[2],
  generation.uuidString != "00000000-0000-0000-0000-000000000000"
else { refuse() }
let mode: String
if arguments.count == 5 {
  guard arguments[3] == "--mode",
    ["echo", "exit17", "parent-lifetime-busy-main"].contains(arguments[4])
  else { refuse() }
  mode = arguments[4]
} else {
  mode = "echo"
}
if mode == "exit17" { Darwin._exit(17) }

// Fixed bounded metadata, observed in the child after exec. No scans, user files,
// inherited environment values, text payload, or dynamic fault commands are logged.
var descriptorFlags: [Int32] = []
var statusFlags: [Int32] = []
var kinds: [UInt16] = []
for fd: Int32 in 0...3 {
  let descriptor = fcntl(fd, F_GETFD)
  let status = fcntl(fd, F_GETFL)
  var info = stat()
  guard descriptor >= 0, status >= 0, fstat(fd, &info) == 0 else { refuse() }
  descriptorFlags.append(descriptor)
  statusFlags.append(status)
  kinds.append(info.st_mode & S_IFMT)
}
var blocked = sigset_t()
guard pthread_sigmask(SIG_SETMASK, nil, &blocked) == 0 else { refuse() }
var blockedSignals: [Int32] = []
for signal: Int32 in 1..<NSIG where sigismember(&blocked, signal) == 1 {
  blockedSignals.append(signal)
}
var pipeAction = sigaction()
guard sigaction(SIGPIPE, nil, &pipeAction) == 0 else { refuse() }
let defaultPipe =
  unsafeBitCast(pipeAction.__sigaction_u.__sa_handler, to: UInt.self)
  == unsafeBitCast(SIG_DFL, to: UInt.self)
let metadata: [String: Any] = [
  "generation": generation.uuidString, "descriptorFlags": descriptorFlags,
  "statusFlags": statusFlags, "kinds": kinds, "blockedSignals": blockedSignals,
  "sigpipeDefault": defaultPipe,
]
guard let encoded = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
  encoded.count < 2_048
else { refuse() }

func writeAll(_ bytes: Data) {
  var offset = 0
  for _ in 0..<256 {
    if offset == bytes.count { return }
    let count = bytes.withUnsafeBytes { raw in
      Darwin.write(1, raw.baseAddress!.advanced(by: offset), raw.count - offset)
    }
    if count > 0 {
      offset += count
    } else if count < 0 && errno == EINTR {
      continue
    } else {
      refuse()
    }
  }
  refuse()
}
if mode == "parent-lifetime-busy-main" {
  do {
    try SearchParentLifetime.start(controlFD: 3)
  } catch {
    refuse()
  }
  // Occupy main without reading request EOF or servicing a run loop. The
  // dedicated lifetime reader must terminate the whole process independently.
  var announced = false
  while true {
    _ = Darwin.getpid()
    if !announced {
      var readiness = metadata
      readiness["mainLoopEntered"] = true
      guard
        let bytes = try? JSONSerialization.data(withJSONObject: readiness, options: [.sortedKeys]),
        bytes.count < 2_048
      else { refuse() }
      writeAll(bytes + Data([10]))
      announced = true
    }
  }
}
writeAll(encoded + Data([10]))
var payload = Data(count: 64)
var offset = 0
for _ in 0..<256 {
  if offset == payload.count { break }
  let count = payload.withUnsafeMutableBytes { raw in
    Darwin.read(0, raw.baseAddress!.advanced(by: offset), raw.count - offset)
  }
  if count > 0 {
    offset += count
  } else if count < 0 && errno == EINTR {
    continue
  } else {
    refuse()
  }
}
guard offset == 64 else { refuse() }
writeAll(payload)
// A fixed final EOF, never another command: parent can consume the echo before
// the child exits. This does not monitor parent lifetime on descriptor3.
var finalByte: UInt8 = 0
var ended = false
for _ in 0..<256 {
  let count = Darwin.read(0, &finalByte, 1)
  if count == 0 {
    ended = true
    break
  }
  if count < 0 && errno == EINTR { continue }
  refuse()
}
guard ended else { refuse() }
Darwin._exit(0)
