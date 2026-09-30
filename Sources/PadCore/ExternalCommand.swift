import Darwin
import Foundation

public struct CommandContext: Sendable {
  public var path: String?
  public var selection: String
  public var text: String?
  public init(path: String?, selection: String, text: String? = nil) {
    self.path = path
    self.selection = selection
    self.text = text
  }
}

public enum CommandTermination: String, Sendable { case exited, cancelled, timedOut, outputLimit }

public struct ExternalCommandResult: Sendable {
  public let stdout: Data
  public let stderr: Data
  public let termination: CommandTermination
  public let exitCode: Int32?
  public let signal: Int32?
  public let outputTruncated: Bool
}

public enum ExternalCommandError: Error, LocalizedError {
  case invalidExecutable, invalidLimits, argumentLimit
  case unavailableVariable(String)
  case unknownVariable(String)
  case reusedRunner
  case spawnSafetyUnavailable
  public var errorDescription: String? {
    switch self {
    case .invalidExecutable: return "Choose an absolute executable path without NUL characters."
    case .invalidLimits:
      return
        "The timeout must be between 0.05 and 30 seconds, and output capture between 1 byte and 4 MB."
    case .argumentLimit:
      return "Command arguments exceed 128 arguments or 1 MB, or contain a NUL character."
    case .unavailableVariable(let name): return "The document context does not provide ${\(name)}."
    case .unknownVariable(let name):
      return "Unknown command variable ${\(name)}. Use path, selection, or text."
    case .reusedRunner: return "Create a new runner for each command."
    case .spawnSafetyUnavailable:
      return
        "Restart \(AppIdentity.name) before running commands because process cleanup could not be confirmed."
    }
  }
}

