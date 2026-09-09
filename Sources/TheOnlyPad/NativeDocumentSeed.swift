import Foundation
import PadCore

/// Preparation values only: no source operation, endpoint, monitor, view or writer authority.
struct NativeDocumentSeed: Sendable {
  enum Kind: Sendable {
    case scratch, opened, restored, backup, diskCopy, duplicate, reopened, legacyRecovery
  }
  struct Limits: Sendable {
    let utf16: Int
    let bytes: Int
    init(utf16: Int = 100_000_000, bytes: Int = 100_000_000) throws {
      guard (1...100_000_000).contains(utf16), (1...100_000_000).contains(bytes) else {
        throw NativeDocumentSeedError.limit
      }
      self.utf16 = utf16
      self.bytes = bytes
    }
    static let standard = try! Limits()
  }
  let id: UUID
  let kind: Kind
  let textUTF16Count: Int
  let originalByteCount: Int
  let text: String
  let encoding: DocumentEncoding
  let hasBOM: Bool
  let url: URL?
  let originalBytes: Data?
  let savedText: String
  let savedEncoding: DocumentEncoding
  let savedHasBOM: Bool
  let name: String?
  let pinned: Bool
  let language: DocumentLanguage
  let manualLanguage: Bool
  let bookmarks: DocumentBookmarks
  let presentation: RestoredPresentationState?

