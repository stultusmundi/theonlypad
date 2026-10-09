struct SearchAdmissionFileIdentity: Sendable, Equatable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  let changedSeconds: Int64
  let changedNanoseconds: Int64

  init(
    device: UInt64, inode: UInt64, size: Int64,
    modifiedSeconds: Int64, modifiedNanoseconds: Int64,
    changedSeconds: Int64, changedNanoseconds: Int64
  ) throws {
    guard size >= 0,
      (0...999_999_999).contains(modifiedNanoseconds),
      (0...999_999_999).contains(changedNanoseconds)
    else { throw SearchAdmissionFileFailure.invalidBounds }
    self.device = device
    self.inode = inode
    self.size = size
    self.modifiedSeconds = modifiedSeconds
    self.modifiedNanoseconds = modifiedNanoseconds
    self.changedSeconds = changedSeconds
    self.changedNanoseconds = changedNanoseconds
  }
}

struct SearchAdmissionFileInput: Sendable {
  let path: String
  let identity: SearchAdmissionFileIdentity
  let windowBytes: Int

  init(
    path: String, identity: SearchAdmissionFileIdentity, windowBytes: Int = 65_536
  ) throws {
    guard identity.size <= 10_000_000,
      path.utf8.first == 47, path.utf8.count <= 4096, !path.utf8.contains(0),
      windowBytes >= 1, windowBytes <= 65_536
    else { throw SearchAdmissionFileFailure.invalidBounds }
    self.path = path
    self.identity = identity
    self.windowBytes = windowBytes
  }
}

struct SearchAdmissionFileReadBounds: Sendable, Equatable {
  let inputBytes: Int
  let inputUTF16: Int
  let windowBytes: Int
  let outputUTF8: Int

  init(input: SearchAdmissionFileInput) throws {
    guard let bytes = Int(exactly: input.identity.size), bytes >= 0, bytes <= 10_000_000,
      input.windowBytes >= 1, input.windowBytes <= 65_536
    else { throw SearchAdmissionFileFailure.invalidBounds }
    let output = bytes.multipliedReportingOverflow(by: 3)
    guard !output.overflow else { throw SearchAdmissionFileFailure.invalidBounds }
    inputBytes = bytes
    inputUTF16 = bytes
    windowBytes = input.windowBytes
    outputUTF8 = output.partialValue
  }
}
