package typealias SearchWorkerChannelFactory =
  (_ inputFD: Int32, _ outputFD: Int32) throws -> any SearchWorkerBlockingChannel

package enum SearchWorkerProgram {
  /// Production supplies stdin/stdout/control descriptors 0/1/3. All descriptors
  /// are borrowed, nonnegative and distinct. The lifetime starter must start an
  /// independent watcher thread and return promptly, never run its wait inline.
  package static func run(
    arguments: [String], inputFD: Int32, outputFD: Int32, controlFD: Int32,
    makeChannel: @escaping SearchWorkerChannelFactory,
    makeAccumulator: @escaping SearchWorkerAccumulatorFactory,
    startParentLifetime: @escaping (Int32) -> Void
  ) -> Int32 {
    let bootstrap: SearchWorkerBootstrap
    do {
      bootstrap = try SearchWorkerBootstrap.parse(arguments: arguments)
    } catch {
      return 64
    }
    guard inputFD >= 0, outputFD >= 0, controlFD >= 0,
      inputFD != outputFD, inputFD != controlFD, outputFD != controlFD
    else {
      return 74
    }
    let channel: any SearchWorkerBlockingChannel
    do {
      channel = try makeChannel(inputFD, outputFD)
    } catch {
      return 74
    }
    startParentLifetime(controlFD)
    do {
      let runtime = try SearchWorkerRuntime(
        generation: bootstrap.generation, channel: channel,
        makeAccumulator: makeAccumulator, engine: FoundationSearchWorkerEngine())
      switch runtime.run() {
      case .cleanEOF: return 0
      case .protocolFailure: return 65
      case .inputSinkFailure, .internalFailure: return 70
      case .inputFailure, .outputFailure: return 74
      }
    } catch {
      // Canonical bootstrap satisfies the reader's generation precondition.
      // Any failure constructing that runtime is an internal setup failure.
      return 70
    }
  }
}
