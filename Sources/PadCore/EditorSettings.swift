import Darwin
import Foundation

public enum EditorTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct EditorSettings: Codable, Equatable, Sendable {
  public var theme: EditorTheme
  public var fontSize: Double
  public var fontName: String
  public var wrap: Bool
  public var tabWidth: Int
  public static let systemMonospacedFontName = "System Monospaced"
  public static let defaults = EditorSettings()

  public init(
    theme: EditorTheme = .system, fontSize: Double = 13,
    fontName: String = EditorSettings.systemMonospacedFontName, wrap: Bool = true, tabWidth: Int = 4
  ) {
    self.theme = theme
    self.fontSize = fontSize
    self.fontName = fontName
    self.wrap = wrap
    self.tabWidth = tabWidth
  }

  @discardableResult public func validated() throws -> EditorSettings {
    guard fontSize.isFinite, (8...36).contains(fontSize) else {
      throw SettingsError.invalidField("Font size must be between 8 and 36 points.")
    }
    guard (2...8).contains(tabWidth) else {
      throw SettingsError.invalidField("Tab width must be between 2 and 8 spaces.")
    }
    guard !fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      fontName.count <= 256,
      !fontName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw SettingsError.invalidField("Enter a valid font name.")
    }
    return self
  }
}

public enum SettingsError: Error, LocalizedError {
  case invalidField(String)
  case unsupportedVersion(Int)
  case unknownFields, invalidFile, unsafeLocation
  public var errorDescription: String? {
    switch self {
    case .invalidField(let message): return message
    case .unsupportedVersion(let version):
      return "Preferences version \(version) is not supported. No settings were changed."
    case .unknownFields:
      return "The preferences file contains unknown fields. No settings were discarded or changed."
    case .invalidFile:
      return "The preferences file is invalid or too large. Select a valid preferences JSON file."
    case .unsafeLocation:
      return "Preferences could not be accessed safely. Check the preferences folder permissions."
    }
  }
}

/// Synchronous bounded I/O; call on a serialized background owner.
public struct SettingsStore: Sendable {
  public let directory: URL
  private static let maximumBytes = 1_048_576
  private struct Header: Decodable { var version: Int }
  private struct Envelope: Codable {
    var version: Int
    var settings: EditorSettings
  }
  private struct Legacy: Decodable {
    var version: Int
    var fontSize: Double
    var wordWrap: Bool
  }

  public static var defaultDirectory: URL {
    let base: URL
    if let override = ProcessInfo.processInfo.environment["THEONLYPAD_STATE_DIRECTORY"],
      !override.isEmpty
    {
      base = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
    }
    return base.appendingPathComponent("Preferences", isDirectory: true)
  }

  public init(directory: URL) { self.directory = directory }

  public func load() throws -> EditorSettings {
    try checkDirectory(create: false)
    guard let data = try readExisting() else { return .defaults }
    return try importData(data)
  }

  public func save(_ settings: EditorSettings) throws {
    let data = try exportData(settings)
    try checkDirectory(create: true)
    let previous = try readExisting()
    try AtomicFileStore().save(data, to: file, expected: previous)
  }

  /// Decode and validate without changing persistent settings. Save explicitly after successful import.
  public func importData(_ data: Data) throws -> EditorSettings {
    guard data.count <= Self.maximumBytes else { throw SettingsError.invalidFile }
    let decoder = JSONDecoder()
    let header: Header
    let object: [String: Any]
    do {
      header = try decoder.decode(Header.self, from: data)
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SettingsError.invalidFile
      }
      object = value
    } catch { throw SettingsError.invalidFile }
    switch header.version {
    case 0:
      guard Set(object.keys) == ["version", "fontSize", "wordWrap"] else {
        throw SettingsError.unknownFields
      }
      let old: Legacy
      do { old = try decoder.decode(Legacy.self, from: data) } catch {
        throw SettingsError.invalidFile
      }
      return try EditorSettings(fontSize: old.fontSize, wrap: old.wordWrap).validated()
    case 1:
      guard Set(object.keys) == ["version", "settings"],
        let values = object["settings"] as? [String: Any],
        Set(values.keys) == ["theme", "fontSize", "fontName", "wrap", "tabWidth"]
      else { throw SettingsError.unknownFields }
      let envelope: Envelope
      do { envelope = try decoder.decode(Envelope.self, from: data) } catch {
        throw SettingsError.invalidFile
      }
      return try envelope.settings.validated()
    default: throw SettingsError.unsupportedVersion(header.version)
    }
  }

  public func exportData(_ settings: EditorSettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(Envelope(version: 1, settings: settings.validated()))
  }

  @discardableResult public func reset() throws -> EditorSettings {
    try save(.defaults)
    return .defaults
  }

  private var file: URL { directory.appendingPathComponent("Settings.json") }

  private func checkDirectory(create: Bool) throws {
    guard directory.isFileURL else { throw SettingsError.unsafeLocation }
    var info = stat()
    if lstat(directory.path, &info) != 0 {
      guard errno == ENOENT else { throw SettingsError.unsafeLocation }
      if !create { return }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard lstat(directory.path, &info) == 0 else { throw SettingsError.unsafeLocation }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else {
      throw SettingsError.unsafeLocation
    }
  }

  private func readExisting() throws -> Data? {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw SettingsError.unsafeLocation
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_size <= Self.maximumBytes
    else { throw SettingsError.invalidFile }
    let data =
      try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(
        upToCount: Self.maximumBytes + 1) ?? Data()
    guard data.count <= Self.maximumBytes else { throw SettingsError.invalidFile }
    return data
  }
}
