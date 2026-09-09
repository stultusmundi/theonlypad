import Foundation

/// Resolved metadata for one logical document. No geometry, file I/O or duplicate text is retained.
public struct RestoredPresentationState: Equatable, Sendable {
  public let presentation: SessionPresentation
  public let bookmarks: DocumentBookmarks
  public let adjustedPaneIndices: [Int]
  public let invalidBookmarks: [Int]

  // Only resolve can construct this state; its presentation has a validated focused index.
  private init(
    presentation: SessionPresentation, bookmarks: DocumentBookmarks,
    adjustedPaneIndices: [Int], invalidBookmarks: [Int]
  ) {
    self.presentation = presentation
    self.bookmarks = bookmarks
    self.adjustedPaneIndices = adjustedPaneIndices
    self.invalidBookmarks = invalidBookmarks
  }
  public var focusedViewState: RestoredViewState {
    RestoredViewState(
      selection: presentation.panes[presentation.focusedPaneIndex].selection,
      bookmarks: bookmarks,
      selectionAdjusted: adjustedPaneIndices.contains(presentation.focusedPaneIndex),
      invalidBookmarks: invalidBookmarks)
  }
  public static func resolve(_ presentation: SessionPresentation, bookmarks: [Int], in text: String)
    throws -> Self
  {
    try presentation.validate()
    let context = try RestoredPositionContext(bookmarks: bookmarks, in: text)
    var adjusted: [Int] = []
    let panes = try presentation.panes.enumerated().map { index, pane in
      let selection = try context.resolve(pane.selection)
      if selection != pane.selection { adjusted.append(index) }
      return SessionPaneState(selection: selection, scrollOrigin: pane.scrollOrigin)
    }
    return Self(
      presentation: SessionPresentation(
        axis: presentation.axis, panes: panes,
        focusedPaneIndex: presentation.focusedPaneIndex), bookmarks: context.bookmarks,
      adjustedPaneIndices: adjusted, invalidBookmarks: context.invalidBookmarks)
  }
}
