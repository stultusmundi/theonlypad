import AppKit
import PadCore

/// Desired window policy, distinct from what each native document has actually applied.
struct WindowPresentationPolicy: Equatable {
  let fontName: String
  let fontSize: Double
  let tabWidth: Int
  let wrap: Bool
  init(_ settings: EditorSettings) {
    fontName = settings.fontName
    fontSize = settings.fontSize
    tabWidth = settings.tabWidth
    wrap = settings.wrap
  }
}
struct AppliedTypography: Equatable {
  let requestedFontName: String
  let requestedFontSize: Double
  let tabWidth: Int
  let resolvedFontName: String
  let resolvedFontSize: Double
  let defaultTabInterval: Double
}
@MainActor struct ResolvedDocumentTypography {
  let signature: AppliedTypography
  let font: NSFont
  let paragraph: NSParagraphStyle
  init(_ settings: EditorSettings) {
    font =
      settings.fontName == EditorSettings.systemMonospacedFontName
      ? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
      : NSFont(name: settings.fontName, size: settings.fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    let style = NSMutableParagraphStyle()
    style.tabStops = []
    style.defaultTabInterval =
      (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(settings.tabWidth)
    paragraph = style.copy() as! NSParagraphStyle
    signature = AppliedTypography(
      requestedFontName: settings.fontName, requestedFontSize: settings.fontSize,
      tabWidth: settings.tabWidth, resolvedFontName: font.fontName,
      resolvedFontSize: font.pointSize, defaultTabInterval: style.defaultTabInterval)
  }
}
enum NativeConfigurationError: Error { case busy, changed }
