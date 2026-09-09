// Appended to a temporary copy of EditorDocument.swift, never shipped.
@MainActor extension EditorDocument {
  func assertDirtyProofInvariant() {
    let current = storage.mutableString
    let baseline = savedText as NSString
    func equal(_ range: Range<Int>) {
      for index in range {
        precondition(index < current.length && index < baseline.length)
        precondition(
          current.character(at: index) == baseline.character(at: index),
          "invalid unchanged-region proof")
      }
    }
    switch dirtyProof {
    case .unknown: break
    case .aligned(let range):
      precondition(current.length == baseline.length)
      if let range {
        precondition(
          range.location >= 0 && range.length >= 0 && range.location <= current.length
            && range.length <= current.length - range.location)
        equal(0..<range.location)
        equal((range.location + range.length)..<current.length)
      } else {
        equal(0..<current.length)
      }
    case .suffix(let low):
      precondition(low >= 0 && low <= min(current.length, baseline.length))
      equal(0..<low)
    }
    if dirtyProofPoisoned {
      if case .unknown = dirtyProof {
      } else {
        preconditionFailure("poison retains no region proof")
      }
    }
  }

  var testDirtyProofIsPoisoned: Bool { dirtyProofPoisoned }
  func assertAlignedDirtyRange(_ expected: NSRange) {
    if case .aligned(let range?) = dirtyProof {
      precondition(range == expected, "empty union must not widen to zero")
    } else {
      preconditionFailure("same-length clean edit should retain aligned proof")
    }
  }
}
@MainActor enum DirtyProofMetrics {
  static var calls: [String: Int] = [:]
  static var comparisonSpanUnits = 0
  static func full(_ count: Int) {
    calls["dirty.fullCompare", default: 0] += 1
    comparisonSpanUnits += count
  }
  static func range(_ count: Int) {
    calls["dirty.rangeCompare", default: 0] += 1
    comparisonSpanUnits += count
  }
  static func reset() {
    calls = [:]
    comparisonSpanUnits = 0
  }
}
