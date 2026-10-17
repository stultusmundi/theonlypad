// SPDX-License-Identifier: MIT
// Frozen native Test projection only. nil always executes the original real native path.
// false is a declared refusal; true is used only by the isolated false-success negative.
@MainActor enum TransferPreferredNativeHook {
  static var beforeFocus: (@MainActor (EditorWindowController, NSResponder?) -> Bool?)?
}
