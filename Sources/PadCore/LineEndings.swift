import Foundation

public enum LineEnding: String, CaseIterable, Codable, Sendable {
  case lf, crlf, cr

  public var sequence: String {
    switch self {
    case .lf: return "\n"
    case .crlf: return "\r\n"
    case .cr: return "\r"
    }
  }

  public var label: String { rawValue.uppercased() }
}

public enum LineEndingDetection: Equatable, Sendable {
  case none
  case uniform(LineEnding)
  case mixed
}

/// Only ASCII CR and LF are document line endings. Other Unicode separators
/// and every other scalar remain untouched, including normalization differences.
public enum LineEndings {
  public static func detect(in text: String) -> LineEndingDetection {
    var first: LineEnding?
    var mixed = false
    walk(
      text, scalar: { _ in },
      ending: { value in
        if let first { mixed = mixed || first != value } else { first = value }
      })
    if mixed { return .mixed }
    return first.map(LineEndingDetection.uniform) ?? .none
  }

  public static func convert(_ text: String, to ending: LineEnding) -> String {
    var result = String.UnicodeScalarView()
    walk(
      text, scalar: { result.append($0) },
      ending: { _ in
        result.append(contentsOf: ending.sequence.unicodeScalars)
      })
    return String(result)
  }

  private static func walk(
    _ text: String, scalar: (Unicode.Scalar) -> Void, ending: (LineEnding) -> Void
  ) {
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    while index < scalars.endIndex {
      let value = scalars[index]
      scalars.formIndex(after: &index)
      if value.value == 13 {
        if index < scalars.endIndex, scalars[index].value == 10 {
          scalars.formIndex(after: &index)
          ending(.crlf)
        } else {
          ending(.cr)
        }
      } else if value.value == 10 {
        ending(.lf)
      } else {
        scalar(value)
      }
    }
  }
}
