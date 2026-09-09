import Darwin
import Foundation

public enum MacroLibraryError: Error, LocalizedError {
  case corrupt, incompatibleVersion, invalidName, duplicateName, invalidCommand, limit,
    missingMacro, unsafeLocation
  public var errorDescription: String? {
    switch self {
    case .corrupt: return "The macro library is invalid. Existing data was left unchanged."
    case .incompatibleVersion:
      return "This macro library uses an unsupported version. Existing data was left unchanged."
    case .invalidName: return "Macro names must contain 1–120 characters and cannot be blank."
    case .duplicateName: return "A macro with that name already exists. Choose another name."
    case .invalidCommand: return "The macro contains an unsupported or invalid editing command."
    case .limit: return "The macro library exceeds this build's storage or command limits."
    case .missingMacro: return "The selected macro no longer exists. Reload the library."
    case .unsafeLocation:
      return "The macro library could not be accessed safely. Check its folder permissions."
    }
  }
}

/// Private, bounded local storage. Names are metadata, never path components.
/// Call off the main thread. Mutations are serialized within this process;
/// opening a library never executes it.
public struct MacroLibrary: Sendable {
  public let directory: URL
  public static var defaultDirectory: URL {
    SettingsStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent(
      "Macros", isDirectory: true)
  }
  private static let maximumBytes = 16_777_216
  private static let mutationLock = NSLock()
  private struct Envelope: Codable {
    var version: Int
    var macros: [EditorMacro]
  }
  private struct Header: Decodable { var version: Int }

  public init(directory: URL) { self.directory = directory }
  public func load() throws -> [EditorMacro] { try state().1 }

  public func save(_ macro: EditorMacro) throws {
    try mutate { macros in
      if let index = macros.firstIndex(where: { $0.id == macro.id }) {
        macros[index] = macro
      } else {
        macros.append(macro)
      }
    }
  }

  public func rename(id: UUID, to name: String) throws {
    try mutate { macros in
      guard let index = macros.firstIndex(where: { $0.id == id }) else {
        throw MacroLibraryError.missingMacro
      }
      macros[index].name = name
    }
  }

  public func delete(id: UUID) throws {
    try mutate { macros in
      guard let index = macros.firstIndex(where: { $0.id == id }) else {
        throw MacroLibraryError.missingMacro
      }
      macros.remove(at: index)
    }
  }

  private func mutate(_ change: (inout [EditorMacro]) throws -> Void) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let (previous, existing) = try state()
    var macros = existing
    try change(&macros)
    try validate(macros)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Envelope(version: 1, macros: macros))
    guard data.count <= Self.maximumBytes else { throw MacroLibraryError.limit }
    try checkDirectory(create: true)
    try AtomicFileStore().save(data, to: file, expected: previous)
  }

  private var file: URL { directory.appendingPathComponent("Library.json") }

  private func state() throws -> (Data?, [EditorMacro]) {
    try checkDirectory(create: false)
    guard let data = try read() else { return (nil, []) }
    let decoder = JSONDecoder()
    let header: Header
    do { header = try decoder.decode(Header.self, from: data) } catch {
      throw MacroLibraryError.corrupt
    }
    guard header.version == 1 else { throw MacroLibraryError.incompatibleVersion }
    try validateSchema(data)
    let envelope: Envelope
    do { envelope = try decoder.decode(Envelope.self, from: data) } catch {
      throw MacroLibraryError.corrupt
    }
    try validate(envelope.macros)
    return (data, envelope.macros)
  }

  private func validateSchema(_ data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys) == ["version", "macros"], let macros = root["macros"] as? [[String: Any]]
    else {
      throw MacroLibraryError.corrupt
    }
    for macro in macros {
      guard Set(macro.keys) == ["version", "id", "name", "commands"],
        let commands = macro["commands"] as? [[String: Any]]
      else { throw MacroLibraryError.corrupt }
      for command in commands {
        guard command.count == 1 else { throw MacroLibraryError.invalidCommand }
        if let transform = command["transform"] as? [String: Any], Set(transform.keys) == ["_0"] {
          continue
        }
        if let replace = command["replace"] as? [String: Any],
          Set(replace.keys) == ["location", "length", "text"]
        {
          continue
        }
        throw MacroLibraryError.invalidCommand
      }
    }
  }

  private func validate(_ macros: [EditorMacro]) throws {
    guard macros.count <= 1_000 else { throw MacroLibraryError.limit }
    var ids = Set<UUID>()
    var names = Set<String>()
    var commandCount = 0
    var replacementSize = 0
    for macro in macros {
      guard macro.version == 1 else { throw MacroLibraryError.incompatibleVersion }
      guard ids.insert(macro.id).inserted else { throw MacroLibraryError.corrupt }
      let trimmed = macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, macro.name.count <= 120,
        !macro.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw MacroLibraryError.invalidName }
      guard
        names.insert(
          trimmed.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        ).inserted
      else { throw MacroLibraryError.duplicateName }
      guard !macro.commands.isEmpty else { throw MacroLibraryError.invalidCommand }
      guard macro.commands.count <= 10_000 - commandCount else { throw MacroLibraryError.limit }
      commandCount += macro.commands.count
      for command in macro.commands {
        if case .replace(let location, let length, let text) = command {
          guard location >= 0, length >= 0, location <= 10_000_000,
            length <= 10_000_000 - location
          else { throw MacroLibraryError.invalidCommand }
          let size = text.utf16.count
          guard size <= 10_000_000 - replacementSize else { throw MacroLibraryError.limit }
          replacementSize += size
        }
      }
    }
  }

  private func checkDirectory(create: Bool) throws {
    guard directory.isFileURL else { throw MacroLibraryError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw MacroLibraryError.unsafeLocation }
      if !create { return }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard lstat(directory.path, &info) == 0 else { throw MacroLibraryError.unsafeLocation }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else {
      throw MacroLibraryError.unsafeLocation
    }
  }

  private func read() throws -> Data? {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw MacroLibraryError.unsafeLocation
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw MacroLibraryError.unsafeLocation }
    guard info.st_size <= Self.maximumBytes else { throw MacroLibraryError.limit }
    let data =
      try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(
        upToCount: Self.maximumBytes + 1) ?? Data()
    guard data.count <= Self.maximumBytes else { throw MacroLibraryError.limit }
    return data
  }
}
