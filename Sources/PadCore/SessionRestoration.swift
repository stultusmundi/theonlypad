import Foundation

public enum RestorationSource: Equatable, Sendable {
  case recovery(RecoverySnapshot)
  case file(path: String, encoding: DocumentEncoding)
  case missingRecovery
}
public struct RestorationTab: Equatable, Sendable {
  public let metadata: SessionTab
  public let source: RestorationSource
}
public struct RestorationWindow: Equatable, Sendable {
  public let id: UUID
  public let tabs: [RestorationTab]
  public let selectedTabID: UUID?
}
public struct SessionRestorationPlan: Equatable, Sendable {
  public let windows: [RestorationWindow]
  public let recentPaths: [String]
  public var missingRecoveryIDs: [UUID] {
    windows.flatMap(\.tabs).filter { $0.source == .missingRecovery }.map { $0.metadata.id }
  }
  public var exceedsPersistenceCapacity: Bool {
    windows.count > 32 || windows.reduce(0) { $0 + $1.tabs.count } > 128
  }
  public var needsResolution: Bool { exceedsPersistenceCapacity || !missingRecoveryIDs.isEmpty }
}
public enum SessionRestorationError: Error, Equatable, LocalizedError {
  case duplicateID, invalidMetadata, limit
  public var errorDescription: String? {
    switch self {
    case .duplicateID:
      return "Session and recovery identifiers conflict. Originals remain unchanged."
    case .invalidMetadata:
      return "Session restoration metadata is invalid. Originals remain unchanged."
    case .limit:
      return
        "Session restoration exceeds its bounded capacity. Resolve the preserved session and recovery records before retrying."
    }
  }
}
public enum SessionRestoration {
  public static func plan(
    session: EditorSession?, recoveries: [RecoverySnapshot], orphanWindowID: UUID = UUID()
  ) throws -> SessionRestorationPlan {
    let session = session ?? EditorSession(windows: [])
    guard session.windows.count <= 32, recoveries.count <= 256, session.recentPaths.count <= 50
    else { throw SessionRestorationError.limit }
    guard Set(session.recentPaths).count == session.recentPaths.count else {
      throw SessionRestorationError.invalidMetadata
    }
    for path in session.recentPaths { try validatePath(path) }
    var windowIDs = Set<UUID>()
    var tabIDs = Set<UUID>()
    var tabCount = 0
    for window in session.windows {
      guard windowIDs.insert(window.id).inserted else { throw SessionRestorationError.duplicateID }
      tabCount += window.tabs.count
      guard tabCount <= 256 else { throw SessionRestorationError.limit }
      guard
        window.tabs.isEmpty
          ? window.selectedTabID == nil
          : window.tabs.contains(where: { $0.id == window.selectedTabID })
      else { throw SessionRestorationError.invalidMetadata }
      for tab in window.tabs {
        guard tabIDs.insert(tab.id).inserted else { throw SessionRestorationError.duplicateID }
        if let path = tab.originalPath { try validatePath(path) }
        do { try tab.presentation.validate() } catch {
          throw SessionRestorationError.invalidMetadata
        }
        guard tab.bookmarks.count <= 10_000 else { throw SessionRestorationError.limit }
        var previous = -1
        for mark in tab.bookmarks {
          guard mark > previous, mark <= 100_000_000 else {
            throw SessionRestorationError.invalidMetadata
          }
          previous = mark
        }
      }
    }
    guard windowIDs.isDisjoint(with: tabIDs) else { throw SessionRestorationError.duplicateID }
    var recoveryByID: [UUID: RecoverySnapshot] = [:]
    var textUnits = 0
    for snapshot in recoveries {
      guard recoveryByID[snapshot.id] == nil, !windowIDs.contains(snapshot.id) else {
        throw SessionRestorationError.duplicateID
      }
      // RecoveryStore validates these bounds. Recheck for direct callers; originalPath is never a destination.
      let count = snapshot.text.utf16.count
      guard count <= 100_000_000 - textUnits, (snapshot.originalPath?.utf16.count ?? 0) <= 4096
      else { throw SessionRestorationError.limit }
      textUnits += count
      recoveryByID[snapshot.id] = snapshot
    }
    let orphans = recoveries.filter { !tabIDs.contains($0.id) }
    guard tabCount + orphans.count <= 256 else { throw SessionRestorationError.limit }
    if !orphans.isEmpty {
      guard !windowIDs.contains(orphanWindowID), !tabIDs.contains(orphanWindowID),
        recoveryByID[orphanWindowID] == nil
      else { throw SessionRestorationError.duplicateID }
    }
    var windows = session.windows.map { window in
      RestorationWindow(
        id: window.id,
        tabs: window.tabs.map { tab in
          let source: RestorationSource
          if let snapshot = recoveryByID[tab.id] {
            source = .recovery(snapshot)
          } else if let path = tab.originalPath {
            source = .file(path: path, encoding: tab.encoding)
          } else {
            source = .missingRecovery
          }
          return RestorationTab(metadata: tab, source: source)
        }, selectedTabID: window.selectedTabID)
    }
    if !orphans.isEmpty {
      windows.append(
        RestorationWindow(
          id: orphanWindowID,
          tabs: orphans.map {
            RestorationTab(
              metadata: SessionTab(id: $0.id, encoding: $0.encoding), source: .recovery($0))
          }, selectedTabID: orphans.first?.id))
    }
    return SessionRestorationPlan(windows: windows, recentPaths: session.recentPaths)
  }
  private static func validatePath(_ path: String) throws {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4096,
      !path.utf8.contains(0),
      URL(fileURLWithPath: path).standardizedFileURL.path.utf8.elementsEqual(path.utf8)
    else { throw SessionRestorationError.invalidMetadata }
  }
}
