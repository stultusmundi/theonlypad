import Darwin
import Foundation

package struct SearchWorkerIOFailure: Error, Equatable {
  package let code: Int32
}

package struct SearchWorkerIOSystem {
  package let setNoSigPipe: (Int32) -> Result<Void, SearchWorkerIOFailure>
  package let read: (Int32, UnsafeMutableRawBufferPointer) -> Result<Int, SearchWorkerIOFailure>
  package let write: (Int32, UnsafeRawBufferPointer) -> Result<Int, SearchWorkerIOFailure>

  package static let darwin = SearchWorkerIOSystem(
    setNoSigPipe: { fd in
      let installed = fcntl(fd, F_SETNOSIGPIPE, 1)
      let installError = errno
      guard installed != -1 else {
        return .failure(SearchWorkerIOFailure(code: installError))
      }
      let enabled = fcntl(fd, F_GETNOSIGPIPE)
      let verificationError = errno
      guard enabled != -1 else {
        return .failure(SearchWorkerIOFailure(code: verificationError))
      }
      guard enabled == 1 else { return .failure(SearchWorkerIOFailure(code: EIO)) }
      return .success(())
    },
    read: { fd, buffer in
      let count = Darwin.read(fd, buffer.baseAddress, buffer.count)
      let code = errno
      return count < 0 ? .failure(SearchWorkerIOFailure(code: code)) : .success(count)
    },
    write: { fd, buffer in
      let count = Darwin.write(fd, buffer.baseAddress, buffer.count)
      let code = errno
      return count < 0 ? .failure(SearchWorkerIOFailure(code: code)) : .success(count)
    })
}

/// Synchronous single-lane adapter borrowing distinct, blocking descriptors.
/// The caller retains descriptor lifetime ownership; this object never closes
/// them or changes process-global SIGPIPE policy.
package final class SearchWorkerFDChannel: SearchWorkerBlockingChannel {
  private let inputFD: Int32
  private let outputFD: Int32
  private let system: SearchWorkerIOSystem

  package init(inputFD: Int32, outputFD: Int32, system: SearchWorkerIOSystem) throws {
    guard inputFD >= 0, outputFD >= 0, inputFD != outputFD else {
      throw SearchWorkerIOFailure(code: EINVAL)
    }
    try system.setNoSigPipe(outputFD).get()
    self.inputFD = inputFD
    self.outputFD = outputFD
    self.system = system
  }

  package func read(maxBytes: Int) throws -> Data {
    guard (1...65_568).contains(maxBytes) else { throw SearchWorkerIOFailure(code: EINVAL) }
    var bytes = Data(count: maxBytes)
    while true {
      let result = bytes.withUnsafeMutableBytes { system.read(inputFD, $0) }
      switch result {
      case .success(let count):
        guard (0...maxBytes).contains(count) else { throw SearchWorkerIOFailure(code: EIO) }
        bytes.count = count
        return bytes
      case .failure(let error):
        if error.code == EINTR { continue }
        throw error
      }
    }
  }

  package func write(_ bytes: Data) throws {
    guard (1...65_536).contains(bytes.count) else { throw SearchWorkerIOFailure(code: EINVAL) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let remaining = UnsafeRawBufferPointer(rebasing: buffer[offset...])
        switch system.write(outputFD, remaining) {
        case .success(let count):
          guard count > 0, count <= remaining.count else { throw SearchWorkerIOFailure(code: EIO) }
          offset += count
        case .failure(let error):
          if error.code == EINTR { continue }
          throw error
        }
      }
    }
  }
}
