# Keyboard shortcuts

Development status: implemented in source and covered by core and hidden native tests. Physical keyboard delivery, alternate layouts and current packaged desktop acceptance remain unverified; see [verification](verification/keyboard-shortcuts.md).

Open **TheOnlyPad → Keyboard Shortcuts…**, or use the link in Settings. Search for a command, select its row and choose **Record**. Press a supported Command-key combination. **Disable** removes a command's shortcut; **Use Default** removes its override. Changes remain a draft until **Apply** confirms a save. Cancel closes the editor without applying draft changes.

Command letters and digits, brackets, slash, comma, equals, and Up/Down arrows are supported. Option, Control and Shift can be combined with Command. Unsupported/dead/multi-key input is refused with an explanation. Escape cancels recording; Tab cancels recording and continues normal focus navigation. Physical keyboard-layout behavior still requires validation.

Undo, Redo, Cut, Copy, Paste, Select All and Close retain their standard native bindings and are read-only. The application also reserves selected native/system combinations such as Quit, Hide and Minimize. Collision checking covers the current command catalog and the app's reservation table; it cannot discover every shortcut configured elsewhere in macOS.

Conflicts name the affected commands. Resolve the entire draft before applying; swapping two assignments is allowed when the final draft has no conflict. Overrides for unavailable extension commands remain listed and exportable, but cannot execute missing commands. If a changed command catalog conflicts with stored customizations, the app uses current defaults and keeps the saved profile with a persistent explanation. Resolve the conflict before saving a new profile.

**Import…** reads a bounded version1 JSON profile into the draft. It does not apply settings, execute commands or install extensions. Malformed or unsupported files leave the draft unchanged. Imports require an available local regular file; download a cloud-only file explicitly before retrying. **Export…** exports the complete draft, including unavailable commands, to a new filename. Existing files are never replaced. **Restore Defaults** clears the draft overrides; use Apply to save that choice.

An external change to stored settings prevents an unchecked overwrite. **Recover Stored Settings…** offers explicit reload or repair actions. If a save was not confirmed, **Verify and Retry** validates its original publication and performs a fresh save; a matching readback alone is not success. Alternatively, explicitly reload and discard the pending changes. Replacing unreadable settings requires a separate confirmation. The app refuses to quit while a shortcut operation or unconfirmed settings publication remains unresolved.

Shortcut settings use a separate versioned profile from appearance preferences. Appearance import/reset does not change shortcuts. Menus, command palette and help use the same effective command registry; changing a shortcut does not change a macro's recorded editing operation. Actual macro invocation through customized physical keys remains a desktop validation requirement.
