# Moving a document between windows

The current development build can move the selected editable tab into an existing editor window. Open another window first, select the tab to move, then choose **File → Move Document to Window…**. Pick the destination and choose **Move**. Cancel leaves the document where it is.

The document retains its text, encoding, line endings, pin state and undo history. A move does not save or overwrite its original file. The selected destination tab becomes the moved document. The command has no default keyboard shortcut and is not recorded in macros; custom shortcuts use the normal Keyboard Shortcuts settings.

A chooser refers to the windows and ownership captured when it opened. If a window closes or the document moves elsewhere, the old choice is refused. Open the chooser again. Ordinary text edits while choosing a destination remain in the moved buffer.

If window reconstruction cannot finish, the process retains the document and unfinished move. Use **File → Retry Session Recovery Save** after the reported issue is resolved. Quit remains refused until required transfer cleanup is safe. A failure to focus a completed destination does not reverse the move.

Current limits: existing windows with one document group and editable documents only. New-window destinations, independent groups, streaming-view transfer and full desktop/IME/accessibility acceptance remain outstanding. Hidden native tests verify model, undo, file-monitor and recovery behavior; they do not prove physical focus or keyboard behavior. See [verification](verification/native-document-transfer-integration.md).
