# Macro library plan

Planned: a private version-1 `Macros/Library.json` and native management window. Macro names are display metadata, never paths. Commands are the existing typed, non-executable `MacroCommand` values. The root integration owns recording and applying/cancelling replay in the editor.

1. Write real-file tests for save/load, stable identity, rename/delete, invalid names/commands, incompatible/corrupt files, and path safety. Observe the missing implementation failure.
2. Implement bounded JSON reads, strict schema validation, command/work limits, private directory/files, and atomic mutation. Validate the complete existing library before mutation so incompatible data is never overwritten.
3. Implement native list, editable name, rename/delete, repeat count, replay callback and cancellation callback. Run all I/O away from the main thread; disable editing during mutations.
4. Run `scripts/swift.sh test --filter MacroLibraryTests --scratch-path .build/macro-library`; compile the native window; record actual evidence here.

## Implemented

`MacroLibrary` provides `load`, `save`, `rename` and `delete`, with a fixed filename and metadata-only names. The complete existing version-1 library is validated before any mutation. Unknown fields/versions/commands, duplicate names, malformed data, symlinks and invalid permissions are refused. Limits are 1,000 macros, 10,000 total commands, 10 million aggregate replacement UTF-16 units and 16 MiB serialized JSON. New folder/file permissions are 0700/0600. In-process mutations are serialized; arbitrary external-process writers still have the documented POSIX comparison/rename race.

`MacroManagerController` provides the list, rename/delete controls, repeat count, replay callback, optional cancellation callback and reload. It uses a native panel to preserve the editor main window. Disk operations run on detached tasks. A reload requested during an existing operation is queued.

## Tested

On 2026-09-09, `scripts/swift.sh test --filter MacroLibraryTests --scratch-path .build/macro-library` compiled the native application and passed **8 tests, 0 failures**. Tests cover persistence, identity preservation, rename/delete, names that resemble paths, private permissions, invalid names/commands, incompatible/corrupt library preservation, unknown fields, command limits, symlink refusal and 20 concurrent saves.

The first test run failed for the missing library implementation. A later concurrency regression failed with 18 errors and one silently lost successful write; serializing library mutations within the process made the same regression pass with all 21 expected entries. An AppKit control probe also found that attaching a number formatter cleared the repeat field's initial value. Explicit numeric initialization changed the probe result from nil to NSNumber(1).

## Outstanding

Packaged GUI recording, management, repeat/replay/cancellation, focus and single-undo workflows remain for integration verification. Native compilation and the isolated control probe do not establish those end-to-end behaviors. Root owns the editor callbacks and command/menu wiring. This library does not provide cross-process transactional merging or support executable macro commands.
