import Darwin

// Synchronous borrowed views and once-close eligibility belong to the caller.
struct SearchAdmissionFileDarwinIO: SearchAdmissionFileIO {
  func openReadOnlyNoFollowNonBlockingCloseOnExec(
    path: UnsafeBufferPointer<CChar>
  ) -> SearchAdmissionFileOpenResult {
    let result = Darwin.open(path.baseAddress!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard result >= 0 else {
      let saved = errno
      return .failed(errno: saved)
    }
    // This exact initializer rejects only negative Int32 values, excluded above.
    return .opened(try! SearchAdmissionFileDescriptor(rawValue: result))
  }

  func sampleDescriptor(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileSampleResult {
    var raw = stat()
    let result = Darwin.fstat(fd.rawValue, &raw)
    guard result == 0 else {
      let saved = errno
      return .failed(errno: saved)
    }
    return Self.normalizedSample(raw)
  }

  func samplePath(_ path: UnsafeBufferPointer<CChar>) -> SearchAdmissionFileSampleResult {
    var raw = stat()
    let result = Darwin.lstat(path.baseAddress!, &raw)
    guard result == 0 else {
      let saved = errno
      return .failed(errno: saved)
    }
    return Self.normalizedSample(raw)
  }

  func read(
    _ fd: SearchAdmissionFileDescriptor, into: UnsafeMutableBufferPointer<UInt8>, offset: Int64
  ) -> SearchAdmissionFileReadResult {
    // Legal reader offsets are Int64, and the selected Darwin off_t is signed64.
    guard let nativeOffset = off_t(exactly: offset) else {
      preconditionFailure("Darwin off_t cannot represent a legal reader offset")
    }
    let result = Darwin.pread(fd.rawValue, into.baseAddress!, into.count, nativeOffset)
    guard result >= 0 else {
      let saved = errno
      return .failed(errno: saved)
    }
    return .bytes(result)
  }

  func closeOnce(_ fd: SearchAdmissionFileDescriptor) -> SearchAdmissionFileCloseResult {
    let result = Darwin.close(fd.rawValue)
    guard result == 0 else {
      let saved = errno
      return .uncertain(errno: saved)
    }
    return .closed
  }

  static func normalizedSample(_ raw: stat) -> SearchAdmissionFileSampleResult {
    guard let inode = UInt64(exactly: raw.st_ino),
      let size = Int64(exactly: raw.st_size),
      let modifiedSeconds = Int64(exactly: raw.st_mtimespec.tv_sec),
      let modifiedNanoseconds = Int64(exactly: raw.st_mtimespec.tv_nsec),
      let changedSeconds = Int64(exactly: raw.st_ctimespec.tv_sec),
      let changedNanoseconds = Int64(exactly: raw.st_ctimespec.tv_nsec)
    else { return .invalidMetadata }
    do {
      let identity = try SearchAdmissionFileIdentity(
        device: UInt64(UInt32(bitPattern: raw.st_dev)), inode: inode, size: size,
        modifiedSeconds: modifiedSeconds, modifiedNanoseconds: modifiedNanoseconds,
        changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds)
      return .sampled(.init(identity: identity, isRegular: raw.st_mode & S_IFMT == S_IFREG))
    } catch {
      return .invalidMetadata
    }
  }
}
