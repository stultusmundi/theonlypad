import Foundation

public enum SessionPaneAxis: String, Codable, Sendable {
  case sideBySide, stacked
}

public struct SessionScrollOrigin: Equatable, Sendable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct SessionPaneState: Equatable, Sendable {
  public let selection: NSRange
  public let scrollOrigin: SessionScrollOrigin
  public init(selection: NSRange, scrollOrigin: SessionScrollOrigin) {
    self.selection = selection
    self.scrollOrigin = scrollOrigin
  }
}

/// One logical document's bounded presentation metadata; runtime pane IDs are not persisted.
public struct SessionPresentation: Equatable, Sendable {
  public let axis: SessionPaneAxis
  public let panes: [SessionPaneState]
  public let focusedPaneIndex: Int
  public init(axis: SessionPaneAxis, panes: [SessionPaneState], focusedPaneIndex: Int) {
    self.axis = axis
    self.panes = panes
    self.focusedPaneIndex = focusedPaneIndex
  }
  public static func single(selection: NSRange) -> Self {
    Self(
      axis: .sideBySide,
      panes: [SessionPaneState(selection: selection, scrollOrigin: .init(x: 0, y: 0))],
      focusedPaneIndex: 0)
  }
  /// Rejects malformed direct values before encoding, indexing, or native conversion.
  public func validate() throws {
    guard (1...2).contains(panes.count), focusedPaneIndex >= 0,
      focusedPaneIndex < panes.count
    else { throw SessionStoreError.invalidMetadata }
    for pane in panes {
      let range = pane.selection
      guard range.location >= 0, range.location <= 100_000_000,
        range.length >= 0, range.length <= 100_000_000 - range.location,
        pane.scrollOrigin.x.isFinite, pane.scrollOrigin.y.isFinite,
        (0...1_000_000_000).contains(pane.scrollOrigin.x),
        (0...1_000_000_000).contains(pane.scrollOrigin.y)
      else { throw SessionStoreError.invalidMetadata }
    }
  }
}
