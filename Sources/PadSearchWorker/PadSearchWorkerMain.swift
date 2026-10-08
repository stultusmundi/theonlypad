import Darwin
import PadSearchWorkerRuntime
import SearchExecution

@main enum PadSearchWorkerMain {
  static func main() {
    let code = SearchWorkerProgram.run(
      arguments: CommandLine.arguments, inputFD: 0, outputFD: 1, controlFD: 3,
      makeChannel: {
        try SearchWorkerFDChannel(inputFD: $0, outputFD: $1, system: .darwin)
      },
      makeAccumulator: { try SearchWorkerUTF8Accumulator(declaredUTF16: $0) },
      startParentLifetime: { try SearchParentLifetime.start(controlFD: $0) })
    Darwin._exit(code)
  }
}
