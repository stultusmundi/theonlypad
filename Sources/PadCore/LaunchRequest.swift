import Foundation

public enum LaunchRequestError: Error, LocalizedError {
  case invalidArguments(String)
  case invalidPosition, invalidURL, lineOutOfRange
  public var errorDescription: String? {
    switch self {
    case .invalidArguments(let message): return message
    case .invalidPosition:
      return
        "Line and column must be positive decimal integers within the platform's integer range."
    case .invalidURL: return "This is not a supported local-file open link."
    case .lineOutOfRange: return "The requested line does not exist in this document."
    }
  }
}

public struct LaunchRequest: Equatable, Sendable {
  public let url: URL
  public let line: Int
  public let column: Int
  public init(url: URL, line: Int = 1, column: Int = 1) {
    self.url = url
    self.line = line
    self.column = column
  }

  /// Options apply to every file in one invocation, regardless of their position.
  public static func parse(arguments: [String], workingDirectory: URL) throws -> [LaunchRequest] {
    guard isLocalFile(workingDirectory) else { throw LaunchRequestError.invalidURL }
    guard arguments.count <= 256 else {
      throw LaunchRequestError.invalidArguments("Too many command-line arguments.")
    }
    var bytes = 0
    for argument in arguments {
      guard argument.utf8.count <= 1_048_576 - bytes, !argument.utf8.contains(0) else {
        throw LaunchRequestError.invalidArguments(
          "Command-line arguments exceed 1 MB or contain a NUL character.")
      }
      bytes += argument.utf8.count
    }
    var line = 1
    var column = 1
    var index = 0
    var options = true
    var seen = Set<String>()
    var files: [String] = []
    while index < arguments.count {
      let argument = arguments[index]
      if options && argument == "--" {
        options = false
        index += 1
        continue
      }
      if options && (argument == "--line" || argument == "--column") {
        guard seen.insert(argument).inserted, index + 1 < arguments.count else {
          throw LaunchRequestError.invalidArguments(
            "Specify each navigation option once, followed by its value.")
        }
        let number = try positiveInteger(arguments[index + 1])
        if argument == "--line" { line = number } else { column = number }
        index += 2
        continue
      }
      guard !argument.isEmpty, !(options && argument.hasPrefix("-")) else {
        throw LaunchRequestError.invalidArguments(
          "Unknown option or empty filename. Use -- before filenames beginning with a dash.")
      }
      files.append(argument)
      guard files.count <= 128 else {
        throw LaunchRequestError.invalidArguments("Open at most 128 files per invocation.")
      }
      index += 1
    }
    guard arguments.isEmpty || !files.isEmpty else {
      throw LaunchRequestError.invalidArguments("Navigation options require at least one file.")
    }
    return files.map { path in
      let url =
        (path as NSString).isAbsolutePath
        ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path)
      return LaunchRequest(url: url.standardizedFileURL, line: line, column: column)
    }
  }

  public static func parse(url: URL) throws -> LaunchRequest {
    guard url.absoluteString.utf8.count <= 1_048_576,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == AppIdentity.urlScheme.lowercased(),
      parts.host?.lowercased() == "open", parts.path.isEmpty,
      parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
    else {
      throw LaunchRequestError.invalidURL
    }
    var values: [String: String] = [:]
    for item in parts.queryItems ?? [] {
      guard ["file", "line", "column"].contains(item.name), values[item.name] == nil,
        let value = item.value
      else { throw LaunchRequestError.invalidURL }
      values[item.name] = value
    }
    guard let raw = values["file"], let target = URL(string: raw), isLocalFile(target) else {
      throw LaunchRequestError.invalidURL
    }
    return LaunchRequest(
      url: target.standardizedFileURL,
      line: try positiveInteger(values["line"] ?? "1"),
      column: try positiveInteger(values["column"] ?? "1"))
  }

  public func protocolURL() throws -> URL {
    guard Self.isLocalFile(url), line > 0, column > 0 else { throw LaunchRequestError.invalidURL }
    var parts = URLComponents()
    parts.scheme = AppIdentity.urlScheme
    parts.host = "open"
    parts.queryItems = [
      URLQueryItem(name: "file", value: url.absoluteString),
      URLQueryItem(name: "line", value: String(line)),
      URLQueryItem(name: "column", value: String(column)),
    ]
    guard let result = parts.url, result.absoluteString.utf8.count <= 1_048_576 else {
      throw LaunchRequestError.invalidURL
    }
    return result
  }

  private static func positiveInteger(_ value: String) throws -> Int {
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let number = Int(value), number > 0
    else {
      throw LaunchRequestError.invalidPosition
    }
    return number
  }

  private static func isLocalFile(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
      && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
      && url.user == nil && url.password == nil && url.port == nil && url.query == nil
      && url.fragment == nil
  }
}

public enum TextNavigation {
  /// Columns count extended grapheme clusters in logical text order, not visual bidi positions.
  public static func utf16Offset(in text: String, line target: Int, column: Int) throws -> Int {
    guard target > 0, column > 0 else { throw LaunchRequestError.invalidPosition }
    var line = 1
    var position = text.startIndex
    while line < target && position < text.endIndex {
      let character = text[position]
      text.formIndex(after: &position)
      if character == "\n" || character == "\r" || character == "\r\n" { line += 1 }
    }
    guard line == target else { throw LaunchRequestError.lineOutOfRange }
    var remaining = column - 1
    while remaining > 0 && position < text.endIndex {
      let character = text[position]
      if character == "\n" || character == "\r" || character == "\r\n" { break }
      text.formIndex(after: &position)
      remaining -= 1
    }
    return position.utf16Offset(in: text)
  }
}
