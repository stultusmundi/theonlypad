// Appended only to a hashed test copy, never compiled into the application.
extension RecentFilesController {
  func fixtureOpen() { openSelected() }
  func fixtureSelectPath(_ path: String) {
    if let row = paths.firstIndex(of: path) {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
  }
}
