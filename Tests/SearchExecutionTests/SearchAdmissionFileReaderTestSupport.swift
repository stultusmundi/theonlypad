@testable import SearchExecution

// Caller-confined synthetic tokens only. No pointer or OS resource escapes a call.
let readerFixturePath = "/synthetic/input.txt"
let readerFixturePathBytes: [UInt8] = [
  47, 115, 121, 110, 116, 104, 101, 116, 105, 99, 47,
  105, 110, 112, 117, 116, 46, 116, 120, 116, 0,
]

func readerIdentity(
  size: Int64, device: UInt64 = 7, inode: UInt64 = 11,
  modifiedSeconds: Int64 = 13, modifiedNanoseconds: Int64 = 17,
  changedSeconds: Int64 = 19, changedNanoseconds: Int64 = 23
) throws -> SearchAdmissionFileIdentity {
  try SearchAdmissionFileIdentity(
    device: device, inode: inode, size: size,
    modifiedSeconds: modifiedSeconds, modifiedNanoseconds: modifiedNanoseconds,
    changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds)
}

enum ReaderFixtureCall: Equatable {
  case open([UInt8])
  case descriptor(Int32)
  case path([UInt8])
  case read(fd: Int32, offset: Int64, count: Int)
  case close(Int32)
}

enum ReaderFixtureReply {
  case bytes([UInt8])
  case failure(Int32)
  case countOnly(Int)
}

enum ReaderFixtureStep {
  case open(SearchAdmissionFileOpenResult)
  case descriptor(SearchAdmissionFileSampleResult)
  case path(SearchAdmissionFileSampleResult)
  case read(offset: Int64, count: Int, reply: ReaderFixtureReply, cancelAfter: Bool = false)
  case close(SearchAdmissionFileCloseResult)

  var call: ReaderFixtureCall {
    switch self {
    case .open: return .open(readerFixturePathBytes)
    case .descriptor: return .descriptor(40)
    case .path: return .path(readerFixturePathBytes)
    case .read(let offset, let count, _, _): return .read(fd: 40, offset: offset, count: count)
    case .close: return .close(40)
    }
  }
}

func readerSamplePair(_ identity: SearchAdmissionFileIdentity) -> [ReaderFixtureStep] {
  let sample = SearchAdmissionFileSampleResult.sampled(.init(identity: identity, isRegular: true))
  return [.descriptor(sample), .path(sample)]
}

// Exactly three finite pairs; callers supply literal offsets/counts, not a reader algorithm.
func readerSuccessSteps(
  identity: SearchAdmissionFileIdentity, reads: [ReaderFixtureStep],
  close: SearchAdmissionFileCloseResult = .closed
) throws -> [ReaderFixtureStep] {
  let fd = try SearchAdmissionFileDescriptor(rawValue: 40)
  return [.open(.opened(fd))] + readerSamplePair(identity) + reads
    + readerSamplePair(identity) + readerSamplePair(identity) + [.close(close)]
}

final class FileReaderScript: SearchAdmissionFileIO {
  private var steps: [ReaderFixtureStep]
  private var nextIndex = 0
  private var disposed = false
  private(set) var calls: [ReaderFixtureCall] = []
  private(set) var violations: [String] = []
  private(set) var liveFakeTokens: Set<Int32> = []
  private(set) var quarantinedFakeTokens: Set<Int32> = []
  private(set) var closeInvocationCount = 0
  var cancelled = false

  init(_ steps: [ReaderFixtureStep]) { self.steps = steps }

  var remainingSteps: Int { steps.count - nextIndex }
  var expectedCalls: [ReaderFixtureCall] { steps.map(\.call) }
  var readCalls: [ReaderFixtureCall] {
    calls.filter {
      if case .read = $0 { return true }
      return false
    }
  }

  private func take(_ call: ReaderFixtureCall) -> ReaderFixtureStep? {
    calls.append(call)
    guard !disposed, nextIndex < steps.count else {
      violations.append("Unexpected call after finite script end or cleanup")
      return nil
    }
    let step = steps[nextIndex]
    nextIndex += 1
    guard step.call == call else {
      violations.append("Actual call differs from the next literal script step")
      return nil
    }
    return step
  }

