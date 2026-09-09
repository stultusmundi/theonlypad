import AppKit

/// Builds an independent print view so pagination never changes editor layout or selection.
@MainActor enum DocumentPrinting {
  static func view(text: String, font: NSFont, printInfo: NSPrintInfo) -> NSTextView {
    let width = max(72, printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    view.isEditable = false
    view.font = font
    view.textColor = .black
    view.backgroundColor = .white
    view.string = text
    view.textContainerInset = NSSize(width: 4, height: 4)
    view.textContainer?.containerSize = NSSize(width: width - 8, height: .greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    if let manager = view.layoutManager, let container = view.textContainer {
      manager.ensureLayout(for: container)
      view.setFrameSize(
        NSSize(width: width, height: max(1, manager.usedRect(for: container).height + 8)))
    }
    return view
  }

  static func printDocument(text: String, font: NSFont, name: String) {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isVerticallyCentered = false
    let operation = NSPrintOperation(
      view: view(text: text, font: font, printInfo: info), printInfo: info)
    operation.jobTitle = name
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true
    operation.run()
  }
}
