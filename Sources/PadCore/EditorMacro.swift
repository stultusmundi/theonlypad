import Foundation

public enum MacroCommand: Codable, Equatable, Sendable {
  case transform(LineTransform)
  case replace(location: Int, length: Int, text: String)
}

public struct EditorMacro: Codable, Equatable, Sendable, Identifiable {
  public let version: Int
  public let id: UUID
  public var name: String
  public var commands: [MacroCommand]
  public init(name: String, commands: [MacroCommand], id: UUID = UUID()) {
    self.version = 1
    self.id = id
    self.name = name
    self.commands = commands
  }
}

public enum MacroError: Error {
  case incompatibleVersion, invalidRepeat, workLimit, outputLimit, cancelled
}

public enum MacroPlayer {
  public static func replay(
    _ macro: EditorMacro, on text: String, repeatCount: Int = 1,
    isCancelled: () -> Bool = { false }
  ) throws -> String {
    guard macro.version == 1 else { throw MacroError.incompatibleVersion }
    guard (1...10_000).contains(repeatCount) else { throw MacroError.invalidRepeat }
    guard macro.commands.count <= 10_000 / repeatCount else { throw MacroError.workLimit }
    let maximum = 10_000_000
    guard text.utf16.count <= maximum else { throw MacroError.outputLimit }
    var result = text
    for _ in 0..<repeatCount {
      for command in macro.commands {
        if isCancelled() { throw MacroError.cancelled }
        switch command {
        case .transform(let transform): result = transform.apply(to: result)
        case .replace(let location, let length, let replacement):
          let count = result.utf16.count
          guard location >= 0, length >= 0, location <= count, length <= count - location else {
            throw TextEditError.invalidRange
          }
          guard replacement.utf16.count <= maximum,
            count - length <= maximum - replacement.utf16.count
          else { throw MacroError.outputLimit }
          result = try TextEdits.apply(
            [
              TextEdit(range: NSRange(location: location, length: length), replacement: replacement)
            ], to: result)
        }
        guard result.utf16.count <= maximum else { throw MacroError.outputLimit }
        if isCancelled() { throw MacroError.cancelled }
      }
    }
    if isCancelled() { throw MacroError.cancelled }
    return result
  }
}
