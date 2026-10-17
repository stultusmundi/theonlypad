// SPDX-License-Identifier: MIT
// Test-only stored-state read; no validation, mutation, callback, token or native focus.
@MainActor extension EditorWindowController {
  var transferPreferredTestFacts: (phase: Int, projecting: Bool, scopedFocus: Bool) {
    let phase: Int
    switch transferProjection?.snapshot.phase {
    case nil: phase = 0
    case .reserved?: phase = 1
    case .rotated?: phase = 2
    case .staged?: phase = 3
    case .restored?: phase = 4
    }
    return (phase, projectionToken != nil, projectionFocus != nil)
  }
}

// Compatibility spelling reads only the actual stored quit flag.
@MainActor extension EditorWindowController {
  var xmlNativeTestPreparingToQuit: Bool { preparingToQuit }
}
