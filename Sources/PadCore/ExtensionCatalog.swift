import Darwin
import Foundation

public struct ExtensionCommand: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let transform: LineTransform
  public init(id: String, title: String, transform: LineTransform) {
    self.id = id
    self.title = title
    self.transform = transform
  }
}
public struct ExtensionManifest: Codable, Equatable, Sendable {
  public let apiVersion: Int
  public let id: String
  public let name: String
  public let version: String
  public let capabilities: [String]
  public let commands: [ExtensionCommand]
  public init(
    apiVersion: Int = 1, id: String, name: String, version: String,
    capabilities: [String] = ["text.transform"], commands: [ExtensionCommand]
  ) {
    self.apiVersion = apiVersion
    self.id = id
    self.name = name
    self.version = version
    self.capabilities = capabilities
    self.commands = commands
  }
}
public struct InstalledExtension: Codable, Equatable, Sendable, Identifiable {
  public var id: String { manifest.id }
  public let manifest: ExtensionManifest
  public var enabled: Bool
}
public struct EnabledExtensionCommand: Equatable, Sendable, Identifiable {
  public var id: String { "extension." + extensionID + "." + commandID }
  public let extensionID: String
  public let extensionName: String
  public let commandID: String
  public let title: String
  public let transform: LineTransform
}
public enum ExtensionCatalogError: Error, LocalizedError {
  case invalidManifest, invalidCatalog, incompatibleVersion, unsupportedCapability,
    unsupportedBinary, duplicate,
    missing, unsafeLocation, limit
  public var errorDescription: String? {
    switch self {
    case .invalidManifest:
      return
        "The extension manifest is invalid or contains unsupported fields. No extension was installed."
    case .unsupportedBinary:
      return String(
        localized:
          "Executable plugin binaries, including Windows Notepad++ plugins, cannot be installed. TheOnlyPad accepts declarative JSON extension manifests."
      )
    case .invalidCatalog:
      return "The installed extension catalog is invalid. Existing data was left unchanged."
    case .incompatibleVersion: return "This extension API or catalog version is not supported."
    case .unsupportedCapability:
      return
        "Only the text.transform capability is supported. Executable code, file access and network access are not extension capabilities."
    case .duplicate:
      return
        "An extension with this identifier is already installed. Uninstall it before installing another version."
    case .missing: return "This extension is no longer installed. Reload the catalog."
    case .unsafeLocation:
      return
        "The extension file or storage location could not be accessed safely. Symbolic links are not accepted."
    case .limit: return "The extension exceeds this build's manifest, command or catalog limits."
    }
  }
}

/// Declarative data only: this catalog never loads or executes extension code.
/// Synchronous bounded I/O; invoke off the main thread. Mutations serialize within this process.
public struct ExtensionCatalog: Sendable {
  public let directory: URL
  public static var defaultDirectory: URL {
    SettingsStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent(
      "Extensions", isDirectory: true)
  }
  private static let manifestLimit = 65_536
  private static let catalogLimit = 4_194_304
  private static let mutationLock = NSLock()
  private struct Envelope: Codable {
    var version: Int
    var extensions: [InstalledExtension]
  }
  public init(directory: URL) { self.directory = directory }

