import Foundation

public struct CommandDescriptor: Equatable, Sendable {
  public let id: String
  public let title: String
  public let shortcut: String?
  public init(id: String, title: String, shortcut: String? = nil) {
    self.id = id
    self.title = title
    self.shortcut = shortcut.map { value in
      let parts = value.lowercased().split(separator: "+").map(String.init)
      guard let key = parts.last else { return value }
      return (Array(Set(parts.dropLast())).sorted() + [key]).joined(separator: "+")
    }
  }
}

public enum CommandRegistryError: Error { case duplicateIdentifier, shortcutCollision }

public struct CommandRegistry: Sendable {
  public private(set) var commands: [CommandDescriptor] = []
  public init() {}
  public mutating func register(_ command: CommandDescriptor) throws {
    guard !commands.contains(where: { $0.id == command.id }) else {
      throw CommandRegistryError.duplicateIdentifier
    }
    if let shortcut = command.shortcut?.lowercased(),
      commands.contains(where: { $0.shortcut?.lowercased() == shortcut })
    {
      throw CommandRegistryError.shortcutCollision
    }
    commands.append(command)
  }
}
