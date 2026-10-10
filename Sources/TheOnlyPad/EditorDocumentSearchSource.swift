import Foundation
import PadCore
import SearchExecution

@MainActor
protocol ApplicationDocumentSearchSource: AnyObject {
  func inspect() throws -> DocumentSearchCredential
  func capture(expected: DocumentSearchCredential) throws -> SearchAdmissionCapture<
    DocumentSearchCredential
  >
  func isCurrent(expected: DocumentSearchCredential) -> Bool
  func select(expected: DocumentSearchCredential, source: String, range: NSRange) -> Bool
  func replace(expected: DocumentSearchCredential, source: String, replacement: String) -> Bool
}

@MainActor
final class EditorDocumentSearchSource: ApplicationDocumentSearchSource {
  private let inspectSource: @MainActor () throws -> DocumentSearchCredential
  private let captureSource:
    @MainActor (DocumentSearchCredential) throws -> SearchAdmissionCapture<DocumentSearchCredential>
  private let currentSource: @MainActor (DocumentSearchCredential) -> Bool
  private let selectSource: @MainActor (DocumentSearchCredential, String, NSRange) -> Bool
  private let replaceSource: @MainActor (DocumentSearchCredential, String, String) -> Bool

  init(
    inspect: @escaping @MainActor () throws -> DocumentSearchCredential,
    capture:
      @escaping @MainActor (DocumentSearchCredential) throws -> SearchAdmissionCapture<
        DocumentSearchCredential
      >,
    isCurrent: @escaping @MainActor (DocumentSearchCredential) -> Bool,
    select: @escaping @MainActor (DocumentSearchCredential, String, NSRange) -> Bool,
    replace: @escaping @MainActor (DocumentSearchCredential, String, String) -> Bool
  ) {
    inspectSource = inspect
    captureSource = capture
    currentSource = isCurrent
    selectSource = select
    replaceSource = replace
  }

  func inspect() throws -> DocumentSearchCredential { try inspectSource() }

  func capture(expected: DocumentSearchCredential) throws -> SearchAdmissionCapture<
    DocumentSearchCredential
  > {
    try captureSource(expected)
  }

  func isCurrent(expected: DocumentSearchCredential) -> Bool { currentSource(expected) }

  func select(expected: DocumentSearchCredential, source: String, range: NSRange) -> Bool {
    selectSource(expected, source, range)
  }

  func replace(expected: DocumentSearchCredential, source: String, replacement: String) -> Bool {
    replaceSource(expected, source, replacement)
  }
}