  private init(
    id: UUID, kind: Kind, decoded: DecodedDocument, url: URL? = nil,
    bytes: Data? = nil, saved: DecodedDocument? = nil, name: String? = nil,
    pinned: Bool = false, language: DocumentLanguage = .plainText, manual: Bool = false,
    bookmarks: DocumentBookmarks = DocumentBookmarks(),
    presentation: RestoredPresentationState? = nil,
    limits: Limits
  ) throws {
    guard (url == nil) == (bytes == nil), url == nil || url!.isFileURL else {
      throw NativeDocumentSeedError.invalidPair
    }
    guard (bytes?.count ?? 0) <= limits.bytes else { throw NativeDocumentSeedError.limit }
    let count = decoded.text.utf16.count
    guard count <= limits.utf16, (saved?.text.utf16.count ?? 0) <= limits.utf16 else {
      throw NativeDocumentSeedError.limit
    }
    self.id = id
    self.kind = kind
    self.textUTF16Count = count
    self.originalByteCount = bytes?.count ?? 0
    self.text = decoded.text
    self.encoding = decoded.encoding
    self.hasBOM = decoded.hasBOM
    self.url = url
    self.originalBytes = bytes
    self.savedText = saved?.text ?? ""
    self.savedEncoding = saved?.encoding ?? .utf8
    self.savedHasBOM = saved?.hasBOM ?? false
    self.name = name
    self.pinned = pinned
    self.language = language
    self.manualLanguage = manual
    self.bookmarks = bookmarks
    self.presentation = presentation
  }
  static func scratch(id: UUID = UUID(), limits: Limits = .standard) throws -> Self {
    try .init(id: id, kind: .scratch, decoded: .init(text: ""), limits: limits)
  }
  /// Decode and language detection belong on the existing preparation worker, not the UI apply path.
  static func opened(
    id: UUID = UUID(), url: URL, bytes: Data,
    encoding: DocumentEncoding? = nil, limits: Limits = .standard
  ) throws -> Self {
    guard bytes.count <= limits.bytes else { throw NativeDocumentSeedError.limit }
    let decoded = try DocumentCodec.decode(bytes, encoding: encoding)
    return try .init(
      id: id, kind: .opened, decoded: decoded, url: url, bytes: bytes,
      saved: decoded,
      language: LanguageService.detect(filename: url.lastPathComponent, text: decoded.text),
      limits: limits)
  }
  static func restored(
    _ metadata: SessionTab, decoded: DecodedDocument, originalBytes: Data?,
    url: URL?, limits: Limits = .standard
  ) throws -> Self {
    guard (url == nil) == (originalBytes == nil), (originalBytes?.count ?? 0) <= limits.bytes,
      decoded.text.utf16.count <= limits.utf16
    else { throw NativeDocumentSeedError.invalidPair }
    if let originalBytes {
      let actual = try DocumentCodec.decode(originalBytes, encoding: decoded.encoding)
      guard actual.hasBOM == decoded.hasBOM, actual.text.utf16.elementsEqual(decoded.text.utf16)
      else {
        throw NativeDocumentSeedError.invalidPair
      }
    }
    let resolved = try RestoredPresentationState.resolve(
      metadata.presentation, bookmarks: metadata.bookmarks, in: decoded.text)
    return try .init(
      id: metadata.id, kind: .restored, decoded: decoded, url: url, bytes: originalBytes,
      saved: url == nil ? nil : decoded,
      name: url == nil
        ? "Recovered "
          + (metadata.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled")
        : nil,
      pinned: metadata.pinned,
      language: metadata.manualLanguage
        ?? LanguageService.detect(filename: url?.lastPathComponent ?? "", text: decoded.text),
      manual: metadata.manualLanguage != nil, bookmarks: resolved.bookmarks, presentation: resolved,
      limits: limits)
  }
  static func backup(
    id: UUID = UUID(), originalPath: String, data: Data,
    encoding: DocumentEncoding, limits: Limits = .standard
  ) throws -> Self {
    guard data.count <= limits.bytes else { throw NativeDocumentSeedError.limit }
    return try .init(
      id: id, kind: .backup, decoded: DocumentCodec.decode(data, encoding: encoding),
      name: "Backup — " + URL(fileURLWithPath: originalPath).lastPathComponent, limits: limits)
  }
  static func diskCopy(
    id: UUID = UUID(), sourceName: String, decoded: DecodedDocument,
    limits: Limits = .standard
  ) throws -> Self {
    try .init(
      id: id, kind: .diskCopy, decoded: decoded, name: "Disk Copy — " + sourceName, limits: limits)
  }
  static func duplicate(
    id: UUID = UUID(), text: String, encoding: DocumentEncoding, hasBOM: Bool,
    language: DocumentLanguage, manualLanguage: Bool, limits: Limits = .standard
  ) throws -> Self {
    try .init(
      id: id, kind: .duplicate, decoded: .init(text: text, encoding: encoding, hasBOM: hasBOM),
      language: language, manual: manualLanguage, limits: limits)
  }
  /// The process supplies a clean-history value; no model, operation or pending publication is retained.
  static func reopened(
    id: UUID = UUID(), text: String, url: URL?, originalBytes: Data?,
    encoding: DocumentEncoding, hasBOM: Bool, saved: DecodedDocument,
    bookmarks: DocumentBookmarks, language: DocumentLanguage, manualLanguage: Bool,
    limits: Limits = .standard
  ) throws -> Self {
    guard text.utf16.elementsEqual(saved.text.utf16), encoding == saved.encoding,
      hasBOM == saved.hasBOM
    else {
      throw NativeDocumentSeedError.dirtyHistory
    }
    if let originalBytes {
      guard originalBytes.count <= limits.bytes else { throw NativeDocumentSeedError.limit }
      let actual = try DocumentCodec.decode(originalBytes, encoding: saved.encoding)
      guard actual.hasBOM == saved.hasBOM, actual.text.utf16.elementsEqual(saved.text.utf16) else {
        throw NativeDocumentSeedError.invalidPair
      }
    }
    let resolved = try RestoredViewState.resolve(
      selection: NSRange(location: 0, length: 0), bookmarks: bookmarks.offsets, in: text)
    guard resolved.bookmarks == bookmarks else { throw NativeDocumentSeedError.invalidPair }
    return try .init(
      id: id, kind: .reopened, decoded: .init(text: text, encoding: encoding, hasBOM: hasBOM),
      url: url, bytes: originalBytes, saved: saved, language: language, manual: manualLanguage,
      bookmarks: bookmarks, limits: limits)
  }
  static func legacyRecovery(_ snapshot: RecoverySnapshot, limits: Limits = .standard) throws
    -> Self
  {
    try .init(
      id: snapshot.id, kind: .legacyRecovery,
      decoded: .init(text: snapshot.text, encoding: snapshot.encoding, hasBOM: snapshot.hasBOM),
      name: "Recovered "
        + (snapshot.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"),
      limits: limits)
  }
}
enum NativeDocumentSeedError: Error, Equatable { case limit, invalidPair, dirtyHistory }