  private func pathBytes(_ path: UnsafeBufferPointer<CChar>) -> [UInt8]? {
    guard path.count > 0, path.count <= 4097 else {
      violations.append("Path view exceeds the bounded fixture contract")
      return nil
    }
    return path.map { UInt8(bitPattern: $0) }
  }

  func openReadOnlyNoFollowNonBlockingCloseOnExec(
    path: UnsafeBufferPointer<CChar>
  ) -> SearchAdmissionFileOpenResult {
    let bytes = pathBytes(path) ?? []
    guard case .open(let result)? = take(.open(bytes)) else { return .failed(errno: 5) }
    if case .opened(let fd) = result {
      guard liveFakeTokens.insert(fd.rawValue).inserted else {
        violations.append("Duplicate synthetic open ownership")
        return .failed(errno: 5)
      }
    }
    return result
  }

  func sampleDescriptor(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileSampleResult {
    let step = take(.descriptor(fd.rawValue))
    guard liveFakeTokens.contains(fd.rawValue) else {
      violations.append("Descriptor sampled without live synthetic ownership")
      return .failed(errno: 5)
    }
    guard case .descriptor(let result)? = step else { return .failed(errno: 5) }
    return result
  }

  func samplePath(_ path: UnsafeBufferPointer<CChar>) -> SearchAdmissionFileSampleResult {
    let bytes = pathBytes(path) ?? []
    let step = take(.path(bytes))
    guard liveFakeTokens.contains(40) else {
      violations.append("Path sampled outside the live descriptor scope")
      return .failed(errno: 5)
    }
    guard case .path(let result)? = step else { return .failed(errno: 5) }
    return result
  }

  func read(
    _ fd: SearchAdmissionFileDescriptor, into: UnsafeMutableBufferPointer<UInt8>, offset: Int64
  ) -> SearchAdmissionFileReadResult {
    let step = take(.read(fd: fd.rawValue, offset: offset, count: into.count))
    guard liveFakeTokens.contains(fd.rawValue), into.count > 0, into.count <= 65_536 else {
      violations.append("Read without live ownership or with an invalid bounded view")
      return .failed(errno: 5)
    }
    // Deterministic poison for a requested-count-versus-actual-count control.
    // These elements are already initialized by the reader; never retain the view.
    for index in into.indices { into[index] = 0 }
    guard case .read(_, _, let reply, let cancelAfter)? = step else { return .failed(errno: 5) }
    if cancelAfter { cancelled = true }
    switch reply {
    case .bytes(let bytes):
      guard bytes.count <= into.count else {
        violations.append("Fixture byte reply would exceed the borrowed view")
        return .failed(errno: 5)
      }
      for (index, byte) in bytes.enumerated() { into[index] = byte }
      return .bytes(bytes.count)
    case .failure(let errno): return .failed(errno: errno)
    case .countOnly(let count): return .bytes(count)
    }
  }

  func closeOnce(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileCloseResult {
    closeInvocationCount += 1
    let step = take(.close(fd.rawValue))
    guard liveFakeTokens.remove(fd.rawValue) != nil else {
      violations.append("Close without exclusive live synthetic ownership")
      return .uncertain(errno: 5)
    }
    guard case .close(let result)? = step else {
      quarantinedFakeTokens.insert(fd.rawValue)
      return .uncertain(errno: 5)
    }
    if case .uncertain = result { quarantinedFakeTokens.insert(fd.rawValue) }
    return result
  }

  // Independent of any candidate receipt. Clears synthetic data only; never calls IO.
  func disposeSyntheticState() {
    steps.removeAll()
    nextIndex = 0
    calls.removeAll()
    violations.removeAll()
    liveFakeTokens.removeAll()
    quarantinedFakeTokens.removeAll()
    cancelled = false
    disposed = true
  }
}