  public func inspect(url: URL) throws -> ExtensionManifest {
    guard
      let data = try read(
        url, maximum: Self.manifestLimit, privateFile: false, missingAllowed: false)
    else { throw ExtensionCatalogError.invalidManifest }
    // This prefix only selects an actionable diagnostic; it does not validate executable files.
    if data.starts(with: [UInt8(0x4d), UInt8(0x5a)]) {
      throw ExtensionCatalogError.unsupportedBinary
    }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch {
      throw ExtensionCatalogError.invalidManifest
    }
    try manifestSchema(object)
    let manifest: ExtensionManifest
    do { manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data) } catch {
      throw ExtensionCatalogError.invalidManifest
    }
    try validate(manifest)
    return manifest
  }

  @discardableResult public func install(from url: URL) throws -> InstalledExtension {
    try install(inspect(url: url))
  }

  /// Installs the exact immutable manifest disclosed to the user, avoiding rereading a changed source file.
  @discardableResult public func install(_ manifest: ExtensionManifest) throws -> InstalledExtension
  {
    try validate(manifest)
    let installed = InstalledExtension(manifest: manifest, enabled: false)
    try mutate { entries in
      guard !entries.contains(where: { $0.id == manifest.id }) else {
        throw ExtensionCatalogError.duplicate
      }
      entries.append(installed)
    }
    return installed
  }
  public func load() throws -> [InstalledExtension] { try state().1 }
  public func setEnabled(id: String, enabled: Bool) throws {
    try mutate { entries in
      guard let index = entries.firstIndex(where: { $0.id == id }) else {
        throw ExtensionCatalogError.missing
      }
      entries[index].enabled = enabled
    }
  }
  public func uninstall(id: String) throws {
    try mutate { entries in
      guard let index = entries.firstIndex(where: { $0.id == id }) else {
        throw ExtensionCatalogError.missing
      }
      entries.remove(at: index)
    }
  }
  public func enabledCommands() throws -> [EnabledExtensionCommand] {
    try load().filter(\.enabled).flatMap { entry in
      entry.manifest.commands.map {
        EnabledExtensionCommand(
          extensionID: entry.id, extensionName: entry.manifest.name, commandID: $0.id,
          title: $0.title, transform: $0.transform)
      }
    }
  }

  private func mutate(_ change: (inout [InstalledExtension]) throws -> Void) throws {
    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    let (previous, old) = try state()
    var entries = old
    try change(&entries)
    try validateEntries(entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(Envelope(version: 1, extensions: entries))
    guard bytes.count <= Self.catalogLimit else { throw ExtensionCatalogError.limit }
    try checkDirectory(create: true)
    try AtomicFileStore().save(bytes, to: file, expected: previous)
  }
  private var file: URL { directory.appendingPathComponent("Catalog.json") }
  private func state() throws -> (Data?, [InstalledExtension]) {
    try checkDirectory(create: false)
    guard
      let bytes = try read(
        file, maximum: Self.catalogLimit, privateFile: true, missingAllowed: true)
    else { return (nil, []) }
    let envelope: Envelope
    do { envelope = try JSONDecoder().decode(Envelope.self, from: bytes) } catch {
      throw ExtensionCatalogError.invalidCatalog
    }
    guard envelope.version == 1 else { throw ExtensionCatalogError.incompatibleVersion }
    guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(root.keys) == ["version", "extensions"],
      let entries = root["extensions"] as? [[String: Any]]
    else { throw ExtensionCatalogError.invalidCatalog }
    for entry in entries {
      guard Set(entry.keys) == ["manifest", "enabled"], let manifest = entry["manifest"] else {
        throw ExtensionCatalogError.invalidCatalog
      }
      try manifestSchema(manifest)
    }
    try validateEntries(envelope.extensions)
    return (bytes, envelope.extensions)
  }
  private func manifestSchema(_ object: Any) throws {
    guard let value = object as? [String: Any],
      Set(value.keys) == ["apiVersion", "id", "name", "version", "capabilities", "commands"],
      let commands = value["commands"] as? [[String: Any]],
      commands.allSatisfy({ Set($0.keys) == ["id", "title", "transform"] })
    else { throw ExtensionCatalogError.invalidManifest }
  }
  private func validateEntries(_ entries: [InstalledExtension]) throws {
    guard entries.count <= 64 else { throw ExtensionCatalogError.limit }
    var ids = Set<String>()
    for entry in entries {
      guard ids.insert(entry.id).inserted else { throw ExtensionCatalogError.invalidCatalog }
      try validate(entry.manifest)
    }
  }
  private func validate(_ manifest: ExtensionManifest) throws {
    guard manifest.apiVersion == 1 else { throw ExtensionCatalogError.incompatibleVersion }
    guard manifest.capabilities == ["text.transform"] else {
      throw ExtensionCatalogError.unsupportedCapability
    }
    guard manifest.id.count <= 120,
      manifest.id.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$", options: .regularExpression)
        != nil,
      validTitle(manifest.name)
    else { throw ExtensionCatalogError.invalidManifest }
    let version = manifest.version.split(separator: ".", omittingEmptySubsequences: false)
    guard manifest.version.count <= 32, version.count == 3,
      version.allSatisfy({
        !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
          && ($0 == "0" || !$0.hasPrefix("0"))
      })
    else { throw ExtensionCatalogError.invalidManifest }
    guard (1...32).contains(manifest.commands.count) else { throw ExtensionCatalogError.limit }
    var ids = Set<String>()
    for command in manifest.commands {
      guard command.id.count <= 64,
        command.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
        ids.insert(command.id).inserted, validTitle(command.title)
      else { throw ExtensionCatalogError.invalidManifest }
    }
    guard try JSONEncoder().encode(manifest).count <= Self.manifestLimit else {
      throw ExtensionCatalogError.limit
    }
  }
  private func validTitle(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 120
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }
  private func checkDirectory(create: Bool) throws {
    guard directory.isFileURL else { throw ExtensionCatalogError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw ExtensionCatalogError.unsafeLocation }
      if !create { return }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard lstat(directory.path, &info) == 0 else { throw ExtensionCatalogError.unsafeLocation }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw ExtensionCatalogError.unsafeLocation }
  }
  private func read(_ url: URL, maximum: Int, privateFile: Bool, missingAllowed: Bool) throws
    -> Data?
  {
    guard url.isFileURL else { throw ExtensionCatalogError.unsafeLocation }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT && missingAllowed { return nil }
      throw ExtensionCatalogError.unsafeLocation
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      !privateFile || (info.st_uid == geteuid() && info.st_mode & 0o077 == 0)
    else { throw ExtensionCatalogError.unsafeLocation }
    guard info.st_size <= maximum else { throw ExtensionCatalogError.limit }
    let bytes =
      try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: maximum + 1)
      ?? Data()
    guard bytes.count <= maximum else { throw ExtensionCatalogError.limit }
    return bytes
  }
}
