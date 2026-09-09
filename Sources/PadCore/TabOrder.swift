import Foundation

public struct TabItem: Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var dirty: Bool
  public var pinned: Bool
  public init(id: UUID, title: String, dirty: Bool, pinned: Bool) {
    self.id = id
    self.title = title
    self.dirty = dirty
    self.pinned = pinned
  }
}
public enum TabOrderError: Error, Equatable { case duplicateID, missingItem, invalidIndex }
public enum TabOrder {
  public static func reordered(items: [UUID], moving: UUID, to index: Int) throws -> [UUID] {
    try validate(items)
    guard let source = items.firstIndex(of: moving) else { throw TabOrderError.missingItem }
    guard items.indices.contains(index) else { throw TabOrderError.invalidIndex }
    var result = items
    result.remove(at: source)
    result.insert(moving, at: index)
    return result
  }
  public static func closingOthers(items: [UUID], keeping: UUID) throws -> [UUID] {
    try validate(items)
    guard items.contains(keeping) else { throw TabOrderError.missingItem }
    return [keeping]
  }
  public static func closingRight(items: [UUID], after: UUID) throws -> [UUID] {
    try validate(items)
    guard let index = items.firstIndex(of: after) else { throw TabOrderError.missingItem }
    return Array(items.prefix(index + 1))
  }
  public static func pinnedFirst(items: [TabItem]) throws -> [TabItem] {
    try validate(items.map(\.id))
    return items.filter(\.pinned) + items.filter { !$0.pinned }
  }
  private static func validate(_ items: [UUID]) throws {
    guard Set(items).count == items.count else { throw TabOrderError.duplicateID }
  }
}
