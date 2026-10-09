enum SearchAdmissionFileReader {
  private enum BodyOutcome {
    case prepared(SearchPreparedUTF8Result)
    case failed(SearchAdmissionFileFailure)
  }

  // Uncertainty leaves the content-owning helper as primitive metadata only.
  private enum Completion {
    case prepared(SearchPreparedUTF8Result)
    case failed(SearchAdmissionFileFailure)
    case uncertain(
      descriptor: SearchAdmissionFileDescriptor, errno: Int32,
      primaryFailure: SearchAdmissionFileFailure?)
  }

  static func read(
    input: SearchAdmissionFileInput, bounds: SearchAdmissionFileReadBounds,
    io: any SearchAdmissionFileIO, cancelled: () -> Bool
  ) -> SearchAdmissionFileReturn {
    do {
      guard bounds == (try SearchAdmissionFileReadBounds(input: input)) else {
        return .failed(.invalidBounds)
      }
    } catch {
      return .failed(.invalidBounds)
    }
    guard !cancelled() else { return .failed(.cancelled) }
    // perform has returned before the public uncertainty record is constructed.
    switch perform(input: input, bounds: bounds, io: io, cancelled: cancelled) {
    case .prepared(let result): return .prepared(result)
    case .failed(let failure): return .failed(failure)
    case .uncertain(let descriptor, let errno, let primaryFailure):
      return .ownershipUncertain(
        .init(
          descriptor: descriptor, expectedIdentity: input.identity,
          closeErrno: errno, primaryFailure: primaryFailure))
    }
  }

  private static func perform(
    input: SearchAdmissionFileInput, bounds: SearchAdmissionFileReadBounds,
    io: any SearchAdmissionFileIO, cancelled: () -> Bool
  ) -> Completion {
    var path = [CChar](repeating: 0, count: input.path.utf8.count + 1)
    for (index, byte) in input.path.utf8.enumerated() { path[index] = CChar(bitPattern: byte) }
    var window = [UInt8](repeating: 0, count: bounds.windowBytes)
    let decoder: SearchPreparedUTF8Decoder
    do {
      decoder = try SearchPreparedUTF8Decoder(
        expectedInputBytes: bounds.inputBytes, maxInputUTF16: bounds.inputUTF16,
        maxWindowBytes: bounds.windowBytes, maxOutputUTF8Bytes: bounds.outputUTF8)
    } catch {
      return .failed(codecFailure(error))
    }
    guard !cancelled() else { return .failed(.cancelled) }
    return path.withUnsafeBufferPointer { pathBytes in
      switch io.openReadOnlyNoFollowNonBlockingCloseOnExec(path: pathBytes) {
      case .failed: return .failed(.unreadable)
      case .opened(let descriptor):
        // This retained token owns the sole close on every normal opened branch.
        let outcome = readOpened(
          descriptor: descriptor, path: pathBytes, identity: input.identity,
          bounds: bounds, window: &window, decoder: decoder, io: io, cancelled: cancelled)
        switch io.closeOnce(descriptor) {
        case .closed:
          switch outcome {
          case .prepared(let result): return .prepared(result)
          case .failed(let failure): return .failed(failure)
          }
        case .uncertain(let errno):
          let primaryFailure: SearchAdmissionFileFailure?
          switch outcome {
          case .failed(let failure): primaryFailure = failure
          case .prepared: primaryFailure = nil
          }
          return .uncertain(
            descriptor: descriptor, errno: errno, primaryFailure: primaryFailure)
        }
      }
    }
  }

  private static func readOpened(
    descriptor: SearchAdmissionFileDescriptor, path: UnsafeBufferPointer<CChar>,
    identity: SearchAdmissionFileIdentity, bounds: SearchAdmissionFileReadBounds,
    window: inout [UInt8], decoder: SearchPreparedUTF8Decoder,
    io: any SearchAdmissionFileIO, cancelled: () -> Bool
  ) -> BodyOutcome {
    if let failure = sampleFailure(descriptor: descriptor, path: path, identity: identity, io: io) {
      return .failed(failure)
    }
    var offset = 0
    while offset < bounds.inputBytes {
      guard !cancelled() else { return .failed(.cancelled) }
      let requested = min(bounds.windowBytes, bounds.inputBytes - offset)
      let reply = window.withUnsafeMutableBufferPointer { storage in
        let view = UnsafeMutableBufferPointer(start: storage.baseAddress, count: requested)
        return io.read(descriptor, into: view, offset: Int64(offset))
      }
      let actual: Int
      switch reply {
      case .failed: return .failed(.unreadable)
      case .bytes(let count): actual = count
      }
      guard actual >= 0 else { return .failed(.unreadable) }
      guard actual <= requested else { return .failed(.internalFailure) }
      guard actual > 0 else { return .failed(.sourceChanged) }
      guard !cancelled() else { return .failed(.cancelled) }
      do {
        try window.withUnsafeBufferPointer { storage in
          let view = UnsafeBufferPointer(start: storage.baseAddress, count: actual)
          try decoder.consume(view)
        }
      } catch {
        return .failed(codecFailure(error))
      }
      let next = offset.addingReportingOverflow(actual)
      guard !next.overflow, next.partialValue <= bounds.inputBytes else {
        return .failed(.internalFailure)
      }
      offset = next.partialValue
    }
    guard !cancelled() else { return .failed(.cancelled) }
    if let failure = sampleFailure(descriptor: descriptor, path: path, identity: identity, io: io) {
      return .failed(failure)
    }
    let result: SearchPreparedUTF8Result
    do {
      result = try decoder.finish()
    } catch {
      return .failed(codecFailure(error))
    }
    guard !cancelled() else { return .failed(.cancelled) }
    // The final pair occurs after materialization while the descriptor is open.
    if let failure = sampleFailure(descriptor: descriptor, path: path, identity: identity, io: io) {
      return .failed(failure)
    }
    return .prepared(result)
  }

  private static func sampleFailure(
    descriptor: SearchAdmissionFileDescriptor, path: UnsafeBufferPointer<CChar>,
    identity: SearchAdmissionFileIdentity, io: any SearchAdmissionFileIO
  ) -> SearchAdmissionFileFailure? {
    if let failure = sampleFailure(io.sampleDescriptor(descriptor), identity: identity) {
      return failure
    }
    return sampleFailure(io.samplePath(path), identity: identity)
  }

  private static func sampleFailure(
    _ sample: SearchAdmissionFileSampleResult, identity: SearchAdmissionFileIdentity
  ) -> SearchAdmissionFileFailure? {
    switch sample {
    case .failed: return .unreadable
    case .invalidMetadata: return .internalFailure
    case .sampled(let value):
      guard value.isRegular else { return .unreadable }
      guard value.identity == identity else { return .sourceChanged }
      return nil
    }
  }

  private static func codecFailure(_ error: Error) -> SearchAdmissionFileFailure {
    guard let error = error as? SearchPreparedUTF8Error else { return .internalFailure }
    switch error {
    case .invalidUTF8: return .invalidUTF8
    case .binaryInput: return .binaryInput
    case .windowLimit, .inputByteLimit, .inputUnitLimit, .outputLimit: return .inputLimit
    case .lengthMismatch: return .sourceChanged
    case .invalidBounds, .invalidScalar, .invalidPhase, .poisoned, .internalFailure:
      return .internalFailure
    }
  }
}
