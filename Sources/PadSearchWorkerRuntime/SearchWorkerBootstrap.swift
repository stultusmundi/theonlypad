import Foundation

package struct SearchWorkerBootstrap: Equatable {
  package let generation: UUID

  package static func parse(arguments: [String]) throws -> SearchWorkerBootstrap {
    guard arguments.count == 3, arguments[1] == "--generation" else {
      throw SearchWorkerBootstrapError.invalidArguments
    }
    let value = arguments[2]
    guard value.utf8.count == 36, let generation = UUID(uuidString: value),
      generation.uuidString.lowercased() == value.lowercased(),
      generation != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    else {
      throw SearchWorkerBootstrapError.invalidArguments
    }
    return SearchWorkerBootstrap(generation: generation)
  }
}

package enum SearchWorkerBootstrapError: Error, Equatable {
  case invalidArguments
}
