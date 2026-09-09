# Encoding and line-ending controls

Status: planned. Owner: LineEndings.swift, LineEndingsTests.swift, EncodingPanelController.swift. Editor command wiring remains root-owned.

1. Add tested scalar-preserving line-ending detection for LF, CRLF, CR, mixed, and no separators. Convert only CR/LF sequences to an explicitly selected ending.
2. Add a native encoding panel with separate Convert and Reopen actions, Unicode-only BOM option, and explicit line-ending conversion. Explain that conversion changes output bytes, while reopen reinterprets existing bytes and requires discard confirmation in the caller.
3. Validate core with targeted Swift tests and panel actions with synthetic in-process AppKit integration if feasible. Never claim desktop keyboard/accessibility interaction from compilation alone.

Integration contract: `EncodingPanelController(current: DecodedDocument, onConvert: (DocumentEncoding, Bool) -> Void, onReopen: (DocumentEncoding) -> Void, onLineEnding: (LineEnding) -> Void)`. Caller validates strict `DocumentCodec.encode` before committing conversion, handles dirty/reopen confirmation, and applies line-ending edits as an undoable transaction.

## Implemented and verified

Implemented the public core types `LineEnding` (`lf`, `crlf`, `cr`, plus `sequence` and `label`), `LineEndingDetection` (`none`, `uniform`, `mixed`), `LineEndings.detect(in:)`, and `LineEndings.convert(_:to:)`. The scalar-based traversal preserves combining sequences, emoji, bidi text, trailing separators, and non-CR/LF Unicode separators exactly.

Implemented native `EncodingPanelController`, including `present(for: NSWindow)` for a modal sheet. Separate Convert/Reopen/Line Ending buttons dismiss before invoking callbacks. Legacy encodings disable and clear BOM. Current-ending detection runs off the main thread and cannot overwrite a target manually selected while detection runs. Cancel invokes no edit callbacks.

Verification:

- Tests first failed because LineEndings did not exist. Production sources and the test binary subsequently compiled. Whole-build execution was temporarily blocked by concurrent MacroLibrary/MacroManager work, so the freshly linked XCTest binary was executed with `scripts/swift.sh test --skip-build --filter LineEndingsTests`: **3 tests passed, zero failures**.
- A synthetic local AppKit harness compiled against production EncodingPanelController and PadCore. It verified conversion/reopen callbacks remain distinct, Unicode-only BOM state, explicit CR selection surviving asynchronous detection, and Cancel causing no callbacks.
- The same harness verified a real parent-window modal sheet attaches and detaches on Cancel when run with authorized desktop-session access. The sandbox-only attempt could not attach a sheet; it is not counted as success. Successful executable: `.local/spikes/encoding-panel/probe` (exit 0). No private documents or screenshots used.

Outstanding: root editor wiring, strict conversion failure handling, dirty reopen confirmation, undo integration for ending changes, encoding/endings status, and keyboard/VoiceOver workflows. Panel tests do not establish those editor-level acceptance criteria. Caller should perform line-ending conversion off the UI thread for large documents.
