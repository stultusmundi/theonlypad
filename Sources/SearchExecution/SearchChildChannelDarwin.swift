import Darwin
import Dispatch
import Foundation

/// Production one-syscall bridge. ChannelCore retains all I/O policy and ownership.
struct DarwinChannelDescriptorOperations: ChannelDescriptorOperations {
  func read(fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> ChannelIOResult {
    let result = Darwin.read(fd, buffer.baseAddress, buffer.count)
    if result < 0 {
      let captured = errno
      return .failed(captured)
    }
    return .count(result)
  }

  func write(fd: Int32, from buffer: UnsafeRawBufferPointer) -> ChannelIOResult {
    let result = Darwin.write(fd, buffer.baseAddress, buffer.count)
    if result < 0 {
      let captured = errno
      return .failed(captured)
    }
    return .count(result)
  }

  func close(fd: Int32) -> Int32 {
    let result = Darwin.close(fd)
    return result == 0 ? 0 : errno
  }
}

/// Creates actual Dispatch readiness sources; source cancellation acknowledges that
/// Dispatch no longer holds the descriptor before ChannelCore performs the raw close.
final class DispatchChannelSourceFactory: ChannelSourceFactory, @unchecked Sendable {
  func make(
    kind: ChannelSourceKind, fd: Int32, queue: DispatchQueue,
    event: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void
  ) -> any ChannelReadinessSource {
    switch kind {
    case .responseRead:
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      return DispatchChannelReadinessSource(source: source, event: event, cancelled: cancelled)
    case .requestWrite:
      let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
      return DispatchChannelReadinessSource(source: source, event: event, cancelled: cancelled)
    }
  }
}

private final class DispatchChannelReadinessSource: ChannelReadinessSource, @unchecked Sendable {
  private let activateBody: @Sendable () -> Void
  private let suspendBody: @Sendable () -> Void
  private let resumeBody: @Sendable () -> Void
  private let cancelBody: @Sendable () -> Void

  init<Source: DispatchSourceProtocol>(
    source: Source, event: @escaping @Sendable () -> Void,
    cancelled: @escaping @Sendable () -> Void
  ) {
    source.setEventHandler(handler: event)
    source.setCancelHandler(handler: cancelled)
    activateBody = { source.activate() }
    suspendBody = { source.suspend() }
    resumeBody = { source.resume() }
    cancelBody = { source.cancel() }
  }

  func activate() { activateBody() }
  func suspend() { suspendBody() }
  func resume() { resumeBody() }
  func cancel() { cancelBody() }
}