/// Runs only when called explicitly. Blocking I/O belongs on a background task.
/// Cancellation controls the launched process, not independently spawned descendants.
public final class ExternalCommandRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var used = false
  private let spawnGate: ProcessSpawnGate
  private let makeProcess: @Sendable () -> Process
  public convenience init() {
    self.init(spawnGate: .process, makeProcess: { Process() })
  }
  init(spawnGate: ProcessSpawnGate, makeProcess: @escaping @Sendable () -> Process) {
    self.spawnGate = spawnGate
    self.makeProcess = makeProcess
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  public func run(
    executable: String, arguments: [String], context: CommandContext,
    timeout: TimeInterval = 30, maximumOutputBytes: Int = 1_048_576
  ) throws -> ExternalCommandResult {
    lock.lock()
    guard !used else {
      lock.unlock()
      throw ExternalCommandError.reusedRunner
    }
    used = true
    lock.unlock()
    guard executable.hasPrefix("/"), !executable.utf8.contains(0) else {
      throw ExternalCommandError.invalidExecutable
    }
    guard timeout.isFinite, (0.05...30).contains(timeout),
      (1...4_194_304).contains(maximumOutputBytes)
    else {
      throw ExternalCommandError.invalidLimits
    }
    let expanded = try Self.expand(arguments, context: context)
    if isCancelled {
      return ExternalCommandResult(
        stdout: Data(), stderr: Data(), termination: .cancelled, exitCode: nil, signal: nil,
        outputTruncated: false)
    }
    let process = makeProcess()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = expanded
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let handles = [output.fileHandleForReading, errors.fileHandleForReading]
    defer {
      for handle in handles { try? handle.close() }
      try? output.fileHandleForWriting.close()
      try? errors.fileHandleForWriting.close()
    }
    for handle in handles {
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    do {
      // No state-lock holder acquires spawnGate: this bounded gate -> state query
      // cannot invert cancellation. A cancelled admission never installs waits
      // or termination cleanup for an unstarted Process.
      guard try spawnGate.run(process, unlessCancelled: { self.isCancelled }) else {
        return ExternalCommandResult(
          stdout: Data(), stderr: Data(), termination: .cancelled, exitCode: nil, signal: nil,
          outputTruncated: false)
      }
    } catch ProcessSpawnGateError.quarantined {
      throw ExternalCommandError.spawnSafetyUnavailable
    }
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
    defer {
      if process.isRunning {
        process.terminate()
        let until = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < until { usleep(10_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
      process.waitUntilExit()
    }
    var descriptors = handles.map {
      pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
    }
    var captured = [Data(), Data()]
    var buffer = [UInt8](repeating: 0, count: 8192)
    var reason: CommandTermination?
    var stoppingSince: TimeInterval?
    var exitedSince: TimeInterval?
    var forced = false
    var truncated = false
    let started = ProcessInfo.processInfo.systemUptime
    while true {
      let now = ProcessInfo.processInfo.systemUptime
      if reason == nil {
        if isCancelled {
          reason = .cancelled
        } else if now - started >= timeout {
          reason = .timedOut
        }
      }
      if reason != nil, process.isRunning {
        if stoppingSince == nil {
          stoppingSince = now
          process.terminate()
        } else if now - stoppingSince! >= 0.25 && !forced {
          _ = kill(process.processIdentifier, SIGKILL)
          forced = true
        }
      }
      if !process.isRunning {
        if exitedSince == nil { exitedSince = now }
        if descriptors.allSatisfy({ $0.fd < 0 }) { break }
        // A descendant can inherit a pipe after the launched process exits.
        // Bound capture rather than waiting indefinitely for that descendant.
        if now - exitedSince! >= 0.25 {
          truncated = true
          break
        }
      }
      let ready = poll(&descriptors, nfds_t(descriptors.count), 25)
      if ready < 0 {
        if errno == EINTR { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      for stream in descriptors.indices
      where descriptors[stream].fd >= 0 && descriptors[stream].revents != 0 {
        // Fairly drain both descriptors even if one produces continuously.
        for _ in 0..<4 {
          let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptors[stream].fd, $0.baseAddress, $0.count)
          }
          if count == 0 {
            descriptors[stream].fd = -1
            break
          }
          if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
          let remaining = maximumOutputBytes - captured[0].count - captured[1].count
          captured[stream].append(contentsOf: buffer.prefix(min(count, remaining)))
          if count > remaining {
            truncated = true
            if reason == nil { reason = .outputLimit }
          }
        }
      }
    }
    process.waitUntilExit()
    return ExternalCommandResult(
      stdout: captured[0], stderr: captured[1], termination: reason ?? .exited,
      exitCode: process.terminationReason == .exit ? process.terminationStatus : nil,
      signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil,
      outputTruncated: truncated)
  }

  private static func expand(_ arguments: [String], context: CommandContext) throws -> [String] {
    let maximum = 1_048_576
    guard arguments.count <= 128 else { throw ExternalCommandError.argumentLimit }
    var total = 0
    return try arguments.map { argument in
      guard argument.utf8.count <= maximum else { throw ExternalCommandError.argumentLimit }
      var expanded = ""
      var offset = argument.startIndex
      func append(_ text: Substring) throws {
        let count = text.utf8.count
        guard count <= maximum - total, !text.utf8.contains(0) else {
          throw ExternalCommandError.argumentLimit
        }
        expanded.append(contentsOf: text)
        total += count
      }
      while let start = argument.range(of: "${", range: offset..<argument.endIndex) {
        try append(argument[offset..<start.lowerBound])
        guard let end = argument[start.upperBound...].firstIndex(of: "}") else {
          throw ExternalCommandError.unknownVariable(String(argument[start.upperBound...]))
        }
        let name = String(argument[start.upperBound..<end])
        let replacement: String?
        switch name {
        case "path": replacement = context.path
        case "selection": replacement = context.selection
        case "text": replacement = context.text
        default: throw ExternalCommandError.unknownVariable(name)
        }
        guard let replacement else { throw ExternalCommandError.unavailableVariable(name) }
        try append(replacement[...])
        offset = argument.index(after: end)
      }
      try append(argument[offset...])
      return expanded
    }
  }
}
