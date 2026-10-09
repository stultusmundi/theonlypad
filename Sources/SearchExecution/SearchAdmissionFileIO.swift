struct SearchAdmissionFileDescriptor: Sendable, Equatable {
  let rawValue: Int32

  init(rawValue: Int32) throws {
    guard rawValue >= 0 else { throw SearchAdmissionFileFailure.invalidBounds }
    self.rawValue = rawValue
  }
}

struct SearchAdmissionFileSample: Sendable, Equatable {
  let identity: SearchAdmissionFileIdentity
  let isRegular: Bool
}

enum SearchAdmissionFileOpenResult {
  case opened(SearchAdmissionFileDescriptor)
  case failed(errno: Int32)
}

enum SearchAdmissionFileSampleResult {
  case sampled(SearchAdmissionFileSample)
  case failed(errno: Int32)
  case invalidMetadata
}

enum SearchAdmissionFileReadResult {
  case bytes(Int)
  case failed(errno: Int32)
}

enum SearchAdmissionFileCloseResult {
  case closed
  case uncertain(errno: Int32)
}

// Caller-confined synchronous calls. Implementations must not retain any view.
protocol SearchAdmissionFileIO {
  func openReadOnlyNoFollowNonBlockingCloseOnExec(
    path: UnsafeBufferPointer<CChar>
  ) -> SearchAdmissionFileOpenResult
  func sampleDescriptor(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileSampleResult
  func samplePath(_ path: UnsafeBufferPointer<CChar>) -> SearchAdmissionFileSampleResult
  func read(
    _ fd: SearchAdmissionFileDescriptor, into: UnsafeMutableBufferPointer<UInt8>, offset: Int64
  ) -> SearchAdmissionFileReadResult
  func closeOnce(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileCloseResult
}

enum SearchAdmissionFileFailure: Error, Sendable, Equatable {
  case invalidBounds, sourceChanged, unreadable, invalidUTF8, binaryInput
  case inputLimit, cancelled, internalFailure
}

// A retained obligation only; this record never grants permission to close again.
struct SearchAdmissionFileOwnershipIssue: Sendable, Equatable {
  let descriptor: SearchAdmissionFileDescriptor
  let expectedIdentity: SearchAdmissionFileIdentity
  let closeErrno: Int32
  let primaryFailure: SearchAdmissionFileFailure?
}

enum SearchAdmissionFileReturn: Sendable, Equatable {
  case prepared(SearchPreparedUTF8Result)
  case failed(SearchAdmissionFileFailure)
  case ownershipUncertain(SearchAdmissionFileOwnershipIssue)
}
